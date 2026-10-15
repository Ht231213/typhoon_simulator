extends Control
## 主游戏场景的装配脚本。
##
## 职责：
##   ① 按窗口大小把地图等比缩放并居中（窗口可缩放，不锁死尺寸）
##   ② 把 WPAC.png 的陆地掩膜采样给海温叠加层
##   ③ 按模式设置时间倍速（自动模式跑快一些）
##   ④ 风季结束时弹结果面板，并把成绩写进存档

const GRID_OVERLAY_PATH := "MapLayer/GridOverlay"

@onready var map_area: PanelContainer = %MapArea
@onready var map_layer: Node2D = %MapLayer
@onready var map_sprite: Sprite2D = %MapSprite
@onready var field: OceanField = %GridOverlay
@onready var path_layer: PathLayer = %PathLayer
@onready var path_editor: Control = %PathEditor
@onready var sim: TyphoonSim = %TyphoonSim
@onready var sidebar: PanelContainer = %Sidebar
@onready var results_panel: Control = %ResultsPanel

## 调试面板（F6）。运行到 _ready 时才会被实例化出来。
var debug_panel: Node = null
## 海区探针（F7）：跟随鼠标显示所指海区的信息。
var cell_probe: Node = null

var _scale := 1.0


func _ready() -> void:
	# ESC 全暂停（get_tree().paused）时界面仍要能操作，所以本场景常驻处理
	process_mode = Node.PROCESS_MODE_ALWAYS

	# ⚠ 子节点会**继承** ALWAYS —— 那样 ESC 全暂停对 TyphoonSim / PathEditor 就无效了
	#    （这就是「ESC 暂停菜单不暂停模拟」的根因）。把该被暂停的两项显式设回 PAUSABLE。
	sim.process_mode = Node.PROCESS_MODE_PAUSABLE
	path_editor.process_mode = Node.PROCESS_MODE_PAUSABLE

	# 点地图自动进入投放环节（不用先去侧栏点「添加台风」）
	path_editor.can_auto_place = _can_auto_place

	# 调试面板：查看/修改运算输入与台风数值（F6 开关）
	debug_panel = load("res://DebugPanel.tscn").instantiate()
	add_child(debug_panel)
	debug_panel.setup(sim, field)

	# 海区探针：跟随鼠标显示所指海区的信息（F7 开关）
	cell_probe = load("res://CellInspector.tscn").instantiate()
	add_child(cell_probe)
	cell_probe.setup(map_layer, field, sim)

	# 地图容器不吃鼠标事件，点击交给 PathEditor 处理
	# （MapLayer 是 Node2D，没有 mouse_filter 属性；能用的是它下面的 PathLayer，已在场景里设为 IGNORE）
	map_area.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 陆地掩膜。
	# ⚠ WPAC_LAND.bmp 暂时**不启用**：它的投影/裁剪与 WPAC.png 不一致，
	#   实测把菲律宾海（146.75°E, 16.95°N）这类开阔洋面也判成陆地，
	#   台风北上时会被误判登陆、吃 -70 节/天的摩擦衰减，直接停止增强。
	#   等用户按 WPAC.png 的取景重导一份（PNG 透明掩膜）再打开。
	# 现在让它走地图像素启发式那条退路（浅海会被误判，但热带洋面基本正确）。
	field.build_land_mask(map_sprite.texture)

	path_editor.path_layer = path_layer
	path_editor.map_layer = map_layer          # 用于把点击位置换算成地图世界坐标
	# 路径点输入只由「投放环节」控制：玩家必须先点「添加台风」进入环节，
	# 才能在地图上标记路径点。退出环节后点击地图无效。

	sim.season_finished.connect(_on_season_finished)
	sim.notice.connect(func(t: String) -> void: pass)

	sidebar.visible = true
	results_panel.visible = false

	map_area.resized.connect(_relayout)
	get_viewport().size_changed.connect(_relayout)
	_relayout()

	if not sim.auto_mode:
		sidebar._on_notice("点「添加台风」进入投放环节，然后在地图上标记路径点")


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).keycode:
		KEY_G:
			# 调试：显示/隐藏 16x12 网格线，用来核对格子与地图是否对齐
			field.show_grid_lines = not field.show_grid_lines
			field.queue_redraw()
			sidebar._on_notice("网格线：%s" % ("开" if field.show_grid_lines else "关"))
			get_viewport().set_input_as_handled()
		KEY_T:
			# 显示/隐藏整个海温（气压）叠加层——192 个格子全部开关
			field.show_field = not field.show_field
			field.queue_redraw()
			sidebar._on_notice("海温区块显示：%s" % ("开" if field.show_field else "关"))
			get_viewport().set_input_as_handled()
		KEY_R:
			# 重新采样陆地掩膜。⚠ 掩膜信息是 12 行 ASCII 图，
			# 绝对不能塞进侧边栏的提示标签（会把整个侧栏挤出窗口），只打到控制台。
			field.build_land_mask(map_sprite.texture)
			print(field.land_mask_info())
			sidebar._on_notice("已重新采样陆地掩膜（详细结果见控制台日志）")
			get_viewport().set_input_as_handled()
		KEY_F3:
			# 调试模式：把所有关键数值打到控制台，同时在侧边栏给一句短提示
			print(sim.debug_text())
			sidebar._on_notice("已输出调试信息到控制台（F3）")
			get_viewport().set_input_as_handled()
		KEY_F4:
			# 调试：循环切换掩膜可视化，用来人工比对掩膜到底贴不贴地图
			field.cycle_mask_view()
			sidebar._on_notice("掩膜显示：%s（再按 F4 切换）" % field.mask_view_name())
			get_viewport().set_input_as_handled()
		KEY_F5:
			# 调试：高亮「游戏实际判定的陆地格子」——物理真正用的就是这份
			field.show_land_cells = not field.show_land_cells
			field.queue_redraw()
			if field.show_land_cells:
				var n := 0
				for i in Const.CELL_COUNT:
					if field.land_mask[i] == 1:
						n += 1
				sidebar._on_notice("陆地格子（橙框）：%d / %d 格" % [n, Const.CELL_COUNT])
			else:
				sidebar._on_notice("陆地格子：关")
			get_viewport().set_input_as_handled()
		KEY_F6:
			# 调试面板：查看/修改运算输入与台风数值
			if debug_panel != null:
				debug_panel.toggle()
			get_viewport().set_input_as_handled()
		KEY_F7:
			# 海区探针：跟随鼠标显示所指海区的信息（行列/编号/海温/季节增幅/冷水坑）
			if cell_probe != null:
				cell_probe.toggle()
				sidebar._on_notice("海区探针：%s" % ("开（F7 关）" if cell_probe.visible else "关"))
			get_viewport().set_input_as_handled()


## 现在能不能直接在地图上开始标路径点（点地图自动进入投放环节用）。
## 条件与侧栏「添加台风」按钮保持一致，避免两边判定不一致。
func _can_auto_place() -> bool:
	if sim == null:
		return false
	if sim.season_over or sim.active_storm != null:
		return false
	if sim.paused:
		return false
	return sim.can_deploy_now()


## 地图等比缩放并在地图区域内居中
func _relayout() -> void:
	var avail := map_area.size
	if avail.x <= 1.0 or avail.y <= 1.0:
		return
	_scale = minf(avail.x / Const.MAP_W, avail.y / Const.MAP_H)
	map_layer.scale = Vector2(_scale, _scale)
	map_layer.position = (avail - Vector2(Const.MAP_W, Const.MAP_H) * _scale) * 0.5


# ============================ 风季结束 ============================

func _on_season_finished() -> void:
	var saved := Game.commit_session_to_save()
	results_panel.show_results(saved)
	sidebar._on_notice("风季结束，成绩已写入 %s" % Game.save_path_absolute())
