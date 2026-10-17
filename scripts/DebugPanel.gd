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
##
## ⚠ 「季节增幅」那行的【−】/【＋】调的是**全局幅度** `GameSettings.seasonal_amplitude`
##   （0~4℃，和「模拟设置」里同一个值），**不是**改某个格子的海温。
##   显示里同时给出「本月算出的季节偏移」和「幅度」两个数——因为幅度是乘数，
##   5 月 / 11 月 sin=0 时算出来的偏移恒为 0，只显示偏移会让人以为按钮坏了。

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
	# ⚠ season 的 step 从 0.0 改成 0.5：这一行现在**可调**（改的是 GameSettings.seasonal_amplitude），
	#   step = 0 时 _add_row 不会建【−】/【＋】按钮，看起来还是只读的。
	{"key": "season", "label": "季节增幅", "step": 0.5},
	{"key": "sst_here", "label": "★ 实际运算用海温", "step": 0.5},
	{"key": "shear", "label": "风切", "step": 5.0},
	{"key": "pressure", "label": "该格气压", "step": 5.0},
	{"key": "hemi", "label": "半球", "step": 1.0},
	{"key": "start_lat", "label": "投放时起始纬度", "step": 0.0},
	{"key": "coriolis", "label": "★ 地转偏向力效应", "step": 0.0},
	{"key": "lat", "label": "当前纬度", "step": 0.0},
	{"sec": "② 台风数值"},
	{"key": "kt", "label": "风速 Kt", "step": 5.0},
	{"key": "cp", "label": "中心气压", "step": 0.0},
	{"key": "cat", "label": "类别", "step": 0.0},
	{"key": "phase", "label": "变性阶段", "step": 1.0},
	{"key": "peak", "label": "巅峰风速", "step": 5.0},
	{"key": "erc", "label": "眼壁置换", "step": 0.0},
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

	# 「季节增幅」这一行有两个容易混的数：本月算出的偏移 vs 可调的幅度。
	# 把完整说明放进 tooltip 兜底（数值本身已经两个都显示了）。
	# ⚠ Label 默认 mouse_filter = IGNORE，鼠标根本进不来、tooltip 不会弹，所以要显式设 STOP。
	if key == "season":
		var tip: String = "前一个数 = 本月算出的季节海温偏移：sin((月−5)×30°) × 幅度 + (平均海温−30)\n" \
			+ "后一个数 = 【−】/【＋】真正在改的全局「季节海温增幅」（0~4℃，会写进设置文件）\n" \
			+ "5 月 / 11 月 sin=0，按按钮时前一个数不变是正常的。"
		for node in [name_label, value_label]:
			var lbl := node as Label
			lbl.tooltip_text = tip
			lbl.mouse_filter = Control.MOUSE_FILTER_STOP

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
			# 两个数一起给，缺一个都会让人看不懂：
			#   前一个 = 本月**算出来**的季节偏移（sin((月−5)×30°)×幅度 + 平均海温−30）
			#   后一个 = 【−】/【＋】真正在改的**幅度**（全局设置）
			# 5 月 / 11 月 sin=0，此时按按钮前一个数不会变，只能靠后一个数看出按钮有效。
			return "%+.2f ℃（幅度 %.2f）" % [
				SimClock.seasonal_sst_amplitude(), GameSettings.seasonal_amplitude]
		"sst_here":
			return "%.2f ℃" % s.sst_here if s != null else "—"
		"shear":
			# ⚠ 参考里内部变量「垂直风切变」是 0~500 的**无量纲刻度**（原始工程里它是隐藏变量），
			#   界面上显示的是换算后的「风切」。所以这里主显风切，内部值放括号里且不标 kt。
			return "%.1f  (内部刻度 %.0f)" % [s.shear_display, s.shear] if s != null else "—"
		"pressure":
			return "%d hPa" % int(roundf(field.pressure[idx])) if field != null else "—"
		"hemi":
			return ("北 N" if s.northern else "南 S") if s != null else "—"
		"start_lat":
			return "%.2f°" % s.start_latitude if s != null else "—"
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
			return "%.1f kt" % s.peak_wind_kt if s != null else "—"
		"erc":
			if s == null:
				return "—"
			if s.erc_phase == Storm.Erc.NONE:
				var cd := "（下次还需 %.2f 天）" % s.erc_wait_days if s.wind_kt >= Const.ERC_MIN_KT else ""
				return "无%s   累计 %d 次（失败 %d 次）" % [cd, s.erc_count, s.erc_fail_count]
			return "%s（已 %.2f 天，本次目标跌 %.0f kt，失败率 %.0f%%）累计 %d 次 / 失败 %d 次" % [
				s.erc_text(), s.erc_days, s.erc_dip_kt,
				sim._erc_fail_chance(s) * 100.0 if sim != null else 0.0,
				s.erc_count, s.erc_fail_count]
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
		"season":
			# 改的是**全局幅度**（GameSettings.seasonal_amplitude），不是格子海温。
			# 范围 0~4℃ 与「模拟设置」里的 SpinBox 一致；旧模型「改格子海温」的做法已废弃，
			# 这里**不要**再碰 field.sst。
			# 这是玩家设置项，改完落盘（DebugPanel 是调试工具，不追求去抖）。
			GameSettings.seasonal_amplitude = clampf(
				GameSettings.seasonal_amplitude + delta, 0.0, 4.0)
			GameSettings.commit()
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
