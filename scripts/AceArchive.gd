extends Control
## 标题画面「ACE 存档」的大窗口（2026-11-22 需求 7；2026-11-22 追加标签页）。
##
## 数据源：`<游戏目录>/saves/ace_records.json`（`Game.history()` 读文件）。
## 4 个标签页 = 存档的 4 个分类（和 `Game.save_category()` 一致）：
##   单台 · 手动 / 多台 · 手动 / 单台 · 自动 / 多台 · 自动
## 每页把该分类下所有局的 `storms[]` 逐场展开成 8 列表格（不再需要「模式」列），
## 按单场 ACE 降序；表头固定、内容滚动；每页独立汇总行。
##
## 由标题画面**运行时实例化**（避免 BUG-1：静态 Control 场景实例在导出包里会丢锚点）。
## 关闭：底部「返回」按钮 / ESC。

## 表格构建器（用 preload 而不是全局 class_name：新脚本在没被编辑器扫描过时，
## 直接跑场景会报 "Identifier AceTable not declared"，preload 更稳）
const AceTableClass := preload("res://scripts/AceTable.gd")

## 标签页顺序（用户指定：单台·手动 / 多台·手动 / 单台·自动 / 多台·自动）
const CATEGORIES: Array[String] = ["单台-手动", "多台-手动", "单台-自动", "多台-自动"]
const TAB_LABELS: Array[String] = ["单台 · 手动", "多台 · 手动", "单台 · 自动", "多台 · 自动"]

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


func _ready() -> void:
	visible = false
	back_button.pressed.connect(close)
	# 外置 TabBar（和设置界面同款）：标题由代码填，避免手改 .tscn
	tab_bar.tab_count = TAB_LABELS.size()
	for i in TAB_LABELS.size():
		tab_bar.set_tab_title(i, TAB_LABELS[i])
	tab_bar.tab_changed.connect(_on_tab_changed)


func open() -> void:
	if tab_bar.tab_count > 0:
		tab_bar.current_tab = clampi(_current_tab, 0, TAB_LABELS.size() - 1)
	_rebuild(_current_tab)
	visible = true


func close() -> void:
	visible = false
	if on_closed.is_valid():
		on_closed.call()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _on_tab_changed(index: int) -> void:
	_current_tab = index
	_rebuild(index)


# ============================ 构建表格 ============================

func _rebuild(index: int) -> void:
	for c in header_host.get_children():
		c.queue_free()
	for c in rows_box.get_children():
		c.queue_free()

	var cat := CATEGORIES[clampi(index, 0, CATEGORIES.size() - 1)]
	var data := _collect(cat)
	AceTableClass.build_header(header_host)
	var rows: Array = data["rows"]
	if rows.is_empty():
		AceTableClass.build_empty(rows_box, "暂无存档记录。跑一局「风季模式」，结束后会自动写入存档。")
	else:
		AceTableClass.build_rows(rows_box, rows)
	summary_label.text = "%s：共 %d 场（%d 局）    总 ACE %.2f" % [
		TAB_LABELS[clampi(index, 0, TAB_LABELS.size() - 1)],
		int(data["storm_count"]), int(data["sessions"]), float(data["total_ace"])]
	hint_label.text = "存档文件：%s" % Game.save_path_absolute()
	table_scroll.scroll_vertical = 0


## 某一分类下的全部存档局 → 逐场展开成表格行
func _collect(category: String) -> Dictionary:
	var rows: Array[Dictionary] = []
	var total_ace := 0.0
	var sessions := 0
	var history: Array = Game.history(category)
	sessions = history.size()
	for entry in history:
		var e: Dictionary = entry
		total_ace += float(e.get("total_ace", 0.0))
		var storms: Array = e.get("storms", [])
		for st in storms:
			rows.append(_row_of(st))
	# 按单场 ACE 降序；同 ACE 时结束日期新的在前
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["_ace"]), float(b["_ace"])):
			return float(a["_ace"]) > float(b["_ace"])
		return float(a["_end"]) > float(b["_end"]))
	return {
		"rows": rows,
		"sessions": sessions,
		"total_ace": total_ace,
		"storm_count": rows.size(),
	}


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
