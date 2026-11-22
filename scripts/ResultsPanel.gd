extends Control
## 风季结束的结果面板（2026-11-22 需求 7 改版：**大窗口 + 表格**）。
##
## 和标题画面「ACE 存档」共用 `AceTable`（同样的 9 列、固定列宽、行高 28、按单场 ACE 降序）。
## 保留（用户要求）：
##   · 汇总行「共生成 N 场台风    总 ACE X.XX」
##   · 存档写入提示（SaveLabel）
##   · 「再跑一局」/「回主菜单」
## ESC = 回主菜单。

## 表格构建器（preload 而不是全局 class_name：新脚本没被编辑器扫描过时直接跑场景会报
## "Identifier AceTable not declared"，preload 更稳）
const AceTableClass := preload("res://scripts/AceTable.gd")

@onready var title_label: Label = %ResultTitle
@onready var summary_label: Label = %ResultSummary
@onready var header_host: VBoxContainer = %TableHeaderHost
@onready var table_scroll: ScrollContainer = %TableScroll
@onready var rows_box: VBoxContainer = %RowsBox
@onready var save_label: Label = %SaveLabel
@onready var again_button: Button = %AgainButton
@onready var menu_button: Button = %MenuButton


func _ready() -> void:
	again_button.pressed.connect(_on_again)
	menu_button.pressed.connect(_on_menu)
	visible = false


func show_results(saved: bool) -> void:
	title_label.text = "风季结束 · %s" % Game.mode_label()
	# ⚠ 用 visible_records()：默认只列热带风暴级及以上，
	#   打开「记录热带扰动和低压」后连 <30 kt 的扰动也一并列出。
	var vis := Game.visible_records()
	summary_label.text = "共生成 %d 场台风    总 ACE %.2f" % [vis.size(), Game.total_ace]

	_rebuild_table(vis)

	if vis.is_empty():
		save_label.text = "本局没有生成任何台风，未写入存档。"
	elif saved:
		save_label.text = "✓ 已写入存档：%s\n分类「%s」" % [Game.save_path_absolute(), Game.save_category()]
	else:
		save_label.text = "⚠ 存档写入失败，请检查 %s" % Game.save_path_absolute()

	table_scroll.scroll_vertical = 0
	visible = true


## ESC：回主菜单（大窗口没有「关掉再看地图」的意义——本局已经结束）
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		# ⚠ 先吞掉事件再切场景：change_scene 会让本节点离树，之后再取 viewport 会 null
		get_viewport().set_input_as_handled()
		_on_menu()


# ============================ 表格 ============================

func _rebuild_table(vis: Array) -> void:
	for c in header_host.get_children():
		c.queue_free()
	for c in rows_box.get_children():
		c.queue_free()

	AceTableClass.build_header(header_host)
	var rows := _collect_rows(vis)
	if rows.is_empty():
		AceTableClass.build_empty(rows_box, "本局没有生成任何台风。")
	else:
		AceTableClass.build_rows(rows_box, rows)


func _collect_rows(vis: Array) -> Array:
	var rows: Array[Dictionary] = []
	for rec in vis:
		var r: Game.StormRecord = rec
		rows.append({
			"number": r.number_text,
			"name": r.storm_name,
			"cat": AceTableClass.category_text(r.reached_st, r.peak_wind_kt),
			"peak": "%d kt" % int(roundf(r.peak_wind_kt)),
			"pressure": "%d hPa" % int(roundf(r.min_pressure)),
			"ace": "%.2f" % r.ace,
			"duration": AceTableClass.duration_text(r.start_day, r.end_day),
			"mode": _mode_text(),
			"end": AceTableClass.end_day_text(r.end_day),
			"_ace": r.ace,
			"_end": r.end_day,
		})
	# 按单场 ACE 降序；同 ACE 时结束日期新的在前（和 ACE 存档页一致）
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["_ace"]), float(b["_ace"])):
			return float(a["_ace"]) > float(b["_ace"])
		return float(a["_end"]) > float(b["_end"]))
	return rows


## 模式列：单台/多台 · 手动/自动（· 风季），和 ACE 存档页同一套文字
func _mode_text() -> String:
	var size_text := "多台" if Game.multi_mode else "单台"
	var trans_text := "自动" if Game.mode == Game.Mode.AUTO else "手动"
	var season_text := "·风季" if Game.season_mode else ""
	return "%s·%s%s" % [size_text, trans_text, season_text]


# ============================ 按钮 ============================

func _on_again() -> void:
	visible = false
	get_tree().reload_current_scene()


func _on_menu() -> void:
	get_tree().change_scene_to_file("res://TitleScreen.tscn")
