extends Node
## 进入模拟时的进场动画（挂在 GameRoot 下，程序化运行，不改 GameRoot.gd 的任何逻辑）。
##
## 顺序（全部非线性缓动）：
##   ① 地图淡入 + 整体左→右飞入
##   ② 右侧面板背景飞入（Sidebar.play_enter 里做 scale 展开）
##   ③ 面板里的文字和按钮在同一个队列里从上往下依次出现
##
## ⚠ 两条硬约束：
##   1. 不能动 MapLayer 的 position/scale —— 那是 GameRoot._relayout() 按容器尺寸算出来的，
##      动画去写它就会互相覆盖，表现为「地图顶部黑一块」。所以用独立的偏移层 MapSlide。
##   2. 平移期间必须把地图贴图的过滤从 NEAREST 临时换成 LINEAR ——
##      MapSprite 是 3000×2400 缩到 0.36 倍，nearest 在亚像素位移下会逐像素跳变，
##      看起来就是「地图一块一块裂开、有缝」。动画结束再切回原值，静态观感不变。

const SIDEBAR_DELAY := 0.26
const MAP_FLY_TIME := 0.82
const MAP_FLY_FROM := Vector2(-1180.0, 0.0)

var _map_sprite: Sprite2D = null
var _saved_filter := 1


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var root := get_parent()
	if root == null:
		return
	var map_slide := root.get_node_or_null("View/MapArea/MapSlide") as Node2D
	var map_layer := root.get_node_or_null("View/MapArea/MapSlide/MapLayer") as Node2D
	_map_sprite = root.get_node_or_null("View/MapArea/MapSlide/MapLayer/MapSprite") as Sprite2D
	var map_area := root.get_node_or_null("View/MapArea") as Control
	var sidebar := root.get_node_or_null("View/Sidebar")

	# ⚠ MapArea 是 PanelContainer，默认主题会画一层面板底色 + 边框；
	#   地图平移时它不动，就会在地图边缘露出一条竖线（看起来像「竖向裂缝」）。直接清空皮肤。
	if map_area != null:
		map_area.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	# 侧栏与地图**同时**开始进场（面板背景延迟 0.26 s 展开，然后内容依次出现）。
	# ⚠ 必须在 await 地图飞入之前调用：否则侧栏会在地图动画期间一直"卡着不动"，
	#   而它的兜底逻辑会先把动画播掉一半，看起来像播了两次。
	if sidebar != null and sidebar.has_method("play_enter"):
		sidebar.call("play_enter", SIDEBAR_DELAY)

	if map_slide != null:
		map_slide.position = MAP_FLY_FROM
		if _map_sprite != null:
			_saved_filter = _map_sprite.texture_filter
			_map_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		if map_layer != null:
			map_layer.modulate = Color(1, 1, 1, 0.0)
			UiKit.tween_float(self, map_layer, "modulate:a", 1.0, 0.5, &"out_quad")

		var tw := UiKit.tween_vec2(self, map_slide, "position", Vector2.ZERO, MAP_FLY_TIME, &"out_cubic")
		await tw.finished
		_restore_filter()
	elif map_layer != null:
		# 没有偏移层时退化为纯淡入，保证绝不会影响布局
		map_layer.modulate = Color(1, 1, 1, 0.0)
		UiKit.tween_float(self, map_layer, "modulate:a", 1.0, 0.5, &"out_quad")


## 恢复地图贴图原来的过滤方式（静态时保持原来的锐利观感）
func _restore_filter() -> void:
	if _map_sprite != null and is_instance_valid(_map_sprite):
		_map_sprite.texture_filter = _saved_filter as CanvasItem.TextureFilter


func _exit_tree() -> void:
	_restore_filter()
