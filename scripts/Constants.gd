extends Node
## 全局数据表与仿真参数（autoload 单例，代码里用 Const.XXX 访问）。
##
## 这里所有数值都从原 Scratch 工程的 project.json 里逐字提取，未做任何四舍五入，
## 方便你对照 docs/ 里的分析文档逐项核对。

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
const SHEAR_WALK_INTERVAL := 0.1
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

## 原始海温分布（192 项，行优先，单位 ℃）
## ⚠ 数据来源：`docs/原始海温数据.txt`（用户提供，从左上至右下为 1..192）。
##    2026-10-11 逐项核对过：**与原表完全一致**（当时误改过第 148 项，已改回 27）。
const BASE_SST: Array[float] = [
	3, 8, 3, 3, 8, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2,
	10, 10, 10, 10, 10, 10, 3, 3, 3, 3, 3, 3, 3, 3, 3, 10,
	12, 12, 12, 12, 12, 20, 20, 4, 4, 10, 10, 10, 10, 10, 12, 12,
	14, 14, 14, 20, 20, 20, 20, 14, 14, 14, 14, 14, 14, 14, 14, 14,
	16, 16, 16, 21, 21, 21, 16, 16, 16, 16, 16, 16, 19, 19, 19, 19,
	18, 18, 18, 23, 23, 28, 30, 31, 26, 30, 26, 26, 26, 26, 26, 26,
	21, 27, 27, 27, 29, 26, 31, 26, 26, 31, 30, 26, 26, 26, 26, 26,
	30, 27, 27, 28, 30, 30, 30, 30, 30, 27, 27, 27, 27, 26, 28, 28,
	30, 30, 30, 30, 29, 29, 29, 29, 28, 28, 28, 28, 27, 29, 31, 30,
	30, 30, 30, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
	29, 29, 29, 29, 29, 26, 24, 29, 26, 26, 26, 26, 26, 26, 27, 27,
	28, 28, 28, 28, 31, 31, 25, 23, 22, 25, 26, 26, 26, 26, 26, 26,
]

## 原始地面气压（全部为标准大气压）
const BASE_PRESSURE := 1013.0

## 陆地区域（把 BASE_SST <= 10 的格子视为陆地，与原工程判定一致）
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
const SIM_HOURS_PER_REAL_SECOND := 6.0     # 1 真实秒 = 6 模拟小时
const SECONDS_PER_SEGMENT := 1.0           # 相邻两个路径点之间走 1 秒
const HOURS_PER_SEGMENT := 6.0             # 这两点之间代表 6 小时的移动
# 派生量：正常速度下 1 个模拟日 = 4 真实秒
const SECONDS_PER_DAY := 24.0 / SIM_HOURS_PER_REAL_SECOND

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
#       但降温本身每 COOLING_APPLY_INTERVAL_TICKS 个 tick 才执行一次。
#
# 取 50（= 2 次/秒）的效果：
#     Kt≥150：0.09 × 2 = 0.18℃/秒 → 穿一格(约9秒)扣约 1.6℃
#     Kt=50 ：0.0175 × 2 = 0.035℃/秒 → 扣约 0.3℃
#     回升同样降到 0.1℃/秒，掉 2℃ 约 20 秒回来
# 想更快/更慢就改这个数：调小=更猛，调大=更温和。
const COOLING_APPLY_INTERVAL_TICKS := 50

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
