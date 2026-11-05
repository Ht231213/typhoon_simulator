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
## 2026-11-05 起：三个下拉合成一个「方案」（= 一个 zip 方案包）
var pack_option: OptionButton = null
## 扫描到的方案包名（下拉项顺序 = 这个数组）
var _pack_names: Array[String] = []
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
	# 用户 2026-10-31：控件不用占满横向，200 px 足够（和最佳路径的选择框一致）
	opt.custom_minimum_size = Vector2(200, 44)
	opt.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	opt.add_theme_font_size_override("font_size", 19)
	opt.tooltip_text = tooltip
	row.add_child(opt)
	return opt


## 预设页：**方案**（一个 zip = 图标 + 登陆特效 + 登陆音效）+ 单位
## ⚠ 用户 2026-11-05：三个下拉合成一个；白色阶段勾选删除；版面不要介绍性文字。
func _build_preset_page() -> void:
	var page := _new_scroll_page("预设")

	pack_option = _add_option_row(page, "方案", "方案包（assets/icons/<名字>.zip）：图标、登陆特效、音效都从里面取")
	_refresh_pack_options()
	pack_option.item_selected.connect(_on_pack_selected)

	unit_option = _add_option_row(page, "单位", "风速显示单位")
	for unit in TyphoonSim.WIND_UNITS:
		unit_option.add_item(unit)
	unit_option.item_selected.connect(_on_unit_selected)

	# 预设页放第一个（TabContainer 里第 0 个）
	pages.move_child(pages.get_child(pages.get_child_count() - 1), 0)


## 重新扫描方案包并填充下拉（每次打开设置都扫，用户新放 zip 立刻可见）
func _refresh_pack_options() -> void:
	if pack_option == null:
		return
	_pack_names = GameSettings.pack_options()
	pack_option.clear()
	for i in _pack_names.size():
		var name := _pack_names[i]
		pack_option.add_item(name)
		# version 和游戏不匹配 → 方案名标黄（不弹窗、不报错；内置 Default 不参与）
		if not GameSettings.is_builtin_pack(name) and not IconPacks.version_ok(name):
			pack_option.set_item_custom_fg_color(i, Color(1.0, 0.85, 0.2))
	if _pack_names.is_empty():
		pack_option.add_item("（无方案包）")
		pack_option.disabled = true
	else:
		pack_option.disabled = false


## 当前选中的方案索引（找不到 = 0）
func _current_pack_index() -> int:
	var i := _pack_names.find(GameSettings.icon_pack)
	return maxi(i, 0)


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

	# 音乐滑块：方案包里有任何 music.* ID 才显示（用户 2026-11-06）
	var music_row := music_slider.get_parent() as Control
	if music_row != null:
		music_row.visible = MusicManager.has_music()

	# 预设页：方案包（每次打开重新扫，能看到用户新放的文件夹）
	_refresh_pack_options()
	pack_option.select(_current_pack_index())
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


## 方案包：立即生效 + 落盘
func _on_pack_selected(index: int) -> void:
	if index < 0 or index >= _pack_names.size():
		return
	GameSettings.set_icon_pack(_pack_names[index])


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
