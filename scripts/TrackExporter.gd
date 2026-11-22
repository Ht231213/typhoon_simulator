class_name TrackExporter
extends RefCounted
## 把「WPAC 地图 + 本局**已结束台风**的归档路径」离屏合成一张 PNG（1.3 ④）。
## ⚠ 2026-11-22 用户要求：只导出**已经结束**的台风（archive 里的，正常结束 + 中途停止），
##   正在跑的活跃台风不导出（PathLayer.export_tracks() 已只取归档）。
##
## 为什么用离屏 SubViewport：
##   · 截全窗口会带 UI；ESC 暂停时还会被 0.72 黑幕盖住；分辨率只有窗口大小
##   · 离屏视口按世界坐标 1:1 重建地图，分辨率自己定，且不含任何 UI
##
## ⚠ 关键坑（2026-11-22 实测）：离屏 PathLayer 只能**直接填 points/intensities/phases**，
##   绝对不能调 set_live_position() —— 那会生成台风图标/风圈，把导出图弄脏。
##
## 只出桌面版：web 版从 Beta.3 起已停止提供（用户 2026-11-22 确认），
## 所以没有浏览器下载分支，统一写到 <游戏根>/导出图片/。
## 不写存档、不做图片库。

const MAP_TEXTURE_PATH := "res://assets/images/WPAC.png"
## 导出分辨率 = WPAC.png **原生 1:1 像素**（最清晰；实测约 1.07 s、PNG 约 5.75 MB）
const EXPORT_SIZE := Vector2i(3000, 2400)
## 导出目录名（游戏根目录下，和 BestTrack/ 同级）
const OUT_DIR_NAME := "导出图片"
## 文件名前缀（后面接系统时间）
const FILE_PREFIX := "TyphoonTrack_"
## 取图前等几帧（SubViewport 首帧可能还没画完）
const WAIT_FRAMES := 2


## 导出。成功返回一句提示（带文件路径），失败返回空字符串。
## host：任意已在场景树里的节点（SubViewport 挂到它下面，用完释放）。
## path_layer：主场景的路径层——只读它的存档数据，不会被改动。
func export_png(host: Node, path_layer: PathLayer) -> String:
	if host == null or path_layer == null or not host.is_inside_tree():
		return ""
	var tracks: Array = path_layer.export_tracks()
	if tracks.is_empty():
		return ""

	var tex: Texture2D = load(MAP_TEXTURE_PATH)
	if tex == null:
		return "导出失败：地图贴图缺失"

	var vp := SubViewport.new()
	vp.size = EXPORT_SIZE
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# 2D MSAA 让折线边缘平滑
	vp.msaa_2d = Viewport.MSAA_4X
	host.add_child(vp)

	# ① 地图底图：铺满世界坐标 (0,0)..(Const.MAP_W, Const.MAP_H)
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	spr.scale = Vector2(
		float(EXPORT_SIZE.x) / float(tex.get_width()),
		float(EXPORT_SIZE.y) / float(tex.get_height()))
	spr.position = Vector2(EXPORT_SIZE) * 0.5
	vp.add_child(spr)

	# ② 路径：复用真正的 PathLayer（同一套配色/平滑/虚线），只喂数据
	var pl := PathLayer.new()
	pl.scale = Vector2(
		float(EXPORT_SIZE.x) / Const.MAP_W,
		float(EXPORT_SIZE.y) / Const.MAP_H)
	vp.add_child(pl)
	await host.get_tree().process_frame          # 等 PathLayer._ready 跑完
	pl.set_export_data(tracks)

	for _i in WAIT_FRAMES:
		await RenderingServer.frame_post_draw

	var img: Image = vp.get_texture().get_image()
	vp.queue_free()
	if img == null or img.is_empty():
		return "导出失败：取图失败"

	var stamp := _timestamp()
	var file_name := "%s%s.png" % [FILE_PREFIX, stamp]

	# ③ 桌面：写到 <游戏根>/导出图片/
	var dir := out_dir()
	var err_dir := DirAccess.make_dir_recursive_absolute(dir)
	if err_dir != OK:
		return "导出失败：无法创建目录 %s" % dir
	var path := dir.path_join(file_name)
	var n := 2
	while FileAccess.file_exists(path):
		path = dir.path_join("%s%s_%d.png" % [FILE_PREFIX, stamp, n])
		n += 1
	var err := img.save_png(path)
	if err != OK:
		return "导出失败：写入出错（%d）%s" % [err, path]
	print("[TrackExporter] 已导出图片 → %s（%d×%d）" % [path, img.get_width(), img.get_height()])
	# 提示格式：已导出：<路径>（用户 2026-11-22 定的文案）
	return "已导出：%s" % path


## 图片导出目录：<游戏根>/导出图片（和 BestTrack/ 同级）
static func out_dir() -> String:
	return _game_root().path_join(OUT_DIR_NAME)


## 系统时间 YYYYmmdd_HHMMSS（文件名不重名）
static func _timestamp() -> String:
	var now := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d_%02d%02d%02d" % [
		int(now["year"]), int(now["month"]), int(now["day"]),
		int(now["hour"]), int(now["minute"]), int(now["second"])]


## 游戏根目录：导出版 = exe 所在目录；编辑器/直接跑 = 工程根（同 BestTrack 的规则）
static func _game_root() -> String:
	if OS.has_feature("template"):
		return OS.get_executable_path().get_base_dir()
	var root := ProjectSettings.globalize_path("res://")
	if root == "":
		root = OS.get_executable_path().get_base_dir()
	return root
