extends CanvasLayer
## ESC 暂停菜单：**整个游戏暂停**（get_tree().paused = true）。
##
## 与侧边栏「暂停模拟」的区别：
##   · 「暂停模拟」：只停模拟（台风、日期），界面仍可操作
##   · 本菜单（ESC）：整个游戏冻结，用来让玩家离开一下
##
## 关键设置：
##   · 本节点 process_mode = ALWAYS，保证「没暂停时也能收到 ESC」
##   · 里面的按钮和遮罩也都设成 ALWAYS，否则 paused = true 之后点不动
##
## 2026-11-22 改版：
##   · 右列从 RichText 列表改成**表格**（和 ACE 存档同款 AceTable）：
##       「进行中」小表（6 列）+ 「已完成」表格（8 列，模式在标题里）
##   · 左列保留：回到游戏 / 设置 / 导出图片 / 返回主菜单
##   · ESC：若 DebugPanel（F6）开着，先让它处理（本菜单不抢）；否则开/关本菜单。

@onready var root: Control = $Root
@onready var resume_button: Button = %ResumeButton
@onready var menu_button: Button = %MenuButton
@onready var settings_button: Button = %SettingsButton
@onready var export_button: Button = %ExportButton
@onready var list_title: Label = %ListTitle
@onready var run_title: Label = %RunTitle
@onready var run_header: VBoxContainer = %RunHeaderHost
@onready var run_rows: VBoxContainer = %RunRows
@onready var done_title: Label = %DoneTitle
@onready var done_header: VBoxContainer = %DoneHeaderHost
@onready var done_rows: VBoxContainer = %DoneRows
@onready var hint_label: Label = %Hint

## 设置界面场景（打开时实例化，与主菜单共用同一份）
const SETTINGS_SCENE := "res://SettingsMenu.tscn"
## 导出图片（1.3 ④）：离屏渲染在 TrackExporter 里做
const TrackExporterClass := preload("res://scripts/TrackExporter.gd")
## 表格构建器（ACE 存档 / 结算界面共用）
const AceTableClass := preload("res://scripts/AceTable.gd")
## GameRoot 内的节点路径（2026-11-22 布局重构后：View/TopRow/...）
const PATH_LAYER_PATH := "View/TopRow/MapArea/MapLayer/PathLayer"
const SIM_PATH := "View/TopRow/MapArea/MapLayer/TyphoonSim"
var _settings: Control = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	root.visible = false
	resume_button.pressed.connect(resume)
	menu_button.pressed.connect(_on_menu_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	export_button.pressed.connect(_on_export_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	# 设置界面开着时，ESC 交给设置界面自己处理
	if _settings != null and _settings.visible:
		return
	# F6 调试面板开着时，ESC 交给它关（DebugPanel 自己会吞掉事件）
	var dbg := _game_node("DebugPanel")
	if dbg != null and dbg is CanvasLayer and (dbg as CanvasLayer).visible:
		return
	if root.visible:
		resume()
	else:
		pause()
	get_viewport().set_input_as_handled()


func pause() -> void:
	_refresh_tables()
	_refresh_export_button()
	hint_label.visible = false
	hint_label.text = ""
	root.visible = true
	get_tree().paused = true


func resume() -> void:
	root.visible = false
	get_tree().paused = false


func _game_node(path: String) -> Node:
	var g := get_parent()
	if g == null:
		return null
	return g.get_node_or_null(path)


# ============================ 本局表格（2026-11-22） ============================

func _refresh_tables() -> void:
	var g := get_parent()
	var sim: TyphoonSim = null
	if g != null:
		sim = g.get_node_or_null(SIM_PATH) as TyphoonSim
	var running: Array = sim.storms if sim != null else []
	var done: Array = Game.visible_records()

	list_title.text = "本局 · %s    总 ACE %.2f" % [Game.mode_label(), Game.total_ace]
	run_title.text = "进行中（%d 场）" % running.size()
	done_title.text = "已完成（%d 场）" % done.size()

	# 进行中：6 列小表
	_clear(run_header)
	_clear(run_rows)
	AceTableClass.build_header(run_header, AceTableClass.COLUMNS_RUNNING)
	var run_rows_data: Array[Dictionary] = []
	for s in running:
		var st: Storm = s
		run_rows_data.append({
			"number": st.number_text(),
			"name": st.name_label(),
			"peak": "%d kt" % int(roundf(st.wind_kt)),
			"pressure": "%d hPa" % int(roundf(st.central_pressure)),
			"center": st.latlon_text(),
			"ace": "%.2f" % st.ace,
		})
	if run_rows_data.is_empty():
		AceTableClass.build_empty(run_rows, "（没有进行中的台风）")
	else:
		AceTableClass.build_rows(run_rows, run_rows_data, AceTableClass.COLUMNS_RUNNING)

	# 已完成：8 列表格（模式在本局标题里，不再单列）
	_clear(done_header)
	_clear(done_rows)
	AceTableClass.build_header(done_header, AceTableClass.COLUMNS_PAUSE)
	var done_data: Array[Dictionary] = []
	for rec in done:
		var r: Game.StormRecord = rec
		done_data.append({
			"number": r.number_text,
			"name": r.storm_name,
			"cat": AceTableClass.category_text(r.reached_st, r.peak_wind_kt),
			"peak": "%d kt" % int(roundf(r.peak_wind_kt)),
			"pressure": "%d hPa" % int(roundf(r.min_pressure)),
			"ace": "%.2f" % r.ace,
			"duration": AceTableClass.duration_text(r.start_day, r.end_day),
			"end": AceTableClass.end_day_text(r.end_day),
		})
	if done_data.is_empty():
		AceTableClass.build_empty(done_rows, "（本局还没有已完成的台风）")
	else:
		AceTableClass.build_rows(done_rows, done_data, AceTableClass.COLUMNS_PAUSE)


func _clear(node: Node) -> void:
	for c in node.get_children():
		c.queue_free()


# ============================ 导出图片（1.3 ④） ============================

func _world_root() -> Node:
	return get_parent()


func _path_layer() -> PathLayer:
	var g := _world_root()
	if g == null:
		return null
	return g.get_node_or_null(PATH_LAYER_PATH) as PathLayer


## 没有「已结束台风」的归档路径时禁用（不是隐藏，别让人找不到）
func _refresh_export_button() -> void:
	var pl := _path_layer()
	var can: bool = pl != null and pl.has_archived_tracks()
	export_button.disabled = not can
	export_button.text = "导出图片"
	export_button.tooltip_text = ("把地图 + 本局已结束台风的路径合并导出成一张 PNG 图片" if can
		else "还没有已结束的台风（先让一场台风结束）")


## ESC 菜单里的「导出图片」：导出后**保持暂停菜单打开**，结果显示在底部 Hint。
func _on_export_pressed() -> void:
	if export_button.disabled:
		return
	var pl := _path_layer()
	if pl == null:
		hint_label.visible = true
		hint_label.text = "导出失败：路径层不存在"
		return
	export_button.disabled = true
	export_button.text = "导出中…"
	var exporter: RefCounted = TrackExporterClass.new()
	var msg: String = await exporter.export_png(self, pl)
	export_button.text = "导出图片"
	_refresh_export_button()
	hint_label.visible = true
	hint_label.text = msg if msg != "" else "导出失败：本局还没有已结束的台风"


# ============================ 按钮 ============================

func _on_menu_pressed() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://TitleScreen.tscn")


## 打开设置界面（独立场景，与主菜单共用同一份）
func _on_settings_pressed() -> void:
	if _settings == null:
		_settings = load(SETTINGS_SCENE).instantiate()
		add_child(_settings)
		# 关掉设置后不留任何样板提示（用户要求去掉这类文字）
		_settings.on_closed = func() -> void:
			hint_label.text = ""
	_settings.open()
