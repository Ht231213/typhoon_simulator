class_name AppSettingsPanel
extends MenuPanel
## 「设置」子界面：左边竖向 tab，右边内容；背景与主界面同一套斜切云图。
##
## 设置项与原 SettingsMenu.gd 完全一致（即时生效 + 立即落盘，没有确定/取消，只有返回）：
##   预设 = 方案包 / 等级扩展图标 / 风速单位；视频 = 全屏；音频 = 音乐 + 音效；
##   模拟设置 = SimSettings 组件（与游戏内那份共用逻辑）。

const NAV := ["预设", "视频", "音频", "模拟设置"]

const PAGE_X := 348.0
const PAGE_Y := 168.0
const PAGE_W := 430.0
const PAGE_H := 440.0

var _nav_buttons: Array[SkewButton] = []
var _pages: Array[Control] = []
var _current := -1

var _pack_option: OptionButton = null
var _pack_warn: Label = null
var _pack_names: Array[String] = []
var _tier_check: CheckBox = null
var _unit_option: OptionButton = null
var _fullscreen_check: CheckBox = null
var _hint: Label = null
var _music_row: Control = null
var _music_slider: HSlider = null
var _music_value: Label = null
var _sfx_slider: HSlider = null
var _sfx_value: Label = null
var _sim_settings: Node = null

const PACK_WARN_TEXT := "数据包版本不兼容"
const PACK_WARN_COLOR := Color(1.0, 0.85, 0.2, 0.55)


func _build() -> void:
	var title := UiKit.make_title("设置", 40)
	add_at(title, Vector2(CONTENT_X, 52.0), Vector2(460.0, 56.0))
	add_label("改动立即生效并保存", Vector2(CONTENT_X + 2.0, 114.0), Vector2(400.0, 22.0), 15, UiKit.TEXT_DIM)

	# --- 左侧竖向 tab ---
	for i in NAV.size():
		var b := add_button(String(NAV[i]), Vector2(CONTENT_X, 170.0 + float(i) * 56.0),
			Vector2(216.0, 46.0), 20)
		b.pressed.connect(_set_page.bind(i))
		_nav_buttons.append(b)

	var back := add_button("返回", Vector2(CONTENT_X, 620.0), Vector2(190.0, 54.0), 21)
	back.pressed.connect(close)

	# --- 右侧页面 ---
	for i in NAV.size():
		var page := VBoxContainer.new()
		page.add_theme_constant_override("separation", 12)
		add_at(page, Vector2(PAGE_X, PAGE_Y), Vector2(PAGE_W, PAGE_H))
		_pages.append(page)

	_build_preset_page(_pages[0])
	_build_video_page(_pages[1])
	_build_audio_page(_pages[2])
	_build_sim_page(_pages[3])

	_set_page(0)


# ------------------------------ 各页 ------------------------------

func _build_preset_page(page: Control) -> void:
	page.add_child(_section("方案"))
	_pack_option = OptionButton.new()
	_pack_option.custom_minimum_size = Vector2(300.0, 42.0)
	_pack_option.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_pack_option.add_theme_font_size_override("font_size", 18)
	_pack_option.tooltip_text = "方案包（assets/icons/<名字>/）：图标、登陆特效、音效都从里面取"
	_pack_option.item_selected.connect(_on_pack_selected)
	UiKit.style_option_button(_pack_option)
	page.add_child(_pack_option)

	_pack_warn = UiKit.make_label(PACK_WARN_TEXT, 15, PACK_WARN_COLOR)
	_pack_warn.visible = false
	page.add_child(_pack_warn)

	_tier_check = CheckBox.new()
	_tier_check.text = "启用等级扩展图标"
	_tier_check.add_theme_font_size_override("font_size", 18)
	_tier_check.tooltip_text = "使用素材里的 +/- 变体图标（只在 advanced / adv_extend 方案可用）"
	_tier_check.toggled.connect(_on_tier_toggled)
	UiKit.style_check_box(_tier_check)
	page.add_child(_tier_check)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 8.0)
	page.add_child(spacer)

	page.add_child(_section("风速单位"))
	_unit_option = OptionButton.new()
	_unit_option.custom_minimum_size = Vector2(300.0, 42.0)
	_unit_option.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_unit_option.add_theme_font_size_override("font_size", 18)
	for unit in TyphoonSim.WIND_UNITS:
		_unit_option.add_item(unit)
	_unit_option.item_selected.connect(_on_unit_selected)
	UiKit.style_option_button(_unit_option)
	page.add_child(_unit_option)


func _build_video_page(page: Control) -> void:
	page.add_child(_section("显示"))
	_fullscreen_check = CheckBox.new()
	_fullscreen_check.text = "全屏显示"
	_fullscreen_check.add_theme_font_size_override("font_size", 18)
	_fullscreen_check.tooltip_text = "切换全屏 / 窗口模式"
	_fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	UiKit.style_check_box(_fullscreen_check)
	page.add_child(_fullscreen_check)

	_hint = UiKit.make_body("", 14, Color(UiKit.WARN.r, UiKit.WARN.g, UiKit.WARN.b, 0.9))
	_hint.custom_minimum_size = Vector2(PAGE_W, 60.0)
	page.add_child(_hint)


func _build_audio_page(page: Control) -> void:
	page.add_child(_section("音乐"))
	_music_row = _slider_row(page, "音乐音量", "主菜单 BGM、模拟内 BGM")
	_music_slider = _music_row.get_node("Slider")
	_music_value = _music_row.get_node("Value")

	page.add_child(_section("音效"))
	var sfx_row := _slider_row(page, "音效音量", "登陆音效、台风音效等")
	_sfx_slider = sfx_row.get_node("Slider")
	_sfx_value = sfx_row.get_node("Value")

	# 音乐出处声明（显眼位置：音频页正文）
	var note := UiKit.make_body(
		"背景音乐：Phigros 开屏音乐（© Pigeon Games）。本作仅作非商业同人演示，音乐版权归原著作权人所有。",
		13, Color(UiKit.ACCENT.r, UiKit.ACCENT.g, UiKit.ACCENT.b, 0.72))
	note.custom_minimum_size = Vector2(PAGE_W, 72.0)
	page.add_child(note)


func _build_sim_page(page: Control) -> void:
	_sim_settings = load("res://SimSettings.tscn").instantiate()
	page.add_child(_sim_settings)
	_sim_settings.setup(true, Game.season_mode)
	_sim_settings.settings_changed.connect(_on_sim_settings_changed)


# ------------------------------ 小工具 ------------------------------

func _section(text: String) -> Label:
	var l := UiKit.make_label(text, 13, Color(UiKit.ACCENT.r, UiKit.ACCENT.g, UiKit.ACCENT.b, 0.85))
	l.custom_minimum_size = Vector2(0.0, 20.0)
	return l


func _slider_row(page: Control, title: String, tip: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = title
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size = Vector2(PAGE_W, 40.0)
	page.add_child(row)

	var lbl := UiKit.make_label(title, 17, UiKit.TEXT)
	lbl.custom_minimum_size = Vector2(110.0, 0.0)
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.name = "Slider"
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = 80.0
	slider.custom_minimum_size = Vector2(0.0, 34.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.tooltip_text = tip
	slider.value_changed.connect(_on_volume_changed.bind(title))
	row.add_child(slider)

	var value := UiKit.make_label("80%", 16, UiKit.TEXT_DIM)
	value.name = "Value"
	value.custom_minimum_size = Vector2(56.0, 0.0)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	return row


# ------------------------------ 页面切换 ------------------------------

func _set_page(index: int) -> void:
	if index < 0 or index >= _pages.size():
		return
	_current = index
	for i in _nav_buttons.size():
		_nav_buttons[i].selected = i == index
	for i in _pages.size():
		_pages[i].visible = i == index


# ------------------------------ 同步 / 回调 ------------------------------

func open() -> void:
	_sync_from_settings()
	_set_page(0)
	super.open()


func _sync_from_settings() -> void:
	if _fullscreen_check != null:
		_fullscreen_check.set_pressed_no_signal(GameSettings.fullscreen)
	if _music_slider != null:
		_music_slider.set_value_no_signal(GameSettings.music_volume * 100.0)
	if _sfx_slider != null:
		_sfx_slider.set_value_no_signal(GameSettings.sfx_volume * 100.0)
	_refresh_volume_labels()

	if _music_row != null:
		_music_row.visible = MusicManager.has_music()

	_refresh_pack_options()
	if _tier_check != null:
		_tier_check.set_pressed_no_signal(GameSettings.tier_variants)
		_tier_check.visible = IconPacks.has_tier_variants(GameSettings.icon_pack)
	if _unit_option != null:
		_unit_option.select(clampi(int(GameSettings.wind_unit_index), 0, TyphoonSim.WIND_UNITS.size() - 1))
	if _hint != null:
		_hint.text = ""


func _refresh_volume_labels() -> void:
	if _music_slider != null and _music_value != null:
		_music_value.text = "%d%%" % int(roundf(_music_slider.value))
	if _sfx_slider != null and _sfx_value != null:
		_sfx_value.text = "%d%%" % int(roundf(_sfx_slider.value))


func _on_volume_changed(value: float, row_name: String) -> void:
	if row_name == "音乐音量":
		GameSettings.set_music_volume(value / 100.0)
	else:
		GameSettings.set_sfx_volume(value / 100.0)
	_refresh_volume_labels()


func _on_fullscreen_toggled(value: bool) -> void:
	var ok: bool = GameSettings.set_fullscreen(value)
	_fullscreen_check.set_pressed_no_signal(GameSettings.fullscreen)
	_hint.text = "" if ok else \
		"当前环境不支持全屏——编辑器里请关掉「编辑器设置 → 运行 → 窗口 → 嵌入游戏窗口」，或运行导出的 exe"


# ------------------------------ 方案包 ------------------------------

func _refresh_pack_options() -> void:
	if _pack_option == null:
		return
	_pack_names = GameSettings.pack_options()
	_pack_option.clear()
	for i in _pack_names.size():
		_pack_option.add_item(_pack_names[i] + (" ⚠" if _pack_mismatch(_pack_names[i]) else ""), i)
	var idx := maxi(_pack_names.find(GameSettings.icon_pack), 0)
	_pack_option.select(idx)
	_pack_option.disabled = _pack_names.is_empty()
	_apply_pack_warning(_selected_pack_mismatch())


func _pack_mismatch(pack_name: String) -> bool:
	return not GameSettings.is_builtin_pack(pack_name) and not IconPacks.version_ok(pack_name)


func _selected_pack_mismatch() -> bool:
	var current := GameSettings.icon_pack
	if not _pack_names.has(current):
		return false
	return _pack_mismatch(current)


func _apply_pack_warning(on: bool) -> void:
	if _pack_option == null:
		return
	const COLOR_SLOTS: Array[String] = [
		"font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]
	const STYLE_SLOTS: Array[String] = ["normal", "hover", "pressed", "focus"]
	if on:
		for slot in COLOR_SLOTS:
			_pack_option.add_theme_color_override(slot, PACK_WARN_COLOR)
		var box := StyleBoxFlat.new()
		box.bg_color = Color(1.0, 0.85, 0.2, 0.18)
		box.border_color = PACK_WARN_COLOR
		box.set_border_width_all(2)
		box.set_corner_radius_all(4)
		for slot in STYLE_SLOTS:
			_pack_option.add_theme_stylebox_override(slot, box)
	else:
		for slot in COLOR_SLOTS:
			_pack_option.remove_theme_color_override(slot)
		for slot in STYLE_SLOTS:
			_pack_option.remove_theme_stylebox_override(slot)
	if _pack_warn != null:
		_pack_warn.visible = on


func _on_pack_selected(index: int) -> void:
	if index < 0 or index >= _pack_names.size():
		return
	GameSettings.set_icon_pack(_pack_names[index])
	_apply_pack_warning(_selected_pack_mismatch())
	if _tier_check != null:
		_tier_check.visible = IconPacks.has_tier_variants(GameSettings.icon_pack)


func _on_tier_toggled(pressed: bool) -> void:
	GameSettings.set_tier_variants(pressed)


func _on_unit_selected(index: int) -> void:
	GameSettings.set_wind_unit_index(index)
	GameSettings.changed.emit()


func _on_sim_settings_changed() -> void:
	GameSettings.commit()
	GameSettings.changed.emit()
