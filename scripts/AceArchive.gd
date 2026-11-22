extends Control
## 标题画面「ACE 存档」的大窗口（2026-11-22 需求 7）。
##
## 数据源：`<游戏目录>/saves/ace_records.json`（`Game.history()` 读文件）。
## 把每个存档局里的 `storms[]` 逐场展开成表格行（9 列，见 AceTable.COLUMNS），
## 按**单场 ACE 降序**排列；表头固定、内容可滚动。
##
## 与 SettingsMenu 一样是「全屏半透明遮罩 + 大面板」；由标题画面**运行时实例化**
## （避免 BUG-1：静态 Control 场景实例在导出包里会丢锚点）。
## 关闭：底部「返回」按钮 / ESC。

## 表格构建器（用 preload 而不是全局 class_name：新脚本在没被编辑器扫描过时，
## 直接跑场景会报 "Identifier AceTable not declared"，preload 更稳）
const AceTableClass := preload("res://scripts/AceTable.gd")

## 存档分类（旧存档只有前两个，新的多台存档是后两个；按 key 取，不枚举）
const CATEGORIES: Array[String] = ["单台-手动", "单台-自动", "多台-手动", "多台-自动"]

@onready var summary_label: Label = %Summary
@onready var header_host: VBoxContainer = %TableHeaderHost
@onready var table_scroll: ScrollContainer = %TableScroll
@onready var rows_box: VBoxContainer = %RowsBox
@onready var hint_label: Label = %Hint
@onready var back_button: Button = %BackButton

## 关闭时的回调（由标题画面注入，用于把焦点还给按钮）
var on_closed: Callable = Callable()


func _ready() -> void:
	visible = false
	back_button.pressed.connect(close)


func open() -> void:
	_rebuild()
	table_scroll.scroll_vertical = 0
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


# ============================ 构建表格 ============================

func _rebuild() -> void:
	for c in header_host.get_children():
		c.queue_free()
	for c in rows_box.get_children():
		c.queue_free()

	var data := _collect()
	AceTableClass.build_header(header_host)
	var rows: Array = data["rows"]
	if rows.is_empty():
		AceTableClass.build_empty(rows_box, "暂无存档记录。跑一局「风季模式」，结束后会自动写入存档。")
		summary_label.text = "存档共 0 场台风（0 局）    总 ACE 0.00"
	else:
		AceTableClass.build_rows(rows_box, rows)
		summary_label.text = "存档共 %d 场台风（%d 局）    总 ACE %.2f" % [
			int(data["storm_count"]), int(data["sessions"]), float(data["total_ace"])]
	hint_label.text = "存档文件：%s" % Game.save_path_absolute()


## 逐局逐场展开成表格行；同时算「总场次 / 总 ACE」
func _collect() -> Dictionary:
	var rows: Array[Dictionary] = []
	var total_ace := 0.0
	var sessions := 0
	for category in CATEGORIES:
		var history: Array = Game.history(category)
		sessions += history.size()
		for entry in history:
			var e: Dictionary = entry
			total_ace += float(e.get("total_ace", 0.0))
			var mode_text := _mode_text(category, str(e.get("mode", "")))
			var storms: Array = e.get("storms", [])
			for st in storms:
				rows.append(_row_of(st, mode_text))
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


func _row_of(st: Dictionary, mode_text: String) -> Dictionary:
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
		"mode": mode_text,
		"end": AceTableClass.end_day_text(end),
		"_ace": float(st.get("ace", 0.0)),
		"_end": end,
	}


## 模式列显示：单台/多台 · 手动/自动（· 风季）。兼容旧存档的 mode 字符串
##（旧："手动模式 + 风季"；新："多台 + 自动 + 风季"）。
func _mode_text(category: String, mode_str: String) -> String:
	var size_text := "多台" if category.begins_with("多台") else "单台"
	var trans_text := "自动" if category.ends_with("自动") else "手动"
	var season_text := "·风季" if mode_str.contains("风季") else ""
	return "%s·%s%s" % [size_text, trans_text, season_text]
