extends CanvasLayer
## 场景切换过渡（autoload）。
##
## 只有一种：淡入淡出。进入模拟 / 返回主菜单都走它。
##   change_scene(path)                普通切换
##   change_scene(path, preloaded)     用调用方提前实例化好的场景直接挂上（省掉重新加载）
##
## 进入模拟时的「地图飞入 / 面板飞入 / 内容依次出现」是**场景内部**的进场动画，
## 由 scripts/ui/game_intro.gd + Sidebar.play_enter() 负责，不在这里。

const INK := Color(0.024, 0.031, 0.043, 1.0)

var _fade: ColorRect = null
var _busy := false


func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS
	_fade = ColorRect.new()
	_fade.name = "Fade"
	_fade.color = INK
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.modulate.a = 0.0
	_fade.visible = false
	add_child(_fade)


## 淡出旧画面 → 换场景 → 淡入新画面
## preloaded 不为空时直接把它挂到树上（调用方已经 instantiate 好，省掉加载停顿）
func change_scene(path: String, preloaded: Node = null, fade_out := 0.24, fade_in := 0.34) -> void:
	if _busy:
		return
	_busy = true
	_fade.visible = true
	await (UiKit.tween_float(self, _fade, "modulate:a", 1.0, fade_out, &"in_cubic")).finished

	if preloaded != null:
		var old_scene := get_tree().current_scene
		get_tree().root.add_child(preloaded)
		get_tree().current_scene = preloaded
		if old_scene != null:
			old_scene.queue_free()
	else:
		get_tree().change_scene_to_file(path)

	await get_tree().process_frame
	await get_tree().process_frame
	await (UiKit.tween_float(self, _fade, "modulate:a", 0.0, fade_in, &"out_cubic")).finished
	_fade.visible = false
	_busy = false
