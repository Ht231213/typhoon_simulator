class_name PathLayer
extends Node2D
## 台风路径、路径点、风圈与**台风图标**的绘制层。
##
## 1.2.1 起台风本体不再是「一个圆点 + 两圈弧」，而是用户素材库的**图标**：
##   · 内圈白盘静止、外圈云系刚体旋转（实测 300 帧 = 5.0 秒一圈 → 72°/s）
##   · 两张同尺寸贴图叠在同一位置；外圈转、内圈不转
##   · 方案/贴图由 `IconScheme` 负责查找与回退（缺档→默认方案→generic）
##   · 找不到任何贴图时**回退到原来的程序化圆点**，不会出现空图标
##
## 风圈（34 kt 风圈 R34）压在图标的**下层**（本层 `_draw()` 永远在子 Sprite 下面），
## 半径按「物理 km → 世界像素」换算，不再用原来的 140 像素拍脑袋值。
##
## 坐标：世界坐标（地图像素，原点在左上角）。

const IconSchemeLoader := preload("res://scripts/IconScheme.gd")

## 图标世界直径的**兜底值**（方案的 scheme.cfg 没写 `world_diameter` 时用这个）。
## ⚠ 用户会**手动改这个数**，不要改成用地图格子尺寸推导出来的表达式。
const ICON_DIAMETER_FALLBACK := 54.0

# ------------------------- 已走过的路径 -------------------------
var points: Array[Vector2] = []
var intensities: Array[float] = []
## 每个路径点对应的变性阶段（Storm.Phase 的整数值）。
## 用来把变性后的那一段画成白色虚线。
var phases: Array[int] = []

# ------------------------- 台风当前位置 -------------------------
var live_position := Vector2.ZERO
var live_intensity := 0.0
var live_phase := 0                   ## Storm.Phase：0 热带 / 1 变性中 / 2 温带
## 隐藏时同步收掉图标（`TyphoonSim` 里有两处直接 `path.live_visible = false`）
var live_visible := false:
	set(value):
		live_visible = value
		if not value:
			_begin_icon_fade()

# ------------------------- 台风图标（1.2.1）-------------------------
## 当前图标方案名（= 方案名，A3：方案同时决定图标/特效/音效）
var icon_scheme := IconSchemeLoader.DEFAULT_SCHEME
## 「≥260 kt 白色阶段」的缓存值（判断设置是否真的变了）
var _bright_ext_cache := false
## 图标世界直径（像素）：方案 scheme.cfg 的 [meta] world_diameter
var icon_diameter := 54.0
## 外圈转速（度/秒）：方案 scheme.cfg 的 [meta] rotation_deg_per_sec
var icon_spin_deg := 72.0
## 旋转方向：北半球逆时针（Godot 2D 顺时针为正 → 取 −1）、南半球 +1
var icon_spin_dir := -1.0
var _icon_outer: Sprite2D = null
var _icon_inner: Sprite2D = null
## SMCY1.3 方案的视频图标播放器（用户 2026-10-30：改用视频，放弃两层 PNG 分解）
var _icon_video: VideoStreamPlayer = null
## 当前视频路径（换档才重新 load+play）
var _icon_video_path := ""
## 叠化用的「旧视频」播放器（换档时把旧视频留在它上面继续播，0.25 s 交叉淡出）
var _icon_video_prev: VideoStreamPlayer = null
## 叠化进度：1 = 全是旧视频，0 = 全是新视频
var _video_fade := 0.0
## 换档叠化时长（秒）
const VIDEO_FADE_SECONDS := 0.25
## 图标动画的周期（秒）：素材 300 帧 = 5.0 s，换档时按这个周期对齐相位
const VIDEO_PHASE_SECONDS := 5.0
## 当前视频的底色（不含 alpha），叠化时用它算两个播放器的 alpha
var _video_tint := Color.WHITE
## 色相/亮度调制的共享材质（参考工程 Scratch 的 COLOR/BRIGHTNESS 的 Godot 版）
var _icon_tint_material: ShaderMaterial = null
## 当前贴图对应的档位名（换档才重新读贴图）
var _icon_tier := ""
## 方案元数据是否已读（只读一次，避免每帧读 cfg）
var _icon_meta_ready := false

# ------------------------- 手动模式待投放的路径点 -------------------------
var pending_waypoints: Array[Vector2] = []

# ------------------------- 登陆特效（占位） -------------------------
## 每个元素 { "pos": Vector2, "kt": float, "age": float, "ttl": float }
var landfall_effects: Array[Dictionary] = []


func _ready() -> void:
	# 图标方案来自「设置 → 视频 → 台风图标方案」；缺素材时 IconScheme 自动回退 default
	icon_scheme = GameSettings.icon_scheme
	if icon_scheme == "":
		icon_scheme = IconSchemeLoader.DEFAULT_SCHEME
	GameSettings.changed.connect(_on_settings_changed)
	# 色相/亮度调制材质（参考工程的 Scratch COLOR / BRIGHTNESS 效果，1.2.0）
	_icon_tint_material = ShaderMaterial.new()
	_icon_tint_material.shader = preload("res://assets/icons/icon_tint.gdshader")
	# 两个 Sprite 作为子节点：子节点永远画在父节点 `_draw()` 之后 →
	# 风圈（父层绘制）自然在图标下面，不需要额外 z_index 打架。
	_icon_outer = Sprite2D.new()
	_icon_outer.name = "StormIconOuter"
	_icon_outer.z_index = 1
	_icon_outer.material = _icon_tint_material
	_icon_outer.visible = false
	add_child(_icon_outer)
	_icon_inner = Sprite2D.new()
	_icon_inner.name = "StormIconInner"
	_icon_inner.z_index = 2
	_icon_inner.material = _icon_tint_material
	_icon_inner.visible = false
	add_child(_icon_inner)

	# SMCY1.3 方案用**视频**播图标（用户 2026-10-30）：
	# 真实图标是「外圈两条弧线各自转速不同 + 中心两条弧线」→ PNG 两层分解丢掉了这些差异。
	# 视频素材见 assets/icons/smcy13/video/<档位>.ogv（19 档，合计约 4.2 MB）。
	_icon_video = VideoStreamPlayer.new()
	_icon_video.name = "StormIconVideo"
	_icon_video.z_index = 1
	_icon_video.loop = true
	_icon_video.expand = true
	# 视频是黑底无 alpha → 用「亮度→alpha」把黑底抠掉（同当年抽 PNG 的做法）
	var vmat := ShaderMaterial.new()
	vmat.shader = preload("res://assets/icons/video_key.gdshader")
	_icon_video.material = vmat
	_icon_video.visible = false
	add_child(_icon_video)

	# 叠化用的第二个播放器（换档时新旧两帧交叉淡入淡出，避免"跳一下"）
	_icon_video_prev = VideoStreamPlayer.new()
	_icon_video_prev.name = "StormIconVideoPrev"
	_icon_video_prev.z_index = 1
	_icon_video_prev.loop = true
	_icon_video_prev.expand = true
	var vmat_prev := ShaderMaterial.new()
	vmat_prev.shader = preload("res://assets/icons/video_key.gdshader")
	_icon_video_prev.material = vmat_prev
	_icon_video_prev.visible = false
	add_child(_icon_video_prev)


## 设置里换了方案 / 勾了「170kt+ 亮蓝扩展」→ 立刻刷新。
## `GameSettings.changed` 也会因音量/海温等触发，这里判一下「真的变了」再动。
func _on_settings_changed() -> void:
	var scheme := GameSettings.icon_scheme
	if scheme == "":
		scheme = IconSchemeLoader.DEFAULT_SCHEME
	var changed := scheme != icon_scheme or _bright_ext_cache != GameSettings.icon_bright_ext
	icon_scheme = scheme
	_bright_ext_cache = GameSettings.icon_bright_ext
	if not changed:
		return
	_icon_meta_ready = false      # 世界直径/转速也可能跟着方案变
	_icon_tier = ""
	# ⚠ 用户 2026-10-31 报的 bug：切方案后另一套还画在屏幕上（Default 圆环叠在视频图标上）
	#   → 切换时**强制**把不属于当前方案的那套彻底关掉（visible + stop），不能只改 texture
	_sync_icon_sets()
	if live_visible:
		_update_icon()


## 切方案后强制「只显示当前方案那一套」，另一套必须 visible=false（视频还要 stop）
func _sync_icon_sets() -> void:
	var use_video := _scheme_uses_video()
	if use_video:
		if _icon_outer != null:
			_icon_outer.visible = false
		if _icon_inner != null:
			_icon_inner.visible = false
		if _icon_video_prev != null:
			_icon_video_prev.stop()
			_icon_video_prev.visible = false
		_video_fade = 0.0
	else:
		if _icon_video != null:
			_icon_video.stop()
			_icon_video.visible = false
		if _icon_video_prev != null:
			_icon_video_prev.stop()
			_icon_video_prev.visible = false
		_video_fade = 0.0


func clear_track() -> void:
	points.clear()
	intensities.clear()
	phases.clear()
	live_visible = false
	landfall_effects.clear()
	queue_redraw()


func set_live_position(world_pos: Vector2, kt: float, phase := 0) -> void:
	live_position = world_pos
	live_intensity = kt
	live_phase = phase
	live_visible = true
	_update_icon()
	# 拉开足够距离才记录，避免高频调用堆出上万个点。
	# 阶段变化时要强制记一个点，否则虚线段起点会不准。
	var phase_changed := not phases.is_empty() and phases[-1] != phase
	if points.is_empty() or phase_changed or points[-1].distance_to(world_pos) > 6.0:
		points.append(world_pos)
		intensities.append(kt)
		phases.append(phase)
	queue_redraw()


# ------------------------- 手动路径点 -------------------------

func add_waypoint(world_pos: Vector2) -> void:
	pending_waypoints.append(world_pos)
	queue_redraw()


## 撤销最后一个路径点。返回是否真的删掉了一个。
func undo_waypoint() -> bool:
	if pending_waypoints.is_empty():
		return false
	pending_waypoints.remove_at(pending_waypoints.size() - 1)
	queue_redraw()
	return true


func clear_waypoints() -> void:
	pending_waypoints.clear()
	queue_redraw()


func waypoint_count() -> int:
	return pending_waypoints.size()


# ------------------------- 登陆特效 -------------------------

func spawn_landfall_effect(world_pos: Vector2, kt: float) -> void:
	landfall_effects.append({"pos": world_pos, "kt": kt, "age": 0.0, "ttl": 1.4})
	queue_redraw()


func _process(delta: float) -> void:
	# 外圈持续旋转：素材实测 300 帧 = 5.0 秒一圈（72°/s），内圈完全不动
	if _icon_outer != null and _icon_outer.visible:
		_icon_outer.rotation += deg_to_rad(icon_spin_deg) * delta * icon_spin_dir
	# 换档叠化（新旧两个视频 alpha 交叉，0.25 s）
	_advance_video_fade(delta)
	# 消散淡出（用 shader 的 fade 参数，代替参考工程的「消散」造型）
	if _icon_fading and (_icon_outer != null or _icon_video != null):
		_icon_fade = maxf(0.0, _icon_fade - delta / ICON_FADE_SECONDS)
		if _icon_tint_material != null:
			_icon_tint_material.set_shader_parameter("fade", _icon_fade)
		if _icon_video != null and _icon_video.visible:
			_apply_video_alpha()
		if _icon_fade <= 0.0:
			_hide_icon()
	# 登陆特效占位：到期就收掉
	if landfall_effects.is_empty():
		return
	var alive: Array[Dictionary] = []
	for fx in landfall_effects:
		fx["age"] = float(fx["age"]) + delta
		if float(fx["age"]) < float(fx["ttl"]):
			alive.append(fx)
	landfall_effects = alive
	queue_redraw()


# ------------------------- 图标 -------------------------

## 按当前强度/变性阶段刷新图标贴图与位置。换档才重新读贴图（贴图有缓存，很便宜）。
func _update_icon() -> void:
	if _icon_outer == null:
		return
	if not _icon_meta_ready:
		_icon_meta_ready = true
		# 图标世界直径：方案 cfg 优先，没写就用常量兜底（用户会手动改 ICON_DIAMETER_FALLBACK）
		icon_diameter = IconSchemeLoader.meta_float(
			IconSchemeLoader.KIND_ICONS, icon_scheme, "world_diameter", ICON_DIAMETER_FALLBACK)
		icon_spin_deg = IconSchemeLoader.meta_float(
			IconSchemeLoader.KIND_ICONS, icon_scheme, "rotation_deg_per_sec", 72.0)
		# 南北半球只差旋向：北半球**逆时针**、南半球顺时针。
		# ⚠ Godot 2D 的 rotation 正方向是**顺时针**（Y 轴向下）→ 北半球要取负值（B1 修）
		var lonlat := Const.lonlat_from_uv(Const.uv_from_world(live_position))
		icon_spin_dir = -1.0 if float(lonlat.y) >= 0.0 else 1.0

	# 变性完成后用「温带气旋」档且**不可逆**（参考工程：形态=1 之后不再按风档分类）；
	# 否则按 15 档形态（1.2.0，参考口径）
	var form: int = Const.FORM_EX if int(live_phase) >= 2 else Const.icon_form(live_intensity)
	# 视频方案（SMCY1.3）：直接播视频，不再用两层 PNG（用户 2026-10-30）
	if _scheme_uses_video():
		_update_icon_video(form)
		return
	_icon_video.visible = false
	var tier := IconSchemeLoader.tier_for_form(IconSchemeLoader.KIND_ICONS, icon_scheme, form)
	if tier != _icon_tier or _icon_outer.texture == null:
		_icon_tier = tier
		var tex := IconSchemeLoader.load_icon_textures(icon_scheme, tier)
		_icon_outer.texture = tex.get("outer")
		_icon_inner.texture = tex.get("inner")
	# 贴图缺失 → 隐藏图标，`_draw()` 会回退到原来的程序化圆点
	if _icon_outer.texture == null:
		_icon_outer.visible = false
		_icon_inner.visible = false
		return
	var side := float(_icon_outer.texture.get_width())
	var diameter := icon_diameter_for(icon_diameter, live_intensity)
	var k := diameter / side if side > 0.0 else 1.0
	_icon_outer.position = live_position
	_icon_outer.scale = Vector2(k, k)
	_icon_outer.visible = true
	if _icon_inner.texture != null:
		_icon_inner.position = live_position
		_icon_inner.scale = Vector2(k, k)
		_icon_inner.visible = true
	else:
		_icon_inner.visible = false
	_reset_icon_fade()
	_apply_icon_tint()


## 图标世界直径：底座（方案 world_diameter）+ 超强台风放大。
##
## 参考工程 `强度` sprite 的尺寸：`Kt < 200 → 16`（百分比），
## `Kt ≥ 200 → 0.15·(Kt−100)`（200 kt=15、300 kt=30 → **两倍**）。
## 我们把这换算成「200 kt 之后最多放大约 1.8 倍」，避免 300 kt 时图标大得离谱。
static func icon_diameter_for(base: float, kt: float) -> float:
	if kt <= 200.0:
		return base
	return base * (1.0 + clampf((kt - 200.0) / 100.0, 0.0, 0.8))


# ------------------------- 视频图标（SMCY1.3）-------------------------

## 当前方案是不是「用视频播图标」（方案 cfg 的 [meta] video=1）
func _scheme_uses_video() -> bool:
	# ⚠ web 版对 Theora 视频支持不可靠 → web 上自动回退 PNG 两层方案（观感略差但一定能播）
	if OS.has_feature("web"):
		return false
	return IconSchemeLoader.meta_float(
		IconSchemeLoader.KIND_ICONS, icon_scheme, "video", 0.0) > 0.5


## 档位 → 视频文件路径（找不到返回 ""）
func _video_path_for_tier(tier: String) -> String:
	var p := "res://assets/icons/%s/video/%s.ogv" % [icon_scheme, tier]
	if ResourceLoader.exists(p):
		return p
	var g := "res://assets/icons/%s/video/generic.ogv" % icon_scheme
	return g if ResourceLoader.exists(g) else ""


## 视频图标的颜色：视频本身已经按档位配色，这里再叠**官方表**算出的偏蓝/提亮。
## ⚠ 视频没法做色相旋转（VideoStreamPlayer 不吃我们的 shader），只能用 modulate
##   "压红提蓝"：红通道压到 0.35 是试验出来的极限（再压数字/弧线就发黑了），
##   所以高段是「蓝紫」而不是纯蓝 —— 受源素材限制。
static func video_tint_for(kt: float) -> Color:
	# 分段（用户 2026-10-30 最终版）：<137 kt 不染色；C5+ 才用 HLS 表的色相/偏蓝
	var blue := IconTint.blue_mix_for(kt)
	var lift := clampf(bright_for(kt) / 1.5, 0.0, 1.0)
	var gain := 1.0 + lift * (0.45 if GameSettings.icon_bright_ext else 0.22)
	var c := Color((1.0 - 0.65 * blue) * gain, (1.0 - 0.10 * blue) * gain,
		(1.0 + 0.30 * blue) * gain, 1.0)
	return c


## 视频方案下刷新图标：换档才重新 load + play，尺寸/位置每帧都跟
func _update_icon_video(form: int) -> void:
	var tier := IconSchemeLoader.tier_for_form(IconSchemeLoader.KIND_ICONS, icon_scheme, form)
	var path := _video_path_for_tier(tier)
	_icon_outer.visible = false
	_icon_inner.visible = false
	if path == "":
		_icon_video.visible = false
		return
	if path != _icon_video_path:
		# ① 相位对齐：换档时新视频从旧视频的**同一动画相位**开始播
		#    （所有图标视频周期 = 5.0 s；不对齐的话新视频从第 0 帧开始 → 旋涡角度跳一下）
		var phase := 0.0
		if _icon_video.stream != null and _icon_video.is_playing():
			phase = fmod(maxf(_icon_video.stream_position, 0.0), VIDEO_PHASE_SECONDS)
		# ② 叠化：旧视频留在 prev 播放器上继续播，0.25 s 内交叉淡出
		if _icon_video.stream != null and _icon_video.visible:
			_icon_video_prev.stream = _icon_video.stream
			_icon_video_prev.size = _icon_video.size
			_icon_video_prev.position = _icon_video.position
			_icon_video_prev.visible = true
			_icon_video_prev.play()
			_icon_video_prev.stream_position = phase
			_video_fade = 1.0
		_icon_video_path = path
		_icon_video.stream = load(path) as VideoStream
		_icon_video.play()
		_icon_video.stream_position = phase
	var d := icon_diameter_for(icon_diameter, live_intensity)
	_icon_video.size = Vector2(d, d)
	_icon_video.position = live_position - Vector2(d, d) * 0.5
	_icon_video.visible = true
	if _icon_video_prev.visible:
		_icon_video_prev.size = Vector2(d, d)
		_icon_video_prev.position = live_position - Vector2(d, d) * 0.5
	if not _icon_video.is_playing():
		_icon_video.play()
	# ③ 颜色（含淡出 alpha）由 _apply_video_alpha() 统一算，叠化期间新旧各占一半
	_video_tint = video_tint_for(live_intensity)
	_apply_video_alpha()


## 按当前叠化进度设置新旧视频的不透明度：旧 = fade，新 = 1−fade
func _apply_video_alpha() -> void:
	var a_new := clampf(1.0 - _video_fade, 0.0, 1.0) * _icon_fade
	var c := _video_tint
	c.a = a_new
	_icon_video.modulate = c
	if _icon_video_prev != null and _icon_video_prev.visible:
		var cp := _video_tint
		cp.a = clampf(_video_fade, 0.0, 1.0) * _icon_fade
		_icon_video_prev.modulate = cp


## 叠化推进（每帧）：结束就停掉旧播放器
func _advance_video_fade(delta: float) -> void:
	if _icon_video_prev == null or not _icon_video_prev.visible:
		return
	_video_fade = maxf(0.0, _video_fade - delta / VIDEO_FADE_SECONDS)
	if _video_fade <= 0.0:
		_icon_video_prev.stop()
		_icon_video_prev.visible = false
		_video_fade = 0.0


## 「消散」用淡出代替直接消失（1.2.0）。参考工程有专门的 `消散` 造型，
## 我们没有那张图 → 用 shader 的 `fade` 参数做 1.5 秒淡出，观感接近。
const ICON_FADE_SECONDS := 1.5
var _icon_fade := 1.0
var _icon_fading := false


func _reset_icon_fade() -> void:
	_icon_fade = 1.0
	_icon_fading = false
	if _icon_tint_material != null:
		_icon_tint_material.set_shader_parameter("fade", 1.0)


## 连续强度着色（B2/B3，2026-10-30 用户要求）。
##
## 参考工程的做法是**每档一条** COLOR 公式（见 docs/参考_图标伪代码.md §5），
## 档与档之间有跳变；用户要求「颜色是风速的连续函数，减弱时要回落到上一档」。
## 所以这里换成一条**平滑单调曲线**（量级对齐参考 C5 段 0.75·(135−Kt)/200）：
##   · kt ≤ 20      → 0（不偏色）
##   · kt 20 → 300  → 负值逐渐变大（Scratch 负色相 = 往蓝/紫偏）
## 因为是**当前风速的纯函数**，增强/减弱自动单调对应（B3 天然满足）。
static func hue_shift_for(kt: float) -> float:
	var t := clampf((kt - 20.0) / 280.0, 0.0, 1.0)
	return -0.75 * pow(t, 1.6)          # kt=300 → −0.75 圈（接近参考的 −0.62）


## 「170 kt+ 提亮」（2026-10-30 修正：**亮蓝保留**，只把最后的「白色阶段」做成开关）。
## 参考公式：BRIGHTNESS = 1.25·(Kt−170)（169–200）/ 1.50·(Kt−170)（199+），
## 换算成 shader 的 0..1 增量；>170 kt 再往冷色混一点（blue_mix）。
## ⚠ 用户：170~260 保留亮蓝，**≥260 不要再提白** → 见 `_apply_icon_tint()` 里的冻结。
static func bright_for(kt: float) -> float:
	if kt < 170.0:
		return 0.0
	var factor: float = 1.25 if kt < 199.0 else 1.5
	return clampf(factor * (kt - 170.0) / 100.0, 0.0, 1.5)


## 「白色阶段」的分界风速：≥260 kt 关闭时停在最亮的蓝（bright 冻结在 260 的值）
const WHITE_STAGE_KT := 260.0


static func blue_mix_for(kt: float) -> float:
	if kt < 170.0:
		return 0.0
	return clampf((kt - 170.0) / 60.0, 0.0, 0.75)


## 简单圆圈方案的**强度色带**（B2/B3）：白圈本身没有颜色，
## 按风速连续给一个颜色（浅蓝 → 蓝绿 → 绿 → 黄 → 橙 → 粉紫）。
## 色标取自 SMCY 图标各档的主色，保证两套方案观感一致。
static func ramp_color(kt: float) -> Color:
	const STOPS := [
		[15.0, Color(0.47, 0.63, 0.86)],
		[34.0, Color(0.40, 0.72, 0.82)],
		[64.0, Color(0.36, 0.82, 0.52)],
		[83.0, Color(0.86, 0.86, 0.32)],
		[96.0, Color(0.95, 0.74, 0.26)],
		[113.0, Color(0.95, 0.58, 0.22)],
		[137.0, Color(0.92, 0.42, 0.26)],
		[155.0, Color(0.90, 0.33, 0.42)],
		[170.0, Color(0.84, 0.32, 0.62)],
		[200.0, Color(0.72, 0.38, 0.86)],
		[300.0, Color(0.58, 0.52, 0.95)],
	]
	if kt <= float(STOPS[0][0]):
		return STOPS[0][1]
	for i in range(1, STOPS.size()):
		var hi: Array = STOPS[i]
		if kt <= float(hi[0]):
			var lo: Array = STOPS[i - 1]
			var t := (kt - float(lo[0])) / (float(hi[0]) - float(lo[0]))
			return (lo[1] as Color).lerp(hi[1] as Color, clampf(t, 0.0, 1.0))
	return STOPS[STOPS.size() - 1][1]


## 当前方案是不是「简单圆圈」：用方案 cfg 的 [meta] simple 标记判断（默认 0 = 不是）
func _is_simple_scheme() -> bool:
	return IconSchemeLoader.meta_float(
		IconSchemeLoader.KIND_ICONS, icon_scheme, "simple", 0.0) > 0.5


func _apply_icon_tint() -> void:
	if _icon_tint_material == null:
		return
	var simple := _is_simple_scheme()
	# 分段配色（用户 2026-10-30 最终版）：
	#   kt < 137 → **不染色**，直接用图标自带颜色（L / D / TS ~ C4）
	#   kt ≥ 137 → HLS-SSHWS 查表（C5+），表里的色相从 137 起渐入
	var hue := 0.0
	var blue := 0.0
	var bright := 0.0
	var base := Color.WHITE
	if simple:
		base = ramp_color(live_intensity)
	else:
		# L / D 段（<34 kt）：用户 2026-10-31 定的「A 读法」——先取深蓝基础色，再偏移 −100°
		base = IconTint.l_d_base_color(live_intensity)
		hue = IconTint.l_d_hue_shift(live_intensity)
		if live_intensity >= IconTint.D_MAX_KT:
			# TS ~ C4（<137 kt）：不染色，用素材原色；C5+ 才查 HLS 表
			# ⚠ IconTint 返回的是**度**（±180 量级），shader 的 hue_shift 要的是**圈数**
			hue = IconTint.hue_shift_for(live_intensity) / 360.0
			blue = IconTint.blue_mix_for(live_intensity)
			bright = blue * 0.45
			if GameSettings.icon_bright_ext:
				bright = minf(bright + bright_for(live_intensity), 1.5)
	_icon_tint_material.set_shader_parameter("hue_shift", hue)
	_icon_tint_material.set_shader_parameter("bright", bright)
	_icon_tint_material.set_shader_parameter("blue_mix", blue)
	_icon_tint_material.set_shader_parameter("white_allow", 1.0 if GameSettings.icon_bright_ext else 0.0)
	_icon_tint_material.set_shader_parameter("base_tint", base)


## 当前图标形态（15 档；变性完成固定 EX）——着色和换图都用它
func _current_form() -> int:
	return Const.FORM_EX if int(live_phase) >= 2 else Const.icon_form(live_intensity)

## 风暴结束 / 清轨迹：**先淡出 1.5 秒**再消失（代替参考工程的「消散」造型）
func _begin_icon_fade() -> void:
	var sprite_on := _icon_outer != null and _icon_outer.visible
	var video_on := _icon_video != null and _icon_video.visible
	var video_prev_on := _icon_video_prev != null and _icon_video_prev.visible
	if video_prev_on:
		_icon_video_prev.stop()
		_icon_video_prev.visible = false
		_video_fade = 0.0
	if not (sprite_on or video_on):
		return
	_icon_fading = true


func _hide_icon() -> void:
	_icon_fading = false
	_icon_fade = 0.0
	if _icon_tint_material != null:
		_icon_tint_material.set_shader_parameter("fade", 1.0)
	if _icon_outer != null:
		_icon_outer.visible = false
	if _icon_inner != null:
		_icon_inner.visible = false
	if _icon_video != null:
		_icon_video.visible = false
	if _icon_video_prev != null:
		_icon_video_prev.stop()
		_icon_video_prev.visible = false
	_video_fade = 0.0


# ------------------------- 绘制 -------------------------

## 路径点圆点半径
const POINT_RADIUS := 7.0
## 路径点颜色（鲜明）
const POINT_COLOR := Color(1.0, 0.85, 0.1)
const POINT_OUTLINE := Color(0.15, 0.10, 0.0, 0.9)


## 路径线宽
const TRACK_WIDTH := 2.5
## 变性中 / 已变性的路径线：白色虚线（用户指定的视觉表现）
const EXTRA_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const EXTRA_DASH := 9.0
const EXTRA_GAP := 7.0
## 变性中：偏白的浅蓝，用来和「完全变性」区分
const TRANSITION_COLOR := Color(0.82, 0.88, 1.0, 0.95)


func _draw() -> void:
	_draw_track()

	# ② 手动模式：待投放的路径点。只画鲜明的圆点，不标数字。
	if not pending_waypoints.is_empty():
		for i in pending_waypoints.size():
			if i > 0:
				draw_dashed_line(pending_waypoints[i - 1], pending_waypoints[i],
					Color(1.0, 0.95, 0.4, 0.7), 2.0, 8.0)
		for p in pending_waypoints:
			draw_circle(p, POINT_RADIUS + 1.5, POINT_OUTLINE)   # 描边，保证在任何底色上都看得清
			draw_circle(p, POINT_RADIUS, POINT_COLOR)

	# ③ 风圈 + （图标贴图缺失时的）台风本体圆点
	if live_visible:
		var c := _track_color_at(live_intensity, live_phase)
		# 34 kt 风圈（R34）：物理 km → 世界像素 → 视觉放大。
		# 画在本层 `_draw()` 里 → 永远在图标 Sprite 的下面，不会盖住内圈数字。
		var ring_r := wind_ring_diameter(live_intensity) * 0.5
		draw_arc(live_position, ring_r * 0.45, 0.0, TAU, 48, Color(c, 0.5), 1.5, true)
		draw_arc(live_position, ring_r, 0.0, TAU, 72, Color(c, 0.28), 1.5, true)
		# 贴图缺失时回退到原来的程序化圆点（不能出现"台风不见了"）
		if _icon_outer == null or _icon_outer.texture == null:
			draw_circle(live_position, 6.0, c)

	# ④ 登陆特效占位（以后换成贴图/粒子）
	for fx in landfall_effects:
		var t := float(fx["age"]) / float(fx["ttl"])
		var pos: Vector2 = fx["pos"]
		var kt := float(fx["kt"])
		var col := Const.track_color(kt)
		draw_arc(pos, 12.0 + 70.0 * t, 0.0, TAU, 48, Color(col.r, col.g, col.b, (1.0 - t) * 0.9), 4.0, true)
		draw_arc(pos, 6.0 + 34.0 * t, 0.0, TAU, 32, Color(1, 1, 1, (1.0 - t) * 0.7), 2.0, true)


## 已走过的路径。
## 按变性阶段分段：热带段用强度配色实线，变性段用浅色虚线，完全变性用白色虚线。
func _draw_track() -> void:
	if points.size() < 2:
		return
	var i := 1
	while i < points.size():
		var phase := phases[i] if i < phases.size() else 0
		# 找出同一阶段的连续区段
		var j := i
		while j + 1 < points.size() and (phases[j + 1] if j + 1 < phases.size() else 0) == phase:
			j += 1
		var run := PackedVector2Array()
		run.append(points[i - 1])
		for k in range(i, j + 1):
			run.append(points[k])

		if run.size() < 2:
			i = j + 1
			continue
		match phase:
			2:      # 已完全变性为温带气旋 → 虚线，颜色按参考 RGB-EX 表随风速连续变化（A6）
				for k in range(1, run.size()):
					var idx := mini(i - 1 + k, intensities.size() - 1)
					var seg_kt: float = intensities[idx] if idx >= 0 else 0.0
					draw_dashed_line(run[k - 1], run[k], Const.ex_track_color(seg_kt),
						TRACK_WIDTH, EXTRA_DASH)
			1:      # 变性中 → 浅色虚线
				for k in range(1, run.size()):
					draw_dashed_line(run[k - 1], run[k], TRANSITION_COLOR, TRACK_WIDTH, EXTRA_DASH)
			_:      # 热带阶段 → 按强度配色的实线
				var cols := PackedColorArray()
				for k in range(i, j + 1):
					cols.append(Const.track_color(intensities[k] if k < intensities.size() else 0.0))
				draw_polyline_colors(run, cols, TRACK_WIDTH, true)
		i = j + 1


## 当前位置的颜色：变性后用白/浅蓝，否则按强度
func _track_color_at(kt: float, phase: int) -> Color:
	match phase:
		2:
			return Const.ex_track_color(kt)
		1:
			return TRANSITION_COLOR
		_:
			return Const.track_color(kt)


## 34 kt 风圈的**物理半径**（km）。真实西太台风 R34 大致 100~300 km，
## 而且**越强核心越紧**、减弱时才向外扩张。
## ⚠ 旧实现是 `18 + kt*0.35 + 档位*4` 夹到 140 世界像素 = 1443 km 半径，
##   比真实值大 4~7 倍，而且方向是反的（越强圈越大）——1.2.1 修掉。
static func r34_radius_km(kt: float) -> float:
	return clampf(300.0 - 1.3 * (kt - 34.0), 100.0, 300.0)


## 1 世界像素 = 多少 km：地图 10.8 px/°、1° ≈ 111 km → 0.0973 px/km
const KM_TO_WORLD_PX := 0.0973
## 视觉放大系数：真实 R34 换算出来只有 30~60 世界像素、几乎看不见，×3 才有存在感
const WIND_RING_VISUAL_SCALE := 3.0
## 视觉直径下限（世界像素）。超强台风 R34 很紧（物理值只有 58 px），
## 没有下限会被图标整个盖住，所以至少画 90 px（Lead 2026-10-25 定）
const WIND_RING_MIN_DIAMETER := 90.0


## 风圈在屏幕上的视觉直径（世界像素）
static func wind_ring_diameter(kt: float) -> float:
	return maxf(
		r34_radius_km(kt) * 2.0 * KM_TO_WORLD_PX * WIND_RING_VISUAL_SCALE,
		WIND_RING_MIN_DIAMETER)
