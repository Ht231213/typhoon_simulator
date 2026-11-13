extends Control
## 2.0 启动动画。音乐取自录屏（一个文件同时当开屏曲和主界面循环）。
##
## 卡点依据 tools/make_music_from_recording.py 的响度分析：
##   这段音乐 0–8 s 是长渐强（-63 → -18 dB），**8.0 s 整体跳上 -11 dB**，
##   16 s 再到 -7 dB。所以「爆发点」取 8.0 s —— 那一刻才真的轰起来，
##   5.77 s 只是一个小瞬态（音量还很轻），放白光会显得「闪早了」。
##
## 时间轴（单位 = 音乐播放位置）：
##   0.00 – 0.85 s  全黑
##   0.85 – 3.20 s  缓出「Hetao|Minedsa」署名 + 细线长出来
##   3.25 – 3.85 s  署名淡出
##   3.60 – 6.60 s  图标 + 标题回弹浮现
##   4.20 s         预加载主界面（纹理 + 场景 + shader 全部提前跑一遍，闪光时不卡）
##   8.00 s         爆发：白光炸开 + 冲击环
##   8.00 – 9.20 s  白光散开，主界面浮出
##
## 任意键 / 点击：跳到爆发前一刻

## 卡点：这段音乐前 40 秒里最强的那次瞬态（tools/make_music_from_recording.py 算出来的）
const IMPACT_TIME := 8.0
## 音频设备有延迟时，用这个值微调（正数 = 视觉往后推）
const IMPACT_OFFSET := 0.0

const BGM_PATH := "res://assets/audio/boot_theme.wav"
const NEXT_SCENE := "res://TitleScreen.tscn"
const SKY_TEXTURE := "res://assets/images/2630_Champi.jpg"

const T_SIGN_IN := 0.85
const T_SIGN_OUT := 3.25
const T_MAIN_IN := 3.60

var _elapsed := 0.0
var _black: ColorRect = null
var _flash: ColorRect = null
var _sign: Label = null
var _sign_rule: ColorRect = null
var _title: Label = null
var _sub: Label = null
var _icon: Control = null
var _ring: Control = null
var _skip_hint: Label = null
## 预热出来的主界面实例（闪白前就建好，白光散去时直接亮出来）
var _title_inst: Node = null
## 预热要跑两帧：第 1 帧建场景 + 上传纹理，第 2 帧把临时状态收回去
var _warm_frames := 0

var _sign_done := false
var _sign_out_done := false
var _main_done := false
var _impact_done := false
var _finished := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	# 异步预载云图（真正的同步加载放在第一帧的 _warm_up 里，那时屏幕还全黑）
	if ResourceLoader.exists(SKY_TEXTURE):
		ResourceLoader.load_threaded_request(SKY_TEXTURE)
	# 交给 MusicManager 播：它是 autoload，换场景不打断，主界面接着听
	if ResourceLoader.exists(BGM_PATH):
		MusicManager.play_boot()


# ------------------------------ 构建 ------------------------------

func _build() -> void:
	_black = ColorRect.new()
	_black.name = "Black"
	_black.color = Color(0, 0, 0, 1)
	_black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_black)

	_sign = UiKit.make_label("Hetao|Minedsa", 30, Color(1, 1, 1, 1))
	_sign.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sign.size = Vector2(640.0, 48.0)
	_sign.position = Vector2(320.0, 330.0)
	_sign.modulate.a = 0.0
	add_child(_sign)

	_sign_rule = ColorRect.new()
	_sign_rule.color = Color(1, 1, 1, 0.55)
	_sign_rule.size = Vector2(0.0, 1.0)
	_sign_rule.position = Vector2(640.0, 392.0)
	_sign_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sign_rule.modulate.a = 0.0
	add_child(_sign_rule)

	_icon = SpiralIcon.new()
	_icon.name = "Icon"
	_icon.size = Vector2(132.0, 132.0)
	_icon.position = Vector2(574.0, 196.0)
	_icon.modulate.a = 0.0
	add_child(_icon)

	_title = UiKit.make_label("台风模拟", 60, Color(1, 1, 1, 1))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.size = Vector2(640.0, 80.0)
	_title.position = Vector2(320.0, 352.0)
	_title.modulate.a = 0.0
	add_child(_title)

	_sub = UiKit.make_label("T Y P H O O N   S I M U L A T O R", 12, Color(1, 1, 1, 0.6))
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub.size = Vector2(640.0, 20.0)
	_sub.position = Vector2(320.0, 436.0)
	_sub.modulate.a = 0.0
	add_child(_sub)

	_skip_hint = UiKit.make_label("任意键跳过", 12, Color(1, 1, 1, 0.22))
	_skip_hint.size = Vector2(160.0, 20.0)
	_skip_hint.position = Vector2(1092.0, 668.0)
	_skip_hint.modulate.a = 0.0
	add_child(_skip_hint)

	# 音乐出处（显眼声明：曲子是 Phigros 的开屏音乐）
	var music_credit := UiKit.make_label("BGM · Phigros OST  © Pigeon Games", 13, Color(1, 1, 1, 0.34))
	music_credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	music_credit.size = Vector2(520.0, 22.0)
	music_credit.position = Vector2(380.0, 664.0)
	music_credit.modulate.a = 0.0
	add_child(music_credit)
	UiKit.tween_float(self, music_credit, "modulate:a", 1.0, 0.9, &"out_quad", 1.1)

	_ring = ShockRing.new()
	_ring.name = "Ring"
	_ring.size = Vector2(1280.0, 720.0)
	add_child(_ring)

	_flash = ColorRect.new()
	_flash.name = "Flash"
	_flash.color = Color(1, 1, 1, 1)
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.modulate.a = 0.0
	_flash.z_index = 100
	add_child(_flash)


# ------------------------------ 时间轴 ------------------------------

func _process(delta: float) -> void:
	if _finished:
		return
	# 第一帧就把所有要用的东西加载完（此时屏幕上只有纯黑，卡了也看不见）
	if _warm_frames < 2:
		_warm_up(_warm_frames)
		_warm_frames += 1

	var pos := MusicManager.boot_position()
	if pos >= 0.0:
		# 用音乐位置当时间轴：白光一定落在鼓点上
		_elapsed = pos
	else:
		# 没有音频设备时退回真实时间，动画照样能走完
		_elapsed += delta

	if not _sign_done and _elapsed >= T_SIGN_IN:
		_sign_done = true
		_sign_in()
	if not _sign_out_done and _elapsed >= T_SIGN_OUT:
		_sign_out_done = true
		_sign_out()
	if not _main_done and _elapsed >= T_MAIN_IN:
		_main_done = true
		_main_in()
	if not _impact_done and _elapsed >= IMPACT_TIME + IMPACT_OFFSET:
		_impact_done = true
		_impact()


func _sign_in() -> void:
	# 署名：单独调过的参数 —— 0.95 s 淡入（in_out，两头都软），上浮只有 14 px
	_sign.position = Vector2(320.0, 344.0)
	UiKit.tween_float(self, _sign, "modulate:a", 1.0, 0.95, &"in_out")
	UiKit.tween_vec2(self, _sign, "position", Vector2(320.0, 330.0), 1.05, &"out_cubic")
	# 细线：从中间往两边展开（先快后停），比文字晚 0.3 s 起
	UiKit.tween_float(self, _sign_rule, "modulate:a", 1.0, 0.6, &"out_cubic", 0.30)
	UiKit.tween_float(self, _sign_rule, "size:x", 132.0, 0.85, &"out_cubic", 0.30)
	UiKit.tween_float(self, _sign_rule, "position:x", 574.0, 0.85, &"out_cubic", 0.30)
	UiKit.tween_float(self, _skip_hint, "modulate:a", 1.0, 0.7, &"out_quad", 0.5)


func _sign_out() -> void:
	# 淡出统一走 out_quad：先掉得快、尾部收得干净，不留一层灰影
	UiKit.tween_float(self, _sign, "modulate:a", 0.0, 0.42, &"out_quad")
	UiKit.tween_float(self, _sign_rule, "modulate:a", 0.0, 0.36, &"out_quad")
	UiKit.tween_vec2(self, _sign, "position", Vector2(320.0, 306.0), 0.5, &"in_cubic")


func _main_in() -> void:
	# 图标：0.85 → 1.0 放大，1.15 s 落位（out_cubic：起步快、尾巴软，没有回弹）
	_icon.scale = Vector2(0.85, 0.85)
	_icon.pivot_offset = _icon.size * 0.5
	_icon.position.y = 214.0
	UiKit.tween_float(self, _icon, "modulate:a", 1.0, 0.95, &"out_quad", 0.05)
	UiKit.tween_vec2(self, _icon, "scale", Vector2(1.0, 1.0), 1.15, &"out_cubic")
	UiKit.tween_float(self, _icon, "position:y", 196.0, 1.15, &"out_cubic")

	# 标题：晚 0.15 s 起，0.9 s 落位，位移 16 px
	_title.position.y = 368.0
	UiKit.tween_float(self, _title, "modulate:a", 1.0, 0.9, &"out_quad", 0.15)
	UiKit.tween_float(self, _title, "position:y", 352.0, 1.0, &"out_cubic", 0.15)
	UiKit.tween_float(self, _sub, "modulate:a", 0.9, 0.85, &"out_quad", 0.45)


# ------------------------------ 预热 ------------------------------

## 第 1 帧：同步加载云图 + 实例化主界面（shader 编译、纹理上传都在这一步，
## 主界面被临时摆成全尺寸可见但 alpha 0.02 —— 视觉上全黑，实际已经画过一遍）。
## 第 2 帧：把临时状态收回去，恢复正常黑场。
func _warm_up(frame: int) -> void:
	if _finished:
		return
	if frame == 0:
		_prewarm()
		# 把本场景的文字/图标也先画一遍（字体字形缓存、自绘管线预热）
		for n in [_sign, _sign_rule, _title, _sub, _icon, _skip_hint]:
			if n != null:
				n.modulate.a = 0.02
		# 让云图真的被采样一次（reveal=0 → 整块可见），下一帧再收回去
		if _title_inst != null:
			var bd = _title_inst.get("_backdrop")
			if bd != null and bd.has_method("set_reveal"):
				bd.call("set_reveal", 0.0)
	else:
		for n in [_sign, _sign_rule, _title, _sub, _icon, _skip_hint]:
			if n != null:
				n.modulate.a = 0.0
		if _title_inst != null:
			var bd = _title_inst.get("_backdrop")
			if bd != null and bd.has_method("set_reveal"):
				bd.call("set_reveal", 1.0)


## 载入并实例化主界面（只在第一帧调用一次）
func _prewarm() -> void:
	if _title_inst != null:
		return
	# 同步读一次云图，确保纹理已经在显存里
	if ResourceLoader.exists(SKY_TEXTURE):
		load(SKY_TEXTURE)
	var packed: PackedScene = load(NEXT_SCENE)
	if packed == null:
		push_error("找不到主界面场景：" + NEXT_SCENE)
		return
	var host := get_parent()
	_title_inst = packed.instantiate()
	_title_inst.set("auto_intro", false)
	host.add_child(_title_inst)
	# 白光必须压在它上面
	host.move_child(self, host.get_child_count() - 1)
	# 几乎不可见但仍在绘制（alpha 0 才会被引擎跳过绘制）
	_title_inst.modulate.a = 0.02


# ------------------------------ 爆发 ------------------------------

func _impact() -> void:
	_finished = true
	UiKit.tween_float(self, _skip_hint, "modulate:a", 0.0, 0.2, &"in_cubic")

	# 白光：0.07 s 冲到全白，冲击环同时炸开
	var tw := UiKit.tween_float(self, _flash, "modulate:a", 1.0, 0.07, &"out_expo")
	_ring.call("burst")
	tw.tween_callback(_spawn_next)


func _spawn_next() -> void:
	if _title_inst == null:
		_prewarm()
	if _title_inst == null:
		return
	# 白光还盖着，把主界面亮出来并开始它的进场
	_title_inst.modulate.a = 1.0
	get_tree().current_scene = _title_inst
	if _title_inst.has_method("play_intro"):
		_title_inst.call("play_intro")

	await get_tree().create_timer(0.10).timeout
	UiKit.tween_float(self, _black, "modulate:a", 0.0, 0.5, &"in_out")
	UiKit.tween_float(self, _title, "modulate:a", 0.0, 0.28, &"out_quad")
	UiKit.tween_float(self, _sub, "modulate:a", 0.0, 0.28, &"out_quad")
	UiKit.tween_float(self, _icon, "modulate:a", 0.0, 0.28, &"out_quad")
	# 白光散开：out_cubic 单调下落（先快后缓），不会出现「亮一下又暗再亮」
	var fade := UiKit.tween_float(self, _flash, "modulate:a", 0.0, 0.85, &"out_cubic")
	await fade.finished
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if _finished:
		return
	var skip := false
	if event is InputEventKey and event.pressed and not event.echo:
		skip = true
	elif event is InputEventMouseButton and event.pressed:
		skip = true
	elif event is InputEventJoypadButton and event.pressed:
		skip = true
	if skip:
		MusicManager.seek_title(maxf(IMPACT_TIME - 0.08, 0.0))
		_sign_done = true
		_sign_out_done = true
		_main_done = true
		_sign.modulate.a = 0.0
		_sign_rule.modulate.a = 0.0
		_title.modulate.a = 1.0
		_sub.modulate.a = 0.8
		_icon.modulate.a = 1.0
		_prewarm()
		get_viewport().set_input_as_handled()


# ------------------------------ 自绘部分 ------------------------------

## 单色台风图标：三条螺旋臂 + 风眼，缓慢自转
class SpiralIcon:
	extends Control
	var spin := 0.0

	func _process(delta: float) -> void:
		spin += delta * 0.45
		queue_redraw()

	func _draw() -> void:
		var center := size * 0.5
		var r_max := minf(size.x, size.y) * 0.5 - 6.0
		for arm in 3:
			var pts := PackedVector2Array()
			var n := 56
			for i in n:
				var t := float(i) / float(n - 1)
				var ang := spin + float(arm) * TAU / 3.0 + t * PI * 1.55
				var r := r_max * (0.16 + 0.84 * t)
				pts.append(center + Vector2.from_angle(ang) * r)
			draw_polyline(pts, Color(1, 1, 1, 0.9), 3.2, true)
		draw_circle(center, r_max * 0.13, Color(1, 1, 1, 0.95))


## 爆发瞬间的冲击环：r / alpha 都由 tween 推
class ShockRing:
	extends Control
	var r := 0.0
	var alpha := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func burst() -> void:
		r = 0.0
		alpha = 1.0
		set_process(true)
		# 环扩散：out_cubic 单调加速后收尾；亮度 out_quad 单调衰减
		UiKit.tween_float(get_parent(), self, "r", 1.0, 0.7, &"out_cubic")
		UiKit.tween_float(get_parent(), self, "alpha", 0.0, 0.8, &"out_quad")

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		if alpha <= 0.01:
			return
		var center := size * 0.5
		var radius := 40.0 + r * 760.0
		draw_arc(center, radius, 0.0, TAU, 96, Color(1, 1, 1, alpha * 0.55), 6.0, true)
		draw_arc(center, radius * 0.72, 0.0, TAU, 96, Color(1, 1, 1, alpha * 0.28), 3.0, true)
