class_name Storm
extends RefCounted
## 一场台风的状态。
##
## 原 Scratch 把台风的变量全摊在「台风//台风中心」这个角色上，所以同时只能有一场台风。
## 新版要「等上一个结束才能投放下一个」，所以把一场台风封成一个对象，
## 引擎只管「当前活跃的 Storm」和「已结束的战报」。
##
## 这里不做任何碰撞/刚体物理——路径就是沿路径点做时间插值，
## 强度用原工程的数值积分公式演化。

# ------------------------- 身份 -------------------------
## 台风胚胎编号（90–99 独立循环），生成时分配，之后固定不变
var depression_number := 90
## 热带风暴编号（01–99W 独立循环），达到热带风暴级时才分配，之后固定不变
var storm_number := 0

# ------------------------- 变性（热带气旋 → 温带气旋）-------------------------
## 变性阶段
enum Phase {
	TROPICAL,        ## 还是热带气旋
	TRANSITIONING,   ## 变性中（渐变过程）
	EXTRATROPICAL,   ## 已完全变性为温带气旋
}
var phase: Phase = Phase.TROPICAL
## 变性中已经过了多少模拟天（用于渐变进度）
var transition_days := 0.0
## 本次变性目标时长（天）：随 B 缩短到 0.5~0.75
var transition_target_days := Const.EXTRATROPICAL_TRANSITION_DAYS
## 失败后的冷却（天），避免每 tick 反复摇概率
var transition_cooldown := 0.0
## 非锋面 ET / 冷心消散（失败但极端环境，仍按 EX 显示并快速消散）
var cold_core_dissipate := false
## ET burst 剩余展示天数（约 1/5 概率出现短时增强）
var et_burst_days := 0.0
## 变性方向（**可逆**，用户 2026-10-30 明确要求）：
##   false = 正在「热带 → 温带」；true = 正在「温带 → 热带」（回南、海温回升时）
var reverting := false

## 兼容旧字段：是否已「完全」变性
var extratropical: bool:
	get: return phase == Phase.EXTRATROPICAL

# ------------------------- 眼壁置换循环（ERC）-------------------------
## 真实气象学里的眼壁置换：强台风外围生成第二圈眼墙 → 外眼墙收缩切断内眼墙水汽 →
## 内眼墙崩溃、强度**暂时下降** → 外眼墙接管成新眼墙 → **重新增强**，常超过原强度。
## 周期约 1~3 天，减弱阶段 6~24 小时，可反复发生。
enum Erc {
	NONE,        ## 没在置换
	FORMING,     ## 外眼墙生成中（强度停滞）
	COLLAPSE,    ## 内眼墙崩溃（强度下降）
	RECOVERY,    ## 新眼墙接管（快速重新增强）
}
var erc_phase: Erc = Erc.NONE
## 当前阶段已经过了多少模拟天
var erc_days := 0.0
## 距离下一次置换还差多少模拟天（倒计时，只在强度够的时候才走）
var erc_wait_days := 0.3
## 这次置换的目标跌幅（kt），在 COLLAPSE 阶段扣完
var erc_dip_kt := 0.0
## 这次置换是否**失败**（外眼墙没组织起来 → 核心结构崩溃）
var erc_failed := false
## 这一生经历过几次置换（战报/调试用）
var erc_count := 0
## 这一生失败过几次
var erc_fail_count := 0

## 眼壁置换阶段的中文名
func erc_text() -> String:
	var tail := "（已失败）" if erc_failed and erc_phase != Erc.NONE else ""
	match erc_phase:
		Erc.FORMING:  return "外眼墙生成"
		Erc.COLLAPSE: return "内眼墙崩溃" + tail
		Erc.RECOVERY: return ("结构崩溃后勉强恢复" if erc_failed else "新眼墙接管") + tail
	return "无"

## 是否已经不属于热带气旋了（变性中 + 已变性）
func is_non_tropical() -> bool:
	return phase != Phase.TROPICAL

## 变性进度 0..1（热带=0，完全变性=1）
func transition_progress() -> float:
	match phase:
		Phase.TROPICAL:
			return 0.0
		Phase.EXTRATROPICAL:
			return 1.0
		_:
			return clampf(transition_days / maxf(0.1, transition_target_days), 0.0, 1.0)

var storm_name := ""
## 是否已「正式命名」（消耗掉命名表里的一个名字）。
## 投放时只用 peek 预看名字填进 storm_name，此标记仍为 false；
## 等增强到台风级才置 true 并真正推进名称游标。
var name_committed := false
var start_sim_day := 0.0
var end_sim_day := 0.0


## 显示用编号：
##   未达热带风暴级 → 台风胚胎编号 9XW
##   已达热带风暴级 → 热带风暴编号 0XW
func number_text() -> String:
	if storm_number > 0:
		return "%02dW" % storm_number
	return "%dW" % depression_number


## 信息栏「名称：」后面显示什么。
## 没有正式命名时返回**空字符串**（不要写占位文字，玩家要求那里就是空的）。
func name_label() -> String:
	if not name_committed:
		return ""
	return storm_name

# ------------------------- 路径（世界坐标 = 地图像素坐标） -------------------------
var waypoints: PackedVector2Array = PackedVector2Array()
var segment := 0                      ## 当前走到第几段
var segment_progress := 0.0           ## 当前段插值进度 0..1
var _entered_new_cell := false        ## 内部标志：本 tick 是否跨过格子边界
var _rng := RandomNumberGenerator.new()

# ------------------------- 气象状态 -------------------------
var wind_kt := Const.INITIAL_WIND_KT
var central_pressure := 1011.0
var category := Const.CAT_DISTURBANCE
var sst_here := 26.5
var latitude := 0.0
var landfall := false
## 是否压在山区（1000m 以上）。参考里「touching 基础系统//山区?」
## 会在陆地 −0.5 之外再扣 −1。
var mountain := false

## 环境垂直风切变（kt），参考里的「垂直风切变」。
## 由西风带分档「瞬间顶到」目标的档位值，另外每 0.1 秒 ±5 随机游走。
var shear := 0.0
## 西风带累计加进来的风切变量。参考用它来「离开西风带时精确扣回去」。
var westerly_shear := 0.0
## 随机游走的计时（参考 `wait(0.1)`，本工程 100 Hz → 10 个 tick 一次）
var shear_walk_counter := 0
## 参考里由垂直风切变换算出的显示量「风切」，物理计算不用它
var shear_display := 0.0

## 南/北半球。参考在「开始模拟」时按**起始纬度**定一次，之后不再改：
##   `if 当前纬度 > 0: N else: S`
## 地转偏向力的判断要用它（北半球看纬度 < 2，南半球看纬度 > −2）。
var northern := true
## 投放时记录下来的起始纬度，调试面板用来核对半球判得对不对
var start_latitude := 0.0

# ------------------------- 统计 -------------------------
var ace := 0.0
var peak_wind_kt := 0.0
var peak_category := Const.CAT_UNKNOWN
var min_pressure := 9999.0


func _init(p_waypoints: PackedVector2Array, p_depression_number: int, seed_value: int = 0) -> void:
	waypoints = p_waypoints
	depression_number = p_depression_number
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()


## 达到热带风暴级时调用，分配热带风暴编号
func assign_storm_number(p_number: int) -> void:
	if storm_number <= 0:
		storm_number = p_number

# ------------------------- 位置 -------------------------

func current_world_position() -> Vector2:
	if waypoints.is_empty():
		return Vector2.ZERO
	if waypoints.size() == 1:
		return waypoints[0]
	var i: int = clampi(segment, 0, waypoints.size() - 1)
	var j: int = mini(i + 1, waypoints.size() - 1)
	return waypoints[i].lerp(waypoints[j], segment_progress)


func current_lonlat() -> Vector2:
	return Const.lonlat_from_uv(Const.uv_from_world(current_world_position()))


func track_done() -> bool:
	if waypoints.size() < 2:
		return true
	return segment >= waypoints.size() - 1 and segment_progress >= 1.0


## 按经过的模拟天数推进路径。
## 相邻两个路径点之间代表 6 小时的移动（原工程：1 秒走完一段）。
func advance_track(days: float) -> void:
	if waypoints.size() < 2:
		return
	# 一段 = Const.HOURS_PER_SEGMENT 小时 → 折算成天
	var seg_days: float = Const.HOURS_PER_SEGMENT / 24.0
	segment_progress += days / seg_days
	while segment_progress >= 1.0 and segment < waypoints.size() - 1:
		segment_progress -= 1.0
		segment += 1
		_entered_new_cell = true
	if segment >= waypoints.size() - 1:
		segment_progress = minf(segment_progress, 1.0)


func consume_cell_change() -> bool:
	var v := _entered_new_cell
	_entered_new_cell = false
	return v

# ------------------------- 段结算 -------------------------

## 每走完一个路径段结算一次。
## ⚠ 参考是在 glide 循环里、每段结束后调一次 `更新ACE`
##（`glide 1s` → `change 路径点数运算用计数 by 1` → `CALL 更新ACE`），
## 所以 ACE 既不是每 tick 也不是每天，而是**每段一次**。
func settle_segment() -> void:
	_update_ace()


## 每个物理 tick 调用。原工程的「计算风速增量」每轮循环都要读类别，
## 气压/类别/巅峰值在循环里也是连续算的——所以这三项连续更新，
## 否则遇到较短的路径（总时长不到 4 秒一"天"）会一次结算都跑不到，
## 战报就会是 0Kt / 9999mB。
func tick_live() -> void:
	_update_pressure()
	_update_category()
	_record_peak()


## 原「计算海区与气压」。
## 严格照参考：三段式，且下限是「小于 0 才归零」，不是夹到某个最小值。
func _update_pressure() -> void:
	var kt_sq := wind_kt * wind_kt
	var p := 0.0
	if wind_kt < 65.0:
		p = 1013.0 - 0.006 * kt_sq
	elif wind_kt < 120.0:
		p = 1013.0 - 0.005 * kt_sq
	else:
		p = 1013.0 - 0.0042 * kt_sq
	p = roundf(p)
	# 用户 2026-11-06：气压公式保持参考三段式（风速本身也不合理，就不单独改了）；
	# 仅保留边界防 0/负数。
	p = clampf(p, 871.0, 1010.0)
	central_pressure = p


## 原「更新ACE」。
## 参考原文：`if (-1 < 巅峰强度)` —— 也就是「类型 >= 0」时才累计，
## 对应 Kt > 33（热带扰动/热带低压/热带风暴以下一律不计）。
## ⚠ 参考是在 glide 循环里每个路径段调一次，不是每 tick，也不是每天。
func _update_ace() -> void:
	if peak_category >= Const.CAT_NAMED:
		ace += roundf(wind_kt * wind_kt / 100.0) / 100.0


## 原「检测类型」。
## 温带变性连续指数 B（研究文档 10 号 §6.1）：
##   B = 0.50·clamp((lat−28)/14) + 0.30·clamp((26.5−SST)/3.5) + 0.20·clamp((shear−10)/20)
## 等效「30~42°N 动态触发」：夏天偏北、秋冬偏南（SST/切变随季节变化）。
func transition_index() -> float:
	return 0.50 * clampf((latitude - 28.0) / 14.0, 0.0, 1.0) \
		+ 0.30 * clampf((26.5 - sst_here) / 3.5, 0.0, 1.0) \
		+ 0.20 * clampf((shear_display - 10.0) / 20.0, 0.0, 1.0)


## 变回热带（TT）的苛刻条件（研究 §4：现实极罕见）
func _tt_conditions_met() -> bool:
	return sst_here >= Const.TT_SST_MIN and latitude < Const.TT_LAT_MAX \
		and shear_display < Const.TT_SHEAR_MAX


## 变性推进（用户 2026-11-06 按真实气象重做）：
##   触发 = 连续指数 B ≥ 0.65（不再是纬度 AND 海温硬门槛）
##   成功率 = clamp(0.30+0.70·B_norm, 0.15, 0.95) × gate(kt)
##   时长   = 0.5~0.75 天（B 越高越快），回退 = ×2.5
##   失败   = 继续热带减弱；B≥0.85 时走「非锋面 ET / 冷心消散」（仍显示 EX）
func update_transition(days: float) -> void:
	var b := transition_index()
	var gate := 0.0
	if wind_kt >= 34.0:
		gate = 1.0
	elif wind_kt >= Const.TRANSITION_MIN_KT:
		gate = 0.5
	if transition_cooldown > 0.0:
		transition_cooldown = maxf(0.0, transition_cooldown - days)
	var rev: float = Const.EXTRATROPICAL_REVERT_DAYS
	match phase:
		Phase.TROPICAL:
			if b >= Const.TRANSITION_B_START and gate > 0.0 and transition_cooldown <= 0.0:
				var bnorm := clampf((b - 0.5) / 0.5, 0.0, 1.0)
				var p := clampf(0.30 + 0.70 * bnorm, 0.15, 0.95) * gate
				if _rng.randf() <= p:
					phase = Phase.TRANSITIONING
					reverting = false
					transition_days = 0.0
					transition_target_days = clampf(Const.EXTRATROPICAL_TRANSITION_DAYS - 0.08 * bnorm, 0.15, Const.EXTRATROPICAL_TRANSITION_DAYS)
				elif b >= Const.TRANSITION_STRONG_B:
					# 非锋面 ET / 冷心消散：环境极强但失败 → 仍显示 EX，快速消散
					phase = Phase.EXTRATROPICAL
					cold_core_dissipate = true
					transition_days = 0.0
				else:
					transition_cooldown = 0.5
		Phase.TRANSITIONING:
			var fwd := maxf(0.1, transition_target_days)
			if _tt_conditions_met():
				# 只有苛刻的 TT 条件才允许回热带
				if not reverting:
					var progress := clampf(transition_days / fwd, 0.0, 1.0)
					reverting = true
					transition_days = (1.0 - progress) * rev
				transition_days -= days
				if transition_days <= 0.0:
					phase = Phase.TROPICAL
					transition_days = 0.0
					reverting = false
			else:
				if reverting:
					var progress2 := 1.0 - clampf(transition_days / rev, 0.0, 1.0)
					reverting = false
					transition_days = progress2 * fwd
				if b >= Const.TRANSITION_B_KEEP or transition_days > 0.0:
					transition_days += days
				if transition_days >= fwd:
					phase = Phase.EXTRATROPICAL
					transition_days = 0.0
					reverting = false
					_maybe_et_burst()
		Phase.EXTRATROPICAL:
			if _tt_conditions_met():
				phase = Phase.TRANSITIONING
				reverting = true
				transition_days = rev


## ET burst（研究 §5）：约 1/5 变性后出现 6~12 小时 +5~15% 短时增强
func _maybe_et_burst() -> void:
	if _rng.randf() < 0.20:
		wind_kt *= _rng.randf_range(1.05, 1.15)
		et_burst_days = _rng.randf_range(0.05, 0.1)
		transition_days = 0.0


func _update_category() -> void:
	if phase != Phase.TROPICAL:
		category = Const.CAT_EXTRATROPICAL
		return
	category = Const.category_from_wind(wind_kt)


## 原「记录巅峰状态」
func _record_peak() -> void:
	peak_wind_kt = maxf(peak_wind_kt, wind_kt)
	peak_category = maxi(peak_category, category)
	min_pressure = minf(min_pressure, central_pressure)

# ------------------------- 输出 -------------------------

func to_record() -> Game.StormRecord:
	var rec := Game.StormRecord.new()
	rec.storm_name = storm_name
	rec.number_text = number_text()
	rec.peak_wind_kt = peak_wind_kt
	rec.min_pressure = min_pressure
	rec.ace = ace
	rec.start_day = start_sim_day
	rec.end_day = end_sim_day
	return rec


func wind_text(unit := "kt") -> String:
	match unit:
		"m/s":
			return "%d m/s" % int(roundf(wind_kt * 0.514))
		"km/h":
			return "%d km/h" % int(roundf(wind_kt * 0.514 * 3.6))
		_:
			return "%d kt" % int(roundf(wind_kt))


## 经纬度文本，南半球用 S
func latlon_text() -> String:
	var ll := current_lonlat()
	var ns := "N" if ll.y >= 0.0 else "S"
	var ew := "E" if ll.x >= 0.0 else "W"
	return "%.1f°%s  %.1f°%s" % [absf(ll.y), ns, absf(ll.x), ew]


## 类别文本。变性中 / 已变性会替换掉热带气旋分级。
func category_text() -> String:
	match phase:
		Phase.TRANSITIONING:
			return "变性中"
		Phase.EXTRATROPICAL:
			return "温带气旋"
	return Const.category_label(category)
