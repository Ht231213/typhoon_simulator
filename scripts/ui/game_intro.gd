extends Node
## 进入模拟时的进场动画（挂在 GameRoot 下，程序化运行，不改 GameRoot.gd 的任何逻辑）。
##
## 顺序（全部非线性缓动）：
##   ① 地图淡入（**只动 modulate，绝不动 MapLayer 的 position/scale**）
##   ② 右侧面板背景飞入（Sidebar.play_enter 里做 scale 展开）
##   ③ 面板里的文字和按钮在同一个队列里从上往下依次出现
##
## ⚠ 为什么不能动 MapLayer.position：
##   GameRoot._relayout() 按 map_area.size 算出等比缩放和居中位置，并且监听 map_area.resized。
##   在动画里写 position 会和它互相覆盖，最后停在一个错误值 —— 表现为「地图顶部黑了一块」。
##   要"从左飞入"必须给地图套一个独立的偏移层（MapSlide），不能直接改 MapLayer 的变换。

const SIDEBAR_DELAY := 0.26


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var root := get_parent()
	if root == null:
		return
	var map_slide := root.get_node_or_null("View/MapArea/MapSlide") as Node2D
	var map_layer := root.get_node_or_null("View/MapArea/MapLayer") as Node2D
	var sidebar := root.get_node_or_null("View/Sidebar")

	# 地图：用独立偏移层 MapSlide 做「从左飞入」，MapLayer 自身的布局变换完全不碰
	if map_slide != null:
		map_slide.position = Vector2(-1180.0, 0.0)
		if map_layer != null:
			map_layer.modulate = Color(1, 1, 1, 0.0)
			UiKit.tween_float(self, map_layer, "modulate:a", 1.0, 0.5, &"out_quad")
		UiKit.tween_vec2(self, map_slide, "position", Vector2.ZERO, 0.82, &"out_cubic")
	elif map_layer != null:
		# 没有偏移层时退化为纯淡入，保证绝不会影响布局
		map_layer.modulate = Color(1, 1, 1, 0.0)
		UiKit.tween_float(self, map_layer, "modulate:a", 1.0, 0.5, &"out_quad")

	if sidebar != null and sidebar.has_method("play_enter"):
		sidebar.call("play_enter", SIDEBAR_DELAY)
