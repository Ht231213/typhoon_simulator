extends ColorRect
## ESC 暂停遮罩。
##
## 原实现有两个问题，这里一起修掉：
##   1. `.visible = false` 少了接收者，Godot 直接报解析错误 → 脚本根本加载不了
##   2. 节点原来是 PROCESS_MODE_WHEN_PAUSED（process_mode = 3），意思是「只在暂停时处理」；
##      可是它自己就是负责「触发暂停」的那个节点。结果游戏没暂停时它不接收输入，
##      按 ESC 永远没反应，暂停菜单永远弹不出来。
##
## 正确做法：这个节点用 PROCESS_MODE_ALWAYS，保证没暂停时也能收到 ESC；
## 里面的按钮本来只有在遮罩可见时才能点到，不需要额外设置。

@onready var resume_button: Button = $ButtonResume

const MIN_SIZE := Vector2(200, 60)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	# 场景里 ESCs 是全屏遮罩，但按钮的锚点是按小面板设的，会被拉得很大。
	# 这里直接用代码把它摆到屏幕中间，省得去调锚点。
	resume_button.custom_minimum_size = MIN_SIZE
	resume_button.set_anchors_preset(Control.PRESET_CENTER)
	resume_button.grow_horizontal = Control.GROW_DIRECTION_BOTH
	resume_button.grow_vertical = Control.GROW_DIRECTION_BOTH
	if not resume_button.pressed.is_connected(_on_button_resume_pressed):
		resume_button.pressed.connect(_on_button_resume_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_set_paused(not visible)
		get_viewport().set_input_as_handled()


func _set_paused(paused: bool) -> void:
	visible = paused
	get_tree().paused = paused


func _on_button_resume_pressed() -> void:
	_set_paused(false)
