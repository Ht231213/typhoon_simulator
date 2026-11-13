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

@onready var title_label: Label = %StatusTitle
## 台风信息固定框里的文字（原来叫 StatusBody）
@onready var info_label: Label = %InfoLabel
@onready var notice_label: Label = %NoticeLabel

@onready var add_button: Button = %AddButton
@onready var pause_button: Button = %PauseButton
@onready var stop_button: Button = %StopButton
@onready var date_button: Button = %DateButton
@onready var clear_points_button: Button = %ClearPointsButton
@onready var undo_point_button: Button = %UndoPointButton
@onready var cancel_button: Button = %CancelButton
## 「撤销 / 清空路径点」所在的行。这行始终保留固定高度，避免按钮显隐时侧栏跳动。
@onready var path_buttons_row: HBoxContainer = %PlacementRow
## 「取消」所在的行，同样预留高度
@onready var cancel_row: HBoxContainer = %CancelRow
## 台风信息固定框（固定高度，避免出现/消失时侧栏跳动）
@onready var info_box: PanelContainer = %InfoBox

const PATH_ROW_HEIGHT := 36.0
const CANCEL_ROW_HEIGHT := 36.0

## 日期弹窗（1.3.0：换成场景内的自定义面板，见 scripts/ui/date_panel.gd）
## 旧版用的是 AcceptDialog（独立系统窗口，主题改不动、也没有动画）。
var _date_panel: Control = null
## 侧栏背景（自绘，用来做「先飞入」）
var _bg: SkewPanel = null
## 进场动画只允许播一次（否则会看到「菜单出现两次」）
var _enter_played := false

func _ready() -> void:
	# 侧栏要在「暂停模拟」和「ESC 全暂停」两种情况下都能操作
	process_mode = Node.PROCESS_MODE_ALWAYS

	_apply_style()

	add_button.pressed.connect(_on_add_pressed)
	pause_button.pressed.connect(_on_pause_pressed)
	stop_button.pressed.connect(_on_stop_pressed)
	date_button.pressed.connect(_on_date_pressed)
	clear_points_button.pressed.connect(_on_clear_points_pressed)
	undo_point_button.pressed.connect(_on_undo_point_pressed)
	cancel_button.pressed.connect(_on_cancel_pressed)

	# 日期弹窗是场景内节点（GameRoot/DatePanel），等它 _ready 注册进 group 之后再连信号
	_bind_date_panel.call_deferred()

	sim.state_changed.connect(refresh)
	sim.storm_finished.connect(_on_storm_finished)
	sim.notice.connect(_on_notice)
	# 时钟每帧都发一次，保证台风信息和日期连续刷新，而不是一天跳一次
	SimClock.clock_ticked.connect(_on_clock_ticked)

	path_editor.waypoints_changed.connect(_on_waypoints_changed)
	path_editor.placement_changed.connect(_on_placement_changed)

	refresh()
	# ⚠ 进场动画只由 game_intro.gd 触发，这里绝不能再自动播一次 ——
	#   两边的调用会各播一遍，玩家看到的就是「右边菜单出现两次」。
	#   （没有 game_intro 的场景里侧栏就是直接可见，不再做兜底。）


# ============================ 1.3.0 皮肤 ============================
# ⚠ 只动外观与透明度/缩放动画：不改 Sidebar 的 custom_minimum_size、不改 SideRows 的布局参数，
#   所以地图区域（HBoxContainer 里 size_flags_horizontal=3 的 MapArea）尺寸和形状完全不变。

func _apply_style() -> void:
	# 面板背景改由 _bg 这个自绘节点负责（好做「飞入」动画），stylebox 留空
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	# 台风信息框：半透明白卡
	var info := StyleBoxFlat.new()
	info.bg_color = Color(1, 1, 1, 0.045)
	info.border_color = Color(1, 1, 1, 0.12)
	info.set_border_width_all(1)
	info.set_corner_radius_all(8)
	info.set_content_margin_all(10)
	info_box.add_theme_stylebox_override("panel", info)

	title_label.add_theme_color_override("font_color", Color(0.55, 0.88, 1.0, 1.0))
	title_label.add_theme_font_size_override("font_size", 21)
	info_label.add_theme_color_override("font_color", Color(0.93, 0.96, 0.99, 0.88))
	notice_label.add_theme_color_override("font_color", Color(0.72, 0.80, 0.87, 0.62))


# ---------------------------- 进场动画 ----------------------------
# 用户要的顺序：**面板背景先飞入 → 然后文字和按钮在同一个队列里从上往下依次出现**。
# 位移不能用（容器会覆盖 position），所以统一用 alpha + scale（不影响布局）。

## 面板背景：从右侧往左展开（scale.x 0.94 → 1），拖一条冰蓝左边缘
func _build_background() -> void:
	_bg = SkewPanel.new()
	_bg.name = "Backdrop"
	_bg.slant = 0.0                     # 侧栏是矩形，不要斜切
	_bg.corner_radius = 0.0
	_bg.edge_width = 0.0
	_bg.accent_width = 3.0              # 左侧那条冰蓝线
	_bg.accent = Color(0.55, 0.88, 1.0, 0.70)
	_bg.fill = Color(0.031, 0.043, 0.059, 0.96)
	add_child(_bg)
	move_child(_bg, 0)


## delay 之后：背景飞入 → 标题 / 信息卡 / 各按钮 / 提示文字依次出现（同一个等待队列）
## ⚠ 只生效一次：任何重复调用都会把 alpha 归零重播，表现为「菜单出现两次」。
func play_enter(delay: float = 0.0) -> void:
	if _enter_played:
		print("[sidebar] play_enter 重复调用，已忽略（避免播两次）")
		return
	_enter_played = true
	print("[sidebar] play_enter 首次调用 delay=", delay)
	await get_tree().process_frame           # 等容器把尺寸算出来，pivot 才有意义
	if _bg == null:
		_build_background()
	_bg.pivot_offset = Vector2(_bg.size.x, _bg.size.y * 0.5)
	_bg.scale = Vector2(0.94, 1.0)
	_bg.modulate.a = 0.0
	UiKit.tween_float(self, _bg, "modulate:a", 1.0, 0.26, &"out_cubic", delay)
	UiKit.tween_vec2(self, _bg, "scale", Vector2.ONE, 0.42, &"out_cubic", delay)

	# 同一个队列：标题 → 信息卡 → 按钮 → 提示（隐藏的项也排队，免得之后突然冒出来）
	var queue: Array[Control] = [title_label, info_box, add_button, path_buttons_row,
		cancel_row, pause_button, stop_button, date_button, notice_label]
	var t := delay + 0.16
	for c in queue:
		if c == null:
			continue
		c.pivot_offset = c.size * 0.5
		c.modulate.a = 0.0
		c.scale = Vector2(0.97, 0.97)
		UiKit.tween_float(self, c, "modulate:a", 1.0, 0.24, &"out_quad", t)
		UiKit.tween_vec2(self, c, "scale", Vector2.ONE, 0.32, &"out_cubic", t)
		t += 0.055


## 兜底：如果 1 秒内没人调 play_enter（没有 game_intro 的场景），自己播一次
## ⚠ 当前 _ready 不再调用它 —— 留着是为了单独调试侧栏时手动触发。
func _enter_fallback() -> void:
	await get_tree().create_timer(1.0).timeout
	if not _enter_played and is_inside_tree():
		play_enter(0.0)


## 立即把内容归零（进场前用，避免闪一下）
func _prepare_hidden() -> void:
	for c in [title_label, info_box, add_button, path_buttons_row, cancel_row,
			pause_button, stop_button, date_button, notice_label]:
		if c != null:
			c.modulate.a = 0.0


## 每帧只刷新文字，不重建按钮状态（避免每帧做布局计算）
func _on_clock_ticked() -> void:
	title_label.text = sim.status_title()
	info_label.text = "\n".join(sim.status_lines())


# ============================ 刷新 ============================

func refresh() -> void:
	title_label.text = sim.status_title()
	info_label.text = "\n".join(sim.status_lines())
	_refresh_button_visibility()


func _refresh_button_visibility() -> void:
	var manual := not sim.auto_mode
	var over := sim.season_over
	var cooling := sim.on_deploy_cooldown()
	var can := sim.can_deploy_now()
	var has_points: bool = path_editor.waypoint_count() > 0
	var placing: bool = path_editor.in_placement

	# ── 投放环节：进入后除「投放台风」「撤销路径点」「清空路径点」「取消」外全部隐藏 ──
	if placing:
		add_button.visible = true
		add_button.text = "★ 投放台风"
		undo_point_button.visible = has_points
		clear_points_button.visible = has_points
		cancel_button.visible = true
		pause_button.visible = false
		stop_button.visible = false
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
		# 停止模拟：仅手动 + 非风季 + 有活跃台风
		# （风季限制操作性功能，「停止模拟」会让玩家规避冷却）
		stop_button.visible = manual and not sim.season_mode and sim.active_storm != null
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
	elif cooling:
		add_button.text = "冷却中…"
	elif sim.active_storm != null:
		add_button.text = "模拟中…"
	else:
		add_button.text = "＋ 添加台风"

	# 暂停按钮自己表述两种状态：没暂停时点它=暂停，已暂停时点它=继续
	pause_button.disabled = over
	pause_button.text = "▶ 继续模拟" if sim.paused else "暂停模拟"
	date_button.disabled = over or sim.season_mode


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


func _on_stop_pressed() -> void:
	sim.stop_simulation()
	refresh()


func _on_date_pressed() -> void:
	if _date_panel == null:
		_bind_date_panel()
	if _date_panel != null:
		_date_panel.call("open", SimClock.month, SimClock.day)


## 日期弹窗确认：写回日期并刷新面板（逻辑与旧 AcceptDialog 版本完全一致）
func _on_date_committed(month: int, day: int) -> void:
	sim.set_date(month, day)
	refresh()


func _bind_date_panel() -> void:
	_date_panel = get_tree().get_first_node_in_group("date_panel")
	if _date_panel != null and not _date_panel.is_connected("confirmed", _on_date_committed):
		_date_panel.connect("confirmed", _on_date_committed)

