class_name MenuPanel
extends Control
## 2.0 子界面的基类：左边操作区、右边背景大图形，进出场动画统一。
##
## 子类只需要实现 `_build()`，用 `add_at()` 往左侧操作区放控件，
## 基类会自动给每一项做「错开滑入 / 错开滑出」的曲线动画。

signal closed

## 子界面分界线在画面底部的 x（相对宽度）。比主界面宽，留给操作区。
const EDGE_BOTTOM_X := 0.56
## 内容区左边距
const CONTENT_X := 84.0
## 右侧云图在子界面里的压暗程度
const DIM := 0.30

var backdrop: Backdrop = null
var content: Control = null
## 关闭后回调（打开方注入）
var on_closed: Callable = Callable()
## ESC 是否等同于点返回
var close_on_cancel := true

var _items: Array[Control] = []
var _home: Array[Vector2] = []
var _busy := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# ESC 暂停菜单里也用它 → 全暂停时仍要能动
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	backdrop = Backdrop.new()
	backdrop.name = "Backdrop"
	backdrop.edge_bottom_x = EDGE_BOTTOM_X
	# 子界面：台风眼往右下挪，让右侧留出更大一片云图
	backdrop.eye_anchor = Vector2(0.82, 0.40)
	backdrop.sky_brightness = 0.66
	backdrop.sky_contrast = 1.22
	backdrop.dim = 0.0
	add_child(backdrop)

	content = Control.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(content)
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_build()


## 子类实现：用 add_at() 往左侧操作区添加控件
func _build() -> void:
	pass


## 往内容区放一个绝对定位控件，并登记进动画列表
func add_at(child: Control, pos: Vector2, sz: Vector2) -> Control:
	content.add_child(child)
	child.position = pos
	child.size = sz
	_items.append(child)
	_home.append(pos)
	return child


## 便捷：加一个文本标签
func add_label(text: String, pos: Vector2, sz: Vector2, font_size: int, color: Color = UiKit.TEXT) -> Label:
	var l := UiKit.make_label(text, font_size, color)
	return add_at(l, pos, sz) as Label


## 便捷：加一个平行四边形按钮
func add_button(text: String, pos: Vector2, sz: Vector2, font_size: int = 22) -> SkewButton:
	var b := SkewButton.new()
	b.label_text = text
	b.label_size = font_size
	b.corner_radius = 9.0
	add_at(b, pos, sz)
	return b


# ------------------------------ 进出场 ------------------------------

func open() -> void:
	if _busy:
		return
	_busy = true
	visible = true
	backdrop.set_reveal(1.0)
	backdrop.set_dim(0.0, 0.0)
	for i in _items.size():
		_items[i].modulate.a = 0.0
		_items[i].position = _home[i] + Vector2(-58.0, 6.0)

	# 背景大图形从右边滑回 + 右侧压暗
	backdrop.reveal_tween(0.0, 0.6, &"out_cubic")
	backdrop.set_dim(DIM, 0.5)

	for i in _items.size():
		_anim_in(i)

	await get_tree().create_timer(0.06).timeout
	_busy = false
	_focus_first()


func close() -> void:
	if _busy or not visible:
		return
	_busy = true
	for i in _items.size():
		var c := _items[i]
		var delay := 0.028 * float(maxi(_items.size() - 1 - i, 0))
		UiKit.tween_float(self, c, "modulate:a", 0.0, 0.22, &"out_quad", delay)
		UiKit.tween_vec2(self, c, "position", c.position + Vector2(76.0, 0.0), 0.36, &"in_cubic", delay)
	backdrop.reveal_tween(1.0, 0.46, &"in_cubic", 0.06)
	backdrop.set_dim(0.0, 0.36)
	await get_tree().create_timer(0.52).timeout
	visible = false
	_busy = false
	closed.emit()
	if on_closed.is_valid():
		on_closed.call()


## 每一项单独：错开 45 ms，淡入 0.26 s，位移 48 px / 0.5 s
func _anim_in(i: int) -> void:
	var c := _items[i]
	var home := _home[i]
	var delay := 0.06 + 0.045 * float(i)
	UiKit.tween_float(self, c, "modulate:a", 1.0, 0.26, &"out_quad", delay)
	UiKit.tween_vec2(self, c, "position", home, 0.5, &"out_cubic", delay)


func _focus_first() -> void:
	for c in _items:
		if c is BaseButton and not c.disabled:
			c.grab_focus()
			return


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not close_on_cancel:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
