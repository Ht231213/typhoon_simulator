extends VBoxContainer
## 可复用的「模拟设置」组件（1.1.0）。
##
## 用在两处（都由 Lead 集成）：
##   ① 暂停菜单 `SettingsMenu` 的第 3 个标签页（进游戏后）
##   ② 标题画面 `SettingsPanel` 里（进游戏前，不另带「开始游戏」按钮）
##
## 设计要点：
##   · **所有设置项都在同一个可折叠框里**（标题按钮控制 Content.visible），默认展开
##   · 三种权限上下文由 `setup()` / `set_context()` 切换，规则只写在 `set_context()` 一处
##   · 值分两个来源：
##       模式 / 风季 → `Game.mode` / `Game.season_mode`
##                     （它们是「一局」的属性，不是应用设置，所以不进 GameSettings）
##       其余 6 项    → `GameSettings.*`（应用级，跨局保存）
##
## ⚠ 落盘：`GameSettings` 只给「海温 / 单位」留了 setter（set_sim_sst / set_wind_unit_index），
##   记录类三项（记录扰动 / 最佳路径 / 路径）**没有任何 setter 会写盘**。
##   所以本组件在每次真正改动之后统一调一次 `GameSettings.commit()`（它的文档就是「再存一次」），
##   否则玩家改完这些开关，重开游戏就丢了。
## ⚠ 本组件不决定「怎么用」这些值（比如平均海温怎么影响物理），只负责读写与权限。

## 任何一项被用户改动后发一次。程序内部同步（refresh_from_store / set_context）不会发。
signal settings_changed

## 折叠框标题
const HEADER_TITLE := "模拟设置"
## 标题栏的三角符号（展开 / 收起）。用文字符号而不是贴图，省素材。
const HEADER_EXPANDED := "▼ %s"
const HEADER_COLLAPSED := "▶ %s"
## 行内字号。`.tscn` 里已经写了一遍，这里只用来补 SpinBox：
## ⚠ SpinBox 的数字是它**内部自己创建的 LineEdit** 画的，场景里的
##   `theme_override_font_sizes` 管不到，只能在代码里给那个 LineEdit 补一次，
##   否则两个数字框的字会比同一行的标签小一圈。
const ROW_FONT_SIZE := 19

@onready var header: Button = %Header
@onready var content: VBoxContainer = %Content

@onready var mode_option: OptionButton = %ModeOption
@onready var season_check: CheckBox = %SeasonCheck
@onready var mean_sst_spin: SpinBox = %MeanSstSpin
@onready var seasonal_amp_spin: SpinBox = %SeasonalAmpSpin
@onready var record_disturbances_check: CheckBox = %RecordDisturbancesCheck
## 「暂停时间轴」勾选框（2026-11-08）
var pause_timeline_check: CheckBox = null
## 「显示台风路径」勾选框（1.3 ④，2026-11-22）
var show_tracks_check: CheckBox = null

# 跟着权限一起压暗的标签（锁住的项如果只有控件变灰、标签还亮着，看起来像坏了）
@onready var mode_label: Label = %ModeLabel
@onready var mean_sst_label: Label = %MeanSstLabel
@onready var seasonal_amp_label: Label = %SeasonalAmpLabel

## 当前权限上下文（进游戏前 / 进游戏后·非风季 / 进游戏后·风季）
var _in_game := false
var _season := false
## _ready 是否已经跑完。setup() 允许在 add_child 之前调用，那时先记下上下文、等 _ready 再套用。
var _ready_done := false


func _ready() -> void:
	# 暂停菜单里（get_tree().paused = true）也要能点，所以固定 ALWAYS；
	# 标题画面里没有暂停，同样无害。
	process_mode = Node.PROCESS_MODE_ALWAYS
	header.text = HEADER_EXPANDED % HEADER_TITLE
	content.visible = true
	_build_sections()

	# 用户 2026-10-31：控件不用占满横向空间，200 px 足够（和最佳路径的选择框一致）
	_normalize_control_widths()

	# ⚠ 2026-10-17 用户更正定义：
	#   **模式选项**（模拟模式 + 风季模式）属于「模拟单台」那个面板（标题画面），
	#   **模拟设置**（本组件）只放**可调参数**，两者互相独立。
	#   所以这里把模式/风季两行**隐藏掉**——节点留着（代码不用改），只是不显示。
	var mode_row := get_node_or_null("%ModeOption")
	if mode_row != null and mode_row.get_parent() != null:
		mode_row.get_parent().visible = false
	var season_node := get_node_or_null("%SeasonCheck")
	if season_node != null:
		season_node.visible = false

	# 用户 2026-10-17：**模拟设置不需要巨大的折叠框**，直接平铺显示。
	# 做法：藏掉折叠标题和分隔线，并把 Frame 的面板底板换成空白（视觉上不像是"框"）。
	var hdr := get_node_or_null("%Header")
	if hdr != null:
		hdr.visible = false
	var content_node := get_node_or_null("%Content")
	if content_node != null and content_node.get_parent() != null:
		var sep_top := content_node.get_parent().get_node_or_null("SepTop")
		if sep_top != null:
			sep_top.visible = false
		var frame := content_node.get_parent().get_parent()
		if frame != null and frame.get_parent() != null:
			var box := frame.get_parent()
			if box is PanelContainer:
				(box as PanelContainer).add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_setup_mode_options()
	_apply_spin_fonts()
	_connect_signals()
	_ready_done = true
	refresh_from_store()
	set_context(_in_game, _season)


# ============================ 对外接口 ============================

## 初始化：先按存储里的值刷新控件，再按权限上下文加锁。
##
## 用法：
##   标题画面          sim_settings.setup(false, false)
##   进游戏后          sim_settings.setup(true, Game.season_mode)
##
## 可以先调用再 add_child —— 那种情况下会记住上下文，等 _ready 时再套用。
## 模拟页分区（2026-11-08）：非作弊的「模拟选项」和影响强度的「环境参数」。
## 用小标题区分，不加图标/变色、不加介绍文字（用户要求）。
func _build_sections() -> void:
	var sec_a := _make_section_label("── 模拟选项 ──")
	var sec_b := _make_section_label("── 环境参数（影响强度）──")
	content.add_child(sec_a)
	content.add_child(sec_b)
	pause_timeline_check = CheckBox.new()
	pause_timeline_check.text = "暂停时间轴"
	pause_timeline_check.custom_minimum_size = Vector2(200, pause_timeline_check.custom_minimum_size.y)
	pause_timeline_check.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	pause_timeline_check.tooltip_text = "日期与季节海温冻结在当前值；台风照常移动、增强/减弱（暂停期间不记最佳路径样本）"
	pause_timeline_check.toggled.connect(_on_pause_timeline_toggled)
	content.add_child(pause_timeline_check)
	# 「显示台风路径」（1.3 ④）：模拟选项（非作弊项），只影响画面，不影响导出。
	show_tracks_check = CheckBox.new()
	show_tracks_check.text = "显示台风路径"
	show_tracks_check.custom_minimum_size = Vector2(200, 40)
	show_tracks_check.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	show_tracks_check.tooltip_text = "显示当前台风和历史台风的路径折线。只影响画面，不影响导出的图片。"
	show_tracks_check.toggled.connect(_on_show_tracks_toggled)
	content.add_child(show_tracks_check)
	# 重排：模拟选项（模式/风季/记录扰动/显示路径）→ 环境参数（海温/季节增幅/暂停时间轴）
	# ⚠ 「最佳路径数据集」已按用户要求搬到设置的「导出」页（2026-11-22），这里不再有。
	var order: Array[Node] = [
		sec_a, content.get_node("ModeRow"), content.get_node("SeasonCheck"),
		content.get_node("SepMid2"), record_disturbances_check,
		show_tracks_check,
		sec_b, content.get_node("MeanSstRow"), content.get_node("SeasonalAmpRow"),
		pause_timeline_check,
	]
	for i in order.size():
		content.move_child(order[i], i)


func _make_section_label(text_value: String) -> Label:
	var lbl := Label.new()
	lbl.text = text_value
	lbl.add_theme_font_size_override("font_size", 17)
	lbl.add_theme_color_override("font_color", Color(0.72, 0.74, 0.78))
	return lbl


func _on_pause_timeline_toggled(pressed: bool) -> void:
	GameSettings.set_pause_timeline(pressed)


## 「显示台风路径」：只影响显示，写入 settings.cfg（1.3 ④）
func _on_show_tracks_toggled(pressed: bool) -> void:
	GameSettings.show_tracks = pressed
	_persist()


func setup(p_in_game: bool, p_season: bool) -> void:
	_in_game = p_in_game
	_season = p_season
	if not _ready_done:
		return
	refresh_from_store()
	set_context(_in_game, _season)


## 用户 2026-10-31：下拉/数值框不占满整行，统一 200 px 宽（和最佳路径的选择框一致）
func _normalize_control_widths() -> void:
	for ctrl in [mode_option, mean_sst_spin, seasonal_amp_spin,
			record_disturbances_check]:
		if ctrl == null:
			continue
		ctrl.custom_minimum_size = Vector2(200, ctrl.custom_minimum_size.y)
		ctrl.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

## 只改权限，不重读值。切换上下文（比如暂停菜单里又进了风季）时用。
## 权限规则只在这个函数里，改规则改这里就够：
##
##   ┌──────────────────┬──────────────────────────────────────────────┐
##   │ 进游戏前          │ 全部可改                                      │
##   │ 进游戏后·非风季   │ 模式 / 风季 → 禁用（模拟已经开跑，改了也没用）；  │
##   │                  │ 其余全部可改                                  │
##   │ 进游戏后·风季     │ 只锁「环境参数」区块：平均海温 / 季节海温增幅 /  │
##   │                  │ 暂停时间轴（调这些等于作弊）；                  │
##   │                  │ 模拟选项（记录扰动 / 显示路径）可改              │
##   └──────────────────┴──────────────────────────────────────────────┘
## ⚠ 2026-11-22：「最佳路径数据集 / 导出方式」已搬到设置的「导出」页（SettingsMenu），
##   本组件不再管它们。
## 用户 2026-11-10：非作弊项不能被风季模式锁住（之前是把除单位外全锁了）。
func set_context(p_in_game: bool, p_season: bool) -> void:
	_in_game = p_in_game
	_season = p_season
	if not _ready_done:
		return

	# ① 模式 / 风季：一进游戏就锁死。
	#    `Game.mode` / `Game.season_mode` 只在 `TyphoonSim._ready()` 里读一次，
	#    进游戏后再改毫无效果，所以必须禁用（这正是「禁用了但值还显示着」的场景）。
	var game_locked := p_in_game
	_set_editable(mode_option, not game_locked)
	_dim_label(mode_label, game_locked)
	_set_editable(season_check, not game_locked)

	# ② 单位：任何上下文都能改。它只影响显示（侧栏/战报读哪个单位），不碰物理。

	# ③ **风季模式只锁「环境参数」区块**（用户 2026-11-10）：
	#    平均海温 / 季节海温增幅 / 暂停时间轴 → 禁用（改这些会影响/冻结物理，算作弊）。
	var env_editable := not (p_in_game and p_season)
	_set_editable(mean_sst_spin, env_editable)
	_dim_label(mean_sst_label, not env_editable)
	_set_editable(seasonal_amp_spin, env_editable)
	_dim_label(seasonal_amp_label, not env_editable)
	if pause_timeline_check != null:
		_set_editable(pause_timeline_check, env_editable)

	# ④ 模拟选项（非作弊项）：记录扰动 / 显示台风路径——**风季模式下也保持可改**。
	#    （「最佳路径数据集」已搬到设置的「导出」页，本组件不再管它。）
	_set_editable(record_disturbances_check, true)
	# 1.3 ④「显示台风路径」：非作弊项，风季模式下也保持可改
	if show_tracks_check != null:
		_set_editable(show_tracks_check, true)


## 从存储重新读值到控件。不写回、不发 settings_changed。
func refresh_from_store() -> void:
	if not _ready_done:
		return

	# 模式：值就是 Game.Mode 枚举，item id 也用的同一个枚举，能直接还原
	var mode_index := mode_option.get_item_index(int(Game.mode))
	mode_option.select(mode_index if mode_index >= 0 else 0)
	season_check.set_pressed_no_signal(Game.season_mode)

	var unit_count := TyphoonSim.WIND_UNITS.size()

	mean_sst_spin.set_value_no_signal(GameSettings.mean_sst)
	seasonal_amp_spin.set_value_no_signal(GameSettings.seasonal_amplitude)
	if pause_timeline_check != null:
		pause_timeline_check.set_pressed_no_signal(GameSettings.pause_timeline)
	if show_tracks_check != null:
		show_tracks_check.set_pressed_no_signal(GameSettings.show_tracks)

	record_disturbances_check.set_pressed_no_signal(GameSettings.record_disturbances)


# ============================ 构建 / 连接 ============================

## 模拟模式下拉。item id 直接用 Game.Mode 枚举值，取的时候能直接还原成枚举。
## 电影模式还没做，照既有做法把该项禁用（`SettingsPanel` 里原本也是这么做的）。
func _setup_mode_options() -> void:
	mode_option.clear()
	mode_option.add_item("手动模式", Game.Mode.MANUAL)
	mode_option.add_item("自动模式", Game.Mode.AUTO)
	mode_option.add_item("电影模式（未开放）", Game.Mode.CINEMATIC)
	var cinematic := mode_option.get_item_index(int(Game.Mode.CINEMATIC))
	if cinematic >= 0:
		mode_option.set_item_disabled(cinematic, true)


## 风速单位。选项直接从 TyphoonSim.WIND_UNITS 拿，别在这里另抄一份字符串，
## 否则以后加了单位两边会悄悄错位。

## SpinBox 的字号要单独补，见 ROW_FONT_SIZE 的注释。
func _apply_spin_fonts() -> void:
	for spin in [mean_sst_spin, seasonal_amp_spin]:
		(spin as SpinBox).get_line_edit().add_theme_font_size_override(
			"font_size", ROW_FONT_SIZE)


func _connect_signals() -> void:
	header.pressed.connect(_on_header_pressed)
	mode_option.item_selected.connect(_on_mode_selected)
	season_check.toggled.connect(_on_season_toggled)
	mean_sst_spin.value_changed.connect(_on_mean_sst_changed)
	seasonal_amp_spin.value_changed.connect(_on_seasonal_amp_changed)
	record_disturbances_check.toggled.connect(_on_record_disturbances_toggled)


# ============================ 用户改动 ============================

func _on_header_pressed() -> void:
	content.visible = not content.visible
	header.text = (HEADER_EXPANDED if content.visible else HEADER_COLLAPSED) % HEADER_TITLE


func _on_mode_selected(index: int) -> void:
	Game.mode = mode_option.get_item_id(index) as Game.Mode
	settings_changed.emit()


func _on_season_toggled(pressed: bool) -> void:
	Game.season_mode = pressed
	settings_changed.emit()



func _on_mean_sst_changed(value: float) -> void:
	if is_equal_approx(GameSettings.mean_sst, value):
		return
	GameSettings.mean_sst = value
	_persist()


func _on_seasonal_amp_changed(value: float) -> void:
	if is_equal_approx(GameSettings.seasonal_amplitude, value):
		return
	GameSettings.seasonal_amplitude = value
	_persist()


func _on_record_disturbances_toggled(pressed: bool) -> void:
	GameSettings.record_disturbances = pressed
	_persist()


# ============================ 小工具 ============================

## 落盘 + 广播。见文件头「落盘」的说明。
## 模式 / 风季两项不在这里 —— 它们存在 Game 里，本来就不写 settings.cfg。
func _persist() -> void:
	GameSettings.commit()
	settings_changed.emit()


## 把控件设成可用 / 不可用。按基类分派，别逐类写死属性名。
##
## BaseButton 自带的 disabled 视觉已经够明显，不再额外压暗；
## SpinBox / LineEdit 禁用后外观几乎没变化，才需要手动调透明度。
static func _set_editable(control: Control, on: bool) -> void:
	if control == null:
		return
	if control is BaseButton:
		(control as BaseButton).disabled = not on
	elif control is SpinBox:
		var spin := control as SpinBox
		spin.editable = on
		# ⚠ 只设 editable 挡不住上 / 下箭头按钮（它们不走 LineEdit 的 editable），
		#   所以锁死时连鼠标事件一起吞掉，才是真的锁住。
		spin.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
		spin.modulate = Color(1, 1, 1, 1) if on else Color(1, 1, 1, 0.6)
	elif control is LineEdit:
		(control as LineEdit).editable = on
		control.modulate = Color(1, 1, 1, 1) if on else Color(1, 1, 1, 0.6)


func _dim_label(label: Label, dimmed: bool) -> void:
	if label == null:
		return
	label.modulate = Color(1, 1, 1, 0.45) if dimmed else Color(1, 1, 1, 1)
