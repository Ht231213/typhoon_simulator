class_name TyphoonSim
extends Node2D
## 模拟引擎：驱动台风沿路径移动、增强、登陆、消散。
##
## 时间结构沿用原 Scratch 工程的「连续积分 + 离散计日」：
##   · _physics_process 由引擎固定在 100 Hz 调用 → 对应原工程的 forever + wait(0.01)
##     这是数值稳定性的关键：原公式是开环正反馈，去掉这层节流会一路涨到几百节
##   · 每过一个模拟日（SimClock.day_advanced）做一次离散结算：气压、分级、巅峰、ACE
##
## 路径推进只是沿路径点做时间插值，不涉及任何碰撞/刚体物理。
##
## 与第一版的关系：自动模式 = 第一版的固定演示路径（起终点固定）；
## 手动模式 = 玩家自己在地图上点的路径点。两者之后的演化逻辑完全一致。

signal state_changed
signal storm_finished(record: Game.StormRecord)
signal season_finished
signal notice(text: String)

@onready var field: OceanField = $"../GridOverlay"
@onready var path: PathLayer = $"../PathLayer"

# ------------------------- 模式 -------------------------
var auto_mode := false
var season_mode := false

# ------------------------- 本局状态 -------------------------
var active_storm: Storm = null
var paused := false
var season_over := false
var wind_unit_index := 0
const WIND_UNITS: Array[String] = ["kt", "m/s", "km/h"]

# ------------------------- 音效（登陆用） -------------------------
## 登陆音效：0 = TS（热带风暴），1..5 = C1..C5
const LANDFALL_FILES: Array[String] = ["TS.wav", "c1.wav", "c2.wav", "c3.wav", "c4.wav", "c5.wav"]
var _sfx_players: Array[AudioStreamPlayer] = []


## 音效路径由「音频设置」里的预设决定（GameSettings.landfall_sfx_path）
func landfall_sfx_path(index: int) -> String:
	return GameSettings.landfall_sfx_path(index)

var _rng := RandomNumberGenerator.new()
## 风季起点（模拟日）。用已过去的天数判断是否满 12 个月，
## 而不是用月份差值——月份在跨年回绕时会漏掉一次。
## 风季起点（年内第几天）。用已过去的天数判断是否满 12 个月。
var _season_start_day := 0.0


func _ready() -> void:
	_rng.randomize()
	auto_mode = Game.auto_mode
	season_mode = Game.season_mode
	SimClock.day_advanced.connect(_on_day_advanced)
	SimClock.year_completed.connect(_on_year_completed)
	# 音效预设换了就重建播放器
	GameSettings.changed.connect(_on_settings_changed)
	_setup_sfx()
	Game.begin_session()
	paused = false
	# 风季模式下让时钟停在 12月30日 不回绕，结算时才不会漏掉跨年那一拍
	SimClock.clamp_at_year_end = season_mode
	SimClock.begin()
	_season_start_day = SimClock.sim_days()
	# 通知 UI 取一次初始状态（否则首帧按钮显隐和文字都不对）
	state_changed.emit()
	if auto_mode:
		call_deferred("deploy_auto_storm")


# ============================ 主循环 ============================

func _physics_process(delta: float) -> void:
	# 空闲加速：没有活跃台风时按 1 秒/天，有台风时按 4 秒/天。
	# ⚠ 电影模式先不加速（以后电影模式会有自己的节奏）。
	SimClock.idle_boost = active_storm == null and Game.mode != Game.Mode.CINEMATIC

	if paused or season_over or active_storm == null:
		return
	var storm := active_storm
	# 模拟时间只用来推进路径和日历（1 真实秒 = 6 模拟小时 → 1 段 1 秒）。
	var sim_delta := SimClock.days_from_seconds(delta)

	# ① 推进路径（纯时间插值）。
	#    参考在每走完一段之后才 CALL 更新ACE，所以这里也要按段结算。
	var seg_before := storm.segment
	storm.advance_track(sim_delta)
	for _i in range(storm.segment - seg_before):
		storm.settle_segment()

	# ② 位置确定了，就能查它落在哪一格、那格的海温是多少
	var pos := storm.current_world_position()
	var cell := Const.cell_index_from_world(pos)
	storm.sst_here = field.sst_at(cell) + SimClock.seasonal_sst_amplitude()
	storm.latitude = storm.current_lonlat().y

	# ③ 登陆判定
	var was_landfall := storm.landfall
	storm.landfall = field.is_land_at_world(pos)
	if storm.landfall and not was_landfall:
		_on_landfall(storm)
	# ③.1 山区判定。参考里「陆地」和「山区」是分开两个判断，
	#      山区在陆地的 −0.5 之外再扣 −1。
	storm.mountain = field.is_mountain_at_world(pos)

	# ④ 变性判定（纬度 + 海温双条件，触发后进入渐变过程）
	var was_phase := storm.phase
	storm.update_transition(sim_delta)
	if storm.phase != was_phase:
		_on_phase_changed(storm, was_phase)

	# ⑤ 风切变演进（参考里的西风带脚本）
	_update_shear(storm)

	# ⑤.1 眼壁置换状态机。必须排在强度积分**之前**，
	#      因为积分时要用到本 tick 的 erc_phase。
	_update_erc(storm, sim_delta)

	# ⑥ 强度积分：参考的「计算风速增量」+「更新台风状态」。
	#    ⚠ ΔKt 是**每个 tick 直接加的增量**，不要再乘 sim_delta、也不要再乘系数。
	#    物理帧率已设成 100 Hz，和参考的 wait(0.01) 一一对应。
	#    ⚠ 没有 MPI 上限——按你的决定删掉了，参考里也没有（能涨到几百节）。
	storm.wind_kt = maxf(0.0, storm.wind_kt + _wind_delta_rate(storm))

	# ⑦ 编号与命名（两套独立计数、两个不同阈值）
	#    Kt > 30 → 换上【热带风暴编号】0XW
	#    Kt > 33 → 从命名表取名，并从这一刻起才计入 ACE
	if storm.storm_number <= 0 and storm.wind_kt > Const.STORM_NUMBER_THRESHOLD_KT:
		storm.assign_storm_number(Game.next_storm_number())
		notice.emit("增强为热带风暴，编号 %s" % storm.number_text())

	if not storm.name_committed and storm.wind_kt > Const.NAMING_THRESHOLD_KT:
		storm.storm_name = Game.commit_storm_name()    # 到这里才真正消耗一个名字
		storm.name_committed = true
		notice.emit("%s 增强为台风，命名 %s" % [storm.number_text(), storm.storm_name])

	# ⑧ 反馈与显示
	# 冷水坑：风场搅起深层冷水，海温下降 → 反过来抑制台风自己。
	field.update_cooling(storm, cell)
	# 参考「计算海区与气压」最后一步：`replace item 对应海区 of 气压数据 with 气压`
	# 把当前中心气压写进所在格，气压图层才有东西显示。
	field.set_pressure_at(cell, storm.central_pressure)
	path.set_live_position(pos, storm.wind_kt, storm.phase as int)
	# 类别与巅峰值连续更新（参考就是在每轮循环里调的）
	storm.tick_live()

	if storm.track_done() or storm.wind_kt <= 0.5:
		_finish_storm()


## 原「计算风速增量」。返回值单位：节/天。
##
## 原「计算风速增量」。
##
## ⚠ 返回的是**每个物理 tick 直接加到 Kt 上的增量**（参考里是 `change Kt by ΔKt`），
##   不是「节/天」的速率。所以调用处**不要**再乘任何时间量，也不要再乘系数。
##   物理帧率已设成 100 Hz，和参考的 `wait(0.01)` 一一对应。
##
## 逐条照抄参考，数值与运算均未改动：
##
##   海温差 = 当前海温 - 26.5
##   效应-海温：ΔT>3.5 且不在陆地 → ΔT×0.8
##              1<ΔT<3.5         → ΔT×0.3
##              其余              → ΔT×0.8
##   效应-风切变：垂直风切变>10 → (垂直风切变−10)×−0.002，否则 0
##   效应-地转偏向力：北半球且纬度<2 → −1；南半球且纬度>−2 → −1；否则 0
##   随机扰动 = random(−0.05, 1.5)
##   类型=−4（温带气旋）：ΔKt = ((切变 + 海温×0.1 + 扰动)×0.05) + random(−0.01, 0.03)
##   其余：               ΔKt = ((切变 + (海温×2 + 0.5) + 扰动)×0.05) + random(−0.01, 0.03)
##   ΔKt += e^(−1.2·ln(月份−8.4))/12 − random(0.085, 0.09)
##   陆地（参考还有山区）：ΔKt −= 0.5
##   ΔKt += 效应-地转偏向力 × (Kt/20)
##
## 已按你的决定删掉的两项（都是我自创的，参考里没有）：
##   · `WIND_RATE_SCALE = 140` 整体标定系数
##   · MPI（海温允许的最大强度）硬上限
## 所以台风可以一路涨到几百节——参考工程自己的存档里 `巅峰风速 = 503.54`。
##
## ⚠ 山区（参考里额外 −1）暂缺：没有山区掩膜，你决定先不做。
func _wind_delta_rate(storm: Storm) -> float:
	# ① 海温效应
	var sst_diff := storm.sst_here - 26.5
	var sst_effect := 0.0
	if sst_diff > 3.5 and not storm.landfall:
		sst_effect = sst_diff * 0.8
	elif sst_diff > 1.0 and sst_diff < 3.5:
		sst_effect = sst_diff * 0.3
	else:
		sst_effect = sst_diff * 0.8

	# ② 风切变效应
	var shear_effect := 0.0
	if storm.shear > 10.0:
		shear_effect = (storm.shear - 10.0) * -0.002

	# ③ 地转偏向力。参考按**半球**分开判断：
	#    北半球看「纬度 < 2」，南半球看「−2 < 纬度」
	var coriolis_effect := 0.0
	if storm.northern:
		if storm.latitude < 2.0:
			coriolis_effect = -1.0
	else:
		if -2.0 < storm.latitude:
			coriolis_effect = -1.0

	# ④ 主体增量。参考判的是 `类型 = -4`（温带气旋）；
	#    本工程用 phase 表达（你决定保留双条件+渐变那套）。
	var noise := _rng.randf_range(-0.05, 1.5)
	var delta := 0.0
	if storm.phase != Storm.Phase.TROPICAL:
		delta = (shear_effect + sst_effect * 0.1 + noise) * 0.05
	else:
		delta = (shear_effect + (sst_effect * 2.0 + 0.5) + noise) * 0.05
	delta += _rng.randf_range(-0.01, 0.03)

	# ⑤ 季节项 `e^(-1.2·ln(月份-8.4))/12 - random(0.085, 0.09)`。
	#    ⚠ 减数是 **random(0.085, 0.09)**，不是固定值。
	#    ⚠ 月份-8.4 ≤ 0 时 ln 无定义；Scratch 的 ln 对非正数返回 0，
	#      于是 e^0 = 1、这一项取 1/12 ≈ 0.083。必须照这个语义，
	#      不能把参数夹到小的正数（那样 e 会爆成几百）。
	var season := 0.0
	var month_arg := float(SimClock.month) - 8.4
	if month_arg > 0.0:
		season = pow(2.718281828, -1.2 * log(month_arg)) / 12.0
	else:
		season = 1.0 / 12.0
	delta += season - _rng.randf_range(0.085, 0.09)

	# ⑥ 陆地摩擦与山区（参考原文）：
	#      if (touching 陆地? or touching 山区?):
	#        change ΔKt by -0.5
	#        if touching 山区?:
	#          change ΔKt by -1
	#    所以「陆地」和「山区」是分开的两个判定，山区总共扣 -1.5。
	if storm.landfall or storm.mountain:
		delta -= 0.5
		if storm.mountain:
			delta -= 1.0

	# ⑦ 科氏项
	delta += coriolis_effect * (storm.wind_kt / 20.0)

	# ⑧ 变性附加衰减。参考没有这一项（它只靠「类型=-4」走温和公式）；
	#    这是你决定保留的本工程附加项，原来按「节/天」写，
	#    现在统一成每 tick 的增量：1 模拟天 = 4 真实秒 = 400 tick。
	match storm.phase:
		Storm.Phase.TRANSITIONING:
			delta -= Const.EXTRATROPICAL_WEAKENING / 400.0
		Storm.Phase.EXTRATROPICAL:
			delta -= Const.EXTRATROPICAL_WEAKENING_DONE / 400.0
		_:
			pass

	# ⑨ MPI 软自限（B′，见 Constants 的说明）。
	#    ΔKt /= (1 + Kt/MPI)：Kt = MPI 时减半，4×MPI 时降到 1/5。
	#    ⚠ 它**永不归零**，所以台风仍然能涨到 500+，只是要更久——
	#      这是用户要的「不设硬顶、但要有遏制」。
	delta /= 1.0 + storm.wind_kt / Const.mpi_for_sst(storm.sst_here)

	# ⑩ 眼壁置换调制。放在最后，作用在完整的 ΔKt 上。
	delta = _apply_erc_modifier(storm, delta)

	return delta


## 眼壁置换对 ΔKt 的调制。三个阶段：
##   ① 外眼墙生成（FORMING）  ：内眼墙被切断水汽 → 强度基本停滞
##   ② 内眼墙崩溃（COLLAPSE） ：在这段时间里把目标跌幅扣完；**同时禁止增长**
##   ③ 新眼墙接管（RECOVERY） ：重新快速增强
func _apply_erc_modifier(storm: Storm, delta: float) -> float:
	match storm.erc_phase:
		Storm.Erc.FORMING:
			return delta * Const.ERC_FORMING_SUPPRESS
		Storm.Erc.COLLAPSE:
			# 负的照样负（登陆/变性/被切变削），正的先压成 0，再叠加崩溃跌幅
			var ticks: float = maxf(1.0, Const.ERC_COLLAPSE_DAYS * float(Const.TICKS_PER_DAY))
			var dip_rate: float = -storm.erc_dip_kt / ticks
			return minf(delta, 0.0) + dip_rate
		Storm.Erc.RECOVERY:
			# 成功 → 爆发式重新增强；失败 → 结构坏了，恢复很吃力
			var bonus: float = Const.ERC_FAIL_RECOVERY_BONUS if storm.erc_failed \
				else Const.ERC_SUCCESS_RECOVERY_BONUS
			return delta * bonus
	return delta


## 这次眼壁置换失败的概率。风切变太大 或 海温太低 → 外眼墙组织不起来。
## 两个因素各贡献一部分，相加后夹在 [0, ERC_FAIL_MAX_P]。
func _erc_fail_chance(storm: Storm) -> float:
	var by_shear: float = clampf(
		(storm.shear - Const.ERC_FAIL_SHEAR_START)
			/ maxf(1.0, Const.ERC_FAIL_SHEAR_FULL - Const.ERC_FAIL_SHEAR_START),
		0.0, 1.0) * 0.75
	var by_sst: float = clampf(
		(Const.ERC_FAIL_SST_START - storm.sst_here)
			/ maxf(0.01, Const.ERC_FAIL_SST_START - Const.ERC_FAIL_SST_FULL),
		0.0, 1.0) * 0.70
	return clampf(by_shear + by_sst, 0.0, Const.ERC_FAIL_MAX_P)


## 眼壁置换状态机。每 tick 推进一步。
##
## 触发用**倒计时**而不是「每 tick 掷骰子」：
##   以前每 tick 概率 = sim_delta / 3天，平均等 3 天，可台风 3 天就从 100 kt 涨到 170 kt，
##   于是表现成「170 kt 才置换」。现在改成强度第一次够上 ERC_MIN_KT 后只等 0.08~0.30 天。
func _update_erc(storm: Storm, sim_delta: float) -> void:
	match storm.erc_phase:
		Storm.Erc.NONE:
			# 不满足条件时倒计时**暂停**（强度掉下去就等着，涨回来再接着数）
			if storm.wind_kt < Const.ERC_MIN_KT:
				return
			if storm.phase != Storm.Phase.TROPICAL or storm.landfall:
				return
			storm.erc_wait_days -= sim_delta
			if storm.erc_wait_days > 0.0:
				return
			storm.erc_phase = Storm.Erc.FORMING
			storm.erc_days = 0.0
			storm.erc_failed = false
			storm.erc_dip_kt = 0.0
			storm.erc_count += 1
			notice.emit("%s 出现双眼墙，开始眼壁置换（第 %d 次）" % [
				storm.number_text(), storm.erc_count])

		Storm.Erc.FORMING:
			storm.erc_days += sim_delta
			if storm.erc_days >= Const.ERC_FORMING_DAYS:
				# 外眼墙生成期结束 → 判定这次能不能组织起来。
				# 风切变太大 / 海温太低 → 失败，核心结构崩溃，掉一大截。
				var chance := _erc_fail_chance(storm)
				storm.erc_failed = _rng.randf() < chance
				var frac: float = Const.ERC_FAIL_DIP_FRACTION if storm.erc_failed \
					else Const.ERC_SUCCESS_DIP_FRACTION
				storm.erc_dip_kt = storm.wind_kt * frac
				storm.erc_days = 0.0
				storm.erc_phase = Storm.Erc.COLLAPSE
				if storm.erc_failed:
					storm.erc_fail_count += 1
					notice.emit("%s 外眼墙没能组织起来，核心结构崩溃！（失败概率 %.0f%%，风切 %.0f 海温 %.1f）" % [
						storm.number_text(), chance * 100.0, storm.shear, storm.sst_here])
				else:
					notice.emit("%s 内眼墙崩溃，强度短暂下降" % storm.number_text())

		Storm.Erc.COLLAPSE:
			storm.erc_days += sim_delta
			if storm.erc_days >= Const.ERC_COLLAPSE_DAYS:
				storm.erc_phase = Storm.Erc.RECOVERY
				storm.erc_days = 0.0
				if storm.erc_failed:
					notice.emit("%s 只剩一圈残缺眼墙，恢复缓慢" % storm.number_text())
				else:
					notice.emit("%s 外眼墙接管，重新增强" % storm.number_text())

		Storm.Erc.RECOVERY:
			storm.erc_days += sim_delta
			var need: float = Const.ERC_FAIL_RECOVERY_DAYS if storm.erc_failed \
				else Const.ERC_RECOVERY_DAYS
			if storm.erc_days >= need:
				storm.erc_phase = Storm.Erc.NONE
				storm.erc_days = 0.0
				storm.erc_wait_days = _rng.randf_range(
					Const.ERC_INTERVAL_MIN, Const.ERC_INTERVAL_MAX)
				if storm.erc_failed:
					notice.emit("%s 眼壁置换失败收场（累计失败 %d 次）" % [
						storm.number_text(), storm.erc_fail_count])
				else:
					notice.emit("%s 眼壁置换完成（新眼墙更大）" % storm.number_text())


## 风切变演进。逐条照抄参考「台风中心.md」里那三个西风带脚本：
##
##   ① 每 0.1 秒 ±5 随机游走一次，然后取整
##   ② 超过 500 就夹到 500
##   ③ 按纬度分档：越过某一档就把垂直风切变**瞬间顶到**该档目标值
##      （+20→30 / +33→75 / +50→120 / +70→250 / +90→400，步长 1/2/3/4/5）
##      同时把加进去的量记进 `西风带风切`
##   ④ 退回第一档以南：把 `西风带风切` 整个扣回去并清零，结果不小于 0
##
## ⚠ 参考用的 `repeat until` 是**瞬间加满**，不是每天慢慢爬——我原来写成「每天增长」是错的。
func _update_shear(storm: Storm) -> void:
	# ① 每 0.1 秒（100 Hz → 10 个 tick）随机游走一次
	storm.shear_walk_counter += 1
	if storm.shear_walk_counter >= int(round(Const.SHEAR_WALK_INTERVAL * 100.0)):
		storm.shear_walk_counter = 0
		storm.shear += _rng.randf_range(-Const.SHEAR_WALK_STEP, Const.SHEAR_WALK_STEP)
		storm.shear = roundf(storm.shear)

	# ② 上限
	if storm.shear > Const.SHEAR_MAX:
		storm.shear = Const.SHEAR_MAX

	# ③④ 分档。从最高档往低档找，第一个满足的就是当前所在档
	var tier := -1
	for i in range(Const.SHEAR_TIER_LATITUDE.size() - 1, -1, -1):
		if storm.latitude > Const.SHEAR_TIER_LATITUDE[i]:
			tier = i
			break

	if tier >= 0:
		var target: float = Const.SHEAR_TIER_TARGET[tier]
		if storm.shear < target:
			var step: float = Const.SHEAR_TIER_STEP[tier]
			if step > 0.0:
				while storm.shear < target:
					storm.shear += step
					storm.westerly_shear += step
	else:
		# 退回西风带以南：把累计的那部分扣回去
		storm.shear -= storm.westerly_shear
		storm.westerly_shear = 0.0
		if storm.shear < 0.0:
			storm.shear = 0.0

	# 显示用的「风切」（参考里那段换算，物理计算不用）
	if storm.shear_display > 25.0:
		storm.shear_display = 25.0
	elif storm.shear < 250.0:
		storm.shear_display = roundf(storm.shear / 2.5) / 10.0
	else:
		storm.shear_display = roundf((storm.shear - 250.0) / 2.5 + 100.0) / 10.0


## 变性阶段变化时给一句提示
func _on_phase_changed(storm: Storm, _was: Storm.Phase) -> void:
	match storm.phase:
		Storm.Phase.TRANSITIONING:
			notice.emit("%s 开始变性为温带气旋" % storm.number_text())
		Storm.Phase.EXTRATROPICAL:
			notice.emit("%s 已完全变性为温带气旋" % storm.number_text())
		_:
			pass
	state_changed.emit()


func _on_day_advanced() -> void:
	if season_over:
		return
	# ⚠ ACE 不在这里结算——参考是「每走完一个路径段调一次 更新ACE」，
	#    见 _physics_process 里的段推进处。
	_check_season_end()
	# 自动模式下利用每日期结算检查冷却是否结束；不用 _process 轮询，避免占用运行时间
	if not season_over and not paused:
		_maybe_auto_deploy()
	state_changed.emit()


# ============================ 投放 ============================

## 下一场台风允许投放的模拟日。上场结束后随机冷却 5–15 天。
var next_deploy_day := 0.0


## 还要等多少模拟日才能投放下一个台风（0 表示现在就可以）
func days_until_deploy() -> float:
	return maxf(0.0, next_deploy_day - SimClock.sim_days())


func on_deploy_cooldown() -> bool:
	return days_until_deploy() > 0.0


## 是否允许投放：没有活跃台风、风季未结束、且不在冷却期
func can_deploy_now() -> bool:
	return active_storm == null and not season_over and not on_deploy_cooldown()


## 取当前该用的路径点：自动模式用内置固定路径，手动模式用玩家标好的
func _current_deploy_waypoints() -> PackedVector2Array:
	if auto_mode:
		return _build_auto_waypoints()
	return _pending_manual_waypoints


func _build_auto_waypoints() -> PackedVector2Array:
	# 与第一版一致的固定演示路径，只做整体小偏移，形状不变
	var offset := Vector2(_rng.randf_range(-30.0, 30.0), _rng.randf_range(-30.0, 30.0))
	var pts := PackedVector2Array()
	for ll in Const.DEFAULT_TRACK_LONLAT:
		var world := Const.world_from_uv(Const.uv_from_lonlat(ll.x, ll.y)) + offset
		pts.append(Vector2(
			clampf(world.x, 4.0, Const.MAP_W - 4.0),
			clampf(world.y, 4.0, Const.MAP_H - 4.0)
		))
	return pts


## 统一的投放入口。带冷却检查，成功返回 true。
func try_deploy() -> bool:
	if active_storm != null:
		notice.emit("已有一场台风在运行，等它结束再投放")
		return false
	if season_over:
		notice.emit("风季已结束")
		return false
	if on_deploy_cooldown():
		notice.emit("还需等待 %.1f 天才能投放下一场" % days_until_deploy())
		return false
	var pts := _current_deploy_waypoints()
	if pts.size() < 2:
		notice.emit("至少需要 2 个路径点")
		return false
	_start_storm(pts)
	return true


## 自动模式：直接投放下一个（内部仍走 try_deploy 的冷却检查）
func deploy_auto_storm() -> void:
	if auto_mode:
		try_deploy()


## 清场：直接丢弃当前台风，不走「停止模拟」那套编号/名称回退。
## 只给自检和标定脚本用，游戏里不要调（玩家应该用 stop_simulation）。
func discard_storm_for_test() -> void:
	active_storm = null
	path.clear_track()


## 手动模式：玩家点完路径点后调用
func deploy_manual_storm(waypoints: PackedVector2Array) -> bool:
	set_pending_waypoints(waypoints)
	return try_deploy()


func set_pending_waypoints(waypoints: PackedVector2Array) -> void:
	_pending_manual_waypoints = waypoints


var _pending_manual_waypoints := PackedVector2Array()


func _start_storm(waypoints: PackedVector2Array) -> void:
	# 生成时先拿「台风胚胎编号」（90–99 独立循环）；
	# 等增强到热带风暴级再分配「热带风暴编号」（01–99W 独立循环）。
	var storm := Storm.new(waypoints, Game.next_depression_number(), _rng.randi())
	# 名字**先留空**。只有增强到台风级（Kt > 33）才从命名表取名，
	# 在此之前信息栏的名称是空的，命名表游标也不会推进。
	storm.start_sim_day = SimClock.sim_days()
	storm.sst_here = field.sst_at(Const.cell_index_from_world(waypoints[0])) + SimClock.seasonal_sst_amplitude()
	storm.latitude = storm.current_lonlat().y
	# 参考在「开始模拟」时按起始纬度定一次半球，之后不再改
	storm.start_latitude = storm.latitude
	storm.northern = storm.latitude > 0.0
	active_storm = storm
	path.clear_track()
	path.set_live_position(waypoints[0], storm.wind_kt, storm.phase as int)
	notice.emit("已生成台风胚胎 %s" % storm.number_text())
	state_changed.emit()


## 台风「正常结束」（走完路径 / 减弱消散）。按 {1} 的规定：
##   ① 台风总计数 +1（与编号系统分开管理）
##   ② 它的 ACE 计入全年总 ACE
##   ③ 它的数据存入台风列表
## 点「停止模拟」不走这里，走 cancel_storm()，以上三项都不做。
func _finish_storm() -> void:
	if active_storm == null:
		return
	var storm := active_storm
	storm.end_sim_day = SimClock.sim_days()
	var rec := storm.to_record()
	Game.add_record(rec)                 # ② 累加 total_ace + ③ 存入列表（add_record 内部做）
	Game.storm_total += 1                # ① 台风总计数
	active_storm = null
	path.live_visible = false
	path.queue_redraw()
	# 冷却只在风季模式生效（非风季模式不显示也不需要等）
	if season_mode:
		next_deploy_day = SimClock.sim_days() + _rng.randf_range(Const.DEPLOY_COOLDOWN_MIN, Const.DEPLOY_COOLDOWN_MAX)
	storm_finished.emit(rec)
	state_changed.emit()


## 自动模式：冷却一过就自动投放下一场（由每日结算驱动，不占用游戏运行期）
func _maybe_auto_deploy() -> void:
	if auto_mode and not season_over and not paused and can_deploy_now():
		try_deploy()


# ============================ 海温反馈 ============================
# 冷却现在由 OceanField.update_cooling() 连续推进（参照工程「海区.json」的算法），
# 每 tick 调一次。这里不再保留「跨越格子时降一次温」的旧实现，避免双重降温。


# ============================ 登陆 ============================

func _on_landfall(storm: Storm) -> void:
	path.spawn_landfall_effect(storm.current_world_position(), storm.wind_kt)
	_play_landfall_sfx(storm)
	notice.emit("%s 登陆！" % storm.storm_name)
	state_changed.emit()


## 建立 6 个音效播放器（TS + C1..C5）。切换音效预设时调用 rebuild_sfx()。
func _setup_sfx() -> void:
	for player in _sfx_players:
		player.queue_free()
	_sfx_players.clear()
	for i in LANDFALL_FILES.size():
		var player := AudioStreamPlayer.new()
		player.bus = GameSettings.BUS_SFX      # 走音效总线，受音频设置里的音效音量控制
		player.volume_db = 0.0
		add_child(player)
		_sfx_players.append(player)
		var res_path := landfall_sfx_path(i)
		# 素材缺失不报错，只是不播放
		if ResourceLoader.exists(res_path):
			player.stream = load(res_path)


## 切换到音效预设后重建播放器。由 GameSettings.changed 信号触发。
func rebuild_sfx() -> void:
	_setup_sfx()


func _on_settings_changed() -> void:
	rebuild_sfx()


## 按强度选音效。参考「台风//登陆」的分支是：
##   类型 0 → ts，类型 1 → c1，类型 2 → c2 … 类型 5 → c5；类型 < 0 不播。
## 本工程的音效数组下标就是：0 = TS.wav，1..5 = c1..c5 —— 正好等于「类型」。
## 所以这里返回的就是类型本身，小于 0 表示不放。
static func Storm_category_index(kt: float) -> int:
	var cat := Const.category_from_wind(kt)
	return cat if cat >= 0 else -1


func _play_landfall_sfx(storm: Storm) -> void:
	var idx := Storm_category_index(storm.wind_kt)
	if idx < 0:
		return                       # 参考：类型 < 0 不放登陆音效
	idx = clampi(idx, 0, LANDFALL_FILES.size() - 1)
	var player := _sfx_players[idx]
	if player.stream != null:
		player.play()
	else:
		notice.emit("登陆音效缺失：%s" % landfall_sfx_path(idx).replace("res://", ""))


func sfx_missing() -> Array[String]:
	var missing: Array[String] = []
	for i in LANDFALL_FILES.size():
		var p := landfall_sfx_path(i)
		if not ResourceLoader.exists(p):
			missing.append(p)
	return missing


# ============================ 风季模式 ============================

## 时钟走完整年时触发（12月30日 → 下一年）。风季模式就靠这一拍结算。
func _on_year_completed() -> void:
	if season_mode:
		_end_season()


## 保底检查：用「已过去的天数」判断，避免任何情况下漏掉结算。
func _check_season_end() -> void:
	if not season_mode or season_over:
		return
	if _elapsed_season_days() >= float(Const.SEASON_MONTHS * Const.DAYS_PER_MONTH):
		_end_season()


func _end_season() -> void:
	if season_over:
		return
	season_over = true
	paused = true
	SimClock.clamp_at_year_end = true
	SimClock.pause()
	SimClock.idle_boost = false
	season_finished.emit()


## 本季已经过去多少天
func _elapsed_season_days() -> float:
	return SimClock.sim_days() - _season_start_day


func season_progress_text() -> String:
	if not season_mode:
		return "无限"
	var elapsed_months := int(_elapsed_season_days() / float(Const.DAYS_PER_MONTH))
	return "第 %d / %d 月" % [clampi(elapsed_months + 1, 1, Const.SEASON_MONTHS), Const.SEASON_MONTHS]


func season_progress_ratio() -> float:
	if not season_mode:
		return 0.0
	return clampf(_elapsed_season_days() / float(Const.SEASON_MONTHS * Const.DAYS_PER_MONTH), 0.0, 1.0)


# ============================ 操作 ============================

## 暂停 / 继续时间轴。
## 「暂停」只停表，不重置日期——之前这里用了会 reset 的 start()，
## 导致每次「继续」都跳回 1月1日，表现就是「日期不增加」。
func toggle_pause() -> void:
	paused = not paused
	if paused:
		SimClock.pause()
	else:
		SimClock.resume()
	state_changed.emit()


## 「停止模拟」：消除当前台风，**且不消耗编号、名称与 ACE**。
## 与 _finish_storm()（正常结束、会计入战报与 ACE）的区别就在这里。
func cancel_storm() -> void:
	if active_storm == null:
		return
	var storm := active_storm
	# 回退编号游标：这次不消耗编号
	if storm.storm_number > 0:
		Game.storm_cursor = storm.storm_number
	# 回退名称游标：这次不消耗名字
	if storm.name_committed:
		Game.rollback_storm_name()
	active_storm = null
	path.live_visible = false
	path.clear_track()
	notice.emit("已停止 %s（不计入编号 / 名称 / ACE）" % storm.number_text())
	state_changed.emit()


## 「停止模拟」：只消除当前台风（不计编号/名称/ACE），
## **不暂停时间轴**——它和「暂停时间轴」是两件事。
func stop_simulation() -> void:
	cancel_storm()
	state_changed.emit()


## 调整游戏内日期（右侧控制栏的「调整日期」）
func set_date(month: int, day: int) -> void:
	SimClock.set_date(month, day)
	state_changed.emit()


func can_deploy() -> bool:
	return active_storm == null and not season_over


func cycle_wind_unit() -> void:
	wind_unit_index = (wind_unit_index + 1) % WIND_UNITS.size()
	state_changed.emit()


func wind_unit() -> String:
	return WIND_UNITS[wind_unit_index]


# ============================ 给 UI 用的文本 ============================

func status_title() -> String:
	if season_over:
		return "风季结束"
	if paused:
		return "已暂停"
	if active_storm != null:
		return "%s  %s" % [active_storm.number_text(), active_storm.name_label()]
	return "待投放"


func status_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("模式：%s" % Game.mode_label())
	out.append("日期：%s" % SimClock.date_text())
	out.append("进度：%s" % season_progress_text())
	out.append("流速：%s" % ("空闲加速" if SimClock.is_idle_speed() else "正常"))

	# 冷却倒计时只在风季模式出现（并排放进同一行）
	if _show_cooldown() and active_storm == null and not season_over:
		var cool_text := "⏳ 还需 %.1f 天" % days_until_deploy() if on_deploy_cooldown() else "✔ 可投放"
		out.append("投放冷却：%s" % cool_text)

	# ── 台风信息：横向「标签：值」成对排布 ──
	var s := active_storm
	if s == null:
		return out
	out.append("")
	out.append("── 当前台风 ──")
	out.append("编号：%s" % s.number_text())
	out.append("名称：%s" % s.name_label())        # 未命名时这里是空的
	out.append("中心：%s" % s.latlon_text())
	out.append("强度：%s" % s.wind_text(wind_unit()))
	out.append("类别：%s" % s.category_text())
	out.append("气压：%d hPa" % int(roundf(s.central_pressure)))
	# 参考里没有「海温决定的强度上限」，所以这里也不显示「上限」了
	# （没有再夹任何上限，台风可以一路涨上去）
	out.append("海温：%.1f ℃    风切：%.1f" % [s.sst_here, s.shear_display])
	out.append("巅峰：%d kt    ACE：%.2f" % [int(roundf(s.peak_wind_kt)), s.ace])
	out.append("路径：%d / %d 段" % [s.segment, s.waypoints.size() - 1])
	match s.phase:
		Storm.Phase.TRANSITIONING:
			out.append("状态：变性中 %.0f%%" % (s.transition_progress() * 100.0))
		Storm.Phase.EXTRATROPICAL:
			out.append("状态：温带气旋（路径已变白虚线）")
		_:
			if s.landfall:
				out.append("状态：已登陆")
	return out


## 冷却只在风季模式生效。非风季模式不显示、也不需要等。
func _show_cooldown() -> bool:
	return season_mode


## F3 调试模式的输出：把所有关键数值摊开，方便定位「日期不动」这类问题。
func debug_text() -> String:
	var out := PackedStringArray()
	out.append("===== 调试 (F3) =====")
	out.append("日历：%s   年内第 %.0f 天   running=%s" % [
		SimClock.date_text(), SimClock.sim_days(), SimClock.running])
	out.append("速度：%.1f 秒/天（%s）   日累加器=%.3f" % [
		SimClock.seconds_per_day(),
		"空闲加速" if SimClock.idle_boost else "正常",
		SimClock._day_accumulator])
	out.append("风季：%s  已过 %.0f 天  上限 %d 天  结束=%s  停在年末=%s" % [
		"开" if season_mode else "关",
		_elapsed_season_days(),
		Const.SEASON_MONTHS * Const.DAYS_PER_MONTH,
		season_over, SimClock.clamp_at_year_end])
	out.append("模式：%s   暂停=%s" % [Game.mode_label(), paused])
	out.append("")
	out.append("-- 编号与计数 --")
	out.append("胚胎游标=%d  风暴游标=%d  名称游标=%d  台风总计数=%d" % [
		Game.depression_cursor, Game.storm_cursor, Game.name_cursor, Game.storm_total])
	out.append("本局场次=%d  本局总ACE=%.2f" % [Game.records.size(), Game.total_ace])
	out.append("冷却：剩余 %.1f 天（下个可投日=%.1f）  显示冷却=%s" % [
		days_until_deploy(), next_deploy_day, _show_cooldown()])

	var s := active_storm
	out.append("")
	if s == null:
		out.append("-- 当前台风：无 --")
		out.append("可投放=%s  待用路径点=%d" % [can_deploy_now(), _pending_manual_waypoints.size()])
	else:
		out.append("-- 当前台风 --")
		out.append("编号=%s  名称=%s  已命名=%s" % [s.number_text(), s.name_label(), s.name_committed])
		out.append("Kt=%.2f  气压=%.1f  类型=%d(%s)" % [
			s.wind_kt, s.central_pressure, s.category, s.category_text()])
		out.append("海温=%.2f  风切=%.1f（内部刻度 %.0f）  纬度=%.2f  半球=%s" % [
			s.sst_here, s.shear_display, s.shear, s.latitude,
			"N" if s.northern else "S"])
		out.append("眼壁置换=%s  已进行 %.2f 天  本次目标跌 %.0f kt  累计 %d 次  下次还需 %.2f 天" % [
			s.erc_text(), s.erc_days, s.erc_dip_kt, s.erc_count, s.erc_wait_days])
		out.append("MPI(B′软限)=%.0f kt  当前自限倍数=1/%.2f" % [
			Const.mpi_for_sst(s.sst_here), 1.0 + s.wind_kt / Const.mpi_for_sst(s.sst_here)])
		out.append("段=%d/%d  段内进度=%.3f  登陆=%s  变性=%s" % [
			s.segment, s.waypoints.size() - 1, s.segment_progress, s.landfall, s.category_text()])
		out.append("ACE=%.2f  巅峰=%.1f  最低气压=%.0f" % [s.ace, s.peak_wind_kt, s.min_pressure])
	out.append("======================")
	return "\n".join(out)
