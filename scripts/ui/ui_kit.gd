class_name UiKit
extends RefCounted
## 2.0 界面的共用工具：配色、手 K 缓动曲线、平行四边形几何、常用控件工厂。
##
## 设计约束：整套界面的所有「斜」都来自同一个斜率常量 SLANT，
## 背景分界线（slant_panel.gdshader）和按钮左右边（SkewButton）因此天然平行。

# ------------------------------- 配色 -------------------------------

const INK := Color(0.024, 0.031, 0.043, 1.0)          # 近黑底色
const INK_SOFT := Color(0.043, 0.055, 0.071, 1.0)
const TEXT := Color(0.93, 0.96, 0.99, 0.95)
const TEXT_DIM := Color(0.72, 0.80, 0.87, 0.66)
const ACCENT := Color(0.55, 0.88, 1.0, 1.0)            # 冰蓝：台风冷色
const ACCENT_DEEP := Color(0.18, 0.52, 0.70, 1.0)
const WARN := Color(1.0, 0.80, 0.35, 1.0)

## 按钮左右边 / 背景分界线共用的斜率：每 1 px 高度 → 水平偏移 0.45 px（约 24.2°）
const SLANT := 0.45
## 分界线在画面底部的 x（相对宽度）
const EDGE_BOTTOM_X := 0.30

# ---------------------------- 手 K 缓动曲线 ----------------------------
# 缓动全部是**严格单调**的数学函数。
# ⚠ 之前用手 K 的 Curve 关键点做 lerp 进度，关键点之间的自动切线会来回波动
#   （back 还带 1.1 的过冲），结果动画看起来像波浪、闪白会「亮一下又暗下去」。
#   进度曲线必须单调递增，每个元素再单独配时长/距离/缓动。

## 结束段缓（起步快、尾巴长）：最常用的「到位」手感
static func ease_out_cubic(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return 1.0 - pow(1.0 - x, 3.0)


static func ease_out_quint(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return 1.0 - pow(1.0 - x, 5.0)


static func ease_out_quad(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return 1.0 - (1.0 - x) * (1.0 - x)


static func ease_out_expo(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return 1.0 if x >= 1.0 else 1.0 - pow(2.0, -10.0 * x)


static func ease_out_sine(t: float) -> float:
	return sin(clampf(t, 0.0, 1.0) * PI * 0.5)


## 起步慢、后面越来越快（甩出画面用）
static func ease_in_cubic(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return x * x * x


static func ease_in_quad(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return x * x


static func ease_in_out_sine(t: float) -> float:
	return 0.5 - 0.5 * cos(clampf(t, 0.0, 1.0) * PI)


static func ease_in_out_cubic(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	if x < 0.5:
		return 4.0 * x * x * x
	return 1.0 - pow(-2.0 * x + 2.0, 3.0) * 0.5


## 按名字取缓动（全部单调，t 与返回值都在 0..1）
static func ease_named(name: StringName, t: float) -> float:
	match String(name):
		"out_expo", "expo":
			return ease_out_expo(t)
		"out_quint":
			return ease_out_quint(t)
		"out_quad":
			return ease_out_quad(t)
		"out_sine", "in_out_sine", "sine":
			return ease_out_sine(t)
		"in_cubic", "in":
			return ease_in_cubic(t)
		"in_quad":
			return ease_in_quad(t)
		"in_out":
			return ease_in_out_cubic(t)
		"linear":
			return clampf(t, 0.0, 1.0)
		_:
			return ease_out_cubic(t)


# ---------------------------- 平行四边形几何 ----------------------------

## 左上角为原点、右倾的平行四边形（顶部相对底部右移 h * slant）
static func parallelogram(size: Vector2, slant: float = SLANT) -> PackedVector2Array:
	var dx := size.y * slant
	return PackedVector2Array([
		Vector2(dx, 0.0),
		Vector2(size.x, 0.0),
		Vector2(size.x - dx, size.y),
		Vector2(0.0, size.y),
	])


## 把凸多边形每个顶点换成半径为 radius 的圆角（顶点顺序保持）
static func round_polygon(pts: PackedVector2Array, radius: float, segs: int = 6) -> PackedVector2Array:
	var n := pts.size()
	if n < 3 or radius <= 0.01:
		return pts
	var out := PackedVector2Array()
	for i in n:
		var p := pts[i]
		var prev := pts[(i - 1 + n) % n]
		var next := pts[(i + 1) % n]
		var d1 := prev - p
		var d2 := next - p
		var l1 := d1.length()
		var l2 := d2.length()
		if l1 < 1e-4 or l2 < 1e-4:
			out.append(p)
			continue
		d1 /= l1
		d2 /= l2
		var theta := acos(clampf(d1.dot(d2), -1.0, 1.0))
		if theta < 0.02 or theta > PI - 0.02:
			out.append(p)
			continue
		var dist := minf(radius / tan(theta * 0.5), minf(l1, l2) * 0.5)
		var r := dist * tan(theta * 0.5)
		var a := p + d1 * dist
		var b := p + d2 * dist
		var bisec := d1 + d2
		if bisec.length() < 1e-5:
			out.append(p)
			continue
		var c := p + bisec.normalized() * (r / sin(theta * 0.5))
		var ang_a := (a - c).angle()
		var ang_b := (b - c).angle()
		var diff := wrapf(ang_b - ang_a, -PI, PI)
		for s in segs + 1:
			var t := float(s) / float(segs)
			out.append(c + Vector2.from_angle(ang_a + diff * t) * r)
	return out


## Sutherland–Hodgman：只保留 x <= x_max 的部分（用于「从左往右填充」）
static func clip_x_max(pts: PackedVector2Array, x_max: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := pts.size()
	if n < 3:
		return out
	for i in n:
		var cur := pts[i]
		var nxt := pts[(i + 1) % n]
		var cur_in := cur.x <= x_max
		var nxt_in := nxt.x <= x_max
		if cur_in:
			out.append(cur)
		if cur_in != nxt_in:
			var dx := nxt.x - cur.x
			if absf(dx) > 1e-6:
				out.append(cur.lerp(nxt, (x_max - cur.x) / dx))
	return out


# ---------------------------- 控件工厂 ----------------------------

static func make_label(text: String, font_size: int, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func make_title(text: String, font_size: int) -> Label:
	var l := make_label(text, font_size, TEXT)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 3)
	return l


static func make_body(text: String, font_size: int = 17, color: Color = TEXT_DIM) -> Label:
	var l := make_label(text, font_size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## 斜切背景材质（mode 0 = 左侧深色区，1 = 右侧云图区）
static func slant_material(mode: int, bottom_x: float = EDGE_BOTTOM_X, tint: Color = Color(0.02, 0.03, 0.05, 0.92),
		line_px: float = 0.0) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/ui/slant_panel.gdshader")
	mat.set_shader_parameter("mode", mode)
	mat.set_shader_parameter("bottom_x", bottom_x)
	mat.set_shader_parameter("slant", SLANT)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("line_px", line_px)
	mat.set_shader_parameter("reveal", 0.0)
	return mat


## 逐项错开的延迟（菜单从上到下依次出场）
static func stagger(i: int, step: float, base: float = 0.0) -> float:
	return base + float(i) * step


# ---------------------------- 缓动补间 ----------------------------
# 界面里所有动画都走这里：先取**单调**缓动，再 lerp 目标属性。
# 同一属性上的旧补间会被自动杀掉 —— 两条动画抢一个属性是「抖」的另一半原因。

static func tween_float(host: Node, target: Object, prop: String, to: float, dur: float,
		ease_name: StringName = &"out_cubic", delay: float = 0.0) -> Tween:
	var tw := host.create_tween()
	_kill_prev(target, prop)
	if delay > 0.0:
		tw.tween_interval(delay)
	# "modulate:a" / "position:y" 这种子属性：Object.get() 不认冒号写法，手动拆
	if ":" in prop:
		var parts := prop.split(":")
		var base := parts[0]
		var comp := parts[1]
		var from_sub := _read_sub(target, base, comp)
		tw.tween_method(func(u: float) -> void:
			_write_sub(target, base, comp, lerpf(from_sub, to, ease_named(ease_name, u)))
		, 0.0, 1.0, dur)
	else:
		var from := float(target.get(prop))
		tw.tween_method(func(u: float) -> void:
			target.set(prop, lerpf(from, to, ease_named(ease_name, u)))
		, 0.0, 1.0, dur)
	_remember(target, prop, tw)
	return tw


static func _read_sub(target: Object, base: String, comp: String) -> float:
	var v: Variant = target.get(base)
	if v is Color:
		match comp:
			"r": return (v as Color).r
			"g": return (v as Color).g
			"b": return (v as Color).b
			_: return (v as Color).a
	if v is Vector2:
		return (v as Vector2).x if comp == "x" else (v as Vector2).y
	if v is float or v is int:
		return float(v)
	return 0.0


static func _write_sub(target: Object, base: String, comp: String, value: float) -> void:
	var v: Variant = target.get(base)
	if v is Color:
		var col := v as Color
		match comp:
			"r": col.r = value
			"g": col.g = value
			"b": col.b = value
			_: col.a = value
		target.set(base, col)
	elif v is Vector2:
		var vec := v as Vector2
		if comp == "x":
			vec.x = value
		else:
			vec.y = value
		target.set(base, vec)


static func tween_vec2(host: Node, target: Object, prop: String, to: Vector2, dur: float,
		ease_name: StringName = &"out_cubic", delay: float = 0.0) -> Tween:
	var tw := host.create_tween()
	_kill_prev(target, prop)
	if delay > 0.0:
		tw.tween_interval(delay)
	var from: Vector2 = target.get(prop)
	tw.tween_method(func(u: float) -> void:
		target.set(prop, from.lerp(to, ease_named(ease_name, u)))
	, 0.0, 1.0, dur)
	_remember(target, prop, tw)
	return tw


static func tween_color(host: Node, target: Object, prop: String, to: Color, dur: float,
		ease_name: StringName = &"out_cubic", delay: float = 0.0) -> Tween:
	var tw := host.create_tween()
	_kill_prev(target, prop)
	if delay > 0.0:
		tw.tween_interval(delay)
	var from: Color = target.get(prop)
	tw.tween_method(func(u: float) -> void:
		target.set(prop, from.lerp(to, ease_named(ease_name, u)))
	, 0.0, 1.0, dur)
	_remember(target, prop, tw)
	return tw


## 同一 target + property 上如果还有旧补间，先杀掉（防止两条动画打架导致抖动）
## ⚠ meta 名字里不能带冒号（"modulate:a" 会报 Invalid metadata identifier），统一换成下划线；
##   get_meta(key) 无默认值的写法在 key 不存在时也会报错，所以先 has_meta 判断。
static func _meta_key(prop: String) -> String:
	return "__tw_" + prop.replace(":", "_")


static func _kill_prev(target: Object, prop: String) -> void:
	var key := _meta_key(prop)
	if not target.has_meta(key):
		return
	var prev = target.get_meta(key)
	if prev is Tween and (prev as Tween).is_valid():
		(prev as Tween).kill()
	target.remove_meta(key)


static func _remember(target: Object, prop: String, tw: Tween) -> void:
	target.set_meta(_meta_key(prop), tw)


# ---------------------------- 原生控件统一皮肤 ----------------------------

## 下拉框：深色半透明底 + 冰蓝悬停边，下拉列表也压成深色
static func style_option_button(opt: OptionButton) -> void:
	var normal := _input_box(Color(1, 1, 1, 0.055), Color(1, 1, 1, 0.20))
	var hover := _input_box(Color(1, 1, 1, 0.11), Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.75))
	var pressed := _input_box(Color(1, 1, 1, 0.16), Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.95))
	var focus := _input_box(Color(1, 1, 1, 0.02), Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.55))
	opt.add_theme_stylebox_override("normal", normal)
	opt.add_theme_stylebox_override("hover", hover)
	opt.add_theme_stylebox_override("pressed", pressed)
	opt.add_theme_stylebox_override("focus", focus)
	opt.add_theme_color_override("font_color", TEXT)
	opt.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	opt.add_theme_color_override("font_pressed_color", ACCENT)
	var popup := opt.get_popup()
	if popup != null:
		var panel := StyleBoxFlat.new()
		panel.bg_color = Color(0.05, 0.07, 0.09, 0.98)
		panel.border_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.35)
		panel.set_border_width_all(1)
		panel.set_corner_radius_all(8)
		panel.set_content_margin_all(6)
		popup.add_theme_stylebox_override("panel", panel)
		popup.add_theme_color_override("font_color", TEXT)
		popup.add_theme_color_override("font_hover_color", Color(0.03, 0.05, 0.07, 1.0))


## 勾选框：统一字色/字号，方框换成 assets/ui/check_{on,off}.svg（2.0 自绘）
static func style_check_box(cb: CheckBox) -> void:
	cb.add_theme_color_override("font_color", TEXT)
	cb.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	cb.add_theme_color_override("font_pressed_color", ACCENT)
	cb.add_theme_font_size_override("font_size", 18)
	var on: Texture2D = load("res://assets/ui/check_on.svg")
	var off: Texture2D = load("res://assets/ui/check_off.svg")
	if on != null:
		for slot in ["checked", "checked_disabled"]:
			cb.add_theme_icon_override(slot, on)
	if off != null:
		for slot in ["unchecked", "unchecked_disabled"]:
			cb.add_theme_icon_override(slot, off)
	# 方框与文字之间留点空隙
	cb.add_theme_constant_override("h_separation", 10)


static func _input_box(bg: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(8)
	box.content_margin_left = 14.0
	box.content_margin_right = 12.0
	box.content_margin_top = 8.0
	box.content_margin_bottom = 8.0
	return box
