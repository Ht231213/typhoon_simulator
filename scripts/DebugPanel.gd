extends CanvasLayer
## 调试面板（快捷键 F6 开关）
##
## 两块内容，都是「先看、再改」，改完立刻反映到物理循环里：
##   ① 运算输入：台风所在格、该格观测海温 / 当前海温、季节增幅、
##               真正参与运算的 sst_here、垂直风切变、该格气压、半球
##   ② 台风数值：Kt、中心气压、类别、变性阶段、巅峰风速、ACE、路径段/进度
##   ③ 快捷操作：重置海温、让台风立刻消散、投放测试台风
##
## ⚠ 只在调试时用。本面板直接改物理状态，绕过正常流程。

var sim: Node = null
var field: OceanField = null

## 上一个台风的引用。台风结束后 `sim.active_storm` 会变成 null，
## 但用户还想看它的最后状态，所以这里持一份引用（Storm 是 RefCounted，持有就不会被回收）。
var _last_storm: Storm = null
## 它最后所在的格号
var _last_cell := 0
## 真实台风是否已经结束（用来在面板上标出来）
var _storm_ended := false

var _root: Control
var _body: VBoxContainer
var _hint: Label
var _rows: Array[Dictionary] = []

## 每一行的定义：key 交给 _get_val / _set_val 处理
const FIELDS: Array[Dictionary] = [
	{"sec": "① 运算输入"},
	{"key": "cell", "label": "台风所在格", "step": 0.0},
	{"key": "base_sst", "label": "该格观测海温", "step": 0.5},
	{"key": "sst", "label": "该格当前海温", "step": 0.5},
	{"key": "season", "label": "季节增幅", "step": 0.0},
	{"key": "sst_here", "label": "★ 实际运算用海温", "step": 0.5},
	{"key": "shear", "label": "垂直风切变", "step": 5.0},
	{"key": "pressure", "label": "该格气压", "step": 5.0},
	{"key": "hemi", "label": "半球（可切换）", "step": 1.0},
	{"key": "start_lat", "label": "投放时起始纬度", "step": 0.0},
	{"key": "coriolis", "label": "★ 地转偏向力效应", "step": 0.0},
	{"key": "lat", "label": "当前纬度", "step": 0.0},
	{"sec": "② 台风数值"},
	{"key": "kt", "label": "风速 Kt", "step": 5.0},
	{"key": "cp", "label": "中心气压", "step": 0.0},
	{"key": "cat", "label": "类别", "step": 0.0},
	{"key": "phase", "label": "变性阶段", "step": 1.0},
	{"key": "peak", "label": "巅峰风速", "step": 5.0},
	{"key": "ace", "label": "ACE", "step": 1.0},
	{"key": "seg", "label": "路径段", "step": 1.0},
	{"key": "prog", "label": "段内进度", "step": 0.1},
]


func setup(p_sim: Node, p_field: OceanField) -> void:
	sim = p_sim
	field = p_field


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 20
	_build_ui()
	visible = false
	set_process(true)


func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.55)
	_root.add_child(dim)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	_root.add_child(margin)

	var panel := PanelContainer.new()
	margin.add_child(panel)

	var scroll := ScrollContainer.new()
	panel.add_child(scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 6)
	scroll.add_child(_body)

	var title := Label.new()
	title.text = "调试面板（F6 关闭）"
	title.add_theme_font_size_override("font_size", 24)
	_body.add_child(title)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.text = "【−】/【+】改数值；改完立刻生效。带 ★ 的是物理真正读的那个量。"
	_body.add_child(_hint)

	for f in FIELDS:
		if f.has("sec"):
			var sep := HSeparator.new()
			_body.add_child(sep)
			var h := Label.new()
			h.text = str(f["sec"])
			h.add_theme_font_size_override("font_size", 18)
			_body.add_child(h)
			continue
		_add_row(str(f["key"]), str(f["label"]), float(f["step"]))

	_body.add_child(HSeparator.new())
	var ops := Label.new()
	ops.text = "③ 快捷操作"
	ops.add_theme_font_size_override("font_size", 18)
	_body.add_child(ops)

	var op_row := HBoxContainer.new()
	op_row.add_theme_constant_override("separation", 8)
	_body.add_child(op_row)
	_op_button(op_row, "海温全部重置", _op_reset_all_sst)
	_op_button(op_row, "该格海温重置", _op_reset_cell_sst)
	_op_button(op_row, "投放测试台风", _op_deploy)
	_op_button(op_row, "清空留存数据", _op_clear_last)

	var op_row2 := HBoxContainer.new()
	op_row2.add_theme_constant_override("separation", 8)
	_body.add_child(op_row2)
	_op_button(op_row2, "台风立刻消散（Kt=0）", _op_kill)
	_op_button(op_row2, "Kt 归 20（重新发展）", _op_revive)
	_op_button(op_row2, "正常结束本台风", _op_finish)


func _op_button(parent: Node, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 15)
	b.pressed.connect(cb)
	parent.add_child(b)


func _add_row(key: String, label_text: String, step: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_body.add_child(row)

	var name_label := Label.new()
	name_label.text = label_text
	name_label.custom_minimum_size = Vector2(230, 0)
	name_label.add_theme_font_size_override("font_size", 15)
	row.add_child(name_label)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(170, 0)
	value_label.add_theme_font_size_override("font_size", 15)
	row.add_child(value_label)

	if step > 0.0:
		var minus := Button.new()
		minus.text = "−"
		minus.custom_minimum_size = Vector2(46, 0)
		minus.pressed.connect(func() -> void: _nudge(key, -step))
		row.add_child(minus)
		var plus := Button.new()
		plus.text = "＋"
		plus.custom_minimum_size = Vector2(46, 0)
		plus.pressed.connect(func() -> void: _nudge(key, step))
		row.add_child(plus)
	else:
		var ro := Label.new()
		ro.text = "（只读）"
		ro.add_theme_font_size_override("font_size", 13)
		row.add_child(ro)

	_rows.append({"key": key, "value": value_label, "step": step})


func open() -> void:
	visible = true
	_refresh()


func close() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func _process(_d: float) -> void:
	if visible:
		_refresh()


# ============================ 读写 ============================

func _cur_storm() -> Storm:
	if sim == null:
		return null
	var s: Storm = sim.active_storm
	if s != null:
		_last_storm = s          # 记住，台风结束后还要给用户看
		_storm_ended = false
		return s
	# 台风已经结束了：仍然返回上一个，面板不至于变成一片「—」
	return _last_storm


func _cur_cell() -> int:
	var s := _cur_storm()
	if s == null:
		return 0
	var c := Const.cell_index_from_world(s.current_world_position())
	if sim != null and sim.active_storm != null:
		_last_cell = c
		_storm_ended = false
		return c
	# 已结束：位置还是它最后停下的那格
	return _last_cell if _last_cell > 0 else c


func _get_val(key: String) -> String:
	var s := _cur_storm()
	var cell := _cur_cell()
	var idx := clampi(cell - 1, 0, Const.CELL_COUNT - 1)
	# 没有台风记录时，画面格相关的项直接显示「—」，别去读第 1 格的数
	if cell <= 0 and key in ["cell", "base_sst", "sst", "pressure"]:
		return "—"
	match key:
		"cell":
			return "%d（行 %d 列 %d）" % [cell, idx / Const.COLS + 1, idx % Const.COLS + 1] if cell > 0 else "—"
		"base_sst":
			return "%.2f ℃" % field.sst_base[idx] if field != null else "—"
		"sst":
			return "%.2f ℃" % field.sst[idx] if field != null else "—"
		"season":
			return "%+.2f ℃" % SimClock.seasonal_sst_amplitude()
		"sst_here":
			return "%.2f ℃" % s.sst_here if s != null else "—"
		"shear":
			return "%.1f kt（风切 %.1f）" % [s.shear, s.shear_display] if s != null else "—"
		"pressure":
			return "%d hPa" % int(roundf(field.pressure[idx])) if field != null else "—"
		"hemi":
			return ("北 N（本次运算按北半球）" if s.northern else "南 S（本次运算按南半球）") if s != null else "—"
		"start_lat":
			if s == null:
				return "—"
			var ok: bool = (s.start_latitude > 0.0) == s.northern
			return "%.2f°  %s" % [s.start_latitude, "OK 与半球一致" if ok else "⚠ 与半球不一致"]
		"coriolis":
			if s == null:
				return "—"
			var eff := 0.0
			if s.northern:
				if s.latitude < 2.0:
					eff = -1.0
			else:
				if -2.0 < s.latitude:
					eff = -1.0
			return "%.0f  →  ΔKt %+.2f/tick（%+.0f kt/秒）" % [
				eff, eff * (s.wind_kt / 20.0), eff * (s.wind_kt / 20.0) * 100.0]
		"lat":
			return "%.2f°（%s）" % [s.latitude, "北" if s.latitude >= 0.0 else "南"] if s != null else "—"
		"kt":
			return "%.1f kt" % s.wind_kt if s != null else "—"
		"cp":
			return "%d hPa" % int(roundf(s.central_pressure)) if s != null else "—"
		"cat":
			return "%s（类型 %d）" % [s.category_text(), s.category] if s != null else "—"
		"phase":
			return ["热带", "变性中", "温带气旋"][s.phase] if s != null else "—"
		"peak":
			return "%.1f kt（巅峰类别 %d）" % [s.peak_wind_kt, s.peak_category] if s != null else "—"
		"ace":
			return "%.2f" % s.ace if s != null else "—"
		"seg":
			return "%d / %d" % [s.segment, s.waypoints.size() - 1] if s != null else "—"
		"prog":
			return "%.2f" % s.segment_progress if s != null else "—"
	return "—"


func _nudge(key: String, delta: float) -> void:
	var s := _cur_storm()
	var cell := _cur_cell()
	var idx := clampi(cell - 1, 0, Const.CELL_COUNT - 1)
	match key:
		"base_sst":
			if field != null:
				field.sst_base[idx] = clampf(field.sst_base[idx] + delta, 0.0, 35.0)
		"sst":
			if field != null:
				field.sst[idx] = clampf(field.sst[idx] + delta, 0.0, 35.0)
		"sst_here":
			if s != null:
				# 直接改「实际运算海温」：同时改该格当前海温，保证下一帧也生效
				s.sst_here = clampf(s.sst_here + delta, 0.0, 35.0)
				if field != null:
					field.sst[idx] = clampf(s.sst_here - SimClock.seasonal_sst_amplitude(), 0.0, 35.0)
		"shear":
			if s != null:
				s.shear = clampf(s.shear + delta, 0.0, Const.SHEAR_MAX)
		"pressure":
			if field != null:
				field.pressure[idx] = clampf(field.pressure[idx] + delta, 800.0, 1050.0)
		"hemi":
			if s != null:
				s.northern = not s.northern
		"kt":
			if s != null:
				s.wind_kt = maxf(0.0, s.wind_kt + delta)
		"phase":
			if s != null:
				s.phase = ((s.phase + int(delta)) % 3 + 3) % 3
				if s.phase != Storm.Phase.TROPICAL:
					s.transition_days = 0.0
		"peak":
			if s != null:
				s.peak_wind_kt = maxf(0.0, s.peak_wind_kt + delta)
		"ace":
			if s != null:
				s.ace = maxf(0.0, s.ace + delta)
		"seg":
			if s != null:
				s.segment = clampi(s.segment + int(delta), 0, maxi(0, s.waypoints.size() - 1))
		"prog":
			if s != null:
				s.segment_progress = clampf(s.segment_progress + delta, 0.0, 1.0)
	if field != null:
		field.queue_redraw()
	_refresh()


func _refresh() -> void:
	var s := _cur_storm()
	var alive: bool = sim != null and sim.active_storm != null
	for r in _rows:
		var key: String = r["key"]
		var vl: Label = r["value"]
		var txt := _get_val(key)
		if txt == "—":
			vl.modulate = Color(0.55, 0.55, 0.55)
		elif not alive:
			vl.modulate = Color(0.9, 0.9, 0.55)     # 已结束：偏黄，提示这是留存数据
		else:
			vl.modulate = Color(1, 1, 1)
		vl.text = txt

	if s == null:
		_hint.text = "当前没有台风记录可用（用下面的「投放测试台风」造一个）"
	elif not alive:
		_hint.text = "⚠ 台风已结束——下面是它最后的状态（留存数据，只供查看）"
	else:
		_hint.text = "【−】/【＋】改数值；改完立刻生效。带 ★ 的是物理真正读的那个量。"


# ============================ 快捷操作 ============================

func _op_reset_all_sst() -> void:
	if field != null:
		field.reset_sst()
	_refresh()


func _op_reset_cell_sst() -> void:
	var cell := _cur_cell()
	if field != null and cell > 0:
		field.sst[cell - 1] = field.sst_base[cell - 1]
		field.queue_redraw()
	_refresh()


func _op_deploy() -> void:
	if sim == null:
		return
	if sim.active_storm != null:
		sim.discard_storm_for_test()
	# 一条从暖池出发的短测试路径
	var lls := [Vector2(148.0, 16.0), Vector2(144.0, 18.0), Vector2(140.0, 20.0),
		Vector2(136.0, 22.0), Vector2(132.0, 24.0), Vector2(128.0, 26.0),
		Vector2(124.0, 27.5), Vector2(120.0, 29.0)]
	var wps := PackedVector2Array()
	for ll in lls:
		wps.append(Const.world_from_uv(Const.uv_from_lonlat(ll.x, ll.y)))
	sim.set_pending_waypoints(wps)
	sim.try_deploy()
	_refresh()


func _op_kill() -> void:
	var s := _cur_storm()
	if s != null:
		s.wind_kt = 0.0
	_refresh()


func _op_revive() -> void:
	var s := _cur_storm()
	if s != null:
		s.wind_kt = Const.INITIAL_WIND_KT
		s.name_committed = false
		s.ace = 0.0
		s.peak_wind_kt = 0.0
		s.peak_category = Const.CAT_UNKNOWN
		s.phase = Storm.Phase.TROPICAL
		s.transition_days = 0.0
	_refresh()


func _op_finish() -> void:
	if sim != null and sim.active_storm != null:
		sim._finish_storm()
	_refresh()


## 丢掉留存的上一场台风数据（面板会回到一片「—」）
func _op_clear_last() -> void:
	_last_storm = null
	_last_cell = 0
	_storm_ended = true
	_refresh()
