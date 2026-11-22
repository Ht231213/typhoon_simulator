extends Control
## 开始菜单。
##
## 保留原工程的布局（Sprite2D 背景 + 半透明遮罩 + 锚点定位的按钮），只做了加法：
## 「开始模拟」打开模拟设置面板，「退出」保持退出，「ACE 存档」查看排行榜。

@onready var single_button: Button = %ButtonSingleTy
@onready var board_button: Button = %ButtonBoard
@onready var settings_button: Button = %ButtonSettings
@onready var exit_button: Button = %ButtonExit
## 背景图（2026-11-22 窗口尺寸可变：大窗口要放大铺满，不能露底）
@onready var background: Sprite2D = get_node_or_null("Background") as Sprite2D
## 1.2.0 设计稿（1280×720）上的原始 scale：窗口不比设计稿大时保持它，观感和 1.2.0 一致
const BG_DESIGN_SCALE := 0.78161705
## 模拟设置（模式 / 风季），不是应用设置
@onready var settings_panel: Control = %SettingsPanel
## 应用设置（视频 / 音频 / 模拟设置选项卡）。
## ⚠ 它**不能**是场景里的静态实例 —— 见 `_ready()` 里的创建代码（BUG-1）。
var app_settings: Control = null
## ACE 存档大窗口（2026-11-22 需求 7）。同样必须运行时实例化（BUG-1）。
var ace_archive: Control = null
## 左下角版本号。文字在 `_ready()` 里从 ProjectSettings 取，不硬编码（改版本号自动跟随）
@onready var version_label: Label = %VersionLabel

## 主菜单背景音乐。
## 用「导出路径」而不是写死 `$TitleBgm`——这样你在编辑器里改名/挪动这个节点时
## 脚本不会崩；路径失效时检查器里会标红，重新拖一下就行。
@export var bgm_path: NodePath = ^"TitleBgm"


func _ready() -> void:
	# ⚠ 音乐总线必须在代码里挂。
	# 场景里写 `bus = &"Music"` 不管用——Godot 编辑器保存场景时会把这个属性丢掉
	# （实测被重写掉两次），结果「音乐音量滑块怎么拖都没反应」。
	# 代码设置编辑器碰不到。
	var bgm := get_node_or_null(bgm_path)
	if bgm != null:
		GameSettings.register_music_player(bgm)
	else:
		push_warning("标题 BGM 没找到（bgm_path=%s），音乐音量会不起作用" % bgm_path)

	# 背景音乐（方案包 music.titlescreen；没有该 ID 就静音）
	MusicManager.play_title()

	single_button.pressed.connect(_on_single_ty_pressed)
	board_button.pressed.connect(_on_board_pressed)
	settings_button.pressed.connect(_on_app_settings_pressed)
	exit_button.pressed.connect(_on_exit_pressed)

	# 版本号从 project.godot 的 `config/version` 取 —— 以后改版本号这里自动跟随，不会忘记改。
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	version_label.text = "v" + version if version != "" else ""

	# ⚠ BUG-1（2026-10-24）：设置界面**不能**用场景里的静态实例。
	#   导出的场景里，「Control 做场景根的静态实例」会丢掉满屏锚点（锚点全 0、尺寸 0x0），
	#   打包后整块设置缩在左上角、还没法用；编辑器里却完全正常，很难查。
	#   ESC 暂停菜单用的是同一个 SettingsMenu 场景、但它是在运行时实例化的 → 一直正常。
	#   这里改成和 PauseLayer 一样：运行时 load + add_child + 显式铺满，不再依赖场景实例。
	app_settings = load("res://SettingsMenu.tscn").instantiate()
	app_settings.name = "AppSettings"
	add_child(app_settings)
	app_settings.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	settings_panel.on_cancel = _on_settings_cancelled
	settings_panel.settings_requested.connect(_on_cinematic_settings_requested)
	settings_panel.visible = false

	# ACE 存档大窗口（2026-11-22 需求 7）：与 SettingsMenu 一样运行时实例化 + 显式铺满，
	# 避免导出包里静态 Control 实例丢锚点的 BUG-1。
	ace_archive = load("res://AceArchive.tscn").instantiate()
	ace_archive.name = "AceArchive"
	add_child(ace_archive)
	ace_archive.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ace_archive.on_closed = _on_ace_archive_closed
	ace_archive.visible = false

	app_settings.on_closed = _on_app_settings_closed
	app_settings.visible = false
	single_button.grab_focus()

	# 背景图 cover：窗口尺寸下拉换成大窗口后，右侧/下方不能出现空底
	get_viewport().size_changed.connect(_fit_background)
	_fit_background()


## 背景图按窗口做 cover 缩放：以设计稿的图片中心为锚点，保证四个边都铺满。
## 窗口 ≤ 设计稿时保持原始 scale → 1280×720/1280×782 下观感与 1.2.0 完全一致。
func _fit_background() -> void:
	if background == null or background.texture == null:
		return
	var tex := background.texture.get_size()
	if tex.x <= 0.0 or tex.y <= 0.0:
		return
	var win := get_viewport().get_visible_rect().size
	var c := background.position
	var need_x := maxf(2.0 * c.x / tex.x, 2.0 * (win.x - c.x) / tex.x)
	var need_y := maxf(2.0 * c.y / tex.y, 2.0 * (win.y - c.y) / tex.y)
	var s := maxf(maxf(need_x, need_y), BG_DESIGN_SCALE)
	background.scale = Vector2(s, s)


func _on_single_ty_pressed() -> void:
	settings_panel.open()


func _on_settings_cancelled() -> void:
	single_button.grab_focus()


## 打开应用设置（视频 / 音频 / 预设 / 模拟 / 导出）
func _on_app_settings_pressed() -> void:
	app_settings.open()


## 电影模式下点「设置」：打开同一份应用设置（电影模式专属参数以后再做）
func _on_cinematic_settings_requested() -> void:
	app_settings.open()


func _on_app_settings_closed() -> void:
	single_button.grab_focus()


func _on_exit_pressed() -> void:
	get_tree().quit()


## 「ACE 存档」：打开大窗口 + 表格（2026-11-22 需求 7，替代原来的 620×460 弹窗）
func _on_board_pressed() -> void:
	ace_archive.open()


func _on_ace_archive_closed() -> void:
	board_button.grab_focus()
