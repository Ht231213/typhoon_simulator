extends Control
## 开始模拟的设置面板（原「模拟设置」面板）。从开始菜单点「开始模拟」后打开。
##
## 2026-11-22 用户要求：
##   · 游戏模式下拉：模拟单台 / 模拟多台 / 电影模式（电影模式是占位，还没实现）
##   · 新增「自动模式」勾选框（勾 = 自动，不勾 = 手动）
##   · 「风季模式」勾选框保留
##   · 右半侧按「下拉 + 自动 + 风季」组合**实时**说明这局会怎么跑
##   · 选中电影模式：右半侧不显示说明，改成「设置」按钮（打开应用设置）；
##     点「确认」不进游戏，只在底部提示「尚未实现」
##
## ⚠ 单台/多台真正生效的是 `Game.multi_mode`（Game.max_active_storms() 决定上限 1/6），
##   本面板只负责在进游戏前把它设好。

## 电影模式下点「设置」→ 由标题画面打开应用设置
signal settings_requested

enum PlayMode { SINGLE, MULTI, CINEMATIC }

@onready var mode_option: OptionButton = %ModeOption
@onready var auto_check: CheckBox = %AutoCheck
@onready var season_check: CheckBox = %SeasonCheck
@onready var desc_label: Label = %DescLabel
@onready var cinematic_settings_button: Button = %CinematicSettingsButton
@onready var confirm_button: Button = %ConfirmButton
@onready var cancel_button: Button = %CancelButton
@onready var hint_label: Label = %HintLabel

const GAME_SCENE := "res://GameRoot.tscn"

## 取消时回调（由开始菜单传入）
var on_cancel: Callable = Callable()


func _ready() -> void:
	_setup_play_modes()
	mode_option.item_selected.connect(_on_mode_selected)
	auto_check.toggled.connect(_on_check_toggled)
	season_check.toggled.connect(_on_check_toggled)
	cinematic_settings_button.pressed.connect(func() -> void: settings_requested.emit())
	confirm_button.pressed.connect(_on_confirm)
	cancel_button.pressed.connect(_on_cancel)
	visible = false
	_update_description()


## 下拉框三项：单台 / 多台 / 电影（item id 用本面板的 PlayMode 枚举，不复用 Game.Mode）
func _setup_play_modes() -> void:
	mode_option.clear()
	mode_option.add_item("模拟单台", PlayMode.SINGLE)
	mode_option.add_item("模拟多台", PlayMode.MULTI)
	mode_option.add_item("电影模式", PlayMode.CINEMATIC)


func open() -> void:
	# 每次打开回到默认（模拟单台 + 手动 + 非风季）
	mode_option.select(0)
	auto_check.set_pressed_no_signal(false)
	season_check.set_pressed_no_signal(false)
	hint_label.text = ""
	_update_description()
	visible = true


func _selected_play_mode() -> int:
	var idx := mode_option.selected
	if idx < 0:
		return PlayMode.SINGLE
	return int(mode_option.get_item_id(idx))


func _on_mode_selected(_index: int) -> void:
	hint_label.text = ""
	_update_description()


func _on_check_toggled(_pressed: bool) -> void:
	hint_label.text = ""
	_update_description()


## 右半侧说明：按组合实时更新；电影模式换成「设置」按钮
func _update_description() -> void:
	var pm := _selected_play_mode()
	var cinematic := pm == PlayMode.CINEMATIC
	cinematic_settings_button.visible = cinematic
	desc_label.visible = not cinematic
	# 电影模式下两个勾选没有意义（模式还没实现），禁用
	auto_check.disabled = cinematic
	season_check.disabled = cinematic
	if cinematic:
		desc_label.text = ""
		return

	var auto := auto_check.button_pressed
	var season := season_check.button_pressed
	var lines := PackedStringArray()
	if pm == PlayMode.MULTI:
		lines.append("· 游戏模式：模拟多台 —— 同屏最多 %d 场台风；它们共用同一片海洋，先经过的台风会削弱后方的海温。" \
			% Const.MAX_ACTIVE_STORMS)
	else:
		lines.append("· 游戏模式：模拟单台 —— 同屏只模拟 1 场台风，这场结束（或点「停止模拟」）后才能投放下一场。")
	if auto:
		lines.append("· 自动模式：台风沿自动生成的路径移动并连续投放，不用手动画线。")
	else:
		lines.append("· 手动模式：点「添加台风」进入投放环节，在地图上左键标记路径点，再点「投放台风」。")
	if season:
		lines.append("· 风季模式：只模拟 12 个月（1月1日 → 12月30日），结束后结算并写入 ACE 存档；风季下「调整日期」被禁用。")
	else:
		lines.append("· 非风季：从 1月1日 起无限模拟，一年结束后回到 1月1日继续。")
	desc_label.text = "\n\n".join(lines)


func _on_confirm() -> void:
	if _selected_play_mode() == PlayMode.CINEMATIC:
		hint_label.text = "电影模式尚未实现，敬请期待（右半侧的「设置」已可用）"
		return
	Game.multi_mode = (_selected_play_mode() == PlayMode.MULTI)
	Game.auto_mode = auto_check.button_pressed
	Game.season_mode = season_check.button_pressed
	visible = false
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_cancel() -> void:
	visible = false
	if on_cancel.is_valid():
		on_cancel.call()
