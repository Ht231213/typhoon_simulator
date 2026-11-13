class_name SkewButton
extends Button
## 2.0 的主按钮：圆角平行四边形（左右边斜率 = 背景分界线斜率），
## 悬停时整体浮起 + 白色从左往右填充、文字反相；移出时反向收回。
## 动画曲线是 UiKit 里手 K 的 Curve，不用内置 ease。

const EDGE_W := 1.6

class Plate:
	extends Control
	var btn          # 指回 SkewButton（内部类不写死类型，避免解析顺序问题）
	func _draw() -> void:
		if btn != null:
			btn.draw_plate(self)


@export var label_text: String = "":
	set(value):
		label_text = value
		if _label != null:
			_label.text = value
@export var label_size: int = 26
## 斜面斜率：每 1 px 高度对应 0.45 px 水平偏移（与 UiKit.SLANT 一致）
@export_range(0.0, 1.0, 0.01) var slant: float = 0.45
@export var corner_radius: float = 10.0
@export var rest_fill: Color = Color(1, 1, 1, 0.055)
@export var hover_fill: Color = Color(0.95, 0.985, 1.0, 0.97)
@export var edge_color: Color = Color(1, 1, 1, 0.20)
@export var edge_hover: Color = Color(0.56, 0.90, 1.0, 0.95)
@export var label_color: Color = Color(0.93, 0.96, 0.99, 0.95)
@export var label_color_hover: Color = Color(0.03, 0.05, 0.07, 1.0)
## accent 色：冰蓝（与 UiKit.ACCENT 一致）
@export var accent: Color = Color(0.55, 0.88, 1.0, 1.0)
## 悬停浮起的像素
@export var lift_px: float = 7.0
## 悬停填充时长（秒）
@export var fill_time: float = 0.40
## 文字水平对齐补偿：平行四边形顶部右移，文字跟着略右移才不显偏
@export var text_shift_ratio: float = 0.5
## 选中态（模式选择 / 侧栏 tab）
@export var selected: bool = false:
	set(value):
		if selected == value:
			return
		selected = value
		_redraw()

var _plate: Control = null
var _label: Label = null
var _hover := 0.0
var _focus := 0.0
var _tween: Tween = null
var _focus_tween: Tween = null
var _enabled := true


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 自身不画任何默认皮肤：所有视觉都在 Plate 里
	flat = true
	for slot in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
		add_theme_stylebox_override(slot, StyleBoxEmpty.new())

	_plate = Plate.new()
	_plate.name = "Plate"
	_plate.btn = self
	_plate.show_behind_parent = true
	_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_plate)
	_plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_label = UiKit.make_label(label_text, label_size, label_color)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# ⚠ 不要用 PRESET_FULL_RECT：锚点左右不等时手动设 size 会被引擎覆盖并刷警告。
	#   锚点全 0 + 显式 position/size（见 _on_resized），随按钮尺寸走。
	add_child(_label)

	mouse_entered.connect(_on_hover_changed.bind(true))
	mouse_exited.connect(_on_hover_changed.bind(false))
	focus_entered.connect(_on_focus_changed.bind(true))
	focus_exited.connect(_on_focus_changed.bind(false))
	resized.connect(_on_resized)
	_on_resized()
	_apply()


func set_enabled(value: bool) -> void:
	_enabled = value
	disabled = not value
	modulate = Color(1, 1, 1, 1) if value else Color(1, 1, 1, 0.38)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if value else Control.CURSOR_FORBIDDEN


func _on_resized() -> void:
	if _label == null:
		return
	_label.add_theme_font_size_override("font_size", label_size)
	var dx := size.y * slant * text_shift_ratio
	_label.position = Vector2(dx, 0.0)
	_label.size = Vector2(maxf(size.x - dx, 1.0), size.y)
	_redraw()


func _redraw() -> void:
	if _plate != null:
		_plate.queue_redraw()


func _on_hover_changed(on: bool) -> void:
	if not _enabled:
		return
	_anim(1.0 if on else 0.0, fill_time, &"out_quint" if on else &"in_cubic")


func _on_focus_changed(on: bool) -> void:
	if _focus_tween != null and _focus_tween.is_valid():
		_focus_tween.kill()
	var from := _focus
	var to := 1.0 if on else 0.0
	_focus_tween = create_tween()
	_focus_tween.tween_method(func(u: float) -> void:
		_focus = lerpf(from, to, UiKit.ease_named(&"out_cubic", u))
		_apply()
	, 0.0, 1.0, 0.24)


func _anim(target: float, dur: float, ease_name: StringName) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	var from := _hover
	_tween = create_tween()
	_tween.tween_method(func(u: float) -> void:
		_hover = lerpf(from, target, UiKit.ease_named(ease_name, u))
		_apply()
	, 0.0, 1.0, dur)


## 立即把填充与焦点归零（菜单整体出场时用）
func reset_visual() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if _focus_tween != null and _focus_tween.is_valid():
		_focus_tween.kill()
	_hover = 0.0
	_focus = 0.0
	_apply()


func _apply() -> void:
	if _label == null:
		return
	var s := clampf(_hover, 0.0, 1.0)
	if _focus > 0.001 and s < 1.0:
		s = maxf(s, 0.075 * _focus)
	_plate.position = Vector2(0.0, -lift_px * s)
	_label.position.y = -lift_px * 0.45 * s
	var tint := label_color
	if selected:
		tint = accent
	if s > 0.0:
		tint = tint.lerp(label_color_hover, clampf((s - 0.22) / 0.5, 0.0, 1.0))
	_label.add_theme_color_override("font_color", tint)
	_redraw()


## 由 Plate 回调：把当前状态画成一块平行四边形
func draw_plate(ci: Control) -> void:
	var sz := ci.size
	if sz.x < 4.0 or sz.y < 4.0:
		return
	var inset := EDGE_W * 0.5
	var w := sz.x - inset * 2.0
	var h := sz.y - inset * 2.0
	var poly := UiKit.round_polygon(UiKit.parallelogram(Vector2(w, h), slant), corner_radius, 6)
	for i in poly.size():
		poly[i] += Vector2(inset, inset)

	# 底
	ci.draw_colored_polygon(poly, rest_fill)

	# 选中态：淡蓝填充 + 左侧高亮条
	if selected:
		ci.draw_colored_polygon(poly, Color(accent.r, accent.g, accent.b, 0.14))
		var bar := UiKit.clip_x_max(poly, inset + 3.5)
		if bar.size() >= 3:
			ci.draw_colored_polygon(bar, accent)

	# 悬停：从左往右填充白色
	var s := clampf(_hover, 0.0, 1.0)
	if s > 0.002:
		var clipped := UiKit.clip_x_max(poly, inset + w * s)
		if clipped.size() >= 3:
			ci.draw_colored_polygon(clipped, hover_fill)

	# 描边（AA）：常态淡白，悬停/选中转冰蓝
	var edge := edge_color
	if selected:
		edge = edge.lerp(edge_hover, 0.55)
	edge = edge.lerp(edge_hover, clampf(s, 0.0, 1.0))
	var ring := poly.duplicate()
	ring.append(poly[0])
	ci.draw_polyline(ring, edge, EDGE_W, true)

	# 键盘焦点：内侧再描一圈细冰蓝线
	if _focus > 0.001:
		var inner := UiKit.round_polygon(
			UiKit.parallelogram(Vector2(w - 7.0, h - 7.0), slant), maxf(corner_radius - 3.0, 2.0), 6)
		for i in inner.size():
			inner[i] += Vector2(inset + 3.5, inset + 3.5)
		var r2 := inner.duplicate()
		r2.append(inner[0])
		ci.draw_polyline(r2, Color(accent.r, accent.g, accent.b, 0.42 * _focus), 1.2, true)
