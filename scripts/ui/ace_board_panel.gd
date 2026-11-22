class_name AceBoardPanel
extends MenuPanel
## 「ACE 存档」子界面：左边操作区选分类、看汇总，右边（下方）是榜单。
##
## 数据来源不变：Game.history(分类) 读游戏目录 saves/ace_records.json。

const CATEGORIES := ["单台-手动", "单台-自动"]
const ROW_H := 36.0
const ROW_GAP := 4.0
const LIST_W := 700.0

var _category := 0
var _cat_buttons: Array[SkewButton] = []
var _summary: Label = null
var _empty: Label = null
var _scroll: ScrollContainer = null
var _rows: VBoxContainer = null


func _build() -> void:
	var title := UiKit.make_title("ACE 存档", 40)
	add_at(title, Vector2(CONTENT_X, 52.0), Vector2(460.0, 56.0))
	add_label("按总 ACE 从高到低", Vector2(CONTENT_X + 2.0, 114.0), Vector2(400.0, 22.0), 15, UiKit.TEXT_DIM)

	for i in CATEGORIES.size():
		var b := add_button(String(CATEGORIES[i]), Vector2(CONTENT_X + float(i) * 264.0, 156.0),
			Vector2(248.0, 48.0), 20)
		b.pressed.connect(_on_category_pressed.bind(i))
		_cat_buttons.append(b)

	_summary = add_label("", Vector2(CONTENT_X, 222.0), Vector2(600.0, 24.0), 15,
		Color(UiKit.ACCENT.r, UiKit.ACCENT.g, UiKit.ACCENT.b, 0.9))

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_at(_scroll, Vector2(CONTENT_X, 258.0), Vector2(LIST_W, 344.0))

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", int(ROW_GAP))
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows)

	_empty = UiKit.make_body("还没有成绩。跑一局「风季模式」，结束后会自动写入排行榜。", 15, UiKit.TEXT_DIM)
	add_at(_empty, Vector2(CONTENT_X + 16.0, 300.0), Vector2(LIST_W - 40.0, 60.0))

	var back := add_button("返回", Vector2(CONTENT_X, 620.0), Vector2(190.0, 54.0), 21)
	back.pressed.connect(close)

	_refresh()


func _on_category_pressed(index: int) -> void:
	_category = index
	_refresh()


func _refresh() -> void:
	for i in _cat_buttons.size():
		_cat_buttons[i].selected = i == _category
	for c in _rows.get_children():
		c.queue_free()

	var list := Game.history(String(CATEGORIES[_category]))
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("total_ace", 0.0)) > float(b.get("total_ace", 0.0)))

	_empty.visible = list.is_empty()
	_scroll.visible = not list.is_empty()

	var best := 0.0
	var total := 0.0
	for e in list:
		var ace := float(e.get("total_ace", 0.0))
		best = maxf(best, ace)
		total += ace
	_summary.text = "存档 %d 条  ·  最高 %.2f  ·  平均 %.2f" % [
		list.size(), best, total / maxf(float(list.size()), 1.0)]

	for i in list.size():
		_rows.add_child(_make_row(i, list[i]))


func _make_row(index: int, entry: Dictionary) -> Control:
	var ace := float(entry.get("total_ace", 0.0))
	var count := int(entry.get("storm_count", 0))
	var when := Time.get_datetime_string_from_unix_time(int(entry.get("saved_at", 0)))
	when = when.replace("T", " ")

	var row := SkewPanel.new()
	row.custom_minimum_size = Vector2(0.0, ROW_H)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.corner_radius = 7.0
	row.accent_width = 3.0
	if index == 0:
		row.fill = Color(0.55, 0.88, 1.0, 0.10)
		row.edge = Color(0.55, 0.88, 1.0, 0.45)
	elif index < 3:
		row.fill = Color(1, 1, 1, 0.075)
		row.edge = Color(1, 1, 1, 0.22)
	else:
		row.fill = Color(1, 1, 1, 0.045)
		row.edge = Color(1, 1, 1, 0.13)

	var star := "★" if index < 3 else ""
	var strong := index < 3
	var color := UiKit.TEXT if strong else UiKit.TEXT_DIM

	# 固定列位置（不用空格凑对齐：中文字体里 ASCII 与中文宽度不同）
	var rank_lbl := UiKit.make_label(("%s%02d" % [star, index + 1]) if star != "" else "%02d" % (index + 1),
		15, UiKit.ACCENT if strong else color)
	rank_lbl.position = Vector2(22.0, 0.0)
	rank_lbl.size = Vector2(56.0, ROW_H)
	rank_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(rank_lbl)

	var ace_lbl := UiKit.make_label("%.2f" % ace, 16, color)
	ace_lbl.position = Vector2(96.0, 0.0)
	ace_lbl.size = Vector2(140.0, ROW_H)
	ace_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ace_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(ace_lbl)

	var ace_unit := UiKit.make_label("ACE", 12, Color(color.r, color.g, color.b, 0.6))
	ace_unit.position = Vector2(244.0, 0.0)
	ace_unit.size = Vector2(50.0, ROW_H)
	ace_unit.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(ace_unit)

	var count_lbl := UiKit.make_label("%d 场" % count, 15, color)
	count_lbl.position = Vector2(320.0, 0.0)
	count_lbl.size = Vector2(90.0, ROW_H)
	count_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(count_lbl)

	var when_lbl := UiKit.make_label(when, 13, Color(color.r, color.g, color.b, 0.7))
	when_lbl.position = Vector2(430.0, 0.0)
	when_lbl.size = Vector2(LIST_W - 452.0, ROW_H)
	when_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	when_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(when_lbl)
	return row
