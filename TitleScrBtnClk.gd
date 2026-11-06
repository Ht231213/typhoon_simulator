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
## 应用设置（视频 / 音频 / 模拟设置选项卡）。
## ⚠ 它**不能**是场景里的静态实例 —— 见 `_ready()` 里的创建代码（BUG-1）。
var app_settings: Control = null
@onready var board_popup: AcceptDialog = %BoardPopup
@onready var board_text: RichTextLabel = %BoardText
## 左下角版本号。文字在 `_ready()` 里从 ProjectSettings 取，不硬编码（改版本号自动跟随）
@onready var version_label: Label = %VersionLabel
## 标题文字（安全区 inset 要把整块内容往右让）
@onready var title_label: Label = %TitleLabel
## 卫星图背景（宽屏时按视口等比放大铺满）
@onready var background: Sprite2D = $Background

## 设计分辨率。宽屏（aspect=expand）后逻辑宽度会 >1280，背景/按钮都要按它做参照。
const DESIGN_SIZE := Vector2(1280.0, 720.0)
## 背景在 1280x720 设计稿里的原始 transform（宽屏时按视口比例放大，构图比例不变）
const BG_BASE_SCALE := 0.78161705
const BG_BASE_POS := Vector2(866.99994, 367.0)

## 按钮 / 标题 / 版本号在设计稿里的原始横向位置（安全区 inset 在此基础上叠加）
var _menu_buttons: Array[Button] = []
var _menu_base_x: Array[Vector2] = []
var _title_base_x := Vector2(56.0, 616.0)
var _version_base_x := Vector2(16.0, 260.0)
var _version_base_y := Vector2(-34.0, -12.0)

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

	# ── 宽屏（aspect=expand）/ 安卓安全区布局 ──
	# 按钮列原来按「宽度百分比」锚定，宽屏上会被横向拉开（按钮变超宽、和背景错位）；
	# 场景里已改成固定像素列：1280x720 下坐标和原来逐像素一致，桌面行为不变。
	_menu_buttons = [single_button, board_button, settings_button, exit_button]
	_menu_base_x.clear()
	for b in _menu_buttons:
		_menu_base_x.append(Vector2(b.offset_left, b.offset_right))
	_title_base_x = Vector2(title_label.offset_left, title_label.offset_right)
	_version_base_x = Vector2(version_label.offset_left, version_label.offset_right)
	_version_base_y = Vector2(version_label.offset_top, version_label.offset_bottom)
	get_viewport().size_changed.connect(_relayout_title)
	_relayout_title()
	# ACE 排行榜弹窗的「确定」按钮不在场景里，只能代码补触摸高度 / 中文文案
	board_popup.get_ok_button().custom_minimum_size = Vector2(160, 52)
	board_popup.get_ok_button().text = "确定"


# ============================ 宽屏 / 安全区布局 ============================

## 手机横屏（aspect=expand）下逻辑宽度 >1280：
##   · 背景卫星图按视口等比放大，构图锚点按视口比例 → 不会在右侧露底、也不变形；
##   · 按钮列已经是固定像素列（见场景），不会被拉宽；
##   · 安卓安全区 inset 把左侧内容避开刘海/挖孔，版本号避开底部手势条。
## 桌面 16:9（1280x720）时 k=1、inset=0 → 与改动前完全一致。
func _relayout_title() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	var k := maxf(vp.x / DESIGN_SIZE.x, vp.y / DESIGN_SIZE.y)
	background.scale = Vector2(BG_BASE_SCALE, BG_BASE_SCALE) * k
	background.position = Vector2(
		BG_BASE_POS.x * (vp.x / DESIGN_SIZE.x),
		BG_BASE_POS.y * (vp.y / DESIGN_SIZE.y))

	var ins := AndroidCompat.safe_insets()
	for i in _menu_buttons.size():
		var b := _menu_buttons[i]
		var base := _menu_base_x[i]
		b.offset_left = base.x + ins.x
		b.offset_right = base.y + ins.x
	title_label.offset_left = _title_base_x.x + ins.x
	title_label.offset_right = _title_base_x.y + ins.x
	version_label.offset_left = _version_base_x.x + ins.x
	version_label.offset_right = _version_base_x.y + ins.x
	version_label.offset_top = _version_base_y.x - ins.w
	version_label.offset_bottom = _version_base_y.y - ins.w


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
