class_name OceanField
extends Node2D
## 海温 / 气压场叠加层 + 陆地掩膜。
##
## 对应原 Scratch 角色「基础系统//海区」：原工程用 192 个克隆体 + 颜色特效铺满地图。
## 这里改成一张 16×12 的叠加层，一次 _draw() 画完：
##   · 海温用半透明热力色叠在 WPAC.png 地图上
##   · 气压用蓝色透明度表示
##   · 陆地直接**从 WPAC.png 的像素里采样**判定，不再手写多边形坐标，省得对不准
##
## 本节点是 MapLayer（Node2D）的子节点，世界坐标即地图像素坐标（0,0 在左上角）。

var sst := PackedFloat32Array()          # 当前海温（℃）——被冷水坑改写后的值
var pressure := PackedFloat32Array()     # 当前地面气压（hPa）
var land_mask := PackedByteArray()       # 1 = 陆地，0 = 海洋

# ------------------------- 冷水坑 -------------------------
## 原始观测海温（℃）。冷水坑只能往下改，回升时以它为上限。
var sst_base := PackedFloat32Array()
## 每一格累计停留了多少个 tick（参考里的「计时」）
var dwell_ticks := PackedFloat32Array()
## 本 tick 的降温强度系数（0..1.8），供调试显示
var cooling_rates := PackedFloat32Array()
## tick 计数，用来把降温/回升降到指定频率（见 COOLING_APPLY_INTERVAL_TICKS）
var _tick_counter := 0

var show_pressure := false               # false 画海温，true 画气压
var show_grid_lines := false             # 是否画格子线（调试用）
## 是否显示整个海温/气压叠加层。快捷键 T 切换——
## 关掉后 192 个格子全部隐藏，只留 WPAC.png 底图。
## ⚠ 默认**关**（用户要求：一进游戏不要被海温色块糊住地图）。
var show_field := false

# ============================ 调试可视化 ============================
# 用来人工比对「掩膜到底贴不贴地图」。快捷键 F4 / F5。
#
#   F4 循环：关 → 陆地掩膜(红) → 1000m 山区(青) → 2500m 山区(黄)
#            把对应掩膜的不透明区域染成半透明色，等比铺在地图上。
#            对齐正确的话，色块的边缘应当**严丝合缝地贴着地图画的海岸线**。
#   F5 开关：游戏实际判定的陆地格子（192 格里哪些被当成陆地，橙色框）
#            这个是物理真正用的东西，和上面那个原始掩膜可以对照看。

## 0=关，1=陆地掩膜，2=1000m 山区，3=2500m 山区
var mask_view_mode := 0
## 是否高亮「游戏实际判定的陆地格子」
var show_land_cells := false

const MASK_VIEW_PATHS: Array[String] = [
	"",
	"res://assets/images/WPAC_LAND.png",
	"res://assets/images/WPAC_LAND1000.png",
	"res://assets/images/WPAC_LAND2500.png",
]
## 每种掩膜叠加的颜色
const MASK_VIEW_TINTS: Array[Color] = [
	Color(0, 0, 0, 0),
	Color(1.00, 0.15, 0.15),     # 陆地 = 红
	Color(0.10, 1.00, 1.00),     # 1000m = 青
	Color(1.00, 0.90, 0.10),     # 2500m = 黄
]
var _mask_view_cache := {}


func mask_view_name() -> String:
	match mask_view_mode:
		1: return "陆地掩膜（红）"
		2: return "1000m 山区（青）"
		3: return "2500m 山区（黄）"
	return "关"


func cycle_mask_view() -> void:
	mask_view_mode = (mask_view_mode + 1) % MASK_VIEW_PATHS.size()
	queue_redraw()


## 把掩膜染成半透明纯色，只做一次并缓存。
## 用「按行找连续段 + fill_rect」而不是逐像素 set_pixel，快很多。
func _mask_view_texture(mode: int) -> Texture2D:
	if _mask_view_cache.has(mode):
		return _mask_view_cache[mode]
	if mode <= 0 or mode >= MASK_VIEW_PATHS.size():
		return null
	var path: String = MASK_VIEW_PATHS[mode]
	if not ResourceLoader.exists(path):
		return null
	var src: Image = (load(path) as Texture2D).get_image()
	if src == null:
		return null
	src.convert(Image.FORMAT_RGBA8)
	var sw := src.get_width()
	var sh := src.get_height()
	var tint: Color = MASK_VIEW_TINTS[mode]
	var col := Color(tint.r, tint.g, tint.b, 0.45)
	var out := Image.create(sw, sh, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	for y in sh:
		var x := 0
		while x < sw:
			if src.get_pixel(x, y).a >= 0.5:
				var x2 := x + 1
				while x2 < sw and src.get_pixel(x2, y).a >= 0.5:
					x2 += 1
				out.fill_rect(Rect2i(x, y, x2 - x, 1), col)
				x = x2
			else:
				x += 1
	var tex := ImageTexture.create_from_image(out)
	_mask_view_cache[mode] = tex
	return tex

var _mask_ready := false
var _mask_source := ""


func _ready() -> void:
	sst.resize(Const.CELL_COUNT)
	sst_base.resize(Const.CELL_COUNT)
	pressure.resize(Const.CELL_COUNT)
	land_mask.resize(Const.CELL_COUNT)
	dwell_ticks.resize(Const.CELL_COUNT)
	cooling_rates.resize(Const.CELL_COUNT)
	pressure.fill(Const.BASE_PRESSURE)
	reset_sst()


## 重置为观测海温（同时清掉所有冷水坑）
func reset_sst() -> void:
	for i in Const.CELL_COUNT:
		sst_base[i] = Const.BASE_SST[i]
		sst[i] = Const.BASE_SST[i]
		dwell_ticks[i] = 0.0
		cooling_rates[i] = 0.0
	queue_redraw()


# ============================ 冷水坑算法 ============================
# 严格照参考「基础系统与舞台.md」里那段标了「不要改数值和运算」的代码：
#
#   DEFINE 计算降温
#     if (Kt < 34):      ↓降温↓ = 0
#     else:
#       if (Kt < 80):    ↓降温↓ = (Kt - 34) / 46
#       else:
#         if (Kt < 150): ↓降温↓ = 0
#         else:          ↓降温↓ = 1.8
#
#   每个海区 clone：
#     if (not(碰到台风中心) and not(类型 = -4)): 计时 = 0
#     else:
#       计时 += 1
#       if (round(240 * 34 / round(Kt)) < 计时):
#         if (基础海温 > 20):
#           基础海温 -= 0.05 * ↓降温↓

## 单格降温强度（对应参考的 ↓降温↓）。数值与分支原样保留。
static func cooling_factor(kt: float) -> float:
	if kt < 34.0:
		return 0.0
	if kt < 80.0:
		return (kt - 34.0) / 46.0
	if kt < 150.0:
		return 0.0
	return 1.8


## 参考的停留阈值：`round((240 * 34) / round(Kt))` 个 tick。
static func dwell_required_ticks(kt: float) -> float:
	var k := roundf(kt)
	if k <= 0.0:
		return INF
	return roundf(Const.COOLING_DWELL_NUMERATOR / k)


## 每 tick 调用一次。storm 是当前台风（可为 null），storm_cell 是它所在格（1-based）。
##
## ⚠ 照抄参考带来的副作用（**未改**，但你要知道）：
##   参考的归零条件是 `not(碰到) and not(类型 = -4)`。
##   一旦台风变成温带气旋（类型 = −4），这个条件永远为假，
##   于是**所有**格子的「计时」都不再归零，整张地图会逐格开始降温。
##   这看起来像参考工程的疏漏，但你说过不要改运算，所以原样保留。
func update_cooling(storm: Storm, storm_cell: int) -> void:
	var kt := 0.0
	var non_tropical := false
	if storm != null:
		kt = storm.wind_kt
		non_tropical = storm.phase != Storm.Phase.TROPICAL
	var threshold := dwell_required_ticks(kt)
	var factor := cooling_factor(kt)

	# ⚠ 降温/回升不是每个 tick 都执行，见 Constants.COOLING_APPLY_INTERVAL_TICKS 的注释。
	#   起始等待时间不变，只把「降温本身」的频率降下来。
	_tick_counter += 1
	var apply_now := _tick_counter % int(Const.COOLING_APPLY_INTERVAL_TICKS) == 0

	for i in Const.CELL_COUNT:
		cooling_rates[i] = 0.0
		if land_mask[i] == 1:
			continue

		var touching := storm_cell == i + 1

		if not touching and not non_tropical:
			# 参考：计时归零，然后「离开后回升」（每帧 +0.05 直到回到原始值）
			dwell_ticks[i] = 0.0
			if apply_now and sst[i] < sst_base[i]:
				sst[i] = minf(sst_base[i], sst[i] + Const.WARM_RECOVERY_STEP)
			continue

		dwell_ticks[i] += 1.0
		if threshold < dwell_ticks[i]:
			cooling_rates[i] = factor
			if apply_now and sst[i] > Const.COOLING_SST_FLOOR:
				sst[i] -= Const.COOLING_STEP * factor

	queue_redraw()


## 当前有多少格被冷水坑改写过（供 UI/调试显示）
func cooling_cell_count() -> int:
	var n := 0
	for i in Const.CELL_COUNT:
		if sst[i] < sst_base[i] - 0.0001:
			n += 1
	return n


## 某格相对原始海温降了多少度
func cooling_drop_at(index: int) -> float:
	if index < 1 or index > Const.CELL_COUNT:
		return 0.0
	return sst_base[index - 1] - sst[index - 1]


func toggle_layer() -> void:
	show_pressure = not show_pressure
	queue_redraw()


# ------------------------- 陆地掩膜 -------------------------

## 掩膜贴图路径。用户提供的 PNG：**海洋透明、陆地纯黑（不透明）**。
## 尺寸 1772×1418，与地图 1080×864 同宽高比、同原点，等比换算即可。
##
## ⚠ 已实测：掩膜与 WPAC.png 的着色**完全一致**（15/15 采样点相符），
##   坐标对齐也正确（东京/上海/香港/马尼拉/北京/澳洲/关岛/远洋全部判对）。
##   但它忠实地反映了地图本身的问题——WPAC.png 把浅海也画成绿色：
##     南海 RGB(56,83,19)、东海 RGB(100,108,64)、黄海 RGB(207,171,128)、
##     日本海 RGB(79,94,39)、鄂霍次克海 RGB(53,67,22) 全是陆地色。
##   所以台风走到这些浅海会被判登陆。这是**地图的已知限制**，不是掩膜的错。
const LAND_MASK_PATH := "res://assets/images/WPAC_LAND.png"
## 设为 false 时忽略 LAND_MASK_PATH，直接走地图像素启发式那条退路
const USE_LAND_MASK_FILE := true

## 掩膜贴图（可在场景里指定；为空则按 LAND_MASK_PATH 加载）
@export var land_mask_texture: Texture2D

## 本次用的掩膜判定方式，供调试输出
var _mask_mode := ""


## 陆地占比超过这个阈值才算整格陆地。
## 用「整格面积占比」而不是「格中心 5×5 采样」的原因：
## 掩膜分辨率远高于网格（1772px / 16 格 ≈ 110px 一格），中心采样会被
## 小岛完全主导——实测格子 87 中心正好压在一个岛上（25/25 全不透明），
## 但台风走到同一格内的 (752,704) 明明是透明海洋，于是被误判登陆。
## 取 0.5：格内过半是陆地才算陆地，小岛和半岛不会被当成整格陆地。
const LAND_FRACTION_THRESHOLD := 0.5
## 每格内部细分的采样数（LAND_FRACTION_SAMPLES × LAND_FRACTION_SAMPLES 个点）
const LAND_FRACTION_SAMPLES := 12

## 山区掩膜（参考里的「基础系统//山区」）。用户用高程数据渲染的 1000m 以上区域。
## 约定和陆地掩膜一样：**不透明 = 该区域**。
const MOUNTAIN_MASK_PATH := "res://assets/images/WPAC_LAND1000.png"
## 2500m 以上的掩膜。参考里没有第三档，暂时留着备用（未接入物理）。
const MOUNTAIN_HIGH_MASK_PATH := "res://assets/images/WPAC_LAND2500.png"

## 山区格子（1 = 1000m 以上），供绘制和 F5 调试视图用
var mountain_mask := PackedByteArray()

# ------------------------- 地形判定的两种粒度 -------------------------
## true  = **按像素采样**（推荐，贴合参考的 `touching` 语义）
## false = 按 192 格数组判定（整格过半才算）
##
## ⚠ 为什么默认用像素级：
##   一格是 8.3°×8.9°（约 900 公里），台湾、日本本州、新几内亚、澳洲大分水岭
##   这些**细长山脉根本占不到一格的一半**，会被整格投票洗掉；
##   而四川盆地连同周围山脉一起投票时，山脉反而赢（盆地被误判成山区）。
##   参考用的是精灵接触判定（等效像素级），所以像素级才是对的粒度。
const USE_PIXEL_TERRAIN_TEST := true

## 掩膜原图缓存，像素级判定要用
var _land_img: Image = null
var _land_img_alpha := true
var _mountain_img: Image = null
var _mountain_img_alpha := true


## 在掩膜原图上按世界坐标取一个像素
func _sample_terrain(img: Image, pos: Vector2, use_alpha: bool) -> bool:
	if img == null:
		return false
	var w := img.get_width()
	var h := img.get_height()
	var px := clampi(int(pos.x / Const.MAP_W * float(w)), 0, w - 1)
	var py := clampi(int(pos.y / Const.MAP_H * float(h)), 0, h - 1)
	return _is_land_sample(img.get_pixel(px, py), use_alpha)


func _load_terrain_image(path: String) -> Array:
	if path.is_empty() or not ResourceLoader.exists(path):
		return [null, true]
	var tex := load(path) as Texture2D
	if tex == null:
		return [null, true]
	var img := tex.get_image()
	if img == null:
		return [null, true]
	img.convert(Image.FORMAT_RGBA8)
	return [img, _mask_has_transparency(img)]


## 把一张掩膜原图按「整格面积占比」采成 192 格的 0/1 数组。
## 陆地掩膜和山区掩膜都用这一套，保证两者判定一致。
## ⚠ 这个数组只用于**绘制和调试显示**；物理碰撞走 is_land_at_world /
##   is_mountain_at_world 的**像素级采样**（见 USE_PIXEL_TERRAIN_TEST）。
func _sample_mask_to_cells(img: Image, use_alpha: bool) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(Const.CELL_COUNT)
	if img == null:
		return out
	var w := img.get_width()
	var h := img.get_height()
	var samples := LAND_FRACTION_SAMPLES
	for i in Const.CELL_COUNT:
		var rect := Const.cell_rect_world(i + 1)
		var hits := 0
		var total := 0
		for sy in samples:
			for sx in samples:
				var wx := rect.position.x + rect.size.x * (sx + 0.5) / samples
				var wy := rect.position.y + rect.size.y * (sy + 0.5) / samples
				var px := clampi(int(wx / Const.MAP_W * float(w)), 0, w - 1)
				var py := clampi(int(wy / Const.MAP_H * float(h)), 0, h - 1)
				total += 1
				if _is_land_sample(img.get_pixel(px, py), use_alpha):
					hits += 1
		out[i] = 1 if float(hits) / maxf(1.0, float(total)) > LAND_FRACTION_THRESHOLD else 0
	return out


## 建立山区掩膜（1000m 以上）。和陆地掩膜各建各的，互不影响。
func build_mountain_mask() -> void:
	var r := _load_terrain_image(MOUNTAIN_MASK_PATH)
	_mountain_img = r[0]
	_mountain_img_alpha = r[1]
	if _mountain_img != null:
		mountain_mask = _sample_mask_to_cells(_mountain_img, _mountain_img_alpha)
	else:
		mountain_mask = PackedByteArray()
		mountain_mask.resize(Const.CELL_COUNT)


## 世界坐标是否落在山区（参考里的「touching 基础系统//山区?」）
func is_mountain_at_world(pos: Vector2) -> bool:
	if USE_PIXEL_TERRAIN_TEST and _mountain_img != null:
		return _sample_terrain(_mountain_img, pos, _mountain_img_alpha)
	var idx := Const.cell_index_from_world(pos)
	if idx < 1 or idx > mountain_mask.size():
		return false
	return mountain_mask[idx - 1] == 1


## 有多少格是山区（调试/显示用）
func mountain_cell_count() -> int:
	var n := 0
	for v in mountain_mask:
		if v == 1:
			n += 1
	return n


## 建立陆地掩膜。
## 优先用用户在场景里指定的贴图，其次用 LAND_MASK_PATH，都没有才退回地图像素启发式。
##
## 两种掩膜格式都支持，自动识别：
##   ① **透明掩膜（当前用这个）**：海洋扣成透明、陆地纯黑 → 判 alpha
##      抗锯齿边缘 alpha 是渐变的，用 0.5 一刀切最干净，不受配色影响
##   ② 二值位图：白 = 海洋、黑 = 陆地 → 判亮度
## 只要掩膜里存在真正的透明像素，就按方式 ① 处理。
func build_land_mask(map_texture: Texture2D = null) -> void:
	# 山区掩膜跟着一起建，保证两者用的是同一套面积占比判定
	build_mountain_mask()

	var mask_tex := land_mask_texture
	if mask_tex == null and USE_LAND_MASK_FILE and ResourceLoader.exists(LAND_MASK_PATH):
		mask_tex = load(LAND_MASK_PATH)
	if mask_tex == null:
		_build_land_mask_from_map(map_texture)
		return

	var img := mask_tex.get_image()
	if img == null:
		_build_land_mask_from_map(map_texture)
		return

	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var use_alpha := _mask_has_transparency(img)
	_mask_mode = "alpha（透明掩膜）" if use_alpha else "亮度（二值位图）"
	# 缓存原图：像素级地形判定要用（见 USE_PIXEL_TERRAIN_TEST）
	_land_img = img
	_land_img_alpha = use_alpha
	var land_count := 0
	var land_cols := ""
	var samples := LAND_FRACTION_SAMPLES

	# 整格面积占比判定
	for i in Const.CELL_COUNT:
		var rect := Const.cell_rect_world(i + 1)
		var land_hits := 0
		var total := 0
		for sy in samples:
			for sx in samples:
				var wx := rect.position.x + rect.size.x * (sx + 0.5) / samples
				var wy := rect.position.y + rect.size.y * (sy + 0.5) / samples
				var px := clampi(int(wx / Const.MAP_W * float(w)), 0, w - 1)
				var py := clampi(int(wy / Const.MAP_H * float(h)), 0, h - 1)
				total += 1
				if _is_land_sample(img.get_pixel(px, py), use_alpha):
					land_hits += 1
		var frac := float(land_hits) / maxf(1.0, float(total))
		var is_land := frac > LAND_FRACTION_THRESHOLD
		land_mask[i] = 1 if is_land else 0
		if is_land:
			land_count += 1
		land_cols += "#" if is_land else "."

	var rows := PackedStringArray()
	for r in Const.ROWS:
		rows.append("    %s" % land_cols.substr(r * Const.COLS, Const.COLS))

	_mask_ready = true
	_mask_source = "掩膜 %dx%d（%s）：陆地 %d / %d 格\n%s" % [
		w, h, _mask_mode, land_count, Const.CELL_COUNT, "\n".join(rows),
	]
	queue_redraw()


## 掩膜里是否存在真正的透明像素 → 决定用 alpha 还是亮度判定
func _mask_has_transparency(img: Image) -> bool:
	var w := img.get_width()
	var h := img.get_height()
	# 稀疏抽样即可，透明掩膜的透明区占比很大（海洋占六成）
	var step_x: int = maxi(1, w / 64)
	var step_y: int = maxi(1, h / 64)
	for y in range(0, h, step_y):
		for x in range(0, w, step_x):
			if img.get_pixel(x, y).a < 0.5:
				return true
	return false


## 单个采样点是不是陆地。
##   use_alpha = true  → 透明掩膜：不透明才是陆地
##   use_alpha = false → 二值位图：偏黑才是陆地（阈值取半，抗锯齿灰边归到陆地一侧）
static func _is_land_sample(c: Color, use_alpha: bool) -> bool:
	if use_alpha:
		return c.a >= 0.5
	return c.r + c.g + c.b < 1.5


## 退路：没有掩膜贴图时，从地图贴图的颜色猜（旧实现，浅海会被误判成陆地）
func _build_land_mask_from_map(map_texture: Texture2D) -> void:
	if map_texture == null:
		_mask_source = "无掩膜也无地图贴图，全部按海洋处理"
		land_mask.fill(0)
		_mask_ready = true
		queue_redraw()
		return

	var img := map_texture.get_image()
	if img == null:
		_mask_source = "无法读取贴图，全部按海洋处理"
		land_mask.fill(0)
		_mask_ready = true
		queue_redraw()
		return

	img.convert(Image.FORMAT_RGBA8)
	img.resize(Const.COLS * 8, Const.ROWS * 8, Image.INTERPOLATE_BILINEAR)
	var w := img.get_width()
	var h := img.get_height()
	var land_count := 0
	var debug_cols := ""

	for i in Const.CELL_COUNT:
		var center := Const.cell_center_world(i + 1)
		var px := clampi(int(center.x / Const.MAP_W * float(w)), 0, w - 1)
		var py := clampi(int(center.y / Const.MAP_H * float(h)), 0, h - 1)
		var votes := 0
		var total := 0
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				total += 1
				if _is_map_land(img.get_pixel(clampi(px + dx, 0, w - 1), clampi(py + dy, 0, h - 1))):
					votes += 1
		var is_land := total > 0 and votes * 2 > total
		land_mask[i] = 1 if is_land else 0
		if is_land:
			land_count += 1
		debug_cols += "#" if is_land else "."

	var debug_rows := PackedStringArray()
	for r in Const.ROWS:
		debug_rows.append("    %s" % debug_cols.substr(r * Const.COLS, Const.COLS))

	_mask_ready = true
	_mask_source = "地图 %dx%d（颜色启发式）：陆地 %d / %d 格\n%s" % [
		w, h, land_count, Const.CELL_COUNT, "\n".join(debug_rows),
	]
	queue_redraw()


## 退路用的判据：海洋 = 蓝色明显压过红色的深蓝；其余都按陆地处理。
static func _is_map_land(c: Color) -> bool:
	if c.a < 0.1:
		return false
	return (c.b - c.r) < 0.10


func land_mask_info() -> String:
	return _mask_source


func is_land_cell(index: int) -> bool:
	if index < 1 or index > Const.CELL_COUNT:
		return false
	return land_mask[index - 1] == 1


## 世界坐标是否落在陆地上（台风登陆判定用）
## 默认按像素采样（见 USE_PIXEL_TERRAIN_TEST 的注释）；关掉才退回整格判定。
func is_land_at_world(pos: Vector2) -> bool:
	if USE_PIXEL_TERRAIN_TEST and _land_img != null:
		return _sample_terrain(_land_img, pos, _land_img_alpha)
	return is_land_cell(Const.cell_index_from_world(pos))


# ------------------------- 数据访问 -------------------------

func sst_at(index: int) -> float:
	if index < 1 or index > Const.CELL_COUNT:
		return 0.0
	return sst[index - 1]


func set_sst_at(index: int, value: float) -> void:
	if index >= 1 and index <= Const.CELL_COUNT:
		sst[index - 1] = value


func set_pressure_at(index: int, value: float) -> void:
	if index >= 1 and index <= Const.CELL_COUNT:
		pressure[index - 1] = value


# ------------------------- 绘制 -------------------------

func _draw() -> void:
	# ① 调试用的掩膜可视化。独立于海温层——按 T 关掉海温后照样能看。
	if mask_view_mode > 0:
		var ov := _mask_view_texture(mask_view_mode)
		if ov != null:
			draw_texture_rect(ov, Rect2(0.0, 0.0, Const.MAP_W, Const.MAP_H), false)

	if not _mask_ready:
		return

	# ② 游戏实际判定的陆地格子（物理真正用的就是这个 192 格数组）
	if show_land_cells:
		for i in Const.CELL_COUNT:
			if land_mask[i] == 1:
				var lr := Const.cell_rect_world(i + 1)
				draw_rect(lr, Color(1.0, 0.55, 0.1, 0.14))
				draw_rect(lr, Color(1.0, 0.7, 0.2, 0.85), false, 1.5)

	# T 键关闭时整层不画，只留 WPAC.png 底图
	if not show_field:
		return

	for i in Const.CELL_COUNT:
		var idx := i + 1
		var rect := Const.cell_rect_world(idx)
		var is_land := land_mask[i] == 1

		if show_pressure:
			# 气压场覆盖全部 192 格（含陆地）——陆地也有地面气压
			var t: float = clampf((pressure[i] - 940.0) / 73.0, 0.0, 1.0)
			draw_rect(rect, Color(0.10, 0.28, 0.85, 0.05 + 0.5 * (1.0 - t)))
		else:
			if is_land:
				# 陆地上把海温色压暗，让地图的陆地纹理透出来
				draw_rect(rect, Color(0.10, 0.10, 0.08, 0.38))
			else:
				var c := Const.sst_color(sst[i])
				draw_rect(rect, Color(c.r, c.g, c.b, 0.42))

		if show_grid_lines:
			draw_rect(rect, Color(1.0, 1.0, 1.0, 0.22), false, 1.0)
