extends Control
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
## 应用设置（视频 / 音频选项卡）
@onready var app_settings: Control = %AppSettings
@onready var board_popup: AcceptDialog = %BoardPopup
@onready var board_text: RichTextLabel = %BoardText

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

	single_button.pressed.connect(_on_single_ty_pressed)
	board_button.pressed.connect(_on_board_pressed)
	settings_button.pressed.connect(_on_app_settings_pressed)
	exit_button.pressed.connect(_on_exit_pressed)
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
				var medal := ""
				if i == 0:
					medal = "🥇 "
				elif i == 1:
					medal = "🥈 "
				elif i == 2:
					medal = "🥉 "
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
