class_name TrackArchive
extends RefCounted
## 本局保留的台风历史路径（1.3 ④）。
##
## 只在内存里：不写存档、不做图片库；退出游戏（或场景重建）就销毁。
## 每条轨迹存**世界坐标**（= 地图像素，0..Const.MAP_W / MAP_H），
## 和 PathLayer 的实时轨迹同一套坐标，所以绘制/导出可以复用同一份画法。
##
## 为什么不用 BestTrack 的采样：那是经纬度 + 6 小时采样，而且只有勾了
## 「最佳路径数据集」才记录，不能拿来画图。

class Track extends RefCounted:
	## 世界坐标路径点
	var points := PackedVector2Array()
	## 每个点对应的风速（kt）
	var intensities := PackedFloat32Array()
	## 每个点对应的变性阶段（Storm.Phase 的整数值）
	var phases := PackedInt32Array()
	## 显示用标签，如 "01W 达维"
	var label := ""
	var peak_kt := 0.0
	var ace := 0.0
	var start_day := 0.0
	var end_day := 0.0
	## true = 自然结束；false = 玩家点「停止模拟」中途终止
	var completed := true
	## 绘制缓存（PathLayer 用）：Array[Dictionary] {pts, cols, dashed}。
	## 归档轨迹只在这里缓存的平滑/取色结果上重画，避免每次重绘都重新平滑（几十场后会掉帧）。
	var render_cache: Array = []

	func point_count() -> int:
		return points.size()


## 本局已保留的轨迹（按结束先后排列：旧 → 新）
var tracks: Array = []


func count() -> int:
	return tracks.size()


func is_empty() -> bool:
	return tracks.is_empty()


func clear() -> void:
	tracks.clear()


## 新建一条轨迹对象（不加入归档）
static func make_track(pts, kts, phs, meta: Dictionary = {}) -> Track:
	var t := Track.new()
	t.points = PackedVector2Array(pts)
	t.intensities = PackedFloat32Array(kts)
	t.phases = PackedInt32Array(phs)
	t.label = str(meta.get("label", ""))
	t.peak_kt = float(meta.get("peak_kt", 0.0))
	t.ace = float(meta.get("ace", 0.0))
	t.start_day = float(meta.get("start_day", 0.0))
	t.end_day = float(meta.get("end_day", 0.0))
	t.completed = bool(meta.get("completed", true))
	return t


## 收一条轨迹进归档（点数 < 2 的没有意义，不收入）
func add_track(pts, kts, phs, meta: Dictionary = {}) -> Track:
	if pts.size() < 2:
		return null
	var t := make_track(pts, kts, phs, meta)
	tracks.append(t)
	return t
