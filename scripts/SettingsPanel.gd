extends Control
## 模拟设置界面。从开始菜单点「模拟单台」后打开。
##
## 控件按整改要求：
##   · 模拟模式：下拉框（手动模式 / 自动模式 / 电影模式）。电影模式还没做，禁用该项。
##   · 风季模式：勾选框（CheckBox）

@onready var mode_option: OptionButton = %ModeOption
@onready var season_check: CheckBox = %SeasonCheck
@onready var desc_label: Label = %DescLabel
@onready var confirm_button: Button = %ConfirmButton
@onready var cancel_button: Button = %CancelButton

const GAME_SCENE := "res://GameRoot.tscn"

## 取消时回调（由开始菜单传入）
var on_cancel: Callable = Callable()


func _ready() -> void:
	_setup_mode_options()
	mode_option.item_selected.connect(_on_mode_selected)
	season_check.toggled.connect(_on_season_toggled)
	confirm_button.pressed.connect(_on_confirm)
	cancel_button.pressed.connect(_on_cancel)
	visible = false
	_update_description()


func _setup_mode_options() -> void:
	mode_option.clear()
	mode_option.add_item("手动模式", Game.Mode.MANUAL)
	mode_option.add_item("自动模式", Game.Mode.AUTO)
	mode_option.add_item("电影模式（未开放）", Game.Mode.CINEMATIC)
	# 电影模式还没实现，禁用该选项
	var cinematic_index := mode_option.get_item_index(Game.Mode.CINEMATIC)
	if cinematic_index >= 0:
		mode_option.set_item_disabled(cinematic_index, true)


func open() -> void:
	# 每次打开回到默认（手动模式 + 非风季）
	mode_option.select(mode_option.get_item_index(Game.Mode.MANUAL))
	season_check.button_pressed = false
	_update_description()
	visible = true


func _selected_mode() -> Game.Mode:
	var idx := mode_option.selected
	if idx < 0:
		return Game.Mode.MANUAL
	return mode_option.get_item_id(idx) as Game.Mode


func _on_mode_selected(_index: int) -> void:
	_update_description()


func _on_season_toggled(_pressed: bool) -> void:
	_update_description()


func _update_description() -> void:
	var mode := _selected_mode()
	var mode_text := ""
	match mode:
		Game.Mode.AUTO:
			mode_text = "台风会自动沿着生成的路径移动。"
		Game.Mode.CINEMATIC:
			mode_text = "还没做。"
		_:
			mode_text = "点「添加台风」进入编辑模式，在地图上左键标记路径点，再点「投放台风」发动。"
	var season_text := "只模拟 12 个月（1月1日 → 12月30日），结束后结算并写入 ACE 排行榜。此模式下调整日期视为作弊，会被禁用。" \
		if season_check.button_pressed else "从 1月1日 起无限模拟，一年结束后回到 1月1日继续。"
	desc_label.text = "· 模拟模式：%s\n\n· 风季模式：%s" % [mode_text, season_text]


func _on_confirm() -> void:
	Game.mode = _selected_mode()
	Game.season_mode = season_check.button_pressed
	visible = false
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_cancel() -> void:
	visible = false
	if on_cancel.is_valid():
		on_cancel.call()
