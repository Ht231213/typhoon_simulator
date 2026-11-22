extends Control
## 2.0 主界面：左侧斜切操作区 + 右侧卫星云图。
##
## 四个按钮**沿背景那条斜线斜向排列**：每往下一个按钮，水平方向就往左退
## GAP_Y * SLANT（和分界线、按钮自身的左右边同一个斜率），所以按钮左边缘
## 连成一条与背景色块完全平行的线。
##
## 所有动画都走 UiKit.tween_float / tween_vec2（手 K 的 Curve）：
## 进场回弹、菜单依次甩出、背景沿斜线滑出，没有一条是线性的。

const VERSION_COLOR := Color(0.62, 0.72, 0.80, 0.55)

const MENU := [
	{"text": "模拟单台", "key": "sim"},
	{"text": "ACE 存档", "key": "ace"},
	{"text": "设置", "key": "settings"},
	{"text": "退出", "key": "quit"},
]

const BTN_W := 316.0
const BTN_H := 58.0
## 第一个按钮的位置（屏幕坐标）
const BTN_X0 := 168.0
const BTN_Y0 := 250.0
## 相邻按钮的垂直间距
const GAP_Y := 74.0
## 每下一个按钮沿斜线左移的距离（= 垂直间距 × 背景斜率）
const STEP_X := -GAP_Y * 0.45

var _backdrop: Backdrop = null
var _header: Control = null
var _footer: Control = null
var _buttons: Array[SkewButton] = []
var _btn_home: Array[Vector2] = []
var _header_home := Vector2.ZERO
var _panels: Dictionary = {}
var _busy := false
var _panel_open := false
## 启动动画会提前把本场景实例化出来预热（避免闪白时卡顿），
## 那种情况下不要自己播进场动画，等它那边调 play_intro()
@export var auto_intro := true


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	# 启动动画那段音乐如果还在放，这里接着放（同一个文件、同一首曲子）
	MusicManager.continue_title()
	if auto_intro:
		play_intro()
	else:
		_prepare_intro()


# ------------------------------ 构建 ------------------------------

func _build() -> void:
	_backdrop = Backdrop.new()
	_backdrop.name = "Backdrop"
	add_child(_backdrop)

	_header = Control.new()
	_header.name = "Header"
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_header)

	var title := UiKit.make_title("台风模拟", 54)
	title.position = Vector2(78.0, 84.0)
	title.size = Vector2(520.0, 74.0)
	_header.add_child(title)

	var sub := UiKit.make_label("T Y P H O O N   S I M U L A T O R",
		13, Color(UiKit.ACCENT.r, UiKit.ACCENT.g, UiKit.ACCENT.b, 0.8))
	sub.position = Vector2(82.0, 160.0)
	sub.size = Vector2(520.0, 20.0)
	_header.add_child(sub)

	var rule := ColorRect.new()
	rule.color = Color(UiKit.ACCENT.r, UiKit.ACCENT.g, UiKit.ACCENT.b, 0.5)
	rule.position = Vector2(82.0, 196.0)
	rule.size = Vector2(196.0, 2.0)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header.add_child(rule)

	# --- 菜单按钮：斜向排列 ---
	for i in MENU.size():
		var item: Dictionary = MENU[i]
		var b := SkewButton.new()
		b.name = "Btn" + String(item.key).capitalize()
		b.label_text = String(item.text)
		b.label_size = 25
		b.corner_radius = 10.0
		var home := Vector2(BTN_X0 + STEP_X * float(i), BTN_Y0 + GAP_Y * float(i))
		b.position = home
		b.size = Vector2(BTN_W, BTN_H)
		b.pressed.connect(_on_menu_pressed.bind(String(item.key)))
		add_child(b)
		_buttons.append(b)
		_btn_home.append(home)

	_footer = Control.new()
	_footer.name = "Footer"
	_footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_footer)

	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	var ver := UiKit.make_label("v" + version if version != "" else "", 14, VERSION_COLOR)
	ver.position = Vector2(82.0, 656.0)
	ver.size = Vector2(240.0, 22.0)
	_footer.add_child(ver)

	# ⚠ 音乐出处：开屏曲与主界面 BGM 取自录屏里的 Phigros 开屏音乐，
	#   这里在界面上明确标出来（作者要求显眼声明）。
	var music := UiKit.make_label("BGM · Phigros OST  © Pigeon Games", 13,
		Color(UiKit.ACCENT.r, UiKit.ACCENT.g, UiKit.ACCENT.b, 0.62))
	music.position = Vector2(80.0, 678.0)
	music.size = Vector2(420.0, 22.0)
	_footer.add_child(music)

	var credit := UiKit.make_label("Hetao | Minedsa", 14, VERSION_COLOR)
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	credit.position = Vector2(880.0, 662.0)
	credit.size = Vector2(316.0, 24.0)
	_footer.add_child(credit)

	_header_home = _header.position


# ------------------------------ 进场 ------------------------------

## 把界面摆到「进场前」的状态（预热实例化时用，不触发动画）
func _prepare_intro() -> void:
	_backdrop.set_reveal(1.0)
	_header.modulate.a = 0.0
	_header.position = _header_home + Vector2(-52.0, 0.0)
	_footer.modulate.a = 0.0
	for i in _buttons.size():
		_buttons[i].modulate.a = 0.0
		# 从左侧沿斜线滑进来（x 退后、y 略微下压）
		_buttons[i].position = _btn_home[i] + Vector2(-92.0, 10.0)
		_buttons[i].reset_visual()


func play_intro() -> void:
	_prepare_intro()
	_backdrop.reveal_tween(0.0, 0.5, &"out_cubic")

	# 标题组：0.45 s 淡入 + 0.6 s 从左侧 52 px 处滑到位置
	UiKit.tween_float(self, _header, "modulate:a", 1.0, 0.45, &"out_quad", 0.04)
	UiKit.tween_vec2(self, _header, "position", _header_home, 0.6, &"out_cubic", 0.04)
	UiKit.tween_float(self, _footer, "modulate:a", 1.0, 0.5, &"out_quad", 0.3)

	# 四个按钮：每个错开 70 ms，位移 78 px，0.62 s 到位
	for i in _buttons.size():
		var b := _buttons[i]
		var home: Vector2 = _btn_home[i]
		var delay := 0.08 + 0.07 * float(i)
		UiKit.tween_float(self, b, "modulate:a", 1.0, 0.3, &"out_quad", delay)
		UiKit.tween_vec2(self, b, "position", home, 0.62, &"out_cubic", delay)


# ------------------------------ 菜单 ------------------------------

func _on_menu_pressed(key: String) -> void:
	if _busy:
		return
	if key == "quit":
		_quit()
		return
	_open_panel(key)


func _panel(key: String) -> MenuPanel:
	if _panels.has(key):
		return _panels[key]
	var p: MenuPanel = null
	match key:
		"sim":
			p = SimSetupPanel.new()
		"ace":
			p = AceBoardPanel.new()
		"settings":
			p = AppSettingsPanel.new()
		_:
			push_error("未知菜单项：" + key)
			return null
	p.name = "Panel" + key.capitalize()
	add_child(p)
	p.on_closed = _on_panel_closed
	_panels[key] = p
	return p


## 点入口：菜单从上到下依次向左甩出，背景大图形沿分界线滑出，再推出子界面
func _open_panel(key: String) -> void:
	if _busy:
		return
	if not ["sim", "ace", "settings"].has(key):
		push_error("未知菜单项：" + key)
		return
	_busy = true
	_panel_open = true
	for b in _buttons:
		b.release_focus()

	# 标题组：0.24 s 淡出；整组往左上退 120 px / 上抬 14 px，0.45 s 完成（in_cubic 越走越快）
	UiKit.tween_float(self, _header, "modulate:a", 0.0, 0.24, &"out_quad")
	UiKit.tween_vec2(self, _header, "position", _header_home + Vector2(-120.0, -14.0), 0.45, &"in_cubic")
	UiKit.tween_float(self, _footer, "modulate:a", 0.0, 0.24, &"out_quad")

	for i in _buttons.size():
		var b := _buttons[i]
		var delay := 0.06 * float(i)
		# 每个按钮单独：位移 560 px、0.5 s、in_cubic（先慢后急甩出去），淡出比位移晚 0.18 s
		UiKit.tween_vec2(self, b, "position", Vector2(-BTN_W - 220.0, b.position.y - 16.0), 0.5, &"in_cubic", delay)
		UiKit.tween_float(self, b, "modulate:a", 0.0, 0.26, &"out_quad", delay + 0.18)

	_backdrop.reveal_tween(1.0, 0.62, &"in_cubic", 0.12)
	await get_tree().create_timer(0.82).timeout
	_busy = false
	var p := _panel(key)
	if p != null:
		p.open()


## 子界面关闭：主界面复位并重新进场
func _on_panel_closed() -> void:
	_busy = true
	_panel_open = false
	_header.position = _header_home + Vector2(-52.0, 0.0)
	_header.modulate.a = 0.0
	_footer.modulate.a = 0.0
	for i in _buttons.size():
		_buttons[i].position = _btn_home[i] + Vector2(-78.0, 8.0)
		_buttons[i].modulate.a = 0.0
		_buttons[i].reset_visual()
	_backdrop.set_reveal(1.0)
	_backdrop.reveal_tween(0.0, 0.5, &"out_cubic")

	UiKit.tween_float(self, _header, "modulate:a", 1.0, 0.45, &"out_quad", 0.04)
	UiKit.tween_vec2(self, _header, "position", _header_home, 0.6, &"out_cubic", 0.04)
	UiKit.tween_float(self, _footer, "modulate:a", 1.0, 0.5, &"out_quad", 0.3)

	for i in _buttons.size():
		var b := _buttons[i]
		var home: Vector2 = _btn_home[i]
		var delay := 0.08 + 0.07 * float(i)
		UiKit.tween_float(self, b, "modulate:a", 1.0, 0.3, &"out_quad", delay)
		UiKit.tween_vec2(self, b, "position", home, 0.62, &"out_cubic", delay)

	await get_tree().create_timer(0.5).timeout
	_busy = false
	_buttons[0].grab_focus()


func _quit() -> void:
	_busy = true
	# 整屏淡出 0.4 s；按钮各自错开 40 ms 往左飞（位移与淡出同步收尾）
	UiKit.tween_float(self, self, "modulate:a", 0.0, 0.4, &"in_out")
	for i in _buttons.size():
		UiKit.tween_vec2(self, _buttons[i], "position",
			_buttons[i].position + Vector2(-BTN_W - 200.0, 0.0), 0.42, &"in_cubic", 0.04 * float(i))
	await get_tree().create_timer(0.44).timeout
	get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if _busy or _panel_open:
		return
	if event.is_action_pressed("ui_cancel"):
		_quit()
		get_viewport().set_input_as_handled()
