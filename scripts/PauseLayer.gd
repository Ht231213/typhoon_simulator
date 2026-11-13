extends CanvasLayer
## ESC 暂停菜单：**整个游戏暂停**（get_tree().paused = true）。
##
## 与侧边栏「暂停模拟」的区别：
##   · 「暂停模拟」：只停模拟（台风、日期），界面仍可操作
##   · 本菜单（ESC）：整个游戏冻结，用来让玩家离开一下
##
## 关键设置：
##   · 本节点 process_mode = ALWAYS，保证「没暂停时也能收到 ESC」
##     （原工程的 esc_handel.gd 设成了 WHEN_PAUSED，结果自己永远收不到触发自己的按键）
##   · 里面的按钮和遮罩也都设成 ALWAYS，否则 paused = true 之后点不动
##
## 1.3.0：换上一套平行四边形按钮 + 弹出动画（遮罩淡入 / 面板轻微放大落位 / 按钮错开淡入），
## 全部只改透明度与缩放，不动布局 —— 地图与模拟区域完全不受影响。

@onready var root: Control = $Root
@onready var box: PanelContainer = $Root/Margin/Box
@onready var list_panel: PanelContainer = $Root/Margin/Box/Rows/Columns/RightColumn/ListPanel
@onready var dim: ColorRect = $Root/Dim
@onready var pause_title: Label = %PauseTitle
@onready var resume_button: Button = %ResumeButton
@onready var menu_button: Button = %MenuButton
@onready var settings_button: Button = %SettingsButton
@onready var storm_list: RichTextLabel = %StormList
@onready var list_title: Label = %ListTitle
@onready var hint_label: Label = %Hint

## 设置界面场景（打开时实例化，与主菜单共用同一份）
## 2.0：换成新的版式（左侧竖向 tab + 右侧背景），ESC 菜单与主菜单观感统一
const SETTINGS_SCENE := "res://AppSettingsPanel.tscn"
var _settings: Control = null
## 正在播放关闭动画（防止连按 ESC 重复触发）
var _closing := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	root.visible = false
	_apply_style()
	resume_button.pressed.connect(resume)
	menu_button.pressed.connect(_on_menu_pressed)
	settings_button.pressed.connect(_on_settings_pressed)


func _apply_style() -> void:
	# 遮罩：更浓一点 + 略偏冷，让暂停面板浮起来
	dim.color = Color(0.01, 0.02, 0.03, 0.78)

	# 面板不要铺满整屏：留出四周，看起来像浮在地图上的弹窗（暂停层是覆盖层，不影响地图布局）
	var margin := $Root/Margin as MarginContainer
	if margin != null:
		for side in ["left", "top", "right", "bottom"]:
			margin.add_theme_constant_override("margin_" + side, 56)

	# 主面板：深色 + 冰蓝细边 + 大圆角
	var b := StyleBoxFlat.new()
	b.bg_color = Color(0.031, 0.043, 0.059, 0.97)
	b.border_color = Color(0.55, 0.88, 1.0, 0.55)
	b.set_border_width_all(1)
	b.set_corner_radius_all(14)
	b.content_margin_left = 24.0
	b.content_margin_right = 24.0
	b.content_margin_top = 20.0
	b.content_margin_bottom = 20.0
	box.add_theme_stylebox_override("panel", b)

	# 台风列表卡片
	var lp := StyleBoxFlat.new()
	lp.bg_color = Color(1, 1, 1, 0.04)
	lp.border_color = Color(1, 1, 1, 0.10)
	lp.set_border_width_all(1)
	lp.set_corner_radius_all(8)
	lp.set_content_margin_all(10)
	list_panel.add_theme_stylebox_override("panel", lp)

	pause_title.add_theme_color_override("font_color", Color(0.55, 0.88, 1.0, 1.0))
	pause_title.add_theme_font_size_override("font_size", 28)
	list_title.add_theme_color_override("font_color", Color(0.72, 0.80, 0.87, 0.85))
	hint_label.add_theme_color_override("font_color", Color(1.0, 0.80, 0.35, 0.9))

	# 底部那条分隔线在弹窗里显得空，收起（Hint 仍然保留，只在出错时显示文字）
	var sep2 := $Root/Margin/Box/Rows/Sep2 as Control
	if sep2 != null:
		sep2.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	# 设置界面开着时，ESC 交给设置界面自己处理
	if _settings != null and _settings.visible:
		return
	if _closing:
		return
	if root.visible:
		resume()
	else:
		pause()
	get_viewport().set_input_as_handled()


func pause() -> void:
	_refresh_storm_list()
	_closing = false
	root.visible = true
	get_tree().paused = true

	# 弹出：遮罩淡入 + 面板从 0.965 倍轻放大到 1，三个按钮再错开淡入
	root.modulate.a = 0.0
	box.pivot_offset = box.size * 0.5
	box.scale = Vector2(0.965, 0.965)
	UiKit.tween_float(self, root, "modulate:a", 1.0, 0.2, &"out_cubic")
	UiKit.tween_vec2(self, box, "scale", Vector2.ONE, 0.34, &"out_cubic")
	var buttons: Array[Control] = [resume_button, settings_button, menu_button]
	for i in buttons.size():
		buttons[i].modulate.a = 0.0
		UiKit.tween_float(self, buttons[i], "modulate:a", 1.0, 0.28, &"out_quad", 0.06 + 0.05 * float(i))


func resume() -> void:
	if not root.visible or _closing:
		return
	_closing = true
	# 收起：面板轻微缩小 + 整体淡出，动画播完再真正解除暂停
	UiKit.tween_vec2(self, box, "scale", Vector2(0.98, 0.98), 0.18, &"in_cubic")
	var tw := UiKit.tween_float(self, root, "modulate:a", 0.0, 0.16, &"in_cubic")
	await tw.finished
	root.visible = false
	box.scale = Vector2.ONE
	root.modulate.a = 1.0
	_closing = false
	get_tree().paused = false


## 本局已自然结束的台风列表。点「停止模拟」的台风不进这里（也不计入 ACE）。
## ⚠ 用 visible_records()：默认只列热带风暴级及以上，
##   打开「记录热带扰动和低压」后连 <30 kt 的扰动也一并列出。
func _refresh_storm_list() -> void:
	var vis := Game.visible_records()
	list_title.text = "本次台风列表（%d 场）    总 ACE %.2f" % [vis.size(), Game.total_ace]
	if vis.is_empty():
		storm_list.text = "[i][color=#889]还没有自然结束的台风。[/color][/i]"
		return
	var lines := PackedStringArray()
	for i in vis.size():
		lines.append(Game.format_record(vis[i]))
	storm_list.text = "\n".join(lines)


func _on_menu_pressed() -> void:
	get_tree().paused = false
	root.visible = false
	SceneTransition.change_scene("res://TitleScreen.tscn")


## 打开设置界面（独立场景，与主菜单共用同一份）
func _on_settings_pressed() -> void:
	if _settings == null:
		_settings = load(SETTINGS_SCENE).instantiate()
		add_child(_settings)
		# 关掉设置后不留任何样板提示（用户要求去掉这类文字）
		_settings.on_closed = func() -> void:
			hint_label.text = ""
	_settings.open()
