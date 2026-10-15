extends Control
## 手动模式的路径点编辑器，负责「投放环节」的状态。
##
## 投放环节（内部叫法，不显示在游戏里）：
##   点「添加台风」进入 → 此时才能在地图上左键标记路径点
##   环节内可用按钮：投放台风 / 撤销路径点 / 清空路径点 / 取消
##   点「投放台风」或「取消」都会退出环节；退出后点击地图**不会**再加路径点
##
## 坐标：玩家点的是屏幕像素，必须换算成地图的世界坐标（0,0 .. MAP_W,MAP_H）
## 再存进列表，否则窗口一缩放/地图一缩放，点出来的位置就会有偏差。

signal waypoints_changed(count: int)
## 投放环节的开关状态变化（进入 / 退出）
signal placement_changed(in_placement: bool)

var map_layer: Node2D = null
var path_layer: PathLayer = null

## 是否处于投放环节。只有为 true 时地图点击才生效。
var in_placement := false

## 「点地图自动进入投放环节」的判定回调，由 GameRoot 注入。
## 返回 true 表示现在可以投放（没有活跃台风、不在冷却、没暂停…）。
## 这样玩家不用先去侧栏点「添加台风」——直接在地图上点第一下就自动开始。
var can_auto_place: Callable = Callable()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS


# ============================ 投放环节 ============================

## 进入投放环节（点「添加台风」时调用）
func begin_placement() -> void:
	if in_placement:
		return
	in_placement = true
	placement_changed.emit(true)


## 退出投放环节。keep_points = true 时保留已标记的路径点（投放成功时用）。
func end_placement(keep_points := false) -> void:
	if not keep_points and path_layer != null:
		path_layer.clear_waypoints()
	in_placement = false
	placement_changed.emit(false)
	waypoints_changed.emit(waypoint_count())


# ============================ 输入 ============================

## 把鼠标位置换算成地图世界坐标，并夹在地图范围内
func world_from_local(local_pos: Vector2) -> Vector2:
	if map_layer == null:
		return local_pos
	var world := map_layer.to_local(global_position + local_pos)
	return Vector2(
		clampf(world.x, 0.0, Const.MAP_W),
		clampf(world.y, 0.0, Const.MAP_H)
	)


func _gui_input(event: InputEvent) -> void:
	if path_layer == null:
		return

	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			# 还没进入投放环节 → 先问一下现在能不能投放；能就**自动进入**（用户要求），
			# 不能（有活跃台风 / 冷却中 / 已暂停）就当作普通点击忽略。
			if not in_placement:
				if not (can_auto_place.is_valid() and bool(can_auto_place.call())):
					return
				begin_placement()
			# 局部像素 → 世界坐标换算，避免缩放导致的偏差
			path_layer.add_waypoint(world_from_local(mb.position))
			waypoints_changed.emit(path_layer.waypoint_count())
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if not in_placement:
				return
			if path_layer.undo_waypoint():
				waypoints_changed.emit(path_layer.waypoint_count())
			accept_event()
	elif event is InputEventKey and event.pressed and not event.echo:
		if not in_placement:
			return
		if (event as InputEventKey).keycode == KEY_BACKSPACE:
			if path_layer.undo_waypoint():
				waypoints_changed.emit(path_layer.waypoint_count())
			accept_event()


# ============================ 路径点操作 ============================

func clear() -> void:
	if path_layer != null:
		path_layer.clear_waypoints()
	waypoints_changed.emit(0)


## 撤销最后一个路径点
func undo_waypoint() -> void:
	if path_layer != null:
		path_layer.undo_waypoint()
	waypoints_changed.emit(waypoint_count())


## 当前已标记的路径点数量
func waypoint_count() -> int:
	return path_layer.waypoint_count() if path_layer != null else 0


## 取路径点（世界坐标列表）
func take_waypoints() -> PackedVector2Array:
	if path_layer == null:
		return PackedVector2Array()
	return PackedVector2Array(path_layer.pending_waypoints)
