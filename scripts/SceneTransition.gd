extends CanvasLayer
## 场景切换过渡（autoload）。
##
## 之前 `change_scene_to_file()` 是硬切 —— 进模拟时画面「闪」一下。现在统一走这里：
## 先淡入一层底色（0.22 s，加速曲线）→ 换场景 → 等两帧 → 淡出（0.34 s）。
## 底色取 UI 的 INK，与主界面/侧栏一致，看起来像画面在暗场里换掉。

const INK := Color(0.024, 0.031, 0.043, 1.0)

var _rect: ColorRect = null
var _busy := false


func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rect = ColorRect.new()
	_rect.name = "Fade"
	_rect.color = INK
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.modulate.a = 0.0
	_rect.visible = false
	add_child(_rect)


## 带过渡地切换场景
func change_scene(path: String) -> void:
	if _busy:
		return
	_busy = true
	_rect.visible = true
	await (UiKit.tween_float(self, _rect, "modulate:a", 1.0, 0.22, &"in_cubic")).finished
	get_tree().change_scene_to_file(path)
	# 等两帧，确保新场景已进树并完成一次布局
	await get_tree().process_frame
	await get_tree().process_frame
	await (UiKit.tween_float(self, _rect, "modulate:a", 0.0, 0.34, &"out_cubic")).finished
	_rect.visible = false
	_busy = false
