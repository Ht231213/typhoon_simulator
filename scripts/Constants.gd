extends Node
## 全局数据表与仿真参数（autoload 单例，代码里用 Const.XXX 访问）。
##
## 这里所有数值都从原 Scratch 工程的 project.json 里逐字提取，未做任何四舍五入，
## 方便你对照 docs/ 里的分析文档逐项核对。

# ============================ 仿真基础节拍 ============================
# 这些值**从配置文件读**（`config/simulation.cfg`），不在代码里写死。
#
#   ① 打包在游戏里的默认值：`res://config/simulation.cfg`
#   ② 导出后想调参：把同名文件放到 **exe 同目录** 下的 `simulation.cfg`，会覆盖 ①
#
# 和玩家设置（`user://settings.cfg`：音量 / 全屏）是**完全分开**的两套东西：
# 那份是运行时由玩家改的，这份是设计参数、随游戏发布。
#
# 背景：参考工程用 `wait(0.01)` 推进强度循环，名义 100 Hz，
# 但 Scratch / TurboWarp 默认只有 30 fps，`wait(0.01)` 实际约 1 帧 —— 真实速率是 30 次/秒。
# 按 100 Hz 照搬会把每模拟日的增量放大 3.33 倍。（用户 2026-10-15 指出）
const SIM_CONFIG_RES_PATH := "res://config/simulation.cfg"
const SIM_CONFIG_EXE_NAME := "simulation.cfg"

## 物理帧率（Hz）。启动时读配置 → 写进 `Engine.physics_ticks_per_second`。
var physics_ticks_per_second := 30
## 1 模拟日 = 多少真实秒
var SECONDS_PER_DAY := 4.0
## 无活跃台风时的空闲加速：1 模拟日 = 多少真实秒
var SECONDS_PER_DAY_IDLE := 1.0
## 1 真实秒 = 多少模拟小时（由 SECONDS_PER_DAY 反推）
var SIM_HOURS_PER_REAL_SECOND := 6.0

## 下面几个由上面的值派生，见 `_sync_tick_rate()`
var TICKS_PER_SECOND := 30
var TICKS_PER_DAY := 120

## 真正生效的配置文件路径（启动时会打到控制台）
var sim_config_source := "（内置默认值）"


func _ready() -> void:
	_load_sim_config()
	_load_sst_data()
	_sync_tick_rate()


## 读 `config/sst.txt` 里的 192 个基础海温值。
## 支持 exe 同目录覆盖（导出后想换海温，放个同名文件到 exe 旁边就行）。
##
## ⚠ 和 `_read_sim_cfg` 一样要**手动剥 BOM**：用户拿记事本或 PowerShell 存过的
##   文件很容易带 UTF-8 BOM，直接按字节解析会把第一个数字读坏。
func _load_sst_data() -> void:
	var path := SST_DATA_RES_PATH
	var over := OS.get_executable_path().get_base_dir().path_join(SST_DATA_EXE_NAME)
	if FileAccess.file_exists(over):
		path = over
	sst_data_source = path

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[Const] 打不开海温数据：%s（将全部按 26.5℃ 处理）" % path)
		BASE_SST = []
		for i in CELL_COUNT:
			BASE_SST.append(26.5)
		return
	var text := f.get_as_text()
	f.close()
	if text.begins_with("\uFEFF"):
		text = text.substr(1)

	# 去掉每行的 `#` 注释，剩下的按空白切
	var clean := ""
	for raw_line in text.split("\n"):
		var line: String = raw_line
		var hash_at := line.find("#")
		if hash_at >= 0:
			line = line.substr(0, hash_at)
		clean += line + " "

	var vals: Array[float] = []
	for tok in clean.replace("\t", " ").split(" ", false):
		var t: String = tok.strip_edges()
		if t.is_valid_float():
			vals.append(t.to_float())

	if vals.size() != CELL_COUNT:
		push_error("[Const] 海温数据应有 %d 项，实际读到 %d 项：%s" % [
			CELL_COUNT, vals.size(), path])
	# 补齐 / 截断，保证后面任何下标都不会越界
	while vals.size() < CELL_COUNT:
		vals.append(26.5)
	if vals.size() > CELL_COUNT:
		vals.resize(CELL_COUNT)
	BASE_SST = vals
	print("[Const] 海温数据：%s（%d 项）" % [sst_data_source, BASE_SST.size()])


## 读 `config/simulation.cfg`，没有就用代码里的默认值。
## exe 同目录下的 `simulation.cfg` 优先，方便导出后调参。
func _load_sim_config() -> void:
	var base := _read_sim_cfg(SIM_CONFIG_RES_PATH)
	var base_ok := base.has_section("timing")

	var over_path := OS.get_executable_path().get_base_dir().path_join(SIM_CONFIG_EXE_NAME)
	var over := _read_sim_cfg(over_path)
	var over_ok := over.has_section("timing")

	if over_ok:
		sim_config_source = over_path
	elif base_ok:
		sim_config_source = SIM_CONFIG_RES_PATH

	physics_ticks_per_second = int(_cfg_num(base, base_ok, over, over_ok,
		"physics_ticks_per_second", physics_ticks_per_second))
	SECONDS_PER_DAY = _cfg_num(base, base_ok, over, over_ok,
		"seconds_per_day", SECONDS_PER_DAY)
	SECONDS_PER_DAY_IDLE = _cfg_num(base, base_ok, over, over_ok,
		"seconds_per_day_idle", SECONDS_PER_DAY_IDLE)
	COOLING_APPLY_INTERVAL_SECONDS = _cfg_num(base, base_ok, over, over_ok,
		"cooling_apply_interval_seconds", COOLING_APPLY_INTERVAL_SECONDS)
	SHEAR_WALK_INTERVAL = _cfg_num(base, base_ok, over, over_ok,
		"shear_walk_interval_seconds", SHEAR_WALK_INTERVAL)

	# 陆地海温（[ocean] 段）——台风在陆地上时海温按这个值算，见 TyphoonSim ①
	LAND_SST = _cfg_num_in(base, base_ok, over, over_ok,
		"ocean", "land_sst", LAND_SST)
	# 浅海热库上限（[ocean] 段）
	SHELF_CAP_100 = _cfg_num_in(base, base_ok, over, over_ok,
		"ocean", "shelf_cap_100m", SHELF_CAP_100)
	SHELF_CAP_50 = _cfg_num_in(base, base_ok, over, over_ok,
		"ocean", "shelf_cap_50m", SHELF_CAP_50)
	SHELF_CAP_20 = _cfg_num_in(base, base_ok, over, over_ok,
		"ocean", "shelf_cap_20m", SHELF_CAP_20)
	SHELF_EXCESS_PULL = _cfg_num_in(base, base_ok, over, over_ok,
		"ocean", "shelf_excess_pull", SHELF_EXCESS_PULL)
	# 超顶超增长抑制（[intensity] 段）
	SUPER_LIMIT_KT = _cfg_num_in(base, base_ok, over, over_ok,
		"intensity", "super_limit_kt", SUPER_LIMIT_KT)
	SUPER_RAMP_KT = _cfg_num_in(base, base_ok, over, over_ok,
		"intensity", "super_ramp_kt", SUPER_RAMP_KT)
	# 陆地指数衰减（[ocean] 段）
	LAND_DECAY_BG_KT = _cfg_num_in(base, base_ok, over, over_ok,
		"ocean", "land_decay_bg_kt", LAND_DECAY_BG_KT)
	LAND_DECAY_TAU_PLAIN = _cfg_num_in(base, base_ok, over, over_ok,
		"ocean", "land_decay_tau_plain", LAND_DECAY_TAU_PLAIN)
	LAND_DECAY_TAU_MOUNTAIN = _cfg_num_in(base, base_ok, over, over_ok,
		"ocean", "land_decay_tau_mountain", LAND_DECAY_TAU_MOUNTAIN)
	LAND_DECAY_TAU_MOUNTAIN2500 = _cfg_num_in(base, base_ok, over, over_ok,
		"ocean", "land_decay_tau_mountain2500", LAND_DECAY_TAU_MOUNTAIN2500)

	# 夹到合理范围，避免配置文件写错把游戏搞崩
	physics_ticks_per_second = clampi(physics_ticks_per_second, 1, 1000)
	SECONDS_PER_DAY = clampf(SECONDS_PER_DAY, 0.1, 600.0)
	SECONDS_PER_DAY_IDLE = clampf(SECONDS_PER_DAY_IDLE, 0.05, SECONDS_PER_DAY)
	COOLING_APPLY_INTERVAL_SECONDS = clampf(COOLING_APPLY_INTERVAL_SECONDS, 0.01, 60.0)
	SHEAR_WALK_INTERVAL = clampf(SHEAR_WALK_INTERVAL, 0.01, 60.0)
	# ⚠ 上限别卡到 10 —— 默认值 26.5 就是「海温项归零」的意思，卡 10 会被夹掉
	LAND_SST = clampf(LAND_SST, -30.0, 40.0)
	# 浅海上限：必须单调（越浅上限越低），且不能为负
	SHELF_CAP_100 = clampf(SHELF_CAP_100, 0.0, 1000.0)
	SHELF_CAP_50 = clampf(SHELF_CAP_50, 0.0, SHELF_CAP_100)
	SHELF_CAP_20 = clampf(SHELF_CAP_20, 0.0, SHELF_CAP_50)
	SHELF_EXCESS_PULL = clampf(SHELF_EXCESS_PULL, 0.0, 0.1)
	# 陆地指数衰减：τ 必须为正且单调（越高越短）
	LAND_DECAY_BG_KT = clampf(LAND_DECAY_BG_KT, 0.0, 60.0)
	LAND_DECAY_TAU_PLAIN = clampf(LAND_DECAY_TAU_PLAIN, 1.0, 500.0)
	LAND_DECAY_TAU_MOUNTAIN = clampf(LAND_DECAY_TAU_MOUNTAIN, 1.0, LAND_DECAY_TAU_PLAIN)
	LAND_DECAY_TAU_MOUNTAIN2500 = clampf(LAND_DECAY_TAU_MOUNTAIN2500, 1.0,
		LAND_DECAY_TAU_MOUNTAIN)
	# 超顶超：门槛要大于 0，ramp 要大于 0（否则除零）
	SUPER_LIMIT_KT = clampf(SUPER_LIMIT_KT, 50.0, 600.0)
	SUPER_RAMP_KT = clampf(SUPER_RAMP_KT, 1.0, 600.0)

	SIM_HOURS_PER_REAL_SECOND = 24.0 / SECONDS_PER_DAY
	print("[Const] 仿真节拍配置：%s" % sim_config_source)
	print("[Const] 帧率=%d Hz  1 模拟日=%.2f 秒  空闲=%.2f 秒  降温间隔=%.2f 秒  风切游走=%.2f 秒  陆地海温=%.1f℃" % [
		physics_ticks_per_second, SECONDS_PER_DAY, SECONDS_PER_DAY_IDLE,
		COOLING_APPLY_INTERVAL_SECONDS, SHEAR_WALK_INTERVAL, LAND_SST])
	print("[Const] 超顶超抑制：超过 %.0f kt 后增长额外除以 1+(Kt−%.0f)/%.0f" % [
		SUPER_LIMIT_KT, SUPER_LIMIT_KT, SUPER_RAMP_KT])


## 读一个 .cfg 并解析。**手动读文本再 parse**，不要直接用 `ConfigFile.load()`：
##
## ⚠ `ConfigFile.load()` 遇到 **UTF-8 BOM** 会返回 OK 但解析出**空段**
##   （实测 `get_sections()` 只拿到 `[""]`，`has_section("timing")` 为 false）。
##   用户拿记事本 / PowerShell 存过的文件很容易带 BOM，那样配置会**静默失效**、
##   悄悄退回代码默认值，很难查。这里统一剥掉 BOM 再解析。
func _read_sim_cfg(path: String) -> ConfigFile:
	var cfg := ConfigFile.new()
	if not FileAccess.file_exists(path):
		return cfg
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[Const] 打不开配置文件：%s" % path)
		return cfg
	var text := f.get_as_text()
	f.close()
	if text.begins_with("\uFEFF"):
		text = text.substr(1)
	var err := cfg.parse(text)
	if err != OK:
		push_warning("[Const] 配置文件解析失败（错误码 %d）：%s" % [err, path])
	return cfg


## 取一个配置值：[timing] 段。exe 旁边的覆盖文件优先，其次内置文件，最后用代码默认值
func _cfg_num(base: ConfigFile, base_ok: bool, over: ConfigFile, over_ok: bool,
		key: String, fallback: float) -> float:
	return _cfg_num_in(base, base_ok, over, over_ok, "timing", key, fallback)


## 取一个配置值（指定段）
func _cfg_num_in(base: ConfigFile, base_ok: bool, over: ConfigFile, over_ok: bool,
		section: String, key: String, fallback: float) -> float:
	if over_ok and over.has_section_key(section, key):
		return float(over.get_value(section, key))
	if base_ok and base.has_section_key(section, key):
		return float(base.get_value(section, key))
	return fallback


## 把配置里的帧率真正应用到引擎，并同步所有「按 tick 计数」的派生量。
## ⚠ 必须在任何节点跑 _physics_process 之前调用（Const 是第一个 autoload，安全）。
func _sync_tick_rate() -> void:
	Engine.physics_ticks_per_second = physics_ticks_per_second
	TICKS_PER_SECOND = maxi(1, physics_ticks_per_second)
	TICKS_PER_DAY = maxi(1, int(round(SECONDS_PER_DAY * float(TICKS_PER_SECOND))))
	# 每个 tick 代表多少模拟小时（陆地指数衰减要用）
	HOURS_PER_TICK = 24.0 / float(TICKS_PER_DAY)
	COOLING_APPLY_INTERVAL_TICKS = maxi(1, int(round(
		COOLING_APPLY_INTERVAL_SECONDS * float(TICKS_PER_SECOND))))

# ============================ 地图与网格 ============================
## 地图逻辑尺寸（世界坐标）。WPAC.png 原始是 3000x2400，比例 1.25，这里按比例缩小。
const MAP_W := 1080.0
const MAP_H := 864.0
const MAP_ASPECT := MAP_W / MAP_H          # 1.25

const COLS := 16
const ROWS := 12
const CELL_W := MAP_W / COLS               # 67.5 px
const CELL_H := MAP_H / ROWS               # 72 px
const CELL_COUNT := COLS * ROWS            # 192

## WPAC.png 覆盖的地理范围。
##
## ⚠ 2026-10-11 校正：**比例尺原来是错的（小了 25%）**
##   旧值来自用户给的基准点（100°E=x80.5、120°E=x242.5、0°=y567、20°N=y405 …），
##   那批点是在一张 **810×648**（= 1080×864 的 75%）的图上量的，所以整批都小了 0.75 倍：
##       用户值 567 / 405 / 243 / 81   vs   真值 756 / 540 / 324 / 108   （比值正好 0.75）
##       用户值 8.1 像素/度             vs   真值 10.8 像素/度            （比值正好 0.75）
##
##   真值是从 **WPAC.png 自己印的经纬网标签**上直接读出来的（逐条交叉验证）：
##       印线在原图 y≈300  → 世界 108    →  60°N
##       印线在原图 y≈600  → 世界 216    →  50°N
##       印线在原图 y≈900  → 世界 324    →  40°N
##       印线在原图 y≈1200 → 世界 432    →  30°N
##     印线间距恒为 300 原图像素 = 10° → 30 原图像素/度 → **世界 10.8 像素/度**
##     外推：赤道在原图 y=2100 → **世界 y=756**；图幅 = 100°经 × 80°纬
##
##   旁证：按 10.8 算，16 列格子宽 67.5÷10.8 = 6.25°，与参考工程
##   `go to x:(-225+(列号*30))` 在 4.8 像素/度下的 30px = 6.25° 完全一致。
const GEO_LON_MIN := 90.06
const GEO_LON_MAX := 190.06
const GEO_LAT_MIN := -10.0
const GEO_LAT_MAX := 70.0
## 赤道在世界坐标里的 y（= 756）。纬度换算的唯一基准。
const EQUATOR_WORLD_Y := 756.0
## 1° 对应多少世界像素（= 30 原图像素/度 × 0.36）
const PX_PER_DEGREE := 10.8

## 台风活跃纬度上限。超过这里（且海温也够低）就开始向温带气旋变性。
const TYPHOON_LAT_LIMIT := 45.0
## 海温低于这个值才算具备变性条件（与纬度组成双条件）
const EXTRATROPICAL_SST_THRESHOLD := 24.0
## 变性过程持续多少模拟天（渐变：热带 → 变性中 → 温带气旋）
const EXTRATROPICAL_TRANSITION_DAYS := 2.0

# ------------------------- 西风带 / 风切变 -------------------------
## 台风越过西风带纬度就开始受中纬西风影响（风切变上升、逐渐变性）。
## 常量本体在下面（WESTERLY_LATITUDE，值 39.89，由地图上 y=243 那条线换算而来）。
##
## 参考「台风中心.md」里那个西风带脚本判的是 y 坐标：
##   `y position > (4.8 × 西风带纬度 − 144) + offset`，offset = 20/33/50/70/90
## 本工程手上只有纬度，用 `纬度 = (y + 107) / 4.8` 反解：
##   纬度门限 = 西风带纬度 − 37/4.8 + offset/4.8
## 常数项 39.89473684210526 − 37/4.8 = 32.18640350877193
const SHEAR_TIER_LATITUDE: Array[float] = [
	36.3531,   # offset 20 → 越过这里，风切变顶到 30
	39.0614,   # offset 33 → 75
	42.6031,   # offset 50 → 120
	46.7697,   # offset 70 → 250
	50.9364,   # offset 90 → 400
]
## 每一档把垂直风切变「直接顶到」的值。
## ⚠ 参考用的是 `repeat until not(垂直风切变 < 目标)`，也就是**瞬间加满**，不是每天慢慢爬。
const SHEAR_TIER_TARGET: Array[float] = [30.0, 75.0, 120.0, 250.0, 400.0]
## 每一档加满时每次的步长（参考：+1 / +2 / +3 / +4 / +5），与上面同序
const SHEAR_TIER_STEP: Array[float] = [1.0, 2.0, 3.0, 4.0, 5.0]
## 风切变硬上限（参考：`if 垂直风切变 > 500: set 垂直风切变 = 500`）
const SHEAR_MAX := 500.0

# ============================ 强度自限（B′ + 眼壁置换）============================
# 背景：参考的 ΔKt 公式里**没有任何与 Kt 有关的负反馈**（唯一相关的是地转项 Kt/20），
# 所以只要暖池正效应 > 0，就以恒定的 ≈ +34 kt/秒 一路涨，没有任何东西能让它慢下来。
# 实测：Kt = 40 / 120 / 300 / 400 时 ΔKt 都是 +0.347/tick。
# 参考工程自己的存档里 `巅峰风速 = 503.54`，说明它本来就这样。
# 用户 2026-10-15 决定：不设硬顶（要大数值），改用下面两套「软」机制。

## （`TICKS_PER_SECOND` / `TICKS_PER_DAY` 定义在文件顶部「仿真基础节拍」一节，
##   由 `config/simulation.cfg` + `_sync_tick_rate()` 算出，别在这里再声明。）

# ------------------------- B′：MPI 软自限 -------------------------
## 海温 → 潜在最大强度（kt）。26.5℃ 基准给 100 kt，每升 1℃ 加 20 kt。
## 取 30.0 做地板，避免低海温算出负数。
## 用法：ΔKt /= (1 + Kt/MPI)。Kt = MPI 时减半，Kt = 4×MPI 时降到 1/5，
## **永不归零**，所以仍然能涨到大数值，只是越来越慢。
static func mpi_for_sst(sst: float) -> float:
	return maxf(30.0, 100.0 + (sst - 26.5) * 20.0)

# ------------------------- 海温效应（原参考「效应-海温」）-------------------------
# 参考原文是三段分支（ΔT = 当前海温 − 26.5）：
#     ΔT > 3.5 且不在陆地 → ΔT × 0.8
#     1.0 < ΔT < 3.5      → ΔT × 0.3
#     其余                → ΔT × 0.8
#
# ⚠ 这个写法有两个**断崖**（严格大于号，台阶实际落在 27.5→27.6 和 29.9→30.0 这两步上，
#   实测扫过一遍，见 task-2 的曲线测试）：
#     27.5℃ → 0.80   27.6℃ → 0.33   （一步掉了 0.47）
#     29.9℃ → 1.02   30.0℃ → 2.80   （一步涨了 2.75 倍）
#   后果不只是数值难看，而是**方向错了**：夏季近岸浅水常 >30℃ 走强支、
#   开阔洋面 29~30℃ 走弱支 → **近岸比外海更适合增强**，与实际相反
#   （用户实测 8-9 月近岸 150 kt → 180 kt）。
#
# 改法（Lead 2026-10-16 定的规格，task-2）：保留「暖池才爆发」的设计意图，
# 但把台阶换成**平滑门限**：
#     系数 = 0.3 + 0.5 × smoothstep(26.5, 30.5, 海温)
#   26.5℃ 给 0.3、30.5℃ 给 0.8，中间单调过渡，**处处连续**。
#   两端的取值就是原来那两条直线（×0.3 与 ×0.8），所以冷端和高海温端行为不变，
#   只有 1.0 < ΔT < 3.5 这一段被抬起来——它原来被系统性压低，
#   而现实中 28~30℃ 恰恰是台风增强的主力区间（见 docs/研究/01 的 A 节）。
#
# ⚠ 顺带清掉的两处（都**不改变数值**）：
#   · `not storm.landfall` 是**死代码**：陆地上 ΔT > 3.5 时第一支为假，
#     第二支又要求 ΔT < 3.5 也为假 → 落进 `else` 仍是 ×0.8，与不在陆地时完全一样。
#   · 原来的 `else: ΔT × 0.8` 和第一支同值，直接合并。
#
# ⚠ Godot 内置的 `smoothstep` 是**三次 Hermite**（两端导数为 0），不是直线段。
#   端点值与规格给的 0.3 / 0.8 完全一致，中间比直线更平缓，仍然单调连续。
const SST_EFFECT_BASE := 26.5          # 参考的基准海温，ΔT = 海温 − 它
const SST_EFFECT_RAMP_LOW := 26.5      # 平滑门起点：系数 = 0.3
const SST_EFFECT_RAMP_HIGH := 30.5     # 平滑门终点：系数 = 0.8
const SST_EFFECT_FACTOR_LOW := 0.3     # 参考中间带（1<ΔT<3.5）的系数
const SST_EFFECT_FACTOR_HIGH := 0.8    # 参考强支（ΔT>3.5）的系数


## 原参考的「效应-海温」。返回值在 TyphoonSim._wind_delta_rate 里还要再
## `×2 + 0.5` 才进主体公式，别在这里提前乘。
static func sst_effect(sst: float) -> float:
	var sst_diff := sst - SST_EFFECT_BASE
	var t: float = smoothstep(SST_EFFECT_RAMP_LOW, SST_EFFECT_RAMP_HIGH, sst)
	return sst_diff * (SST_EFFECT_FACTOR_LOW
		+ (SST_EFFECT_FACTOR_HIGH - SST_EFFECT_FACTOR_LOW) * t)

# ------------------------- 眼壁置换循环（ERC）-------------------------
# 按真实气象学：强台风外围生成**第二圈眼墙** → 外眼墙收缩、切断内眼墙水汽 →
# 内眼墙崩溃、**强度暂时下降** → 外眼墙接管成新眼墙 → **重新增强**，常常超过原强度。
# 真实周期约 1~3 天，其中减弱阶段 6~24 小时，可反复发生（如 2004 年的 Ivan）。
## 低于这个强度不会发生（约等于 C3；真实 ERC 也基本只在强台风上出现）
const ERC_MIN_KT := 100.0
## ⚠ 触发用的是**倒计时**，不是「每 tick 掷骰子」。
##   以前的写法是每 tick 概率 = sim_delta / 3天，平均要等 3 天才触发——
##   可台风 3 天就从 100 kt 涨到 170 kt 了，所以实际变成「170 kt 才置换」。
##   现在改成：强度第一次够上 ERC_MIN_KT 后，只等下面这么点时间就触发。
const ERC_FIRST_WAIT_MIN := 0.08
const ERC_FIRST_WAIT_MAX := 0.30
## 之后两次置换之间的间隔（天），随机取。加上三个阶段共 1.55 天，
## 总周期约 2.0~3.0 天，和真实（1~3 天）一致。
const ERC_INTERVAL_MIN := 0.5
const ERC_INTERVAL_MAX := 1.5
## ① 外眼墙生成期（天）：强度停滞
const ERC_FORMING_DAYS := 0.5
##   停滞期还保留多少增长（0.15 = 只留 15%）
const ERC_FORMING_SUPPRESS := 0.15
## ② 内眼墙崩溃期（天）：在这段时间里把目标跌幅扣完
const ERC_COLLAPSE_DAYS := 0.35
## ③ 新眼墙接管、重新增强期（天）。失败时改用 ERC_FAIL_RECOVERY_DAYS
const ERC_RECOVERY_DAYS := 0.7
## 跌幅 = 触发时的强度 × 下面的比例
## 成功：外眼墙组织成功 → 只是短暂减弱，随后爆发式恢复
const ERC_SUCCESS_DIP_FRACTION := 0.12
## 失败：外眼墙没组织起来 → **核心结构崩溃**，掉一大截
const ERC_FAIL_DIP_FRACTION := 0.35

# ---- 失败判定：风切变太大 或 海温太低 ----
# 真实原因：强垂直风切变会把涡旋切歪、外眼墙组织不起来；
# 海温不够时也没有多余能量去维持内外两圈眼墙。
## 风切变超过这里开始明显偏向失败
const ERC_FAIL_SHEAR_START := 40.0
## 风切变到这里基本必崩
const ERC_FAIL_SHEAR_FULL := 100.0
## 海温低于这里开始危险
const ERC_FAIL_SST_START := 27.0
## 海温低到这里基本必崩
const ERC_FAIL_SST_FULL := 25.0
## 失败概率的上限（永远留一点运气，不会 100% 必崩）
const ERC_FAIL_MAX_P := 0.95

# ---- 恢复期 ----
## 成功后重新增强的放大倍数（爆发式）
const ERC_SUCCESS_RECOVERY_BONUS := 1.35
## 失败后恢复期的放大倍数（< 1 = 恢复得很吃力）
const ERC_FAIL_RECOVERY_BONUS := 0.6
## 失败后恢复期延长到多少天（结构坏了要更久才缓过来）
const ERC_FAIL_RECOVERY_DAYS := 1.2

# ------------------------- 半球（地转偏向力）-------------------------
# ⚠ `Storm.northern` 在投放时按**起始纬度**定一次，之后**永不改变**。
#   这是参考的行为，也是正确的：半球是台风所属区域的属性，不该跟着赤道翻。
#   （曾经试过「每 tick 跟随当前位置」，那是错的，已撤销。）
#
# ⚠ 但要注意参考那两支条件本身是不对称的：
#     北半球：`当前纬度 < 2`        → 效应 = −1
#     南半球：`−2 < 当前纬度`       → 效应 = −1
#   后一个条件对**任何北纬**都成立。所以如果一场台风的起始纬度在南半球
#   （`northern = false`），它北上过赤道后会一直吃 `ΔKt −= Kt/20`。
#   实测 Kt=53.9、纬度 22°N 时是 **−269 kt/秒**，1 秒就掉到 2 kt。
#   这是参考原样，**没有改**；投放时要注意别把起始点放在赤道以南。
## 随机游走幅度（参考：每 0.1 秒 `change 垂直风切变 by random(5, -5)`）
const SHEAR_WALK_STEP := 5.0
## 随机游走的间隔（秒）
## 随机游走间隔（秒）。**值由 config/simulation.cfg 决定**，见文件顶部。
var SHEAR_WALK_INTERVAL := 0.1
## 初始风切变范围（参考在开始模拟前 `set 垂直风切变 = random(0, 30)`）
const SHEAR_INIT_MAX := 30.0
## 变性中每天的额外衰减（节/天）。参考里没有这一项，是本工程保留的附加项。
const EXTRATROPICAL_WEAKENING := 6.0
## 完全变性后每天的额外衰减（节/天），比变性中更快
const EXTRATROPICAL_WEAKENING_DONE := 9.0

## 地图上的经纬网刻度（只用于显示）
const GRID_LON_STEP := 10.0
const GRID_LAT_STEP := 5.0

## 便捷换算：坐标 ↔ 经纬度（和 GEO_* 范围严格等价，改用 GEO_LON_MIN / EQUATOR_WORLD_Y）
static func world_x_from_lon(lon: float) -> float:
	return (lon - GEO_LON_MIN) * PX_PER_DEGREE


static func world_y_from_lat(lat: float) -> float:
	return EQUATOR_WORLD_Y - lat * PX_PER_DEGREE


static func lon_from_world_x(x: float) -> float:
	return x / PX_PER_DEGREE + GEO_LON_MIN


static func lat_from_world_y(y: float) -> float:
	return (EQUATOR_WORLD_Y - y) / PX_PER_DEGREE

# ============================ 坐标换算 ============================
# 三套坐标，转换函数都集中在这里，别在别处手算：
#   ① uv        0..1 归一化坐标（存档、设置项里用它最稳）
#   ② 世界坐标  地图左上角为原点，(0,0)..(MAP_W, MAP_H)
#   ③ 经纬度    100°E–180°E / 0°N–45°N

## 经纬度 → uv
static func uv_from_lonlat(lon: float, lat: float) -> Vector2:
	return Vector2(
		(lon - GEO_LON_MIN) / (GEO_LON_MAX - GEO_LON_MIN),
		(GEO_LAT_MAX - lat) / (GEO_LAT_MAX - GEO_LAT_MIN)
	)


## uv → 经纬度
static func lonlat_from_uv(uv: Vector2) -> Vector2:
	return Vector2(
		GEO_LON_MIN + uv.x * (GEO_LON_MAX - GEO_LON_MIN),
		GEO_LAT_MAX - uv.y * (GEO_LAT_MAX - GEO_LAT_MIN)
	)


## uv → 世界坐标
static func world_from_uv(uv: Vector2) -> Vector2:
	return Vector2(uv.x * MAP_W, uv.y * MAP_H)


## 世界坐标 → uv
static func uv_from_world(pos: Vector2) -> Vector2:
	return Vector2(pos.x / MAP_W, pos.y / MAP_H)


## 世界坐标 → 海区编号（1..192）
static func cell_index_from_world(pos: Vector2) -> int:
	var col := clampi(int(floor(pos.x / CELL_W)), 0, COLS - 1)
	var row := clampi(int(floor(pos.y / CELL_H)), 0, ROWS - 1)
	return cell_index_of(row, col)


static func cell_index_of(row: int, col: int) -> int:
	return row * COLS + col + 1


## 海区编号 → 该格中心的世界坐标
static func cell_center_world(index: int) -> Vector2:
	var i := clampi(index - 1, 0, CELL_COUNT - 1)
	var row := i / COLS
	var col := i % COLS
	return Vector2(col * CELL_W + CELL_W * 0.5, row * CELL_H + CELL_H * 0.5)


## 海区编号 → 该格的世界坐标矩形（用于画格子和采样）
static func cell_rect_world(index: int) -> Rect2:
	var i := clampi(index - 1, 0, CELL_COUNT - 1)
	var row := i / COLS
	var col := i % COLS
	return Rect2(col * CELL_W, row * CELL_H, CELL_W, CELL_H)


# ============================ 观测数据 ============================

# ------------------------- 基础海温数据 -------------------------
# ⚠ 数据本体在 **`config/sst.txt`**，不在代码里（用户 2026-10-17 决定）。
#   想改海温直接改那个文本文件，不用碰 scripts/。
#
#   文件格式：忽略 `#` 注释和空行，空白分隔的数字都算；按 12 行 × 16 列排，
#   行优先，`对应海区 = 行号 * 16 + 列号 + 1`（1..192，1 起算）。
#
#   数据来源：`docs/原始海温数据.txt`（用户提供），2026-10-11 逐项核对过与原表一致。
const SST_DATA_RES_PATH := "res://config/sst.txt"
const SST_DATA_EXE_NAME := "sst.txt"

## 192 项基础海温（℃），启动时从文件读。**代码里不再写死数值。**
var BASE_SST: Array[float] = []

## 真正生效的 SST 数据来源（启动时打到控制台）
var sst_data_source := "（未加载）"

## 当台风被判定在陆地上时，海温按这个值算（陆地上没有海表面温度）。
## 参考用「海温 ≤ 10℃」编码陆地；这里取 2.0（参考里最常见的陆地编码值）。
## 值在 config/simulation.cfg 的 [ocean] 段里可调。
## 台风能"读到"的海温上限（℃）。平均海温可以设到 100，但读进来最多这么多。
## 用户 2026-10-17：大数值增加可玩性；上限防止 MPI 软限算出荒谬的数。
const SST_READ_CAP := 100.0
var LAND_SST := 2.0

# ------------------------- 浅海热库上限 -------------------------
# 近岸浅海的暖水层被海底封顶 → 可提取的热量少 → 撑不起超强台风。
# 水深档由 `WPAC_SHELF20/50/100.png` **逐像素**判定（6.3 km/px，比 700 km 的
# 192 格细 110 倍），档位见 `OceanField.shelf_band_at_world()`：
#   0 = >100m（不限制）  1 = <100m  2 = <50m  3 = <20m
#
# 数值依据（OHC ≈ 0.41 × (海温−26) × 暖水层厚度，kJ/cm²）：
#   暖水层 20m / 30℃ → 33 kJ/cm²，低于快速增强门槛(50~60) → 撑不起强台风
#   暖水层 50m / 30℃ → 82 kJ/cm²，能到 C2 左右
#   暖水层 100m/ 30℃ → 164 kJ/cm²，完全支持
#
# ⚠ 用户 2026-10-17 明确要求：**不加移速调制**（不要因为走得快就放宽）。
var SHELF_CAP_100 := 140.0
var SHELF_CAP_50 := 110.0
var SHELF_CAP_20 := 80.0
## 超过上限后每 tick 往下拽的系数（0.004 → 超出 50 kt 时约 −24 kt/模拟日）
var SHELF_EXCESS_PULL := 0.004


## 某档水深的强度上限（kt）。0 档返回一个足够大的数 = 不限制。
func shelf_cap_kt(band: int) -> float:
	match band:
		3: return SHELF_CAP_20
		2: return SHELF_CAP_50
		1: return SHELF_CAP_100
	return 1.0e9


# ------------------------- 超顶超增长抑制 -------------------------
# 参考工程没有强度上限，台风能一路涨到 500+ kt（原版存档里就是 503.54）。
# B′ 的 MPI 软自限虽然会减速，但过了一定强度后增长还是嫌快。
#
# 用户 2026-10-17 决定：**超过 170 kt（超顶超）之后额外压一下增长**，
# 但不要硬顶——仍然要能慢慢爬到 300~400 kt 增加可玩性。
#
# 施加方式：只在 ΔKt > 0（正增长）时除以下面这个因子，衰减不受影响。
#   divisor = 1 + (Kt − 170) / ramp
#   Kt=170 → 1.0（无影响）
#   Kt=255 → 1.5      Kt=340 → 2.0      Kt=510 → 3.0
# 叠加 B′ 之后，Kt=340 时总抑制约 6 倍 → 增长从 ~36 kt/日 降到 ~6 kt/日。
var SUPER_LIMIT_KT := 170.0
var SUPER_RAMP_KT := 170.0


## 超过超顶超门槛后，正增长要额外除的因子。没超过返回 1.0（不影响）。
func super_typhoon_damping(wind_kt: float) -> float:
	if wind_kt <= SUPER_LIMIT_KT or SUPER_RAMP_KT <= 0.0:
		return 1.0
	return 1.0 + (wind_kt - SUPER_LIMIT_KT) / SUPER_RAMP_KT


# ------------------------- 陆地衰减（指数式）-------------------------
# **本工程对参考的改写**，依据 `docs/研究/01` 第 ⑥ 节的现实标定。
#
# 参考原文只有一句 `ΔKt -= 0.5`（山区再 -1），是**线性**扣减：
# 结果越弱掉得越快，会一路崩到 0。而现实是指数衰减、趋于一个背景强度
#   V(t) = Vb + (V0 − Vb)·e^(−t/τ)
# 强台风初期绝对跌幅大、弱台风拖很久（内陆残涡能维持好几天）。
#
# 实测对照（100 kt 登陆，τ=30h）：
#     +12h ≈ 69 kt   +24h ≈ 51 kt   +48h ≈ 33 kt   渐近 26.7
# 现实区间 −30 ~ −65 kt/24h（NHC「24h 减半」=50、Kaplan–DeMaria τ=10.5h = 33、
# 中国统计约 80~85 但被弱台风摊薄）→ 取 τ=22h 对齐研究的分档表。
#
# τ 按地形分三档（研究结论：地形 > 移速 > 土壤湿度 > 大小结构）：
#   平地 22h ｜ 1000m 山区 12h ｜ 2500m 高山 9h
# 2500m 那档专门用来复现「穿过台湾中央山脉 / 吕宋高山」的急降。
var LAND_DECAY_BG_KT := 26.7
var LAND_DECAY_TAU_PLAIN := 22.0
var LAND_DECAY_TAU_MOUNTAIN := 12.0
var LAND_DECAY_TAU_MOUNTAIN2500 := 9.0

## 每个 tick 代表多少模拟小时（由 TICKS_PER_DAY 反推，见 _sync_tick_rate）
var HOURS_PER_TICK := 0.2


## 陆地衰减的「每 tick 应扣多少」（正数 = 减弱）。
## 指数式：dKt = −(Kt − Vb) / τ × 每 tick 小时数。
## 低于背景强度时不扣（不然内陆残涡会被"越弱越涨"拉回 Vb，不合物理）。
func land_decay_delta(wind_kt: float, tau_hours: float) -> float:
	var excess: float = maxf(0.0, wind_kt - LAND_DECAY_BG_KT)
	if excess <= 0.0 or tau_hours <= 0.0:
		return 0.0
	return -(excess / tau_hours) * HOURS_PER_TICK

## 原始地面气压（全部为标准大气压）
const BASE_PRESSURE := 1013.0

## 陆地区域（参考把 BASE_SST <= 10 的格子视为陆地）
const LAND_SST_THRESHOLD := 10.0

## 默认演示路径（经度、纬度），一条典型的西北太平洋台风：
## 从关岛以东生成，向西北移动，掠过菲律宾北部后转向台湾一带登陆。
## 自动模式下会在这条路径上叠加随机摆动；手动模式下由玩家自己点路径点。
const DEFAULT_TRACK_LONLAT: Array[Vector2] = [
	Vector2(148.0, 12.0),
	Vector2(145.5, 13.2),
	Vector2(143.0, 14.5),
	Vector2(140.5, 15.6),
	Vector2(138.0, 16.6),
	Vector2(135.5, 17.5),
	Vector2(133.0, 18.3),
	Vector2(130.5, 19.0),
	Vector2(128.5, 19.8),
	Vector2(127.0, 20.7),
	Vector2(125.5, 21.7),
	Vector2(124.0, 22.8),
	Vector2(122.5, 23.9),
	Vector2(121.5, 24.8),
	Vector2(121.0, 25.6),
	Vector2(121.2, 26.5),
	Vector2(122.0, 27.5),
	Vector2(123.5, 28.6),
	Vector2(125.5, 29.8),
	Vector2(128.0, 31.0),
	Vector2(131.0, 32.5),
	Vector2(134.5, 34.0),
	Vector2(138.5, 35.5),
	Vector2(143.0, 37.0),
	Vector2(148.0, 38.5),
]

## 西北太平洋台风命名表（140 项，逐字提取）
const STORM_NAMES: Array[String] = ["Damrey", "Haikui", "Kirogi", "Yun-yeung", "Koinu", "Bolaven", "Sanba", "Jelawat", "Ewiniar", "Maliksi", "Gaemi", "Prapiroon", "Maria", "Saomai", "Bopha", "Wukong", "Jongdari", "Shanshan", "Yagi", "Leepi", "Bebinca", "Rumbia", "Soulik", "Cimaron", "Jebi", "Mangkhut", "Barijat", "Trami", "Kong-rey", "Yutu", "Toraji", "Man-yi", "Usagi", "Pabuk", "Wutip", "Sepat", "Mun", "Danas", "Nari", "Wipha", "Francisco", "Lekima", "Krosa", "Haiyan", "Podul", "Lingling", "Kajiki", "Faxai", "Peipah", "Tapah", "Mitag", "Hagibis", "Neoguri", "Rammasun", "Matmo", "Halong", "Nakri", "Fengshen", "Kalmaegi", "Fung-wong", "Kammuri", "Nokaen", "Vongfong", "Nuri", "Sinlaku", "Hagupit", "Jangmi", "Mekkhala", "Higos", "Bavi", "Maysak", "Haishen", "Noul", "Dolphin", "Kujira", "Chan-hom", "Peilou", "Nangka", "Soudelor", "Narra", "Goni", "Atsani", "Etau", "Vamco", "Krovanh", "Dujuan", "Surigae", "Choi-wan", "Koguma", "Champi", "In-Fa", "Cempaka", "Nepartak", "Lupit", "Mirinae", "Nida", "Omais", "Conson", "Chanthu", "Dianmu", "Mindulle", "Lionrock", "Kompasu", "Namtheun", "Malou", "Meranti", "Rai", "Malakas", "Megi", "Chaba", "Aere", "Songda", "Trases", "Haima", "Meari", "Ma-on", "Tokage", "Hinnamnor", "Muifa", "Merbok", "Nanmadol", "Talas", "Noru", "Kulap", "Roke", "Sonca", "Nesat", "Haitang", "Nalgae", "Banyan", "Hato", "Pakhar", "Sanvu", "Mawar", "Guchol", "Talim", "Doksuri", "Khanun", "Lan", "Saola"]

# ============================ 仿真参数 ============================
const START_MONTH := 1
const START_DAY := 1

## 日历：每月固定 30 天，12 个月 = 360 天
const DAYS_PER_MONTH := 30
const MONTHS_PER_YEAR := 12

# ---- 时间模型（三者必须自洽）----
# 原工程：路径点之间 1 秒走完，两点之间代表 6 小时；时间轴同样是 4 秒 = 1 天。
# 6 小时/秒 × 4 秒 = 24 小时，正好 1 天 —— 这套换算是自洽的。
#
# ⚠ `SIM_HOURS_PER_REAL_SECOND` 和 `SECONDS_PER_DAY` 现在是**变量**，
#   定义在文件顶部「仿真基础节拍」一节，由 `config/simulation.cfg` 决定
#   （`SECONDS_PER_DAY = 24 / SIM_HOURS_PER_REAL_SECOND`，两者永远自洽）。
const SECONDS_PER_SEGMENT := 1.0           # 相邻两个路径点之间走 1 秒
const HOURS_PER_SEGMENT := 6.0             # 这两点之间代表 6 小时的移动

## 自检要跑多少模拟日
const SELFTEST_DAYS := 40

# ============================ 海温「冷水坑」算法 ============================
# 严格照参考「基础系统与舞台.md」里那段标了「不要改数值和运算」的代码。
# 台风把暖水搅上来、留下冷尾流，这个冷坑反过来抑制台风自己。

## 降温强度分档（参考的 ↓降温↓）：
##   Kt < 34    → 0
##   34 ≤ Kt < 80  → (Kt−34)/46
##   80 ≤ Kt < 150 → 0        （照抄参考：这一段不降温）
##   Kt ≥ 150   → 1.8
## 原样保留在 OceanField.cooling_factor() 里，这里是文档。

## 停留阈值系数。参考原文：`if (round(((240 * 34) / round(Kt))) < 计时)`
## 也就是需要 240×34/Kt = 8160/Kt 个 tick 才开始降温。
const COOLING_DWELL_NUMERATOR := 240.0 * 34.0
## 单次降温幅度系数（参考：`基础海温数据 − (0.05 * ↓降温↓)`）
const COOLING_STEP := 0.05

# ------------------------- ⚠ 频率修正（偏离参考，经用户同意）-------------------------
# 参考的降温循环里 `wait(0.01)` 在**阈值分支内部**，名义上是每 0.01 秒降一次。
# 本工程按 100 Hz 照搬 → 每个 tick 都扣：
#     0.05 × 1.8 = 0.09℃/tick × 100 tick/秒 = **-9℃/秒**
# 台风穿过一格要 9 秒 → 理论能扣 81℃，海温被直接抠穿（实测 1 秒掉 5.76℃）。
# 于是台风被自己的冷坑打成 10kt 死区，卡在那里不动。
#
# 所以：**起始等待时间不变**（仍按 COOLING_DWELL_NUMERATOR 算 tick），
#       但降温本身每 COOLING_APPLY_INTERVAL_SECONDS 秒才执行一次。
#
# 取 0.5 秒（= 2 次/秒）的效果：
#     Kt≥150：0.09 × 2 = 0.18℃/秒 → 穿一格(约9秒)扣约 1.6℃
#     Kt=50 ：0.0175 × 2 = 0.035℃/秒 → 扣约 0.3℃
#     回升同样降到 0.1℃/秒，掉 2℃ 约 20 秒回来
# ⚠ 现在按**秒**表达，不再写死 tick 数 —— 换物理帧率时自动换算（见 _sync_tick_rate）。
#   想更快/更慢就改 `config/simulation.cfg` 里的 cooling_apply_interval_seconds。
var COOLING_APPLY_INTERVAL_SECONDS := 0.5
## 实际间隔（tick），由 `_sync_tick_rate()` 按上面的秒数 × 物理帧率算出
var COOLING_APPLY_INTERVAL_TICKS := 15

## 低于这个海温就不再继续降温（参考：`if (item 对应海区 of 基础海温数据 > 20)`）
const COOLING_SST_FLOOR := 20.0
## 台风离开后每个 tick 回升多少（参考：`+ 0.05`）
const WARM_RECOVERY_STEP := 0.05

## 风季模式的时长
const SEASON_MONTHS := 12

## 上一场台风结束后，需要等待多少模拟日才允许投放下一场（随机区间）
const DEPLOY_COOLDOWN_MIN := 5.0
const DEPLOY_COOLDOWN_MAX := 15.0

const SEASONAL_AMPLITUDE := 1.5
const MEAN_SST := 30.0
const INITIAL_WIND_KT := 20.0        # 台风基础风速
const WESTERLY_LATITUDE := 39.89473684210526
const CALM_PRESSURE := 1013.0
const SST_ADJUSTMENT := 0.75         # 海温增幅（最终）
const NAME_CURSOR_START := 1         # 台风名游标初值（1-based）

# ============================ 编号系统 ============================
## 台风胚胎编号：90 → 99 → 90 循环，只给"热带低压及以下"用
const DEPRESSION_NUMBER_START := 90
const DEPRESSION_NUMBER_END := 99
## 热带风暴编号：01W → 99W 循环，只给达到热带风暴级及以上的用
const STORM_NUMBER_START := 1
const STORM_NUMBER_END := 99
## 达到这个强度（节）就换上【热带风暴编号】。Kt > 30 即算热带风暴级。
const STORM_NUMBER_THRESHOLD_KT := 30.0
## 达到这个强度（节）才从命名表取名、并开始计入 ACE。Kt > 33 即台风级。
const NAMING_THRESHOLD_KT := 33.0

# ============================ 强度分级 ============================
# 严格对齐参考「台风中心.md → 检测类型」里的「类型」变量。
# ⚠ 参考用的是**顺序 if**（后面的覆盖前面），且都是**严格大于号**，不是 elif 链。
#
#   类型 −4  纬度 > 西风带纬度        → 温带气旋
#   类型 −3  round(Kt) < 19          → 参考里没有名称
#   类型 −2  19 < round(Kt) < 31     → 热带扰动（此时才有热带扰动编号）
#   类型 −1  30 < round(Kt)          → 热带低压
#   类型  0  33 < round(Kt)          → 热带风暴（此时才命名）
#   类型  1..5  63/82/95/112/136 <   → C1..C5
const CAT_UNKNOWN := -10          ## 初始值，还没测过强度
const CAT_EXTRATROPICAL := -4     ## 温带气旋（纬度越过西风带）
const CAT_WEAK := -3              ## round(Kt) < 19
const CAT_DISTURBANCE := -2       ## 热带扰动
const CAT_DEPRESSION := -1        ## 热带低压
const CAT_TROPICAL_STORM := 0     ## 热带风暴（命名门槛）
const CAT_C1 := 1
const CAT_C2 := 2
const CAT_C3 := 3
const CAT_C4 := 4
const CAT_C5 := 5

## 「已命名 / 开始计 ACE」的门槛。参考原文：`if (-1 < 巅峰强度)`
const CAT_NAMED := CAT_TROPICAL_STORM


## 风速（节）→ 类型。逐条照抄参考「检测类型」里的顺序 if，不做任何改动。
static func category_from_wind(kt: float) -> int:
	var k := roundf(kt)
	var t := CAT_WEAK
	if 19.0 < k and k < 31.0:
		t = CAT_DISTURBANCE
	if 30.0 < k:
		t = CAT_DEPRESSION
	if 33.0 < k:
		t = CAT_TROPICAL_STORM
		if 63.0 < k:
			t = CAT_C1
		if 82.0 < k:
			t = CAT_C2
		if 95.0 < k:
			t = CAT_C3
		if 112.0 < k:
			t = CAT_C4
		if 136.0 < k:
			t = CAT_C5
	return t


## 侧栏「类别」栏的中文显示。
## 参考里给 −2/−1 分别起名「热带扰动」「热带低压」，0 起是命名台风，
## 1..5 直接用参考自己的 C1..C5 列表。
static func category_label(cat: int) -> String:
	match cat:
		CAT_EXTRATROPICAL: return "温带气旋"
		CAT_WEAK: return "热带扰动"
		CAT_DISTURBANCE: return "热带扰动"
		CAT_DEPRESSION: return "热带低压"
		CAT_TROPICAL_STORM: return "热带风暴"
		CAT_C1, CAT_C2, CAT_C3, CAT_C4, CAT_C5:
			return "C%d" % cat
	return "未知"


## 战报里的短标签。
## ⚠ 类型 0 是**热带风暴（TS）**，不是 C0——参考里 1..5 才是 C1..C5
##   （看它的登陆音效分支：类型 0 放 ts，类型 1..5 放 c1..c5）。
##   类型 < 0 表示还没到命名门槛，参考只记台风名，这里给个 TD 占位。
static func category_short(cat: int) -> String:
	if cat < CAT_NAMED:
		return "TD"
	if cat == CAT_TROPICAL_STORM:
		return "TS"
	if cat > CAT_C5:
		return "C5"
	return "C%d" % cat


# ============================ 配色 ============================
const SST_MIN := 2.0
const SST_MAX := 31.0
const WATER_COLD := Color("1d4f8f")
const WATER_WARM := Color("d9534f")
const LAND_COLOR := Color("2f3a2c")
const GRID_LINE := Color(0.0, 0.0, 0.0, 0.14)

static func sst_color(sst: float) -> Color:
	var t: float = clampf((sst - SST_MIN) / (SST_MAX - SST_MIN), 0.0, 1.0)
	return WATER_COLD.lerp(WATER_WARM, t)


## 台风路径颜色，逐个对应参考「台风中心.md」里按类型设的画笔颜色：
##   −4 #e8e8e8 / −3 #d8d8d8 / −2 #00caff / −1 #0090ff / 0 #1dff00
##    1 #ffff00 /  2 #ffd000 /  3 #ff7b00 /  4 #ff0000 / 5 #ff007b
const TRACK_COLORS: Array[Color] = [
	Color("e8e8e8"), Color("d8d8d8"), Color("00caff"), Color("0090ff"),
	Color("1dff00"), Color("ffff00"), Color("ffd000"), Color("ff7b00"),
	Color("ff0000"), Color("ff007b"),
]

static func track_color(kt: float) -> Color:
	var cats := category_from_wind(kt)
	var idx := clampi(cats - CAT_EXTRATROPICAL, 0, TRACK_COLORS.size() - 1)
	return TRACK_COLORS[idx]
