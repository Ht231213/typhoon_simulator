extends Control
## 设置界面：选项卡式（预设 / 视频 / 音频 / 模拟设置），比窗口略小的半透明框，
## 顶部选项卡、底部「返回」。
##
## 改动是「即时生效 + 立即落盘」，没有确定/取消（只有「返回」）。
##
## 两种用法都支持：
##   ① 场景里放一个实例（主菜单用），调用 open()
##   ② 运行时 load(...).instantiate() 再加进树（ESC 菜单用）
## 本节点 process_mode = ALWAYS，所以 ESC 全暂停（get_tree().paused）时也能操作。
##
## ⚠ 2026-10-30 用户要求（A4）：
##   · 新增「预设」页 = 方案（图标+特效+音效，A3 一起换）+「170kt+ 亮蓝扩展」勾选 + 风速单位
##   · 「视频」页只留全屏；「模拟设置」只留模拟参数（单位已挪到预设页）

@onready var tab_bar: TabBar = %TabBar
@onready var pages: TabContainer = %Pages

@onready var fullscreen_check: CheckBox = %FullscreenCheck

@onready var music_slider: HSlider = %MusicSlider
@onready var music_value: Label = %MusicValue
@onready var sfx_slider: HSlider = %SfxSlider
@onready var sfx_value: Label = %SfxValue

@onready var back_button: Button = %BackButton
@onready var hint_label: Label = %HintLabel

## 「预设」页的控件（用代码建，避免手改 .tscn）
var icon_scheme_option: OptionButton = null
var effect_scheme_option: OptionButton = null
var sfx_scheme_option: OptionButton = null
var bright_ext_check: CheckBox = null
var unit_option: OptionButton = null

## 关闭时的回调（由打开方注入）
var on_closed: Callable = Callable()

## 「模拟设置」组件实例（1.1.0）。只放**可调参数**，不含模式选项。
var sim_settings: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	_build_preset_page()
	_build_sim_page()

	# 用外置 TabBar 控制 TabContainer：同步标签数量 + 标题，再藏掉 TabContainer 自带的标签条
	pages.tabs_visible = false
	tab_bar.tab_count = pages.get_tab_count()
	for i in pages.get_tab_count():
		tab_bar.set_tab_title(i, pages.get_tab_title(i))
	tab_bar.tab_changed.connect(_on_tab_changed)

	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	music_slider.value_changed.connect(_on_music_changed)
	sfx_slider.value_changed.connect(_on_sfx_changed)
	back_button.pressed.connect(close)


# ============================ 构建各页 ============================

## 新建一个可滚动页（TabContainer 用直接子节点的名字当标签标题，所以 scroll 必须叫标题名）
func _new_scroll_page(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.clip_contents = true        # 内容超长时别画到相邻 UI 上
	scroll.follow_focus = true         # Tab 键跳到看不见的控件时自动滚过去
	pages.add_child(scroll)
	var page := VBoxContainer.new()
	page.name = "Page"
	page.add_theme_constant_override("separation", 8)
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(page)
	return page


## 一行「标签 + 下拉」
func _add_option_row(page: VBoxContainer, label_text: String, tooltip: String) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	page.add_child(row)
	var lbl := Label.new()
	lbl.custom_minimum_size = Vector2(130, 0)
	lbl.add_theme_font_size_override("font_size", 19)
	lbl.text = label_text
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(0, 44)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_theme_font_size_override("font_size", 19)
	opt.tooltip_text = tooltip
	row.add_child(opt)
	return opt


## 预设页：图标方案 / 特效方案 / 音效方案（各自独立）+ 白色阶段 + 单位
## ⚠ 用户 2026-10-31：下拉里**只写方案名**；版面上**不要任何介绍性文字**（tooltip 可以留）。
func _build_preset_page() -> void:
	var page := _new_scroll_page("预设")

	icon_scheme_option = _add_option_row(page, "图标方案", "台风图标的素材方案")
	_fill_scheme_option(icon_scheme_option)
	icon_scheme_option.item_selected.connect(_on_icon_scheme_selected)

	effect_scheme_option = _add_option_row(page, "特效方案", "登陆特效的素材方案")
	_fill_scheme_option(effect_scheme_option)
	effect_scheme_option.item_selected.connect(_on_effect_scheme_selected)

	sfx_scheme_option = _add_option_row(page, "音效方案", "登陆音效的素材方案")
	_fill_scheme_option(sfx_scheme_option)
	sfx_scheme_option.item_selected.connect(_on_sfx_scheme_selected)

	bright_ext_check = CheckBox.new()
	bright_ext_check.text = "白色阶段"
	bright_ext_check.custom_minimum_size = Vector2(0, 44)
	bright_ext_check.add_theme_font_size_override("font_size", 19)
	bright_ext_check.tooltip_text = "打开后 ≥260 kt 的图标会变成白色（会盖住数字/闪电）"
	bright_ext_check.toggled.connect(_on_bright_ext_toggled)
	page.add_child(bright_ext_check)

	unit_option = _add_option_row(page, "单位", "风速显示单位")
	for unit in TyphoonSim.WIND_UNITS:
		unit_option.add_item(unit)
	unit_option.item_selected.connect(_on_unit_selected)

	# 预设页放第一个（TabContainer 里第 0 个）
	pages.move_child(pages.get_child(pages.get_child_count() - 1), 0)


## 填充方案下拉：item id = PRESET_SCHEMES 下标，文字只显示方案名
func _fill_scheme_option(option: OptionButton) -> void:
	option.clear()
	var idx := 0
	for name in GameSettings.PRESET_SCHEMES:
		option.add_item(str(GameSettings.PRESET_LABELS.get(name, name)), idx)
		idx += 1


## 模拟设置页（1.1.0）：只放可调参数，不含模式选项
func _build_sim_page() -> void:
	# ⚠ 外面包一层 ScrollContainer（2026-10-17，用户报「内容被裁掉」）：
	#   TabContainer 的高度是场景里定死的，而它的**最小高度**取自「当前页的最小高度」。
	#   模拟设置页有 6 行内容（最小 376 px 高），直接当 Pages 的子节点会把 Pages 的最小
	#   高度顶到 376，于是矮窗口时 VBox 只能按最小值排 → 整页把「返回」按钮顶出屏幕。
	var page := _new_scroll_page("模拟设置")
	sim_settings = load("res://SimSettings.tscn").instantiate()
	page.add_child(sim_settings)
	sim_settings.setup(true, Game.season_mode)
	sim_settings.settings_changed.connect(_on_sim_settings_changed)


func _on_tab_changed(index: int) -> void:
	pages.current_tab = index


## 「模拟设置」改动：落盘 + 广播，让 TyphoonSim 等重同步（如最佳路径开关）
func _on_sim_settings_changed() -> void:
	GameSettings.commit()
	GameSettings.changed.emit()


# ============================ 打开 / 同步 ============================

## 打开设置界面：先把控件同步到当前设置值
func open() -> void:
	fullscreen_check.set_pressed_no_signal(GameSettings.fullscreen)
	music_slider.set_value_no_signal(GameSettings.music_volume * 100.0)
	sfx_slider.set_value_no_signal(GameSettings.sfx_volume * 100.0)
	_refresh_volume_labels()

	# 预设页（三个方案各自独立）
	icon_scheme_option.select(maxi(GameSettings.PRESET_SCHEMES.find(GameSettings.icon_scheme), 0))
	effect_scheme_option.select(maxi(GameSettings.PRESET_SCHEMES.find(GameSettings.effect_scheme), 0))
	sfx_scheme_option.select(maxi(GameSettings.PRESET_SCHEMES.find(GameSettings.sfx_preset), 0))
	bright_ext_check.set_pressed_no_signal(GameSettings.icon_bright_ext)
	bright_ext_check.visible = GameSettings.icon_scheme == "smcy13"
	unit_option.select(clampi(int(GameSettings.wind_unit_index), 0, TyphoonSim.WIND_UNITS.size() - 1))

	# 回到第一个选项卡。用 tab_count 判断，避免标签还没同步时报越界
	if tab_bar.tab_count > 0:
		tab_bar.current_tab = 0
	if pages.get_tab_count() > 0:
		pages.current_tab = 0
	# ⚠ 这里**不再**写任何「已保存到 …」之类的样板提示文字（用户要求去掉）。
	hint_label.text = ""
	visible = true


func _refresh_volume_labels() -> void:
	music_value.text = "%d%%" % int(roundf(music_slider.value))
	sfx_value.text = "%d%%" % int(roundf(sfx_slider.value))


# ============================ 各控件回调 ============================
# 全部都「即时生效 + 立即保存」，所以没有确定/取消按钮，只有一个「返回」。

func _on_fullscreen_toggled(value: bool) -> void:
	var ok: bool = GameSettings.set_fullscreen(value)
	# 没生效（编辑器内嵌窗口）→ 把勾选框拉回去，并说明原因，别让它显示成已开
	fullscreen_check.set_pressed_no_signal(GameSettings.fullscreen)
	# 只有真出错才给文字，成功时不留任何提示
	hint_label.text = "" if ok else \
		"当前环境不支持全屏——编辑器里请关掉「编辑器设置 → 运行 → 窗口 → 嵌入游戏窗口」，或运行导出的 exe"


func _on_music_changed(value: float) -> void:
	GameSettings.set_music_volume(value / 100.0)
	_refresh_volume_labels()


func _on_sfx_changed(value: float) -> void:
	GameSettings.set_sfx_volume(value / 100.0)
	_refresh_volume_labels()


## 图标方案（独立）
func _on_icon_scheme_selected(index: int) -> void:
	if index < 0 or index >= GameSettings.PRESET_SCHEMES.size():
		return
	GameSettings.set_icon_scheme(GameSettings.PRESET_SCHEMES[index])
	# 「白色阶段」只在 SMCY1.3 下显示
	bright_ext_check.visible = GameSettings.icon_scheme == "smcy13"


## 特效方案（独立）
func _on_effect_scheme_selected(index: int) -> void:
	if index < 0 or index >= GameSettings.PRESET_SCHEMES.size():
		return
	GameSettings.set_effect_scheme(GameSettings.PRESET_SCHEMES[index])


## 音效方案（独立）
func _on_sfx_scheme_selected(index: int) -> void:
	if index < 0 or index >= GameSettings.PRESET_SCHEMES.size():
		return
	GameSettings.set_sfx_scheme(GameSettings.PRESET_SCHEMES[index])


## 「170 kt+ 亮蓝扩展」（B4）：立即生效 + 落盘
func _on_bright_ext_toggled(pressed: bool) -> void:
	if GameSettings.icon_bright_ext == pressed:
		return
	GameSettings.icon_bright_ext = pressed
	GameSettings.commit()
	GameSettings.changed.emit()


## 风速单位：只影响显示，立即落盘
func _on_unit_selected(index: int) -> void:
	GameSettings.set_wind_unit_index(index)
	GameSettings.changed.emit()


# ============================ 关闭 ============================

## 「返回」按钮：改动早就保存了，这里只关掉界面
func close() -> void:
	visible = false
	if on_closed.is_valid():
		on_closed.call()


## ESC 等同于点「返回」
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
