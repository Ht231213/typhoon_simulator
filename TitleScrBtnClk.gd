extends Control
## ⚠ 2.0 起停用：主界面已由 scripts/ui/title_screen.gd 重做（TitleScreen.tscn 不再挂本脚本）。
##   保留此文件只为对照 1.x 的行为；它引用的 %SettingsPanel / %BoardPopup 节点在新场景里已不存在。
##
## 开始菜单。
##
## 保留原工程的布局（Sprite2D 背景 + 半透明遮罩 + 锚点定位的按钮），只做了加法：
## 「模拟单台」改为打开模拟设置界面，「退出」保持退出，新增「ACE 存档」查看排行榜。

@onready var single_button: Button = %ButtonSingleTy
@onready var board_button: Button = %ButtonBoard
@onready var settings_button: Button = %ButtonSettings
@onready var exit_button: Button = %ButtonExit
## 模拟设置（模式 / 风季），不是应用设置
@onready var settings_panel: Control = %SettingsPanel
## 应用设置（视频 / 音频 / 模拟设置选项卡）。
## ⚠ 它**不能**是场景里的静态实例 —— 见 `_ready()` 里的创建代码（BUG-1）。
var app_settings: Control = null
@onready var board_popup: AcceptDialog = %BoardPopup
@onready var board_text: RichTextLabel = %BoardText
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
	settings_panel.visible = false
	app_settings.on_closed = _on_app_settings_closed
	app_settings.visible = false
	single_button.grab_focus()


func _on_single_ty_pressed() -> void:
	settings_panel.open()


func _on_settings_cancelled() -> void:
	single_button.grab_focus()


## 打开应用设置（视频 / 音频）
func _on_app_settings_pressed() -> void:
	app_settings.open()


func _on_app_settings_closed() -> void:
	single_button.grab_focus()


func _on_exit_pressed() -> void:
	get_tree().quit()


func _on_board_pressed() -> void:
	board_text.text = _build_board_text()
	board_popup.popup_centered(Vector2i(620, 460))


## ACE 排行榜：按总 ACE 从高到低排，只显示前 10 条
func _build_board_text() -> String:
	var lines := PackedStringArray()
	lines.append("[b][font_size=20]ACE 排行榜[/font_size][/b]")
	lines.append("[color=#9aa]存档：%s[/color]" % Game.save_path_absolute())
	lines.append("")

	var total := 0
	for category in ["单台-手动", "单台-自动"]:
		var history: Array = Game.history(category)
		total += history.size()
		lines.append("[b][font_size=17]%s[/font_size][/b]  （共 %d 条）" % [category, history.size()])
		if history.is_empty():
			lines.append("    [i]暂无记录[/i]")
		else:
			# 排序：总 ACE 高的在前
			var sorted := history.duplicate()
			sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return float(a.get("total_ace", 0.0)) > float(b.get("total_ace", 0.0)))
			var top: int = mini(10, sorted.size())
			lines.append("    [color=#889]排名  总ACE     场次   时间[/color]")
			for i in top:
				var e: Dictionary = sorted[i]
				# ⚠ 原来的奖牌 emoji（U+1F947/48/49）不在 Noto Sans SC 的 cmap 里
				#   （网页版没系统字体 → 方框），改用字体自带的 ★；
				#   名次数字本来就在后面打印，信息没少。
				var medal := "★ " if i < 3 else ""
				lines.append("    %s%-4d %8.2f  %3d 场  %s" % [
					medal, i + 1,
					float(e.get("total_ace", 0.0)),
					int(e.get("storm_count", 0)),
					Time.get_datetime_string_from_unix_time(int(e.get("saved_at", 0))),
				])
		lines.append("")

	if total == 0:
		lines.append("[i]还没有任何成绩。跑一局「风季模式」，结束后会自动写入排行榜。[/i]")
	return "\n".join(lines)
