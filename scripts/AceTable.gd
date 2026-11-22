class_name AceTable
extends RefCounted
## ACE 记录表格构建器（2026-11-22 需求 7）。
##
## 两处共用：
##   · 标题画面「ACE 存档」→ 全部存档场次（AceArchive）
##   · 风季结束 ResultsPanel → 本局场次
##
## ⚠ 中文宽度对齐的坑：**每列用固定像素宽度的单元格 + 对齐方式**，
##   绝不用空格补位（`Game._pad_display` 那套只适合等宽 ItemList）。
##   表头和数据行用同一份 COLUMNS 宽度 → 列 x 坐标天然逐列相等。
##
## 行结构：PanelContainer(底色) → HBoxContainer → Label × 9
## 表头和数据行都由本类创建，样式/字号保持一致。

## 列定义（唯一真源：表头和数据行都读它）
## align：0=左 1=中 2=右（HORIZONTAL_ALIGNMENT_*）
const COLUMNS: Array[Dictionary] = [
	{"key": "number", "title": "编号", "width": 96, "align": 0},
	{"key": "name", "title": "名称", "width": 150, "align": 0},
	{"key": "cat", "title": "巅峰等级", "width": 90, "align": 1},
	{"key": "peak", "title": "巅峰风速", "width": 110, "align": 2},
	{"key": "pressure", "title": "最低气压", "width": 110, "align": 2},
	{"key": "ace", "title": "ACE", "width": 100, "align": 2},
	{"key": "duration", "title": "持续时间", "width": 110, "align": 2},
	{"key": "mode", "title": "模式", "width": 160, "align": 0},
	{"key": "end", "title": "结束日期", "width": 120, "align": 0},
]

const ROW_HEIGHT := 28
const ROW_FONT_SIZE := 16
const HEADER_FONT_SIZE := 17
const CELL_SEPARATION := 8
## 表头底色 / 描边（蓝，和设置页的「最佳路径」框同一色系）
const HEADER_BG := Color(0.42, 0.62, 1.0, 0.16)
const HEADER_BORDER := Color(0.45, 0.72, 1.0, 0.55)
## 隔行底色（很淡的白，深色主题下能看出行边界）
const ROW_ALT_BG := Color(1.0, 1.0, 1.0, 0.035)


## 在 parent 下建表头。返回表头 PanelContainer（测试里用来看列 x 坐标）。
static func build_header(parent: Node) -> PanelContainer:
	var pair := _new_row(HEADER_BG, true)
	var panel: PanelContainer = pair[0]
	var row: HBoxContainer = pair[1]
	for col in COLUMNS:
		row.add_child(_make_cell(
			str(col["title"]), float(col["width"]), int(col["align"]), HEADER_FONT_SIZE, true))
	parent.add_child(panel)
	return panel


## 在 parent（VBox）下建数据行。rows 是 Dictionary 列表，key 见 COLUMNS。
static func build_rows(parent: Node, rows: Array) -> void:
	for i in rows.size():
		var alt := (i % 2 == 1)
		var pair := _new_row(ROW_ALT_BG if alt else Color(1, 1, 1, 0), false)
		var panel: PanelContainer = pair[0]
		var row: HBoxContainer = pair[1]
		var data: Dictionary = rows[i]
		for col in COLUMNS:
			row.add_child(_make_cell(
				str(data.get(col["key"], "")), float(col["width"]),
				int(col["align"]), ROW_FONT_SIZE, false))
		parent.add_child(panel)


## 空表格提示（「暂无存档记录」这类）
static func build_empty(parent: Node, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size = Vector2(0, 72)
	lbl.add_theme_font_size_override("font_size", 17)
	lbl.add_theme_color_override("font_color", Color(0.62, 0.65, 0.70))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(lbl)


# ============================ 数据格式化（两处共用） ============================

## 年内第 N 天（1月1日 = 0）→ 「6月20日」
static func end_day_text(end_day: float) -> String:
	var d := int(roundf(end_day))
	var month := clampi(d / Const.DAYS_PER_MONTH + 1, 1, Const.MONTHS_PER_YEAR)
	var day := clampi(d % Const.DAYS_PER_MONTH + 1, 1, Const.DAYS_PER_MONTH)
	return "%d月%d日" % [month, day]


## 持续天数（结束日 − 开始日）
static func duration_text(start_day: float, end_day: float) -> String:
	return "%.1f 天" % maxf(0.0, end_day - start_day)


## 巅峰等级短名（ST 优先，否则按峰值风速分级）
static func category_text(reached_st: bool, peak_kt: float) -> String:
	var cat := Const.CAT_SUBTROPICAL if reached_st else Const.category_from_wind(peak_kt)
	return Const.category_short(cat)


# ============================ 内部 ============================

## 返回 [PanelContainer, HBoxContainer]
static func _new_row(bg: Color, with_border: bool) -> Array:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _make_style(bg, with_border))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", CELL_SEPARATION)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(row)
	return [panel, row]


static func _make_style(bg: Color, with_border: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	# ⚠ 内容边距必须显式清零：表头/数据行都从同一个 x 起，列才会逐列对齐
	sb.content_margin_left = 0.0
	sb.content_margin_right = 0.0
	sb.content_margin_top = 0.0
	sb.content_margin_bottom = 0.0
	if with_border:
		sb.border_width_bottom = 1
		sb.border_color = HEADER_BORDER
	return sb


static func _make_cell(text: String, width: float, align: int, font_size: int, header: bool) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size = Vector2(width, ROW_HEIGHT)
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.horizontal_alignment = align as HorizontalAlignment
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.clip_text = true
	if header:
		lbl.add_theme_color_override("font_color", Color(0.78, 0.85, 0.95))
	return lbl
