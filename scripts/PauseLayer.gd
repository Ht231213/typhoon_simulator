extends CanvasLayer
## ESC 暂停菜单：**整个游戏暂停**（get_tree().paused = true）。
##
## 与侧边栏「暂停模拟」的区别：
##   · 「暂停模拟」：只停模拟（台风、日期），界面仍可操作
##   · 本菜单（ESC）：整个游戏冻结，用来让玩家离开一下
##
## 关键设置：
##   · 本节点 process_mode = ALWAYS，保证「没暂停时也能收到 ESC」
##     （原工程的 esc_handel.gd 设成了 WHEN_PAUSED，结果自己永远收不到触发自己的按键）
##   · 里面的按钮和遮罩也都设成 ALWAYS，否则 paused = true 之后点不动
##
## 2026-11-22 需求：
##   · 左列加「导出图片」（位置：设置下面、返回主菜单上面）
##   · 导出只含**已结束台风**的路径；没有已结束台风时按钮禁用
##   · 点导出后**保持菜单打开**，结果显示在底部 Hint：「已导出：<路径>」

@onready var root: Control = $Root
@onready var resume_button: Button = %ResumeButton
@onready var menu_button: Button = %MenuButton
@onready var settings_button: Button = %SettingsButton
@onready var export_button: Button = %ExportButton
@onready var storm_list: RichTextLabel = %StormList
@onready var list_title: Label = %ListTitle
@onready var hint_label: Label = %Hint

## 设置界面场景（打开时实例化，与主菜单共用同一份）
const SETTINGS_SCENE := "res://SettingsMenu.tscn"
## 导出图片（1.3 ④）：离屏渲染在 TrackExporter 里做
const TrackExporterClass := preload("res://scripts/TrackExporter.gd")
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
	if root.visible:
		resume()
	else:
		pause()
	get_viewport().set_input_as_handled()


func pause() -> void:
	_refresh_storm_list()
	_refresh_export_button()
	hint_label.visible = false
	hint_label.text = ""
	root.visible = true
	get_tree().paused = true


func resume() -> void:
	root.visible = false
	get_tree().paused = false


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


# ============================ 台风列表 ============================

## 本局台风列表：⑤A-1 多台风起分「进行中」和「已完成」两组。
## 点「停止模拟」的台风不进已完成列表（也不计入 ACE）。
## ⚠ 用 visible_records()：默认只列热带风暴级及以上，
##   打开「记录热带扰动和低压」后连 <30 kt 的扰动也一并列出。
func _refresh_storm_list() -> void:
	var vis := Game.visible_records()
	var g := _world_root()
	var sim: TyphoonSim = null
	if g != null:
		sim = g.get_node_or_null(SIM_PATH) as TyphoonSim
	var running: Array = sim.storms if sim != null else []
	var title := "本次台风列表（已完成 %d 场" % vis.size()
	if not running.is_empty():
		title += " · 进行中 %d 场" % running.size()
	title += "）    总 ACE %.2f" % Game.total_ace
	list_title.text = title

	var lines := PackedStringArray()
	if not running.is_empty():
		lines.append("[b]进行中（%d 场）[/b]" % running.size())
		for i in running.size():
			var s: Storm = running[i]
			lines.append("  %s %s  %3d kt  %4d hPa  %s" % [
				s.number_text(), s.name_label(),
				int(roundf(s.wind_kt)), int(roundf(s.central_pressure)),
				s.latlon_text()])
		lines.append("")
	if vis.is_empty():
		if running.is_empty():
			storm_list.text = "[i][color=#889]还没有台风。[/color][/i]"
		else:
			storm_list.text = "\n".join(lines)
		return
	lines.append("[b]已完成（%d 场）[/b]" % vis.size())
	for i in vis.size():
		lines.append(Game.format_record(vis[i]))
	storm_list.text = "\n".join(lines)


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
