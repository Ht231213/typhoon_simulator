class_name SimSetupPanel
extends MenuPanel
## 「模拟单台」子界面：左边操作区选模式 / 风季，右边背景云图。
##
## 逻辑与原 SettingsPanel.gd 一致（同样的 Game.Mode / season_mode 写入、同样的说明文案），
## 只把下拉框换成三个平行四边形选项卡，确认后进 GameRoot。

const GAME_SCENE := "res://GameRoot.tscn"
const COL_W := 520.0
const BTN_H := 50.0

const MODES := [
	{"mode": 0, "text": "手动模式"},        # Game.Mode.MANUAL
	{"mode": 1, "text": "自动模式"},        # Game.Mode.AUTO
	{"mode": 2, "text": "电影模式（未开放）"},  # Game.Mode.CINEMATIC
]

var _mode := 0
var _season := false
var _mode_buttons: Array[SkewButton] = []
var _season_button: SkewButton = null
var _desc: Label = null


func _build() -> void:
	var title := UiKit.make_title("模拟单台", 40)
	add_at(title, Vector2(CONTENT_X, 52.0), Vector2(460.0, 56.0))
	add_label("选择本局规则", Vector2(CONTENT_X + 2.0, 114.0), Vector2(400.0, 22.0), 15, UiKit.TEXT_DIM)

	add_label("模拟模式", Vector2(CONTENT_X, 170.0), Vector2(220.0, 20.0), 13,
		Color(UiKit.ACCENT.r, UiKit.ACCENT.g, UiKit.ACCENT.b, 0.85))

	for i in MODES.size():
		var item: Dictionary = MODES[i]
		var b := add_button(String(item["text"]), Vector2(CONTENT_X, 198.0 + float(i) * 60.0),
			Vector2(COL_W, BTN_H), 21)
		b.pressed.connect(_on_mode_pressed.bind(int(item["mode"])))
		if int(item["mode"]) == 2:
			b.set_enabled(false)
		_mode_buttons.append(b)

	add_label("风季模式", Vector2(CONTENT_X, 400.0), Vector2(220.0, 20.0), 13,
		Color(UiKit.ACCENT.r, UiKit.ACCENT.g, UiKit.ACCENT.b, 0.85))
	_season_button = add_button("风季模式 · 关", Vector2(CONTENT_X, 428.0), Vector2(COL_W, BTN_H), 21)
	_season_button.pressed.connect(_on_season_pressed)

	_desc = UiKit.make_body("…", 15, UiKit.TEXT_DIM)
	add_at(_desc, Vector2(CONTENT_X, 500.0), Vector2(COL_W + 110.0, 96.0))

	var start := add_button("开始模拟", Vector2(CONTENT_X, 622.0), Vector2(250.0, 56.0), 23)
	start.selected = true
	start.pressed.connect(_on_start)
	var back := add_button("返回", Vector2(CONTENT_X + 274.0, 622.0), Vector2(190.0, 56.0), 21)
	back.pressed.connect(close)

	_refresh()


func _on_mode_pressed(mode: int) -> void:
	_mode = mode
	_refresh()


func _on_season_pressed() -> void:
	_season = not _season
	_refresh()


func _refresh() -> void:
	for i in MODES.size():
		_mode_buttons[i].selected = int(MODES[i]["mode"]) == _mode
	_season_button.selected = _season
	_season_button.label_text = "风季模式 · 开" if _season else "风季模式 · 关"
	if _desc != null:
		_desc.text = _description()


func _description() -> String:
	var mode_text := ""
	match _mode:
		1:
			mode_text = "台风会自动沿着生成的路径移动。"
		2:
			mode_text = "还没做。"
		_:
			mode_text = "点「添加台风」进入编辑模式，在地图上左键标记路径点，再点「投放台风」发动。"
	var season_text := "只模拟 12 个月（1月1日 → 12月30日），结束后结算并写入 ACE 排行榜。此模式下调整日期视为作弊，会被禁用。" \
		if _season else "从 1月1日 起无限模拟，一年结束后回到 1月1日继续。"
	return "· 模拟模式：%s\n\n· 风季模式：%s" % [mode_text, season_text]


func _on_start() -> void:
	Game.mode = _mode
	Game.season_mode = _season
	MusicManager.stop_sim()
	# 走淡入淡出过渡，别硬切（硬切进游戏会「闪」一下）
	SceneTransition.change_scene(GAME_SCENE)
