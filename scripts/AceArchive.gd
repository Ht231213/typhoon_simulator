extends Control
## 标题画面「ACE 存档」的大窗口（2026-11-22 需求 7；之后多次扩展）。
##
## 两级内容（**同一个大窗口内切换**，不叠窗口）：
##   一级：4 个标签页 = 存档分类（单台·手动 / 多台·手动 / 单台·自动 / 多台·自动）
##         每页 = **每次风季模拟（session）一行** 的场次表（7 列，按总 ACE 降序排名）
##         双击某行 → 进入二级
##   二级：该局（session）的**逐场台风明细**（8 列，按单场 ACE 降序）
##         ESC / 「返回上一级」→ 回一级；一级 ESC → 关闭整个窗口
##
## 数据源：`<游戏目录>/saves/ace_records.json`（`Game.history()` 读文件）。
## 关闭：底部按钮 / ESC。由标题画面运行时实例化（避免 BUG-1 锚点丢失）。

## 表格构建器（preload，避免新脚本未被编辑器扫描时 class_name 未注册）
const AceTableClass := preload("res://scripts/AceTable.gd")

## 标签页顺序（用户指定：单台·手动 / 多台·手动 / 单台·自动 / 多台·自动）
const CATEGORIES: Array[String] = ["单台-手动", "多台-手动", "单台-自动", "多台-自动"]
const TAB_LABELS: Array[String] = ["单台 · 手动", "多台 · 手动", "单台 · 自动", "多台 · 自动"]

@onready var heading_label: Label = %Heading
@onready var tab_bar: TabBar = %TabBar
@onready var summary_label: Label = %Summary
@onready var header_host: VBoxContainer = %TableHeaderHost
@onready var table_scroll: ScrollContainer = %TableScroll
@onready var rows_box: VBoxContainer = %RowsBox
@onready var hint_label: Label = %Hint
@onready var back_button: Button = %BackButton

## 关闭时的回调（由标题画面注入，用于把焦点还给按钮）
var on_closed: Callable = Callable()
## 上次选中的标签（本次会话内记住；默认第一个）
var _current_tab := 0
## 1 = 场次表；2 = 单局台风明细
var _level := 1
## 当前标签页的 session 列表（一级排序后的结果，双击时按行号取）
var _sessions: Array = []
## 二级当前选中的 session 字典
var _session: Dictionary = {}


func _ready() -> void:
	visible = false
	back_button.pressed.connect(_on_back_pressed)
	heading_label.text = "ACE 存档"
	# 外置 TabBar（和设置界面同款）：标题由代码填，避免手改 .tscn
	tab_bar.tab_count = TAB_LABELS.size()
	for i in TAB_LABELS.size():
		tab_bar.set_tab_title(i, TAB_LABELS[i])
	tab_bar.tab_changed.connect(_on_tab_changed)


func open() -> void:
	_level = 1
	if tab_bar.tab_count > 0:
		tab_bar.current_tab = clampi(_current_tab, 0, TAB_LABELS.size() - 1)
	_rebuild_level1()
	visible = true


func close() -> void:
	visible = false
	if on_closed.is_valid():
		on_closed.call()


## ESC：二级 → 回一级；一级 → 关窗
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _level == 2:
			_go_back_to_level1()
		else:
			close()


func _on_tab_changed(index: int) -> void:
	_current_tab = index
	# 切标签时若在二级，先回一级（避免串数据）
	_level = 1
	_rebuild_level1()


func _on_back_pressed() -> void:
	if _level == 2:
		_go_back_to_level1()
	else:
		close()


# ============================ 一级：场次表 ============================

func _rebuild_level1() -> void:
	_clear_table()
	_level = 1
	var cat := _category()
	_sessions = Game.history(cat)
	# 按总 ACE 降序；同 ACE 时场次日期新的在前
	_sessions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var aa := float(a.get("total_ace", 0.0))
		var bb := float(b.get("total_ace", 0.0))
		if not is_equal_approx(aa, bb):
			return aa > bb
		return int(a.get("saved_at", 0)) > int(b.get("saved_at", 0)))

	heading_label.text = "ACE 存档"
	tab_bar.visible = true
	back_button.text = "返回"
	AceTableClass.build_header(header_host, AceTableClass.COLUMNS_SESSION)
	var total_ace := 0.0
	var total_storms := 0
	var rows: Array[Dictionary] = []
	for i in _sessions.size():
		var e: Dictionary = _sessions[i]
		total_ace += float(e.get("total_ace", 0.0))
		var storms: Array = e.get("storms", [])
		total_storms += storms.size()
		rows.append(_session_row(i + 1, e, storms))
	if rows.is_empty():
		AceTableClass.build_empty(rows_box, "暂无存档记录。跑一局「风季模式」，结束后会自动写入存档。")
	else:
		var panels: Array = AceTableClass.build_rows(rows_box, rows, AceTableClass.COLUMNS_SESSION)
		for i in panels.size():
			_make_row_clickable(panels[i], i)
	summary_label.text = "%s：共 %d 局 · %d 场台风    总 ACE %.2f" % [
		_tab_label(), _sessions.size(), total_storms, total_ace]
	hint_label.text = "存档文件：%s（双击某行查看该局台风明细）" % Game.save_path_absolute()
	table_scroll.scroll_vertical = 0


func _session_row(rank: int, e: Dictionary, storms: Array) -> Dictionary:
	var peak := 0.0
	var end_day := -1.0
	for st in storms:
		peak = maxf(peak, float(st.get("peak_kt", 0.0)))
		end_day = maxf(end_day, float(st.get("end_day", 0.0)))
	var mode_str := str(e.get("mode", ""))
	# ⚠ "非风季" 里也含 "风季" 子串，必须先判「非风季」
	var mode_text := "非风季" if mode_str.contains("非风季") else "风季"
	return {
		"rank": "%d" % rank,
		"date": _session_date(int(e.get("saved_at", 0))),
		"mode": mode_text,
		"count": "%d" % storms.size(),
		"ace": "%.2f" % float(e.get("total_ace", 0.0)),
		"peak": "%d kt" % int(roundf(peak)),
		"end": AceTableClass.end_day_text(end_day) if end_day >= 0.0 else "—",
	}


## 场次行整行可双击 → 进二级
func _make_row_clickable(panel: Control, index: int) -> void:
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.tooltip_text = "双击查看该局台风明细"
	panel.gui_input.connect(_on_session_row_input.bind(index))


func _on_session_row_input(event: InputEvent, index: int) -> void:
	if _level != 1 or index < 0 or index >= _sessions.size():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.double_click:
			_session = _sessions[index]
			_rebuild_level2()
			accept_event()


# ============================ 二级：单局台风明细 ============================

func _rebuild_level2() -> void:
	_clear_table()
	_level = 2
	heading_label.text = "%s · %s" % [_tab_label(), _session_date(int(_session.get("saved_at", 0)))]
	tab_bar.visible = false
	back_button.text = "返回上一级"
	var storms: Array = _session.get("storms", [])
	AceTableClass.build_header(header_host)
	var rows: Array[Dictionary] = []
	var peak := 0.0
	for st in storms:
		peak = maxf(peak, float(st.get("peak_kt", 0.0)))
		rows.append(_row_of(st))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["_ace"]), float(b["_ace"])):
			return float(a["_ace"]) > float(b["_ace"])
		return float(a["_end"]) > float(b["_end"]))
	if rows.is_empty():
		AceTableClass.build_empty(rows_box, "该局没有生成台风。")
	else:
		AceTableClass.build_rows(rows_box, rows)
	summary_label.text = "%d 场台风    总 ACE %.2f    最高峰值 %d kt" % [
		storms.size(), float(_session.get("total_ace", 0.0)), int(roundf(peak))]
	hint_label.text = "存档文件：%s（ESC / 「返回上一级」回到场次列表）" % Game.save_path_absolute()
	table_scroll.scroll_vertical = 0


func _go_back_to_level1() -> void:
	_session = {}
	_rebuild_level1()


# ============================ 数据 ============================

## 当前标签对应的存档分类 key
func _category() -> String:
	return CATEGORIES[clampi(_current_tab, 0, CATEGORIES.size() - 1)]


func _tab_label() -> String:
	return TAB_LABELS[clampi(_current_tab, 0, TAB_LABELS.size() - 1)]


## 真实存档时间 YYYY-MM-DD HH:MM（按**本地时区**显示；unix 时间是 UTC）
func _session_date(unix: int) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(unix + bias)
	return "%04d-%02d-%02d %02d:%02d" % [
		int(d["year"]), int(d["month"]), int(d["day"]), int(d["hour"]), int(d["minute"])]


func _row_of(st: Dictionary) -> Dictionary:
	var peak := float(st.get("peak_kt", 0.0))
	var start := float(st.get("start_day", 0.0))
	var end := float(st.get("end_day", 0.0))
	return {
		"number": str(st.get("number", "")),
		"name": str(st.get("name", "")),
		"cat": AceTableClass.category_text(bool(st.get("reached_st", false)), peak),
		"peak": "%d kt" % int(roundf(peak)),
		"pressure": "%d hPa" % int(roundf(float(st.get("min_pressure", 0.0)))),
		"ace": "%.2f" % float(st.get("ace", 0.0)),
		"duration": AceTableClass.duration_text(start, end),
		"end": AceTableClass.end_day_text(end),
		"_ace": float(st.get("ace", 0.0)),
		"_end": end,
	}


func _clear_table() -> void:
	for c in header_host.get_children():
		c.queue_free()
	for c in rows_box.get_children():
		c.queue_free()
