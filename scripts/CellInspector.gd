extends CanvasLayer
## 海区探针：跟随鼠标显示所指海区的全部调试信息。由 T 键（海温查看模式）一并开关。
##
## 显示内容（用户要求）：
##   · 行列号 + 海区编号
##   · 该处经纬度
##   · 观测海温 / 季节变化幅度 / 两者相加的实际运算海温
##   · **是否进入冷水坑状态**（即是否被台风搅起的深层冷水降过温），
##     以及当前降温因子、停留计数、距阈值还差多少
##   · 陆地 / 山区 标记
##
## ⚠ 浮窗的 mouse_filter 必须是 IGNORE —— 它贴在鼠标底下，
##   要是吃掉鼠标事件，就没法在地图上点路径点了。

var map_layer: Node2D = null
var field: OceanField = null
var sim: Node = null

var _panel: PanelContainer
var _label: Label
var _hint: Label
var _last_idx := -1


func setup(p_map_layer: Node2D, p_field: OceanField, p_sim: Node) -> void:
	map_layer = p_map_layer
	field = p_field
	sim = p_sim


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 15
	_build_ui()
	visible = false


func _build_ui() -> void:
	_panel = PanelContainer.new()
	# ⚠ 绝对不能让浮窗吃鼠标事件，否则地图点不动
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", _make_style())
	add_child(_panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	_panel.add_child(box)

	_hint = Label.new()
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_theme_font_size_override("font_size", 16)
	_hint.add_theme_color_override("font_color", Color(0.65, 0.9, 1.0))
	box.add_child(_hint)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 14)
	box.add_child(_label)


func _make_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.08, 0.12, 0.88)
	sb.border_color = Color(0.4, 0.7, 0.9, 0.8)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


func open() -> void:
	visible = true
	set_process(true)
	_update()


func close() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func _process(_delta: float) -> void:
	if visible:
		_update()


func _update() -> void:
	if map_layer == null or field == null:
		return
	var world: Vector2 = map_layer.get_local_mouse_position()
	var inside: bool = world.x >= 0.0 and world.y >= 0.0 \
		and world.x < Const.MAP_W and world.y < Const.MAP_H

	if inside:
		var idx := Const.cell_index_from_world(world)
		if idx != _last_idx:
			_last_idx = idx
			_label.text = _describe(world, idx)
			# 文字变了要重新量一遍尺寸，否则浮窗大小不跟着变
			_panel.reset_size()
	else:
		_last_idx = -1
		_label.text = "鼠标不在图幅内"

	# 跟随鼠标；靠近右/下边缘时翻到另一侧，别跑出窗口
	var vp := get_viewport().get_visible_rect().size
	var mp := get_viewport().get_mouse_position()
	var size := _panel.size
	var pos := mp + Vector2(20.0, 20.0)
	if pos.x + size.x > vp.x:
		pos.x = mp.x - size.x - 20.0
	if pos.y + size.y > vp.y:
		pos.y = mp.y - size.y - 20.0
	_panel.position = pos


## 把一个海区的全部信息拼成多行文本
func _describe(world: Vector2, idx: int) -> String:
	var i := idx - 1
	var row := i / Const.COLS + 1
	var col := i % Const.COLS + 1

	var seasonal: float = SimClock.seasonal_sst_amplitude()
	var base: float = field.sst_base[i]
	var cur: float = field.sst[i]
	var drop: float = base - cur
	var dwell: int = int(field.dwell_ticks[i])
	var factor: float = field.cooling_rates[i]

	_hint.text = "海区探针 %d 号" % idx

	var L := PackedStringArray()
	L.append("行 %d   列 %d   编号 #%d" % [row, col, idx])

	var ll := Const.lonlat_from_uv(Const.uv_from_world(world))
	L.append("经纬   %.2f°E  %.2f°N" % [ll.x, ll.y])

	L.append("观测海温   %.2f ℃" % base)
	L.append("季节增幅   %+.2f ℃" % seasonal)
	L.append("★ 实际运算 %.2f ℃" % (cur + seasonal))

	# ---- 冷水坑状态（用户重点要的）----
	if drop > 0.001:
		L.append("")
		L.append("❄ 冷水坑：**是**（已被台风降 %.2f ℃）" % drop)
		L.append("   当前海温 %.2f ℃（观测 %.2f）" % [cur, base])
		if factor > 0.0:
			L.append("   正在降温中，降温因子 %.2f" % factor)
		else:
			L.append("   台风已离开，回升中")
		var kt := _active_wind()
		if kt > 0.0:
			var need: int = field.dwell_required_ticks(kt)
			L.append("   停留计数 %d tick（当前 %d kt 的阈值 %d）" % [dwell, int(roundf(kt)), need])
		else:
			L.append("   停留计数 %d tick" % dwell)
	else:
		L.append("")
		L.append("冷水坑：否（还没被台风降温过）")
		if dwell > 0:
			var kt2 := _active_wind()
			if kt2 > 0.0:
				L.append("   停留计数 %d tick（阈值 %d，够了才开始降温）" % [
					dwell, field.dwell_required_ticks(kt2)])
			else:
				L.append("   停留计数 %d tick" % dwell)

	# ---- 地形标记 ----
	# ⚠ 用**像素级**判定，和物理一致。整格掩膜（land_mask/mountain_mask）
	#   只用于绘制和 F5 调试视图，两者不一定相同（例：台湾所在格过半是海，
	#   整格判「海洋」，但站在台北那一点上物理判「陆地」）。
	var tags := PackedStringArray()
	if field.is_land_at_world(world):
		tags.append("陆地")
	if field.is_mountain_at_world(world):
		tags.append("山区（1000m 以上）")
	if tags.is_empty():
		tags.append("开阔海面")
	L.append("")
	L.append("地形（物理判定）：" + "、".join(tags))

	var cell_tags := PackedStringArray()
	if field.land_mask[i] == 1:
		cell_tags.append("陆地")
	if field.mountain_mask[i] == 1:
		cell_tags.append("山区")
	if cell_tags.is_empty():
		cell_tags.append("海洋")
	L.append("整格掩膜：%s" % "、".join(cell_tags))

	return "\n".join(L)


func _active_wind() -> float:
	if sim == null:
		return 0.0
	var s = sim.active_storm
	return s.wind_kt if s != null else 0.0
