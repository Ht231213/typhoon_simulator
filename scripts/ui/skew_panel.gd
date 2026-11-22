class_name SkewPanel
extends Control
## 静态平行四边形底板：卡片、榜单行、提示条都用它。
## 斜率和主界面分界线一致（UiKit.SLANT），因此界面里所有边看起来属于同一套几何。

@export var slant: float = 0.45
@export var corner_radius: float = 9.0
@export var fill: Color = Color(1, 1, 1, 0.055)
@export var edge: Color = Color(1, 1, 1, 0.16)
@export var edge_width: float = 1.4
## 左侧高亮竖条（选中行 / 强调块），0 = 不画
@export var accent_width: float = 0.0
## accent 色：冰蓝（与 UiKit.ACCENT 一致）
@export var accent: Color = Color(0.55, 0.88, 1.0, 1.0)

var _points: PackedVector2Array = PackedVector2Array()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_rebuild)
	_rebuild()


func _rebuild() -> void:
	var inset := maxf(edge_width, 1.0) * 0.5
	var w := size.x - inset * 2.0
	var h := size.y - inset * 2.0
	if w < 2.0 or h < 2.0:
		_points = PackedVector2Array()
	else:
		_points = UiKit.round_polygon(UiKit.parallelogram(Vector2(w, h), slant), corner_radius, 6)
		for i in _points.size():
			_points[i] += Vector2(inset, inset)
	queue_redraw()


func _draw() -> void:
	if _points.size() < 3:
		return
	draw_colored_polygon(_points, fill)
	if accent_width > 0.0:
		var bar := UiKit.clip_x_max(_points, accent_width)
		if bar.size() >= 3:
			draw_colored_polygon(bar, accent)
	if edge_width > 0.0:
		var ring := _points.duplicate()
		ring.append(_points[0])
		draw_polyline(ring, edge, edge_width, true)
