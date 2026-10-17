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
## 默认导出目录的文件夹名，放在「游戏根」下（导出后就是 exe 旁边）
const BEST_TRACK_DIR_NAME := "BestTrack"
## 行内字号。`.tscn` 里已经写了一遍，这里只用来补 SpinBox：
## ⚠ SpinBox 的数字是它**内部自己创建的 LineEdit** 画的，场景里的
##   `theme_override_font_sizes` 管不到，只能在代码里给那个 LineEdit 补一次，
##   否则两个数字框的字会比同一行的标签小一圈。
const ROW_FONT_SIZE := 19

@onready var header: Button = %Header
@onready var content: VBoxContainer = %Content

@onready var mode_option: OptionButton = %ModeOption
@onready var season_check: CheckBox = %SeasonCheck
@onready var unit_option: OptionButton = %UnitOption
@onready var mean_sst_spin: SpinBox = %MeanSstSpin
@onready var seasonal_amp_spin: SpinBox = %SeasonalAmpSpin
@onready var record_disturbances_check: CheckBox = %RecordDisturbancesCheck
@onready var best_track_check: CheckBox = %BestTrackCheck
@onready var best_track_dir_edit: LineEdit = %BestTrackDirEdit
@onready var best_track_browse_button: Button = %BestTrackBrowseButton
@onready var dir_dialog: FileDialog = %DirDialog

# 跟着权限一起压暗的标签（锁住的项如果只有控件变灰、标签还亮着，看起来像坏了）
@onready var mode_label: Label = %ModeLabel
@onready var unit_label: Label = %UnitLabel
@onready var mean_sst_label: Label = %MeanSstLabel
@onready var seasonal_amp_label: Label = %SeasonalAmpLabel
@onready var best_track_dir_label: Label = %BestTrackDirLabel

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
	_setup_unit_options()
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
func setup(p_in_game: bool, p_season: bool) -> void:
	_in_game = p_in_game
	_season = p_season
	if not _ready_done:
		return
	refresh_from_store()
	set_context(_in_game, _season)


## 只改权限，不重读值。切换上下文（比如暂停菜单里又进了风季）时用。
## 权限规则只在这个函数里，改规则改这里就够：
##
##   ┌──────────────────┬──────────────────────────────────────────────┐
##   │ 进游戏前          │ 全部可改                                      │
##   │ 进游戏后·非风季   │ 模式 / 风季 → 禁用（模拟已经开跑，改了也没用）；  │
##   │                  │ 单位 / 海温 / 季节增幅 / 记录扰动 / 最佳路径可改  │
##   │ 进游戏后·风季     │ 只有「单位」可改；最佳路径**强制开启且不可关**    │
##   └──────────────────┴──────────────────────────────────────────────┘
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
	_set_editable(unit_option, true)
	_dim_label(unit_label, false)

	# ③ 风季模式里除了单位以外全部锁死；非风季的进游戏后则都还能改。
	var others_editable := not (p_in_game and p_season)
	_set_editable(mean_sst_spin, others_editable)
	_dim_label(mean_sst_label, not others_editable)
	_set_editable(seasonal_amp_spin, others_editable)
	_dim_label(seasonal_amp_label, not others_editable)
	_set_editable(record_disturbances_check, others_editable)

	# ④ 最佳路径：风季模式「必须记录」，所以直接设成勾上再锁住，不给玩家关掉的机会。
	#    ⚠ 这里**故意不写 GameSettings.best_track_enabled** —— 风季必须记录是规则，
	#      不是玩家的设置，写进存档会让玩家回到主菜单后看到它莫名其妙亮着。
	#      `TyphoonSim._sync_best_track_state()` 里也是这么算的
	#      （`recording = season_mode or GameSettings.best_track_enabled`）。
	#      离开风季上下文时还原成存储里的真实值，别在界面上留下假状态。
	if p_in_game and p_season:
		best_track_check.set_pressed_no_signal(true)
	else:
		best_track_check.set_pressed_no_signal(GameSettings.best_track_enabled)
	_set_editable(best_track_check, others_editable)
	_update_dir_row()


## 从存储重新读值到控件。不写回、不发 settings_changed。
func refresh_from_store() -> void:
	if not _ready_done:
		return

	# 模式：值就是 Game.Mode 枚举，item id 也用的同一个枚举，能直接还原
	var mode_index := mode_option.get_item_index(int(Game.mode))
	mode_option.select(mode_index if mode_index >= 0 else 0)
	season_check.set_pressed_no_signal(Game.season_mode)

	var unit_count := TyphoonSim.WIND_UNITS.size()
	unit_option.select(clampi(int(GameSettings.wind_unit_index), 0, unit_count - 1))

	mean_sst_spin.set_value_no_signal(GameSettings.mean_sst)
	seasonal_amp_spin.set_value_no_signal(GameSettings.seasonal_amplitude)

	record_disturbances_check.set_pressed_no_signal(GameSettings.record_disturbances)
	best_track_check.set_pressed_no_signal(GameSettings.best_track_enabled)

	# 存储里是空字符串 = 还没选过，直接显示默认目录（<游戏根>/BestTrack），
	# 但**不**把默认值写进存储，免得用户没动过它也留下一条记录。
	var dir: String = GameSettings.best_track_dir
	best_track_dir_edit.text = dir if dir != "" else default_best_track_dir()
	_update_dir_row()


## 默认导出目录 = <游戏根>/BestTrack。
## ⚠ 「游戏根」在两种运行方式下不是同一个地方：
##   · 编辑器 / 直接跑工程：`res://` 就是工程根，可写
##   · 导出成 exe：`res://` 在 PCK 里**只读**，必须写到 exe 所在目录
##   `OS.has_feature("template")` 就是「我正在导出模板里跑」。
func default_best_track_dir() -> String:
	var base := ""
	if OS.has_feature("template"):
		base = OS.get_executable_path().get_base_dir()
	else:
		base = ProjectSettings.globalize_path("res://")
	return base.path_join(BEST_TRACK_DIR_NAME)


## 当前上下文是否「强制记录最佳路径」（= 进游戏后 + 风季）。
func is_best_track_forced() -> bool:
	return _in_game and _season


## 实际要不要记录最佳路径：玩家勾了 **或** 风季模式强制记录。
## Lead 的记录逻辑请用这个，而不是直接读 GameSettings.best_track_enabled
## （否则风季模式里会被「勾选框亮着但存储是 false」坑到）。
func effective_best_track_enabled() -> bool:
	return GameSettings.best_track_enabled or is_best_track_forced()


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
func _setup_unit_options() -> void:
	unit_option.clear()
	for unit in TyphoonSim.WIND_UNITS:
		unit_option.add_item(unit)


## SpinBox 的字号要单独补，见 ROW_FONT_SIZE 的注释。
func _apply_spin_fonts() -> void:
	for spin in [mean_sst_spin, seasonal_amp_spin]:
		(spin as SpinBox).get_line_edit().add_theme_font_size_override(
			"font_size", ROW_FONT_SIZE)


func _connect_signals() -> void:
	header.pressed.connect(_on_header_pressed)
	mode_option.item_selected.connect(_on_mode_selected)
	season_check.toggled.connect(_on_season_toggled)
	unit_option.item_selected.connect(_on_unit_selected)
	mean_sst_spin.value_changed.connect(_on_mean_sst_changed)
	seasonal_amp_spin.value_changed.connect(_on_seasonal_amp_changed)
	record_disturbances_check.toggled.connect(_on_record_disturbances_toggled)
	best_track_check.toggled.connect(_on_best_track_toggled)
	best_track_dir_edit.text_submitted.connect(_on_dir_submitted)
	best_track_dir_edit.focus_exited.connect(_commit_best_track_dir)
	best_track_browse_button.pressed.connect(_on_browse_pressed)
	dir_dialog.dir_selected.connect(_on_dir_selected)


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


func _on_unit_selected(index: int) -> void:
	GameSettings.wind_unit_index = index
	_persist()


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


func _on_best_track_toggled(pressed: bool) -> void:
	GameSettings.best_track_enabled = pressed
	_update_dir_row()
	_persist()


## 导出路径：用「回车 / 失去焦点」提交，而不是每敲一个字就写一次存储
## （Web 上每次写盘都是 IndexedDB 操作，见 PROGRESS 的 W1）。
func _on_dir_submitted(_text: String) -> void:
	_commit_best_track_dir()


func _commit_best_track_dir() -> void:
	var dir := best_track_dir_edit.text.strip_edges()
	if dir == "":
		# 清空 = 用回默认目录（存空字符串没意义，读的人还得再猜一次默认值）
		dir = default_best_track_dir()
		best_track_dir_edit.text = dir
		best_track_dir_edit.caret_column = dir.length()
	if dir == GameSettings.best_track_dir:
		return
	GameSettings.best_track_dir = dir
	_persist()


func _on_browse_pressed() -> void:
	var start := best_track_dir_edit.text.strip_edges()
	if start == "":
		start = default_best_track_dir()
	dir_dialog.current_dir = start
	dir_dialog.popup_centered_ratio(0.62)


func _on_dir_selected(dir: String) -> void:
	best_track_dir_edit.text = dir
	_commit_best_track_dir()


# ============================ 小工具 ============================

## 落盘 + 广播。见文件头「落盘」的说明。
## 模式 / 风季两项不在这里 —— 它们存在 Game 里，本来就不写 user://settings.cfg。
func _persist() -> void:
	GameSettings.commit()
	settings_changed.emit()


## 导出路径只有在「勾了最佳路径」且「当前上下文允许改最佳路径」时才可用。
func _update_dir_row() -> void:
	var can_edit := not (_in_game and _season)
	var on := can_edit and best_track_check.button_pressed
	_set_editable(best_track_dir_edit, on)
	_set_editable(best_track_browse_button, on)
	_dim_label(best_track_dir_label, not on)


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
