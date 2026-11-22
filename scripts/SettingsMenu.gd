extends Control
## 设置界面：选项卡式（预设 / 视频 / 音频 / 模拟 / 导出），比窗口略小的半透明框，
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

## 视频页：窗口大小下拉（2026-11-22 用户要求；替代原来的「全屏显示」勾选框）
@onready var window_size_option: OptionButton = %WindowSizeOption
@onready var window_size_hint: Label = %WindowSizeHint

@onready var music_slider: HSlider = %MusicSlider
@onready var music_value: Label = %MusicValue
@onready var sfx_slider: HSlider = %SfxSlider
@onready var sfx_value: Label = %SfxValue

@onready var back_button: Button = %BackButton
@onready var hint_label: Label = %HintLabel

## 「预设」页的控件（用代码建，避免手改 .tscn）
## 2026-11-05 起：三个下拉合成一个「方案」（= 一个 zip 方案包）
## 2026-11-10 用户要求：改回**原生 OptionButton 下拉框**（之前是折叠行内列表）
var pack_option: OptionButton = null
## 方案下拉框右侧的「数据包版本不兼容」提示（只在当前包版本不兼容时显示）
var pack_warn: Label = null
## 扫描到的方案包名（下拉项顺序 = 这个数组，item id = 下标）
var _pack_names: Array[String] = []
var unit_option: OptionButton = null
## 「启用等级扩展图标」勾选框（用户 2026-11-07）
var tier_variants_check: CheckBox = null

## 数据包版本不兼容时：整个下拉框 + 右侧提示都用**半透明黄**（用户 2026-11-10）
const PACK_WARN_TEXT := "数据包版本不兼容"
const PACK_WARN_COLOR := Color(1.0, 0.85, 0.2, 0.55)

## 「导出」页的图片导出器（1.3 ④，2026-11-22 从侧栏搬进设置）
const TrackExporterClass := preload("res://scripts/TrackExporter.gd")
## 最佳路径默认导出目录名（游戏根目录下）
const BEST_TRACK_DIR_NAME := "BestTrack"
## 「导出方式」下拉的显示文字。值由 `GameSettings.BEST_TRACK_FORMATS` 决定，
## 顺序必须一致（`_setup_best_track_format_options` 按格式值遍历）。
const FORMAT_LABELS := {
	"noaa": "NOAA（IBTrACS）",
	"cma": "CMA（中国气象局）",
}

## 关闭时的回调（由打开方注入）
var on_closed: Callable = Callable()

## 「模拟」页组件实例（1.1.0）。只放**可调参数**，不含模式选项。
var sim_settings: Node = null

## ── 「导出」页控件（2026-11-22）──
## 路径图片导出按钮 + 状态文字
var export_button: Button = null
var export_status: Label = null
## 最佳路径数据集（从 SimSettings 搬来）
var best_track_check: CheckBox = null
var best_track_format_option: OptionButton = null
var best_track_format_label: Label = null
var best_track_dir_label: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	_build_preset_page()
	_build_sim_page()
	_build_export_page()

	# 用外置 TabBar 控制 TabContainer：同步标签数量 + 标题，再藏掉 TabContainer 自带的标签条
	pages.tabs_visible = false
	tab_bar.tab_count = pages.get_tab_count()
	for i in pages.get_tab_count():
		tab_bar.set_tab_title(i, pages.get_tab_title(i))
	tab_bar.tab_changed.connect(_on_tab_changed)

	_setup_window_sizes()
	music_slider.value_changed.connect(_on_music_changed)
	sfx_slider.value_changed.connect(_on_sfx_changed)
	back_button.pressed.connect(close)


# ============================ 视频页：窗口大小（2026-11-22） ============================

## 下拉项 = GameSettings.WINDOW_PRESETS + 末尾「全屏」；当前屏幕放不下的档置灰
func _setup_window_sizes() -> void:
	window_size_option.clear()
	for i in GameSettings.WINDOW_PRESETS.size():
		window_size_option.add_item(GameSettings.window_size_label(i), i)
	window_size_option.add_item(GameSettings.window_size_label(GameSettings.WINDOW_FULLSCREEN_INDEX),
		GameSettings.WINDOW_FULLSCREEN_INDEX)
	window_size_option.item_selected.connect(_on_window_size_selected)


## 打开设置时：按当前档位选中；放不下的档置灰并写 tooltip
func _refresh_window_size_option() -> void:
	for i in window_size_option.item_count:
		var idx: int = int(window_size_option.get_item_id(i))
		var fits: bool = GameSettings.window_size_fits(idx)
		window_size_option.set_item_disabled(i, not fits)
		window_size_option.set_item_tooltip(i,
			"" if fits else "当前屏幕放不下（可用区高度需 ≥ 窗口高 + 标题栏）")
	var cur := GameSettings.window_size_index
	if cur < 0:
		cur = GameSettings.best_window_size_index()
	# 玩家可能自己拖拽窗口改了大小：按**实际窗口尺寸**优先匹配档位，避免下拉显示过期
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN:
		var win := DisplayServer.window_get_size()
		for i in GameSettings.WINDOW_PRESETS.size():
			var p: Dictionary = GameSettings.WINDOW_PRESETS[i]
			if int(p["w"]) == win.x and int(p["h"]) == win.y:
				cur = i
				break
	for i in window_size_option.item_count:
		if int(window_size_option.get_item_id(i)) == cur:
			window_size_option.select(i)
			break
	window_size_hint.text = "当前窗口：%d × %d px（选「全屏」可全屏；更大的档位需要更大的显示器）" % [
		DisplayServer.window_get_size().x, DisplayServer.window_get_size().y]


## 选中窗口大小：立刻生效 + 落盘（GameSettings 会处理屏幕放不下时退回最大可放档）
func _on_window_size_selected(index: int) -> void:
	if index < 0 or index >= window_size_option.item_count:
		return
	var idx: int = int(window_size_option.get_item_id(index))
	GameSettings.set_window_size_index(idx)
	_refresh_window_size_option()


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

	# 方案选择：**原生下拉框**（用户 2026-11-10 要求改回 OptionButton）
	var pack_row := HBoxContainer.new()
	pack_row.add_theme_constant_override("separation", 14)
	page.add_child(pack_row)
	var pack_label := Label.new()
	pack_label.custom_minimum_size = Vector2(130, 0)
	pack_label.add_theme_font_size_override("font_size", 19)
	pack_label.text = "方案"
	pack_row.add_child(pack_label)
	pack_option = OptionButton.new()
	# 用户 2026-10-31：控件不用占满横向，200 px 足够（和最佳路径的选择框一致）
	pack_option.custom_minimum_size = Vector2(200, 44)
	pack_option.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	pack_option.add_theme_font_size_override("font_size", 19)
	pack_option.tooltip_text = "方案包（assets/icons/<名字>/）：图标、登陆特效、音效都从里面取"
	pack_option.item_selected.connect(_on_pack_selected)
	pack_row.add_child(pack_option)
	# ⚠ 用户 2026-11-10：版本不兼容时，在下拉框**正右方**（间距 14 px，远小于 150 px）显示提示
	pack_warn = Label.new()
	pack_warn.text = PACK_WARN_TEXT
	pack_warn.visible = false
	pack_warn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	pack_warn.add_theme_font_size_override("font_size", 17)
	pack_warn.add_theme_color_override("font_color", PACK_WARN_COLOR)
	pack_row.add_child(pack_warn)
	_refresh_pack_options()

	tier_variants_check = CheckBox.new()
	tier_variants_check.text = "启用等级扩展图标"
	tier_variants_check.custom_minimum_size = Vector2(200, 44)
	tier_variants_check.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tier_variants_check.add_theme_font_size_override("font_size", 19)
	tier_variants_check.tooltip_text = "使用素材里的 +/- 变体图标（只在 advanced / adv_extend 方案可用）"
	tier_variants_check.toggled.connect(_on_tier_variants_toggled)
	page.add_child(tier_variants_check)

	unit_option = _add_option_row(page, "单位", "风速显示单位")
	for unit in TyphoonSim.WIND_UNITS:
		unit_option.add_item(unit)
	unit_option.item_selected.connect(_on_unit_selected)

	# 预设页放第一个（TabContainer 里第 0 个）
	pages.move_child(pages.get_child(pages.get_child_count() - 1), 0)


## 重新扫描方案包并重建下拉项（用户新放文件夹立刻可见）。
## 版本不兼容的方案：下拉项文字后加 ⚠；**当前选中的**不兼容包 → 下拉框整体半透明黄 + 右侧提示。
func _refresh_pack_options() -> void:
	if pack_option == null:
		return
	_pack_names = GameSettings.pack_options()
	pack_option.clear()
	for i in _pack_names.size():
		var item_name := _pack_names[i]
		pack_option.add_item(item_name + (" ⚠" if _pack_mismatch(item_name) else ""), i)
	pack_option.select(_current_pack_index())
	pack_option.disabled = _pack_names.is_empty()
	_apply_pack_warning(_selected_pack_mismatch())


## 某个方案包是否「版本不兼容」（内置方案永远兼容）
static func _pack_mismatch(pack_name: String) -> bool:
	return not GameSettings.is_builtin_pack(pack_name) and not IconPacks.version_ok(pack_name)


## 当前加载中的方案是否版本不兼容（不在列表里 → 当兼容处理）
func _selected_pack_mismatch() -> bool:
	var current := GameSettings.icon_pack
	if not _pack_names.has(current):
		return false
	return _pack_mismatch(current)


## 版本不兼容提示：整个下拉框染半透明黄（字色 + 各状态底框/边框），右侧提示文字可见。
## 兼容时移除所有覆盖，恢复主题默认外观（用户 2026-11-10）
func _apply_pack_warning(on: bool) -> void:
	if pack_option == null:
		return
	const COLOR_SLOTS: Array[String] = [
		"font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]
	const STYLE_SLOTS: Array[String] = ["normal", "hover", "pressed", "focus"]
	if on:
		for slot in COLOR_SLOTS:
			pack_option.add_theme_color_override(slot, PACK_WARN_COLOR)
		var box := StyleBoxFlat.new()
		box.bg_color = Color(1.0, 0.85, 0.2, 0.18)     # 半透明黄底
		box.border_color = PACK_WARN_COLOR
		box.set_border_width_all(2)
		box.set_corner_radius_all(4)
		for slot in STYLE_SLOTS:
			pack_option.add_theme_stylebox_override(slot, box)
	else:
		for slot in COLOR_SLOTS:
			pack_option.remove_theme_color_override(slot)
		for slot in STYLE_SLOTS:
			pack_option.remove_theme_stylebox_override(slot)
	if pack_warn != null:
		pack_warn.visible = on


## 当前选中的方案索引（找不到 = 0）
func _current_pack_index() -> int:
	var i := _pack_names.find(GameSettings.icon_pack)
	return maxi(i, 0)


## 模拟页（2026-11-22 原「模拟设置」页改名为「模拟」）：只放可调参数，不含模式选项
func _build_sim_page() -> void:
	# ⚠ 外面包一层 ScrollContainer（2026-10-17，用户报「内容被裁掉」）：
	#   TabContainer 的高度是场景里定死的，而它的**最小高度**取自「当前页的最小高度」。
	#   模拟页内容较多，直接当 Pages 的子节点会把 Pages 的最小高度顶高，
	#   于是矮窗口时 VBox 只能按最小值排 → 整页把「返回」按钮顶出屏幕。
	var page := _new_scroll_page("模拟")
	sim_settings = load("res://SimSettings.tscn").instantiate()
	page.add_child(sim_settings)
	sim_settings.setup(true, Game.season_mode)
	sim_settings.settings_changed.connect(_on_sim_settings_changed)


# ============================ 「导出」页（2026-11-22） ============================
# 用户要求：把「路径图片导出」和「最佳路径数据集」两组从「模拟」页挪到新的「导出」页。
# 路径图片导出：和 ESC 暂停菜单的「导出图片」是同一个功能，两个入口。

## 一行的分区小标题（「── 路径图片导出 ──」这种）
func _section_label(text_value: String) -> Label:
	var lbl := Label.new()
	lbl.text = text_value
	lbl.add_theme_font_size_override("font_size", 17)
	lbl.add_theme_color_override("font_color", Color(0.72, 0.74, 0.78))
	return lbl


## 一行灰色小字（说明 / 路径）
func _hint_text(text_value: String) -> Label:
	var lbl := Label.new()
	lbl.text = text_value
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.62, 0.65, 0.70))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return lbl


func _build_export_page() -> void:
	var page := _new_scroll_page("导出")

	# ── ① 路径图片导出 ──
	page.add_child(_section_label("── 路径图片导出 ──"))
	var export_row := HBoxContainer.new()
	export_row.add_theme_constant_override("separation", 14)
	page.add_child(export_row)
	export_button = Button.new()
	export_button.custom_minimum_size = Vector2(240, 48)
	export_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	export_button.add_theme_font_size_override("font_size", 20)
	export_button.text = "导出图片"
	export_button.tooltip_text = "把地图 + 本局已结束台风的路径合并导出成一张 PNG 图片"
	export_button.pressed.connect(_on_export_pressed)
	export_row.add_child(export_button)
	export_status = Label.new()
	export_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	export_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	export_status.add_theme_font_size_override("font_size", 15)
	export_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	export_row.add_child(export_status)
	page.add_child(_hint_text("导出目录：%s" % _export_image_dir()))

	# ── ② 最佳路径数据集（从「模拟」页搬来） ──
	page.add_child(_section_label("── 最佳路径数据集 ──"))
	best_track_check = CheckBox.new()
	best_track_check.text = "最佳路径数据集"
	best_track_check.custom_minimum_size = Vector2(200, 44)
	best_track_check.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	best_track_check.add_theme_font_size_override("font_size", 19)
	best_track_check.tooltip_text = "把每场台风的路径点、强度、时间记录成数据集，用来和真实最佳路径做对比。"
	best_track_check.toggled.connect(_on_best_track_toggled)
	page.add_child(best_track_check)

	var fmt_row := HBoxContainer.new()
	fmt_row.add_theme_constant_override("separation", 14)
	page.add_child(fmt_row)
	best_track_format_label = Label.new()
	best_track_format_label.custom_minimum_size = Vector2(130, 0)
	best_track_format_label.add_theme_font_size_override("font_size", 19)
	best_track_format_label.text = "导出方式"
	fmt_row.add_child(best_track_format_label)
	best_track_format_option = OptionButton.new()
	best_track_format_option.custom_minimum_size = Vector2(200, 44)
	best_track_format_option.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	best_track_format_option.add_theme_font_size_override("font_size", 19)
	best_track_format_option.tooltip_text = "导出的文件格式：NOAA 是 IBTrACS（国际通用），CMA 是中国气象局格式。两种格式共用同一份轨迹数据。"
	best_track_format_option.item_selected.connect(_on_best_track_format_selected)
	fmt_row.add_child(best_track_format_option)
	best_track_dir_label = _hint_text("导出目录：%s" % _default_best_track_dir())
	page.add_child(best_track_dir_label)

	_setup_best_track_format_options()


## 「导出方式」下拉：顺序/允许值以 `GameSettings.BEST_TRACK_FORMATS` 为唯一真源，
## item 的 id 就是数组下标（选中后按 `BEST_TRACK_FORMATS[index]` 换回字符串）。
func _setup_best_track_format_options() -> void:
	if best_track_format_option == null:
		return
	best_track_format_option.clear()
	var idx := 0
	for fmt in GameSettings.BEST_TRACK_FORMATS:
		best_track_format_option.add_item(FORMAT_LABELS.get(fmt, fmt), idx)
		idx += 1


## 打开设置 / 改动后同步「导出」页：按钮可用性、勾选值、下拉值、目录文字
func _refresh_export_page() -> void:
	if export_button == null:
		return
	best_track_check.set_pressed_no_signal(GameSettings.best_track_enabled)
	_update_best_track_controls()

	var pl := _game_path_layer()
	var can: bool = pl != null and pl.has_archived_tracks()
	export_button.disabled = not can
	export_button.text = "导出图片"
	if can:
		export_button.tooltip_text = "把地图 + 本局已结束台风的路径合并导出成一张 PNG 图片"
		if export_status != null and export_status.text == "":
			export_status.text = "可导出：本局已有已结束的台风"
	else:
		export_button.tooltip_text = "还没有可导出的路径"
		if export_status != null:
			export_status.text = ("进游戏后才可用" if pl == null else "还没有已结束的台风")


## 勾选「最佳路径数据集」才允许改导出方式；风季模式下也保持可改（非作弊项）
func _update_best_track_controls() -> void:
	if best_track_check == null:
		return
	var on := best_track_check.button_pressed
	best_track_format_option.disabled = not on
	best_track_format_label.modulate = Color(1, 1, 1, 1) if on else Color(1, 1, 1, 0.45)
	var fmt_idx: int = GameSettings.BEST_TRACK_FORMATS.find(GameSettings.best_track_format)
	best_track_format_option.select(maxi(fmt_idx, 0))


## 当前场景里的路径层（进游戏后才存在；标题画面 = null → 导出按钮禁用）
func _game_path_layer() -> PathLayer:
	var scene := get_tree().current_scene
	var pl := _path_layer_in(scene)
	if pl != null:
		return pl
	# 兜底：从自己往上找最近一个含 PathLayer 的祖先
	# （ESC 菜单/测试探针里当前场景可能不是 GameRoot）
	var n := get_parent()
	while n != null:
		pl = _path_layer_in(n)
		if pl != null:
			return pl
		n = n.get_parent()
	return null


func _path_layer_in(root: Node) -> PathLayer:
	if root == null:
		return null
	return root.get_node_or_null("View/TopRow/MapArea/MapLayer/PathLayer") as PathLayer


## 路径图片导出目录：<游戏根>/导出图片（和 TrackExporter 保持一致）
func _export_image_dir() -> String:
	if OS.has_feature("template"):
		return OS.get_executable_path().get_base_dir().path_join("导出图片")
	return ProjectSettings.globalize_path("res://").path_join("导出图片")


## 最佳路径默认导出目录 = <游戏根>/BestTrack。
## ⚠ 「游戏根」在两种运行方式下不是同一个地方：
##   · 编辑器 / 直接跑工程：`res://` 就是工程根，可写
##   · 导出成 exe：`res://` 在 PCK 里**只读**，必须写到 exe 所在目录
func _default_best_track_dir() -> String:
	var base := ""
	if OS.has_feature("template"):
		base = OS.get_executable_path().get_base_dir()
	else:
		base = ProjectSettings.globalize_path("res://")
	return base.path_join(BEST_TRACK_DIR_NAME)


## 「导出图片」按钮：导出后把结果写在本页状态行 + 底部 Hint（与 ESC 菜单同功能）
func _on_export_pressed() -> void:
	if export_button == null or export_button.disabled:
		return
	var pl := _game_path_layer()
	if pl == null:
		export_status.text = "导出失败：进游戏后才可用"
		return
	export_button.disabled = true
	export_button.text = "导出中…"
	export_status.text = "正在导出…"
	var exporter: RefCounted = TrackExporterClass.new()
	var msg: String = await exporter.export_png(self, pl)
	export_button.text = "导出图片"
	_refresh_export_page()
	export_status.text = msg if msg != "" else "导出失败：本局还没有已结束的台风"
	hint_label.text = export_status.text


## 最佳路径数据集：立即生效 + 落盘（与「模拟」页的其它设置同一套持久化）
func _on_best_track_toggled(pressed: bool) -> void:
	GameSettings.best_track_enabled = pressed
	_update_best_track_controls()
	_on_sim_settings_changed()


## 导出方式：切格式**不清空已有轨迹**（采样与格式无关，一年只在年底写一次文件，
## 所以整份文件必然用切换后的格式；跨年延后写的那种边角也用新格式，可接受）。
func _on_best_track_format_selected(index: int) -> void:
	var formats: Array[String] = GameSettings.BEST_TRACK_FORMATS
	if index < 0 or index >= formats.size():
		return
	if GameSettings.best_track_format == formats[index]:
		return
	GameSettings.best_track_format = formats[index]
	_on_sim_settings_changed()


func _on_tab_changed(index: int) -> void:
	pages.current_tab = index


## 「模拟设置」改动：落盘 + 广播，让 TyphoonSim 等重同步（如最佳路径开关）
func _on_sim_settings_changed() -> void:
	GameSettings.commit()
	GameSettings.changed.emit()


# ============================ 打开 / 同步 ============================

## 打开设置界面：先把控件同步到当前设置值
func open() -> void:
	# 视频页：窗口大小下拉（每次打开按当前窗口重新判断哪些档位放得下）
	_refresh_window_size_option()
	music_slider.set_value_no_signal(GameSettings.music_volume * 100.0)
	sfx_slider.set_value_no_signal(GameSettings.sfx_volume * 100.0)
	_refresh_volume_labels()

	# 音乐滑块：方案包里有任何 music.* ID 才显示（用户 2026-11-06）
	var music_row := music_slider.get_parent() as Control
	if music_row != null:
		music_row.visible = MusicManager.has_music()

	# 预设页：方案包（每次打开重新扫，能看到用户新放的文件夹）
	_refresh_pack_options()
	tier_variants_check.set_pressed_no_signal(GameSettings.tier_variants)
	tier_variants_check.visible = _tier_variants_available()
	unit_option.select(clampi(int(GameSettings.wind_unit_index), 0, TyphoonSim.WIND_UNITS.size() - 1))

	# 导出页：按钮可用性 / 最佳路径选项（每次打开重算）
	_refresh_export_page()

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

func _on_music_changed(value: float) -> void:
	GameSettings.set_music_volume(value / 100.0)
	_refresh_volume_labels()


func _on_sfx_changed(value: float) -> void:
	GameSettings.set_sfx_volume(value / 100.0)
	_refresh_volume_labels()


## 当前方案是否支持 +/− 变体（内置方案 / single 不显示勾选框）
func _tier_variants_available() -> bool:
	# 只在作者于 index.json 声明 tier_variants=true、且包里真有变体 ID 时显示
	return IconPacks.has_tier_variants(GameSettings.icon_pack)


func _on_tier_variants_toggled(pressed: bool) -> void:
	GameSettings.set_tier_variants(pressed)


## 方案包：立即生效 + 落盘；版本不兼容的包 → 下拉框变半透明黄 + 右侧提示
func _on_pack_selected(index: int) -> void:
	if index < 0 or index >= _pack_names.size():
		return
	GameSettings.set_icon_pack(_pack_names[index])
	_apply_pack_warning(_selected_pack_mismatch())
	if tier_variants_check != null:
		tier_variants_check.visible = _tier_variants_available()


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
