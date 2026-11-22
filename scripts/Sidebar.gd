extends PanelContainer
## 右侧信息栏 + 底部按钮行。
##
## 2026-11-22 布局重构后：
##   · 侧栏（本节点）= 模拟状态 + 台风参数，**底部留空**（以后放新增按钮）
##   · 按钮行在 `View/ButtonBar`（不属于本节点），但节点都是 `unique_name_in_owner`，
##     跨树用 `%名字` 仍能解析，所以按钮逻辑继续集中在本脚本，避免再拆一个脚本。
##
## 按「手动/自动」×「风季/非风季」×「单台/多台」切换按钮状态，规则：
##
##   单台（默认） | 场上有 1 场台风时「添加台风」置灰（与 1.2.0 之前一致）
##   多台         | 同屏最多 6 场，6 场时置灰并显示「已达上限 6 场」
##   投放环节     | 只留 投放 / 撤销 / 清空 / 取消

@onready var sim: TyphoonSim = %TyphoonSim
@onready var path_editor: Control = %PathEditor

@onready var title_label: Label = %StatusTitle
## 「模拟状态」区的文字（日期 / 流速 / 状态 / 时长 / 场次 / ACE / 海温）
@onready var sim_status_label: Label = %SimStatusLabel
## 「台风参数」固定框里的文字（选中那场台风的详情）
@onready var info_label: Label = %InfoLabel
## 描述文字：放在按钮行最右侧（2026-11-22 从侧栏底部移过去）
@onready var notice_label: Label = %NoticeLabel

@onready var add_button: Button = %AddButton
@onready var pause_button: Button = %PauseButton
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

@onready var date_dialog: AcceptDialog = %DateDialog
@onready var month_spin: SpinBox = %MonthSpin
@onready var day_spin: SpinBox = %DaySpin


func _ready() -> void:
	# 侧栏/按钮行在「暂停模拟」和「ESC 全暂停」两种情况下都能操作
	process_mode = Node.PROCESS_MODE_ALWAYS

	add_button.pressed.connect(_on_add_pressed)
	pause_button.pressed.connect(_on_pause_pressed)
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
	# 时钟每帧都发一次，保证模拟状态和台风信息连续刷新，而不是一天跳一次
	SimClock.clock_ticked.connect(_on_clock_ticked)

	path_editor.waypoints_changed.connect(_on_waypoints_changed)
	path_editor.placement_changed.connect(_on_placement_changed)

	# 按钮行背景是接近白色（2026-11-22 用户要求）→ 按钮改成白底深灰字
	_style_button_bar()

	refresh()


## 按钮行 = 纯白/近白底 → 按钮文字必须换深色，否则看不见（用户 2026-11-22）。
## 只改颜色/底框，按钮的尺寸、位置、排列一律不动：
##   正常：透明底 + 深灰字；hover/pressed：淡灰底；禁用：浅灰字。
const BAR_FONT_COLOR := Color(0.10, 0.12, 0.16, 1.0)
const BAR_FONT_HOVER := Color(0.0, 0.0, 0.0, 1.0)
const BAR_FONT_DIM := Color(0.52, 0.55, 0.60, 0.9)


func _style_button_bar() -> void:
	var normal := _bar_style(Color(0, 0, 0, 0))
	var hover := _bar_style(Color(0, 0, 0, 0.07))
	var pressed := _bar_style(Color(0, 0, 0, 0.13))
	var disabled := _bar_style(Color(0, 0, 0, 0))
	var focus := _bar_style(Color(0, 0, 0, 0.04))
	var buttons := [add_button, pause_button, stop_button, stop_all_button, date_button,
		undo_point_button, clear_points_button, cancel_button]
	for b in buttons:
		if b == null:
			continue
		b.add_theme_color_override("font_color", BAR_FONT_COLOR)
		b.add_theme_color_override("font_hover_color", BAR_FONT_HOVER)
		b.add_theme_color_override("font_pressed_color", BAR_FONT_HOVER)
		b.add_theme_color_override("font_focus_color", BAR_FONT_COLOR)
		b.add_theme_color_override("font_disabled_color", BAR_FONT_DIM)
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("pressed", pressed)
		b.add_theme_stylebox_override("disabled", disabled)
		b.add_theme_stylebox_override("focus", focus)


## 白底上的按钮底框：左右留 10 px 内边距（保证文字不贴边），高度由按钮 min 决定
static func _bar_style(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 0.0
	sb.content_margin_bottom = 0.0
	sb.corner_radius_top_left = 5
	sb.corner_radius_top_right = 5
	sb.corner_radius_bottom_right = 5
	sb.corner_radius_bottom_left = 5
	return sb


## 每帧只刷新文字，不重建按钮状态（避免每帧做布局计算）
func _on_clock_ticked() -> void:
	_refresh_texts()


# ============================ 刷新 ============================

func refresh() -> void:
	_refresh_texts()
	_refresh_button_visibility()


func _refresh_texts() -> void:
	title_label.text = sim.status_title()
	sim_status_label.text = "\n".join(sim.status_state_lines())
	var storm_lines: PackedStringArray = sim.status_lines()
	info_label.text = "\n".join(storm_lines) if not storm_lines.is_empty() else "（暂无活跃台风）"
	_refresh_storm_select()


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
	var has_points: bool = path_editor.waypoint_count() > 0
	var placing: bool = path_editor.in_placement
	var active_count := sim.storms.size()
	var limit := Game.max_active_storms()

	# ── 投放环节：进入后除「投放台风」「撤销路径点」「清空路径点」「取消」外全部隐藏 ──
	if placing:
		add_button.visible = true
		add_button.text = "★ 投放台风"
		add_button.disabled = not has_points      # 没标点就不能投放
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

		# 添加台风按钮：文字 + 可用性（用户 2026-11-22 要求：
		#   单台模式照 1.2.0 之前 —— 场上有台风就置灰，不是点击后提示）
		if over:
			add_button.text = "风季已结束"
			add_button.disabled = true
		elif cooling:
			add_button.text = "冷却中…"
			add_button.disabled = true
		elif sim.paused:
			add_button.disabled = true
			add_button.text = "＋ 添加台风"
		elif not Game.multi_mode:
			# 单台模式：同屏只能有 1 场
			add_button.disabled = active_count >= 1
			add_button.text = "＋ 添加台风（单台）" if add_button.disabled else "＋ 添加台风"
		else:
			# 多台模式：同屏最多 Const.MAX_ACTIVE_STORMS 场
			add_button.disabled = active_count >= limit
			add_button.text = ("已达上限 %d 场" % limit) if add_button.disabled else "＋ 添加台风"

		# 按钮提示文字：说清楚现在是什么模式、最多几场
		add_button.tooltip_text = "进入投放环节。进入后在地图上左键标记路径点，再点本按钮投放台风。%s：同屏最多 %d 场。" % [
			"多台模式" if Game.multi_mode else "单台模式", limit]

	# 暂停按钮自己表述两种状态：没暂停时点它=暂停，已暂停时点它=继续
	pause_button.disabled = over
	pause_button.text = "▶ 继续模拟" if sim.paused else "暂停模拟"
	date_button.disabled = over or sim.season_mode

	# ⚠ 按钮图标只能用 Noto Sans SC 覆盖的符号（▶ ＋ ■ ★ …），不要用 emoji。


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
		# 兜底：按钮理论上已置灰，但防止其它入口（快捷键/测试脚本）绕过上限
		if sim.storms.size() >= Game.max_active_storms():
			_on_notice("单台模式只能有一场，切换多台模式请重新开始" if not Game.multi_mode \
				else "最多同时 %d 场台风，先停掉一场再投放" % Game.max_active_storms())
			return
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
