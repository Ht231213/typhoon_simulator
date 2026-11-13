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

@onready var root: Control = $Root
@onready var resume_button: Button = %ResumeButton
@onready var menu_button: Button = %MenuButton
@onready var settings_button: Button = %SettingsButton
@onready var storm_list: RichTextLabel = %StormList
@onready var list_title: Label = %ListTitle
@onready var hint_label: Label = %Hint

## 设置界面场景（打开时实例化，与主菜单共用同一份）
const SETTINGS_SCENE := "res://SettingsMenu.tscn"
var _settings: Control = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	root.visible = false
	resume_button.pressed.connect(resume)
	menu_button.pressed.connect(_on_menu_pressed)
	settings_button.pressed.connect(_on_settings_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	# 设置界面开着时，ESC 交给设置界面自己处理
	if _settings != null and _settings.visible:
		return
	if root.visible:
		resume()
	else:
		pause()
	get_viewport().set_input_as_handled()


func pause() -> void:
	_refresh_storm_list()
	root.visible = true
	get_tree().paused = true


func resume() -> void:
	root.visible = false
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
	get_tree().change_scene_to_file("res://TitleScreen.tscn")


## 打开设置界面（独立场景，与主菜单共用同一份）
func _on_settings_pressed() -> void:
	if _settings == null:
		_settings = load(SETTINGS_SCENE).instantiate()
		add_child(_settings)
		# 关掉设置后不留任何样板提示（用户要求去掉这类文字）
		_settings.on_closed = func() -> void:
			hint_label.text = ""
	_settings.open()
