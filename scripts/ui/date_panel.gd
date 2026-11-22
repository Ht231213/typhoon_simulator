class_name DatePanel
extends Control
## 「调整日期」弹窗（1.3.0 重做）：场景内的自定义面板，不用 AcceptDialog。
## AcceptDialog 是独立系统窗口，主题改不动、也没有动画，跟其它界面完全不搭。
##
## 用法：
##   panel.open(SimClock.month, SimClock.day)
##   面板自己 emit confirmed(month, day)，调用方去写 sim.set_date。
##
## 动画：遮罩淡入 + 卡片从 0.96 倍放大落位 + 内容错开淡入；关闭反向。

signal confirmed(month: int, day: int)

const CARD_SIZE := Vector2(460.0, 268.0)

var _dim: ColorRect = null
var _card: SkewPanel = null
var _title: Label = null
var _month_spin: SpinBox = null
var _day_spin: SpinBox = null
var _ok: SkewButton = null
var _cancel: SkewButton = null
var _items: Array[Control] = []
var _busy := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	# ⚠ 台风图标/粒子在 PathLayer 里用的是**绝对 z_index**（图标 2、粒子 20），
	#   普通 Control 的 z_index 是 0，光靠树序盖不住它们（弹窗会被台风图标压住）。
	#   这里提到 30，保证弹窗、遮罩在整张地图之上；暂停菜单走的是 CanvasLayer(10)，仍然更高。
	z_index = 30
	visible = false
	add_to_group("date_panel")
	_build()


func _build() -> void:
	# 遮罩：点空白处 = 取消
	_dim = ColorRect.new()
	_dim.color = Color(0.01, 0.02, 0.03, 0.74)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.gui_input.connect(_on_dim_input)
	add_child(_dim)

	# 卡片
	_card = SkewPanel.new()
	_card.corner_radius = 14.0
	# ⚠ 卡片用正圆角矩形（slant = 0）：平行四边形放到这么大尺寸会斜得很夸张，
	#   按钮的斜切是有意为之，卡片不是。
	_card.slant = 0.0
	_card.fill = Color(0.031, 0.043, 0.059, 0.98)
	_card.edge = Color(0.55, 0.88, 1.0, 0.55)
	_card.edge_width = 1.4
	_card.size = CARD_SIZE
	_card.position = (Vector2(1280.0, 720.0) - CARD_SIZE) * 0.5
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_card)

	var x := _card.position.x
	var y := _card.position.y
	var pad := 40.0
	var inner_w := CARD_SIZE.x - pad * 2.0

	_title = UiKit.make_label("调整日期", 24, Color(UiKit.ACCENT.r, UiKit.ACCENT.g, UiKit.ACCENT.b, 1.0))
	add_at(_title, Vector2(x + pad, y + 28.0), Vector2(inner_w, 32.0))

	# 两行：月份 / 日期
	_month_spin = _make_row(x + pad, y + 84.0, inner_w, "月份", 1, 12)
	_day_spin = _make_row(x + pad, y + 138.0, inner_w, "日期", 1, 30)

	# 按钮
	var ok_x := x + pad + inner_w - 300.0
	_ok = _add_skew_button("确定", Vector2(ok_x, y + CARD_SIZE.y - 84.0), Vector2(150.0, 48.0))
	_ok.selected = true
	_ok.pressed.connect(_on_ok)
	_cancel = _add_skew_button("取消", Vector2(ok_x + 162.0, y + CARD_SIZE.y - 84.0), Vector2(138.0, 48.0))
	_cancel.pressed.connect(close)


func _make_row(x: float, y: float, width: float, title: String, lo: int, hi: int) -> SpinBox:
	var label := UiKit.make_label(title, 17, UiKit.TEXT_DIM)
	add_at(label, Vector2(x, y), Vector2(90.0, 40.0))

	var spin := SpinBox.new()
	spin.min_value = float(lo)
	spin.max_value = float(hi)
	spin.step = 1.0
	spin.value = float(lo)
	spin.add_theme_font_size_override("font_size", 18)
	spin.size = Vector2(220.0, 40.0)
	spin.position = Vector2(x + 96.0, y)
	add_child(spin)
	_style_spin(spin)
	_items.append(spin)
	return spin


func _style_spin(spin: SpinBox) -> void:
	var le := spin.get_line_edit()
	if le == null:
		return
	le.add_theme_color_override("font_color", UiKit.TEXT)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(1, 1, 1, 0.06)
	box.border_color = Color(1, 1, 1, 0.20)
	box.set_border_width_all(1)
	box.set_corner_radius_all(7)
	box.content_margin_left = 10.0
	box.content_margin_right = 6.0
	le.add_theme_stylebox_override("normal", box)
	le.add_theme_stylebox_override("focus", box)


func _add_skew_button(text: String, pos: Vector2, sz: Vector2) -> SkewButton:
	var b := SkewButton.new()
	b.label_text = text
	b.label_size = 19
	b.corner_radius = 9.0
	b.position = pos
	b.size = sz
	add_child(b)
	_items.append(b)
	return b


func add_at(node: Control, pos: Vector2, sz: Vector2) -> void:
	add_child(node)
	node.position = pos
	node.size = sz
	_items.append(node)


# ------------------------------ 开关 ------------------------------

func open(month: int, day: int) -> void:
	_busy = false
	visible = true
	_month_spin.set_value_no_signal(clampi(month, 1, 12))
	_day_spin.set_value_no_signal(clampi(day, 1, 30))

	# 遮罩淡入 + 卡片放大落位 + 内容错开淡入
	_dim.modulate.a = 0.0
	UiKit.tween_float(self, _dim, "modulate:a", 1.0, 0.18, &"out_cubic")
	_card.pivot_offset = _card.size * 0.5
	_card.scale = Vector2(0.96, 0.96)
	UiKit.tween_vec2(self, _card, "scale", Vector2.ONE, 0.3, &"out_cubic")
	for i in _items.size():
		var c := _items[i]
		c.modulate.a = 0.0
		UiKit.tween_float(self, c, "modulate:a", 1.0, 0.24, &"out_quad", 0.05 + 0.04 * float(i))
	_ok.grab_focus()


func close() -> void:
	if _busy or not visible:
		return
	_busy = true
	UiKit.tween_vec2(self, _card, "scale", Vector2(0.98, 0.98), 0.16, &"in_cubic")
	var tw := UiKit.tween_float(self, _dim, "modulate:a", 0.0, 0.14, &"in_cubic")
	await tw.finished
	visible = false
	_card.scale = Vector2.ONE
	_dim.modulate.a = 1.0
	_busy = false


func _on_ok() -> void:
	confirmed.emit(int(_month_spin.value), int(_day_spin.value))
	close()


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
