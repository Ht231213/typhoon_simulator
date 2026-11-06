extends Node
## [autoload: AndroidCompat] 安卓分支专用适配层（安全区 / 返回键 / 全屏）。
##
## 只在 `android` 分支注册（project.godot 的 [autoload] 段）。
## 桌面运行同样安全：安全区 inset 全 0，返回键通知不会触发，全屏强制被跳过。
##
## 安全区：
##   `DisplayServer.get_display_safe_area()` 给的是**物理像素**，
##   这里换算成「逻辑像素」inset 后叠加到注册过的 MarginContainer 四边，
##   避免刘海/挖孔/圆角挡住按钮。窗口尺寸或旋转变化时自动重算。
##
## 返回键：
##   project.godot 设 `application/config/quit_on_go_back=false`，
##   安卓返回键改由这里分发：
##     ① 关掉最上层的弹窗（ACE 排行榜 / 调整日期等 AcceptDialog）
##     ② 关掉可见的设置覆盖层
##     ③ 暂停中 → 恢复
##     ④ 游戏中 → 弹出暂停菜单
##     ⑤ 主菜单 → **第一次只提示「再返回一次退出应用」，2 秒内再按才退出**
##   依赖节点分组：settings_overlay / pause_layer / game_root。
##
## 全屏：
##   导出预设已开 `screen/immersive_mode`（_cl_ 里带 --fullscreen）+
##   `screen/edge_to_edge`（内容铺到系统栏下面）。
##   这里再兜底调用 window_set_mode(FULLSCREEN)，并在回到前台/获得焦点时重试，
##   因为部分机型启动后会把状态栏重新显示出来。

const GROUP_SETTINGS_OVERLAY := "settings_overlay"
const GROUP_PAUSE_LAYER := "pause_layer"
const GROUP_GAME_ROOT := "game_root"

## 主菜单「再返回一次退出」的确认窗口（秒）
const QUIT_CONFIRM_SECONDS := 2.0
const QUIT_HINT_TEXT := "再返回一次退出应用"
## 全屏兜底重试间隔（秒）
const FULLSCREEN_RETRY_SECONDS := 2.0

## 测试钩子：桌面截图/验证时可手动设成想模拟的安全区 inset（逻辑像素）。
## 任一分量 < 0 = 不启用（默认），按真实 DisplayServer 计算。
static var test_insets := Vector4(-1, -1, -1, -1)
## 测试钩子：true 时不真的退出（只累加 quit_count_for_test），供 headless 自检
static var test_mode := false

var quit_count_for_test := 0

## [{node: MarginContainer, base: Vector4}] 已注册的安全区容器
var _safe_entries: Array = []
## 主菜单返回键「确认退出」状态
var _quit_pending := false
var _quit_deadline_msec := 0
## 顶部提示条（「再返回一次退出应用」）
var _toast_layer: CanvasLayer = null
var _toast_label: Label = null
var _toast_left := 0.0
var _fullscreen_retry_left := 0.0


func _ready() -> void:
	# 暂停（get_tree().paused）时返回键仍要能用
	process_mode = Node.PROCESS_MODE_ALWAYS
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_size_changed):
		vp.size_changed.connect(_on_viewport_size_changed)
	_apply_safe_areas()
	if is_android():
		_setup_toast()
		_apply_android_fullscreen()
	set_process(true)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			_handle_back()
		NOTIFICATION_APPLICATION_RESUMED:
			# 从后台回来（部分机型会把状态栏重新显示）→ 重新进全屏
			_apply_android_fullscreen()
		NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_apply_android_fullscreen()


func _process(delta: float) -> void:
	# 提示条倒计时
	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0:
			_hide_toast()
	# 「再返回一次退出」2 秒没再按就作废
	if _quit_pending:
		var scene := get_tree().current_scene
		if Time.get_ticks_msec() > _quit_deadline_msec or scene == null \
				or scene.name != "TitleScreen":
			_reset_quit_pending()
	# 全屏兜底：部分机型启动几秒后会把状态栏弹回来，定期确认
	if is_android():
		_fullscreen_retry_left -= delta
		if _fullscreen_retry_left <= 0.0:
			_fullscreen_retry_left = FULLSCREEN_RETRY_SECONDS
			_apply_android_fullscreen()


# ============================ 平台判断 ============================

func is_android() -> bool:
	return OS.has_feature("android")


func is_editor() -> bool:
	return OS.has_feature("editor")


# ============================ 全屏 ============================

## 安卓全屏兜底：请求全屏窗口模式。导出预设的 immersive_mode / edge_to_edge
## 负责真正的系统栏隐藏，这里只保证窗口模式是 FULLSCREEN（部分安卓机启动后会回退）。
func _apply_android_fullscreen() -> void:
	if not is_android():
		return
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
			or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


# ============================ 安全区 ============================

## 安全区 inset（逻辑像素，顺序 left / top / right / bottom）。桌面返回全 0。
func safe_insets() -> Vector4:
	if test_insets.x >= 0.0:
		return test_insets
	if not is_android():
		return Vector4.ZERO
	var win := DisplayServer.window_get_size()
	if win.x <= 0 or win.y <= 0:
		return Vector4.ZERO
	var screen := DisplayServer.screen_get_size()
	if screen.x <= 0 or screen.y <= 0:
		return Vector4.ZERO
	# 只有窗口≈屏幕（沉浸式全屏）时，屏幕坐标才能直接换算；分屏/小窗直接不处理
	if absi(screen.x - win.x) > 4 or absi(screen.y - win.y) > 4:
		return Vector4.ZERO
	var vp := get_viewport()
	var vis := vp.get_visible_rect().size if vp != null else Vector2(win)
	if vis.x <= 0.0 or vis.y <= 0.0:
		return Vector4.ZERO
	var sx := vis.x / float(win.x)
	var sy := vis.y / float(win.y)
	var safe: Rect2i = DisplayServer.get_display_safe_area()
	var left := float(safe.position.x) * sx
	var top := float(safe.position.y) * sy
	var right := float(screen.x - safe.position.x - safe.size.x) * sx
	var bottom := float(screen.y - safe.position.y - safe.size.y) * sy
	return Vector4(maxf(left, 0.0), maxf(top, 0.0), maxf(right, 0.0), maxf(bottom, 0.0))


## 把一个 MarginContainer 注册为「安全区容器」：
## 它**第一次**注册时的四边 margin 记作 base（存在节点 meta 上），之后自动叠加安全区 inset。
## 重复注册同一节点只更新引用、不会把已经叠加过 inset 的 margin 再当基准重复叠加。
const META_SAFE_BASE := "_android_safe_base"

func register_safe_area(margin: MarginContainer) -> void:
	if margin == null:
		return
	if not margin.has_meta(META_SAFE_BASE):
		margin.set_meta(META_SAFE_BASE, Vector4(
			float(margin.get_theme_constant("margin_left")),
			float(margin.get_theme_constant("margin_top")),
			float(margin.get_theme_constant("margin_right")),
			float(margin.get_theme_constant("margin_bottom"))))
	var base: Vector4 = margin.get_meta(META_SAFE_BASE)
	for e in _safe_entries:
		if e.get("node") == margin:
			e["base"] = base
			_apply_one(e)
			return
	_safe_entries.append({"node": margin, "base": base})
	_apply_one(_safe_entries[_safe_entries.size() - 1])


func _apply_one(entry: Dictionary) -> void:
	var node: MarginContainer = entry.get("node")
	if node == null or not is_instance_valid(node):
		return
	var ins := safe_insets()
	var b: Vector4 = entry.get("base", Vector4.ZERO)
	node.add_theme_constant_override("margin_left", int(roundf(b.x + ins.x)))
	node.add_theme_constant_override("margin_top", int(roundf(b.y + ins.y)))
	node.add_theme_constant_override("margin_right", int(roundf(b.z + ins.z)))
	node.add_theme_constant_override("margin_bottom", int(roundf(b.w + ins.w)))


func _apply_safe_areas() -> void:
	var i := _safe_entries.size() - 1
	while i >= 0:
		var e: Dictionary = _safe_entries[i]
		var n = e.get("node")
		if n == null or not is_instance_valid(n) or not (n as Node).is_inside_tree():
			_safe_entries.remove_at(i)
		else:
			_apply_one(e)
		i -= 1


func _on_viewport_size_changed() -> void:
	_apply_safe_areas()


# ============================ 返回键 ============================

func _first_in_group(group: String) -> Node:
	var nodes := get_tree().get_nodes_in_group(group)
	return nodes[0] if not nodes.is_empty() else null


## 安卓返回键分发：弹窗 → 设置覆盖层 → 取消暂停 → 暂停 → 主菜单两次确认退出。
func _handle_back() -> void:
	# ① 先关最上层的弹窗（ACE 排行榜 / 调整日期 / 任何 AcceptDialog）
	if _close_top_popup():
		_reset_quit_pending()
		return
	# ② 可见的设置覆盖层（约定：组内节点实现 close()，否则隐藏）
	for n in get_tree().get_nodes_in_group(GROUP_SETTINGS_OVERLAY):
		if not is_instance_valid(n):
			continue
		if n is CanvasItem and not (n as CanvasItem).visible:
			continue
		_reset_quit_pending()
		if n.has_method("close"):
			n.close()
			return
		if n is CanvasItem:
			(n as CanvasItem).visible = false
			return
	# ③ 整体暂停中 → 恢复
	if get_tree().paused:
		_reset_quit_pending()
		var pause_layer := _first_in_group(GROUP_PAUSE_LAYER)
		if pause_layer != null and pause_layer.has_method("resume"):
			pause_layer.resume()
			return
		get_tree().paused = false
		return
	# ④ 游戏中 → 弹出暂停菜单
	var scene := get_tree().current_scene
	if scene != null and scene.is_in_group(GROUP_GAME_ROOT):
		_reset_quit_pending()
		var pause_layer2 := _first_in_group(GROUP_PAUSE_LAYER)
		if pause_layer2 != null and pause_layer2.has_method("pause"):
			pause_layer2.pause()
			return
	# ⑤ 主菜单：第一次只提示「再返回一次退出应用」，2 秒内再按才退出
	if scene != null and scene.name == "TitleScreen":
		if _quit_pending:
			_quit_game()
		else:
			_quit_pending = true
			_quit_deadline_msec = Time.get_ticks_msec() + int(QUIT_CONFIRM_SECONDS * 1000.0)
			_show_toast(QUIT_HINT_TEXT)
		return
	# 其它（理论上没有）→ 退出
	_quit_game()


## 关掉当前场景里最上层的可见 Window/AcceptDialog（返回键用）。
func _close_top_popup() -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var wins := scene.find_children("*", "Window", true, false)
	for i in range(wins.size() - 1, -1, -1):
		var w := wins[i] as Window
		if w == null or not w.visible:
			continue
		w.hide()
		return true
	return false


func is_quit_pending() -> bool:
	return _quit_pending


func is_toast_visible() -> bool:
	return _toast_label != null and _toast_label.visible


func _quit_game() -> void:
	_reset_quit_pending()
	if test_mode:
		quit_count_for_test += 1
		return
	get_tree().quit()


func _reset_quit_pending() -> void:
	_quit_pending = false
	_quit_deadline_msec = 0
	_toast_left = 0.0
	_hide_toast()


# ============================ 顶部提示条 ============================

func _setup_toast() -> void:
	if _toast_layer != null:
		return
	_toast_layer = CanvasLayer.new()
	_toast_layer.name = "AndroidCompatToast"
	_toast_layer.layer = 128
	add_child(_toast_layer)
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_layer.add_child(root)
	_toast_label = Label.new()
	_toast_label.name = "Hint"
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast_label.add_theme_font_size_override("font_size", 30)
	_toast_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.96))
	_toast_label.add_theme_constant_override("outline_size", 10)
	_toast_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_toast_label)
	_toast_label.anchor_left = 0.0
	_toast_label.anchor_right = 1.0
	_toast_label.anchor_top = 1.0
	_toast_label.anchor_bottom = 1.0
	_toast_label.offset_left = 0.0
	_toast_label.offset_right = 0.0
	_toast_label.offset_top = -170.0
	_toast_label.offset_bottom = -100.0
	_toast_label.visible = false


func _show_toast(text: String) -> void:
	if _toast_label == null:
		return
	_toast_label.text = text
	_toast_label.visible = true
	_toast_left = QUIT_CONFIRM_SECONDS + 0.5


func _hide_toast() -> void:
	if _toast_label != null:
		_toast_label.visible = false
