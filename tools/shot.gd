extends SceneTree
## 开发用截图/巡检工具（不参与游戏逻辑，导出时排除）。
##
## 用法：
##   godot --path . -s res://tools/shot.gd -- --scene=res://TitleScreen.tscn --out=C:/tmp/shot.png --frames=60
##
## 额外参数：
##   --wait=SECONDS   截图前等待的秒数（默认按帧数算）
##   --scale=1.0      输出缩放
##   --quit          （默认总是退出）

var _scene_path := "res://TitleScreen.tscn"
var _out_path := "user://shot.png"
var _frames := 40
var _wait_seconds := -1.0
var _open := ""
var _hover := -1
var _page := -1
var _opened := false
var _hovered := false
var _paged := false
var _open_time := 0.0
var _elapsed := 0.0
var _done := false


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scene="):
			_scene_path = a.substr(8)
		elif a.begins_with("--out="):
			_out_path = a.substr(6)
		elif a.begins_with("--frames="):
			_frames = int(a.substr(9))
		elif a.begins_with("--wait="):
			_wait_seconds = float(a.substr(7))
		elif a.begins_with("--open="):
			_open = a.substr(7)
		elif a.begins_with("--hover="):
			_hover = int(a.substr(8))
		elif a.begins_with("--page="):
			_page = int(a.substr(7))
	print("[shot] scene=", _scene_path, " out=", _out_path, " frames=", _frames, " wait=", _wait_seconds, " open=", _open)
	var packed: PackedScene = load(_scene_path)
	if packed == null:
		printerr("[shot] cannot load scene: ", _scene_path)
		quit(2)
		return
	var inst := packed.instantiate()
	root.add_child(inst)


func _process(delta: float) -> bool:
	if _done:
		return true
	_elapsed += delta
	# 需要打开子界面时：主界面进场动画走完再点进去
	if _open != "" and not _opened and _elapsed > 1.35:
		_opened = true
		_open_time = _elapsed
		var scene := root.get_child(root.get_child_count() - 1)
		if scene != null and scene.has_method("_open_panel"):
			scene.call("_open_panel", _open)
	# 面板展开后切到指定页（设置界面用）
	if _page >= 0 and _opened and not _paged and _elapsed > _open_time + 1.05:
		_paged = true
		for child in root.get_child(root.get_child_count() - 1).get_children():
			if child.has_method("_set_page"):
				child.call("_set_page", _page)
				print("[shot] page -> ", _page)
	# 悬停某个按钮（真实鼠标坐标，走 mouse_entered）
	if _hover >= 0 and not _hovered and _elapsed > 1.35:
		_hovered = true
		var sc := root.get_child(root.get_child_count() - 1)
		var buttons = sc.get("_buttons")
		if buttons is Array and _hover < buttons.size():
			var b: Control = buttons[_hover]
			var center := b.position + b.size * 0.5
			root.warp_mouse(center)
			print("[shot] hover button ", _hover, " at ", center)
	if _wait_seconds > 0.0:
		if _elapsed < _wait_seconds:
			return false
	else:
		if Engine.get_process_frames() < _frames:
			return false
	return _capture()


func _capture() -> bool:
	_done = true
	var vp := root.get_viewport()
	var tex := vp.get_texture()
	if tex == null:
		printerr("[shot] no viewport texture (headless?)")
		return true
	var img := tex.get_image()
	if img == null or img.is_empty():
		printerr("[shot] empty image")
		return true
	var err := img.save_png(_out_path)
	if err != OK:
		printerr("[shot] save failed err=", err, " path=", _out_path)
	else:
		print("[shot] saved ", _out_path, " size=", img.get_width(), "x", img.get_height())
	quit(0)
	return true
