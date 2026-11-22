extends PanelContainer
## 右侧竖向控制栏。
##
## 按「手动/自动」×「风季/非风季」四种组合切换按钮组，规则来自你的规格：
##
##   手动 · 非风季 | 添加(继续)  暂停  停止  调整日期
##   自动 · 非风季 | 暂停  继续
##   手动 · 风季   | 添加(继续)  暂停  调整日期
##   自动 · 风季   | 暂停  继续

@onready var sim: TyphoonSim = %TyphoonSim
@onready var path_editor: Control = %PathEditor
@onready var path_layer: PathLayer = %PathLayer

## 导出图片（1.3 ④）：离屏渲染在 TrackExporter 里做
const TrackExporterClass := preload("res://scripts/TrackExporter.gd")

@onready var title_label: Label = %StatusTitle
## 台风信息固定框里的文字（原来叫 StatusBody）
@onready var info_label: Label = %InfoLabel
@onready var notice_label: Label = %NoticeLabel

@onready var add_button: Button = %AddButton
@onready var pause_button: Button = %PauseButton
@onready var export_button: Button = %ExportButton
@onready var stop_button: Button = %StopButton
@onready var stop_all_button: Button = %StopAllButton
@onready var date_button: Button = %DateButton
@onready var clear_points_button: Button = %ClearPointsButton
@onready var undo_point_button: Button = %UndoPointButton
@onready var cancel_button: Button = %CancelButton
## ⑤A-1 多台风：「选中台风」下拉（只在 >1 场时显示）
@onready var storm_select_row: HBoxContainer = %StormSelectRow
@onready var storm_select: OptionButton = %StormSelect
## 下拉列表的"签名"，只有台风数量/编号/名称变了才重建（避免每帧重建下拉框）
var _storm_select_sig := ""
## 「撤销 / 清空路径点」所在的行。这行始终保留固定高度，避免按钮显隐时侧栏跳动。
@onready var path_buttons_row: HBoxContainer = %PlacementRow
## 「取消」所在的行，同样预留高度
@onready var cancel_row: HBoxContainer = %CancelRow
## 台风信息固定框（固定高度，避免出现/消失时侧栏跳动）
@onready var info_box: PanelContainer = %InfoBox

const PATH_ROW_HEIGHT := 36.0
const CANCEL_ROW_HEIGHT := 36.0

@onready var date_dialog: AcceptDialog = %DateDialog
@onready var month_spin: SpinBox = %MonthSpin
@onready var day_spin: SpinBox = %DaySpin


func _ready() -> void:
	# 侧栏要在「暂停模拟」和「ESC 全暂停」两种情况下都能操作
	process_mode = Node.PROCESS_MODE_ALWAYS

	add_button.pressed.connect(_on_add_pressed)
	pause_button.pressed.connect(_on_pause_pressed)
	export_button.pressed.connect(_on_export_pressed)
	stop_button.pressed.connect(_on_stop_pressed)
	stop_all_button.pressed.connect(_on_stop_all_pressed)
	date_button.pressed.connect(_on_date_pressed)
	clear_points_button.pressed.connect(_on_clear_points_pressed)
	undo_point_button.pressed.connect(_on_undo_point_pressed)
	cancel_button.pressed.connect(_on_cancel_pressed)
	storm_select.item_selected.connect(_on_storm_selected)

	date_dialog.confirmed.connect(_on_date_confirmed)

	sim.state_changed.connect(refresh)
	sim.storm_finished.connect(_on_storm_finished)
	sim.notice.connect(_on_notice)
	# 时钟每帧都发一次，保证台风信息和日期连续刷新，而不是一天跳一次
	SimClock.clock_ticked.connect(_on_clock_ticked)

	path_editor.waypoints_changed.connect(_on_waypoints_changed)
	path_editor.placement_changed.connect(_on_placement_changed)

	refresh()


## 每帧只刷新文字，不重建按钮状态（避免每帧做布局计算）
func _on_clock_ticked() -> void:
	title_label.text = sim.status_title()
	info_label.text = "\n".join(sim.status_lines())
	_refresh_storm_select()


# ============================ 刷新 ============================

func refresh() -> void:
	title_label.text = sim.status_title()
	info_label.text = "\n".join(sim.status_lines())
	_refresh_storm_select()
	_refresh_button_visibility()


## ⑤A-1 多台风：「选中台风」下拉（只在 >1 场时显示）。
## 台风命名后编号/名称会变，所以用签名判断是否要重建列表（每帧调用也便宜）。
func _refresh_storm_select() -> void:
	var sig := ""
	for s in sim.storms:
		sig += "%s|%s|%d;" % [s.number_text(), s.name_label(), s.get_instance_id()]
	var focus := sim.focus_storm()
	var idx := sim.storms.find(focus)
	if sig != _storm_select_sig:
		_storm_select_sig = sig
		storm_select.clear()
		for s in sim.storms:
			storm_select.add_item("%s %s" % [s.number_text(), s.name_label()])
	if idx >= 0 and storm_select.item_count > idx and storm_select.selected != idx:
		storm_select.select(idx)
	storm_select_row.visible = sim.storms.size() > 1


func _refresh_button_visibility() -> void:
	var manual := not sim.auto_mode
	var over := sim.season_over
	var cooling := sim.on_deploy_cooldown()
	var can := sim.can_deploy_now()
	var has_points: bool = path_editor.waypoint_count() > 0
	var placing: bool = path_editor.in_placement
	var active_count := sim.storms.size()

	# ── 投放环节：进入后除「投放台风」「撤销路径点」「清空路径点」「取消」外全部隐藏 ──
	if placing:
		add_button.visible = true
		add_button.text = "★ 投放台风"
		undo_point_button.visible = has_points
		clear_points_button.visible = has_points
		cancel_button.visible = true
		pause_button.visible = false
		stop_button.visible = false
		stop_all_button.visible = false
		date_button.visible = false
	else:
		# ── 普通状态 ──
		# 添加台风：仅手动模式（含风季）与未来的电影模式
		add_button.visible = manual
		undo_point_button.visible = false
		clear_points_button.visible = false
		cancel_button.visible = false
		# 暂停时间轴：所有模式都出现
		pause_button.visible = not over
		# 停止模拟：仅手动 + 非风季 + 有活跃台风（⑤A-1：停"选中的那一场"）
		# （风季限制操作性功能，「停止模拟」会让玩家规避冷却）
		stop_button.visible = manual and not sim.season_mode and active_count > 0
		# 全部停止：多台时才出现（⑤A-1 新增）
		stop_all_button.visible = manual and not sim.season_mode and active_count > 1
		# 调整日期：仅手动 + 非风季（风季下算作弊）
		date_button.visible = manual and not sim.season_mode
		# 单位切换按钮已删除（1.2.0）：设置 → 模拟设置 → 单位设置 里已经有了

	# 两行始终保留高度，避免按钮显隐时侧栏跳动
	path_buttons_row.custom_minimum_size.y = PATH_ROW_HEIGHT
	cancel_row.custom_minimum_size.y = CANCEL_ROW_HEIGHT

	# ⚠ 按钮图标只能用 Noto Sans SC 覆盖的符号（▶ ＋ ■ ★ …）。
	#   原来那 4 个 emoji 图标（U+23F3 / U+1F300 / U+23F8 / U+1F4C5）字体里没有字形，
	#   Windows 版靠系统字体兜底而正常，**网页版没有系统字体 → 会显示成方框**
	#   （2026-10-24 BUG-2 收尾时去掉，只留文字）。
	add_button.disabled = (not can and not placing) or (sim.paused and not placing)
	if placing:
		add_button.disabled = not has_points          # 没标点就不能投放
	elif over:
		add_button.text = "风季已结束"
	elif cooling:
		add_button.text = "冷却中…"
	elif active_count >= Const.MAX_ACTIVE_STORMS:
		add_button.text = "已达上限 %d 场" % Const.MAX_ACTIVE_STORMS
		add_button.disabled = true
	else:
		add_button.text = "＋ 添加台风"

	# 暂停按钮自己表述两种状态：没暂停时点它=暂停，已暂停时点它=继续
	pause_button.disabled = over
	pause_button.text = "▶ 继续模拟" if sim.paused else "暂停模拟"
	date_button.disabled = over or sim.season_mode

	# 「导出图片」（1.3 ④）：**随时暂停随时导出**——有历史归档，或当前已跑出的轨迹
	# （⑤A-1 多台后，当前轨迹在各自的视图里，所以用 has_visible_tracks() 统一判断）。
	# ⚠ 位置在「暂停模拟」按钮下面；ESC 暂停菜单不加。
	# ⚠ 变量名是 path_layer（见文件头 @onready），不是 path。
	export_button.visible = (not placing) and sim.paused and not over \
		and path_layer != null and path_layer.has_visible_tracks()


func _on_storm_finished(_rec: Game.StormRecord) -> void:
	refresh()


func _on_notice(text: String) -> void:
	notice_label.text = text


func _on_waypoints_changed(_count: int) -> void:
	_refresh_button_visibility()


# ============================ 按钮 ============================

## 「添加台风 / 投放台风」是同一个按钮的两段行为：
##   不在投放环节 → 进入投放环节（此时才能在地图上标路径点）
##   已在投放环节 → 把标记好的路径点交给引擎，投放台风，并退出环节
func _on_add_pressed() -> void:
	if sim.auto_mode:
		sim.deploy_auto_storm()
		refresh()
		return

	if not path_editor.in_placement:
		path_editor.begin_placement()
		_on_notice("投放环节：在地图上左键标记路径点，标完点「投放台风」")
		refresh()
		return

	# 已在投放环节：至少要有 2 个点才能构成一条路径
	if path_editor.waypoint_count() < 2:
		_on_notice("至少需要 2 个路径点才能投放")
		return
	if sim.deploy_manual_storm(path_editor.take_waypoints()):
		# 退出投放环节并清掉路径点——投放后台风自己会画轨迹，
		# 待投放的路径点连线要收起来，等下次进入投放环节再显示。
		path_editor.end_placement(false)
	refresh()


## 「取消」：退出投放环节，并清掉已标记的路径点
func _on_cancel_pressed() -> void:
	path_editor.end_placement(false)
	_on_notice("已退出投放环节")
	refresh()


func _on_placement_changed(_in_placement: bool) -> void:
	refresh()


func _on_clear_points_pressed() -> void:
	path_editor.clear()
	refresh()


## 撤销最后一个路径点
func _on_undo_point_pressed() -> void:
	path_editor.undo_waypoint()
	refresh()


## 「暂停时间轴」按钮：没暂停时点它=暂停；已暂停时点它=继续。
## 两种情况都走 toggle，不要再加 `if not sim.paused` 之类的判断——
## 之前那个判断让「已暂停」状态下按钮被禁用，永远解不开。
func _on_pause_pressed() -> void:
	sim.toggle_pause()
	refresh()


## 「导出图片」：把底图 + 本局保留的全部路径合并成一张 PNG（1.3 ④）。
## 生成是异步的（要等离屏视口渲染一两帧），期间按钮临时禁用。
func _on_export_pressed() -> void:
	if export_button.disabled:
		return
	export_button.disabled = true
	export_button.text = "导出中…"
	var exporter: RefCounted = TrackExporterClass.new()
	var msg: String = await exporter.export_png(self, path_layer)
	export_button.disabled = false
	export_button.text = "导出图片"
	_on_notice("导出失败：本局还没有可导出的路径" if msg == "" else msg)


func _on_stop_pressed() -> void:
	sim.stop_simulation()
	refresh()


## ⑤A-1「全部停止」：把所有活跃台风都按「停止模拟」处理
func _on_stop_all_pressed() -> void:
	sim.stop_all_storms()
	refresh()


## ⑤A-1「选中台风」下拉切换：只换"选中"，不影响模拟
func _on_storm_selected(index: int) -> void:
	sim.select_storm_index(index)
	refresh()


func _on_date_pressed() -> void:
	month_spin.value = SimClock.month
	day_spin.value = SimClock.day
	date_dialog.popup_centered()


func _on_date_confirmed() -> void:
	sim.set_date(int(month_spin.value), int(day_spin.value))
	refresh()

