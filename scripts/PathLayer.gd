class_name PathLayer
extends Node2D
## 台风路径、路径点与风圈的绘制层。
##
## 全部用画笔（draw_*）画，作为占位实现。以后要换成贴图时，只需要把 _draw() 里
## 对应的 draw_* 调用替换成 draw_texture_rect()，外部接口（add_point / set_live_position
## / set_pending_waypoints）都不用改。
##
## 坐标：世界坐标（地图像素，原点在左上角）。

# ------------------------- 已走过的路径 -------------------------
var points: Array[Vector2] = []
var intensities: Array[float] = []
## 每个路径点对应的变性阶段（Storm.Phase 的整数值）。
## 用来把变性后的那一段画成白色虚线。
var phases: Array[int] = []

# ------------------------- 台风当前位置 -------------------------
var live_position := Vector2.ZERO
var live_intensity := 0.0
var live_phase := 0                   ## Storm.Phase：0 热带 / 1 变性中 / 2 温带
var live_visible := false

# ------------------------- 手动模式待投放的路径点 -------------------------
var pending_waypoints: Array[Vector2] = []

# ------------------------- 登陆特效（占位） -------------------------
## 每个元素 { "pos": Vector2, "kt": float, "age": float, "ttl": float }
var landfall_effects: Array[Dictionary] = []


func clear_track() -> void:
	points.clear()
	intensities.clear()
	phases.clear()
	live_visible = false
	landfall_effects.clear()
	queue_redraw()


func set_live_position(world_pos: Vector2, kt: float, phase := 0) -> void:
	live_position = world_pos
	live_intensity = kt
	live_phase = phase
	live_visible = true
	# 拉开足够距离才记录，避免高频调用堆出上万个点。
	# 阶段变化时要强制记一个点，否则虚线段起点会不准。
	var phase_changed := not phases.is_empty() and phases[-1] != phase
	if points.is_empty() or phase_changed or points[-1].distance_to(world_pos) > 6.0:
		points.append(world_pos)
		intensities.append(kt)
		phases.append(phase)
	queue_redraw()


# ------------------------- 手动路径点 -------------------------

func add_waypoint(world_pos: Vector2) -> void:
	pending_waypoints.append(world_pos)
	queue_redraw()


## 撤销最后一个路径点。返回是否真的删掉了一个。
func undo_waypoint() -> bool:
	if pending_waypoints.is_empty():
		return false
	pending_waypoints.remove_at(pending_waypoints.size() - 1)
	queue_redraw()
	return true


func clear_waypoints() -> void:
	pending_waypoints.clear()
	queue_redraw()


func waypoint_count() -> int:
	return pending_waypoints.size()


# ------------------------- 登陆特效 -------------------------

func spawn_landfall_effect(world_pos: Vector2, kt: float) -> void:
	landfall_effects.append({"pos": world_pos, "kt": kt, "age": 0.0, "ttl": 1.4})
	queue_redraw()


func _process(delta: float) -> void:
	if landfall_effects.is_empty():
		return
	var alive: Array[Dictionary] = []
	for fx in landfall_effects:
		fx["age"] = float(fx["age"]) + delta
		if float(fx["age"]) < float(fx["ttl"]):
			alive.append(fx)
	landfall_effects = alive
	queue_redraw()


# ------------------------- 绘制 -------------------------

## 路径点圆点半径
const POINT_RADIUS := 7.0
## 路径点颜色（鲜明）
const POINT_COLOR := Color(1.0, 0.85, 0.1)
const POINT_OUTLINE := Color(0.15, 0.10, 0.0, 0.9)


## 路径线宽
const TRACK_WIDTH := 2.5
## 变性中 / 已变性的路径线：白色虚线（用户指定的视觉表现）
const EXTRA_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const EXTRA_DASH := 9.0
const EXTRA_GAP := 7.0
## 变性中：偏白的浅蓝，用来和「完全变性」区分
const TRANSITION_COLOR := Color(0.82, 0.88, 1.0, 0.95)


func _draw() -> void:
	_draw_track()

	# ② 手动模式：待投放的路径点。只画鲜明的圆点，不标数字。
	if not pending_waypoints.is_empty():
		for i in pending_waypoints.size():
			if i > 0:
				draw_dashed_line(pending_waypoints[i - 1], pending_waypoints[i],
					Color(1.0, 0.95, 0.4, 0.7), 2.0, 8.0)
		for p in pending_waypoints:
			draw_circle(p, POINT_RADIUS + 1.5, POINT_OUTLINE)   # 描边，保证在任何底色上都看得清
			draw_circle(p, POINT_RADIUS, POINT_COLOR)

	# ③ 台风本体 + 风圈
	if live_visible:
		var c := _track_color_at(live_intensity, live_phase)
		draw_circle(live_position, 6.0, c)
		var outer := _wind_ring_radius(live_intensity)
		draw_arc(live_position, outer * 0.45, 0.0, TAU, 48, Color(c, 0.5), 1.5, true)
		draw_arc(live_position, outer, 0.0, TAU, 72, Color(c, 0.28), 1.5, true)

	# ④ 登陆特效占位（以后换成贴图/粒子）
	for fx in landfall_effects:
		var t := float(fx["age"]) / float(fx["ttl"])
		var pos: Vector2 = fx["pos"]
		var kt := float(fx["kt"])
		var col := Const.track_color(kt)
		draw_arc(pos, 12.0 + 70.0 * t, 0.0, TAU, 48, Color(col.r, col.g, col.b, (1.0 - t) * 0.9), 4.0, true)
		draw_arc(pos, 6.0 + 34.0 * t, 0.0, TAU, 32, Color(1, 1, 1, (1.0 - t) * 0.7), 2.0, true)


## 已走过的路径。
## 按变性阶段分段：热带段用强度配色实线，变性段用浅色虚线，完全变性用白色虚线。
func _draw_track() -> void:
	if points.size() < 2:
		return
	var i := 1
	while i < points.size():
		var phase := phases[i] if i < phases.size() else 0
		# 找出同一阶段的连续区段
		var j := i
		while j + 1 < points.size() and (phases[j + 1] if j + 1 < phases.size() else 0) == phase:
			j += 1
		var run := PackedVector2Array()
		run.append(points[i - 1])
		for k in range(i, j + 1):
			run.append(points[k])

		if run.size() < 2:
			i = j + 1
			continue
		match phase:
			2:      # 已完全变性为温带气旋 → 白色虚线
				for k in range(1, run.size()):
					draw_dashed_line(run[k - 1], run[k], EXTRA_COLOR, TRACK_WIDTH, EXTRA_DASH)
			1:      # 变性中 → 浅色虚线
				for k in range(1, run.size()):
					draw_dashed_line(run[k - 1], run[k], TRANSITION_COLOR, TRACK_WIDTH, EXTRA_DASH)
			_:      # 热带阶段 → 按强度配色的实线
				var cols := PackedColorArray()
				for k in range(i, j + 1):
					cols.append(Const.track_color(intensities[k] if k < intensities.size() else 0.0))
				draw_polyline_colors(run, cols, TRACK_WIDTH, true)
		i = j + 1


## 当前位置的颜色：变性后用白/浅蓝，否则按强度
func _track_color_at(kt: float, phase: int) -> Color:
	match phase:
		2:
			return EXTRA_COLOR
		1:
			return TRANSITION_COLOR
		_:
			return Const.track_color(kt)


## 风圈半径，对应原工程「风圈」按 Kt 分档设置 size 的逻辑
static func _wind_ring_radius(kt: float) -> float:
	var tier := Const.category_from_wind(kt)
	var base := 18.0 + maxf(0.0, kt) * 0.35
	return clampf(base + tier * 4.0, 18.0, 140.0)
