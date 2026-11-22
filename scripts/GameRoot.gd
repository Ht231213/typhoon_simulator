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
@onready var zoom_out_button: Button = %ZoomOutButton
@onready var zoom_in_button: Button = %ZoomInButton

## 调试面板（F6）。运行到 _ready 时才会被实例化出来。
var debug_panel: Node = null
## 海区探针：跟随鼠标显示所指海区的信息。由 T 键（海温查看模式）一并开关。
var cell_probe: Node = null

## 地图缩放档位（2026-11-22 用户要求）：1x = 适应窗口看全图；≥2x 跟随选中台风
const ZOOM_LEVELS: Array[float] = [1.0, 2.0, 4.0, 8.0]
## 当前缩放档位下标（默认 0 = 1x，不写盘）
var _zoom_index := 0
## 「适应窗口」时地图的 scale（窗口尺寸变了要重算）
var _fit_scale := 1.0


func _ready() -> void:
	MusicManager.play_sim()
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

	# 海区探针：跟随鼠标显示所指海区的信息（由 T 键海温查看模式一并开关）
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

	# 地图缩放 / 跟随（2026-11-22）：侧栏底部 − / ＋ 两个按钮
	zoom_out_button.pressed.connect(_on_zoom_step.bind(-1))
	zoom_in_button.pressed.connect(_on_zoom_step.bind(1))
	set_process(true)                 # ≥2x 时每帧把镜头对准选中的台风

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
			# 海温查看模式：**色块 + 鼠标探针，一开全给**（用户 2026-10-17 决定）。
			#   色块 = 192 格的海温/气压颜色叠层，一眼看分布
			#   探针 = 鼠标指哪看哪，显示该格的具体数值和冷水坑/地形等状态
			var sst_view_on: bool = not field.show_field
			field.show_field = sst_view_on
			if cell_probe != null:
				if sst_view_on:
					cell_probe.open()
				else:
					cell_probe.close()
			field.queue_redraw()
			sidebar._on_notice("海温查看：%s（色块 + 探针）" % ("开" if sst_view_on else "关"))
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


## 现在能不能直接在地图上开始标路径点（点地图自动进入投放环节用）。
## 条件与侧栏「添加台风」按钮保持一致，避免两边判定不一致。
## ⑤A-1 多台风：已有台风时**也能继续添加**（只受上限/风季/冷却限制）。
func _can_auto_place() -> bool:
	if sim == null:
		return false
	if sim.season_over:
		return false
	if sim.paused:
		return false
	return sim.can_deploy_now()


# ============================ 地图缩放 / 跟随（2026-11-22） ============================
# 手写镜头：沿用 map_layer.scale / position（不引入 Camera2D，UI 不受影响）。
#   1x        = 适应窗口看全图（原有行为）
#   2x ~ 8x   = 只放大地图，并把「侧栏选中的那场台风」放到 MapArea 中心；
#               没有活跃台风时保持地图中心。
# 跟随到地图边缘时把 position 夹紧，保证地图边不会缩进 MapArea（不露深色底）。

## 窗口/地图区尺寸变了：重算「适应窗口」scale，再按当前档位套用
func _relayout() -> void:
	var avail := map_area.size
	if avail.x <= 1.0 or avail.y <= 1.0:
		return
	_fit_scale = minf(avail.x / Const.MAP_W, avail.y / Const.MAP_H)
	_apply_view()


## 按当前缩放档位计算 map_layer 的 scale / position
func _apply_view() -> void:
	var avail := map_area.size
	if avail.x <= 1.0 or avail.y <= 1.0:
		return
	var zoom: float = ZOOM_LEVELS[_zoom_index]
	var s := _fit_scale * zoom
	var map_size := Vector2(Const.MAP_W, Const.MAP_H) * s
	var pos := (avail - map_size) * 0.5          # 默认：地图居中
	if zoom > 1.0001:
		var focus := sim.focus_storm()
		if focus != null:
			# 把选中台风的中心放到 MapArea 中心；再去夹紧，保证不露出地图外
			pos = avail * 0.5 - focus.current_world_position() * s
		pos = _clamp_view(pos, map_size, avail)
	map_layer.scale = Vector2(s, s)
	map_layer.position = pos
	_refresh_zoom_buttons()


## 放大时夹紧镜头：地图比可视区大的轴，保证地图边缘不进入 MapArea
func _clamp_view(pos: Vector2, map_size: Vector2, avail: Vector2) -> Vector2:
	if map_size.x >= avail.x:
		pos.x = clampf(pos.x, avail.x - map_size.x, 0.0)
	else:
		pos.x = (avail.x - map_size.x) * 0.5
	if map_size.y >= avail.y:
		pos.y = clampf(pos.y, avail.y - map_size.y, 0.0)
	else:
		pos.y = (avail.y - map_size.y) * 0.5
	return pos


func _on_zoom_step(dir: int) -> void:
	_zoom_index = clampi(_zoom_index + dir, 0, ZOOM_LEVELS.size() - 1)
	_apply_view()
	var zoom: float = ZOOM_LEVELS[_zoom_index]
	if zoom <= 1.0:
		sidebar._on_notice("地图缩放：1x（适应窗口看全图）")
	else:
		var focus := sim.focus_storm()
		sidebar._on_notice("地图缩放：%dx（跟随 %s）" % [
			int(zoom), focus.number_text() if focus != null else "地图中心"])


func _refresh_zoom_buttons() -> void:
	zoom_out_button.disabled = _zoom_index <= 0
	zoom_in_button.disabled = _zoom_index >= ZOOM_LEVELS.size() - 1


## 放大状态下每帧更新跟随目标（选中台风会移动 / 也会被切换）
func _process(_delta: float) -> void:
	if _zoom_index > 0:
		_apply_view()


# ============================ 风季结束 ============================

func _on_season_finished() -> void:
	var saved := Game.commit_session_to_save()
	results_panel.show_results(saved)
	sidebar._on_notice("风季结束，成绩已写入 %s" % Game.save_path_absolute())



func _exit_tree() -> void:
	# 离开模拟场景 → 停模拟音乐（标题画面会自己播 music.titlescreen）
	MusicManager.stop_sim()
