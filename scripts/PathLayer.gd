class_name PathLayer
extends Node2D
## 台风路径、路径点、风圈与**台风图标**的绘制层。
##
## 1.2.2 起图标改成「方案包（zip）」系统（用户 2026-11-05 定）：
##   · 方案包 = `<游戏目录>/assets/icons/<方案名>.zip`，内含 index.json + mainicon/ landfall/ particle/
##   · 事件 ID 查表拿到包内相对路径 → 直接读文件播放（`IconPacks` 负责）
##   · 查不到的 ID → **程序化渲染**（画圆 + 等级文字；170+ 扩展档就是这么来的）
##   · 换档：0.25 s 叠化 + 相位对齐（同一视频 5.0 s 周期，seek 到相同进度）
##
## 风圈（R34 两圈）画在图标的**下层**（本层 `_draw()` 永远在子节点下面）。
##
## 坐标：世界坐标（地图像素，原点在左上角）。

const IconPacksLoader := preload("res://scripts/IconPacks.gd")
const VIDEO_SHADER := preload("res://assets/shaders/video_unpremultiply.gdshader")

## 图标世界直径的**兜底值**（像素）。用户会手动改这个数。
## 单个方案可以在 index.json 里写 `icon_size` 覆盖它（见 _apply_pack_icon_size）。
const ICON_DIAMETER_FALLBACK := 100.0
## 登陆特效视频的显示直径（世界像素）
const LANDFALL_VIDEO_DIAMETER := 150.0
## 粒子 / 瞬间特效的显示直径
const FX_ERI_SIZE := 170.0
const FX_NOTE_TS_SIZE := 140.0
## 换档叠化时长
## ⚠ 用户 2026-11-08：升级特效/音效在 34 kt 那一 tick 立刻触发（实测图标 ID 也是同 tick 切换），
## 但 0.25 s 叠化让旧图标还明显可见 → 感觉「图标晚到」。缩到 0.10 s 与特效同步。
const VIDEO_FADE_SECONDS := 0.10
## 视频图标的相位周期：素材实测 5.0 秒一圈，换档时按这个取模对齐
const VIDEO_PHASE_SECONDS := 5.0
## 消散淡出时长
const ICON_FADE_SECONDS := 1.5

# ------------------------- 已走过的路径 -------------------------
var points: Array[Vector2] = []
var intensities: Array[float] = []
## 每个路径点对应的变性阶段（Storm.Phase 的整数值），用来把变性后的那一段画成白色虚线
var phases: Array[int] = []

# ------------------------- 台风当前位置 -------------------------
var live_position := Vector2.ZERO
var live_intensity := 0.0
var live_phase := 0                   ## Storm.Phase：0 热带 / 1 变性中 / 2 温带
## 当前台风所在海温（℃）与纬度（给程序化渲染/未来配色用）
var live_sst := -1.0
## 变性中途的副热带子状态（显示 ST）
var live_subtype_st := false
var live_lat := 999.0
## 隐藏时同步收掉图标（`TyphoonSim` 里有两处直接 `path.live_visible = false`）
var live_visible := false:
	set(value):
		live_visible = value
		if not value:
			_begin_icon_fade()

## 当前方案名（GameSettings.icon_pack；"" = 没有方案 → 全程序化）
var icon_pack := ""

## 图标世界直径（世界像素）
var icon_diameter := ICON_DIAMETER_FALLBACK

# ------------------------- 图标视频 -------------------------
var _icon_video: VideoStreamPlayer = null
var _icon_video_prev: VideoStreamPlayer = null
## 当前正在播的事件 ID（换档判断用）
var _icon_video_id := ""
var _video_fade := 0.0
## 当前图标是否走「程序化渲染」兜底（决定 _draw() 画不画那个圆）
var _procedural_icon := false
## type=single 方案用的单张图片（png/jpg）
var _single_sprite: Sprite2D = null
## 内置方案模式：0 = 用方案包；1 = Default（1.1.1 两圈+小点）；2 = Advanced default（彩色盘+文字）
var _builtin_mode := 1
var _icon_tier := ""                  ## 当前档位/事件 ID 的短名（调试/测试用）
## 当前图标是否用了「玩家自定义扩展档位」（用了就不再做 170+ 渲染变色）
var _icon_uses_extension := false
## 上次生效的「等级扩展图标」开关（变了要重建图标）
var _tier_variants_cache := true
## 视频图标的原始宽高比（高/宽）：EX 素材是 400×600（比例 1.5），
## 不能强制拉成正方形，否则画面内容会变小（用户 2026-11-08 报 EX 比其他图标小）。
var _icon_ratio_cache: Dictionary = {}
var _icon_ratio := 1.0

# ------------------------- 其它特效播放器 -------------------------
var _landfall_video: VideoStreamPlayer = null
var _fx_eri: VideoStreamPlayer = null
var _fx_note_ts: VideoStreamPlayer = null

# ------------------------- 消散淡出 -------------------------
var _icon_fade := 1.0
var _icon_fading := false

# ------------------------- 手动模式待投放点 -------------------------
var pending_waypoints: Array[Vector2] = []
## 程序化登陆特效（视频缺失时的兜底）：[{pos, kt, age, ttl}]
var landfall_effects: Array[Dictionary] = []


func _ready() -> void:
	icon_pack = GameSettings.icon_pack
	_tier_variants_cache = GameSettings.tier_variants
	icon_diameter = ICON_DIAMETER_FALLBACK
	# 播放器都在图标之前创建：z 相同（1）时按树序绘制 → 特效在图标下面、底图上面
	_landfall_video = _make_video("LandfallEffectVideo")
	_fx_eri = _make_video("FxEri")
	_fx_note_ts = _make_video("FxNoteTs")
	_icon_video = _make_video("StormIconVideo")
	_icon_video.loop = true
	_icon_video_prev = _make_video("StormIconVideoPrev")
	_icon_video_prev.loop = true
	# type=single（单一图标）用：一张 png/jpg，不旋转不变色
	_single_sprite = Sprite2D.new()
	_single_sprite.name = "StormIconSingle"
	_single_sprite.z_index = 2
	_single_sprite.visible = false
	add_child(_single_sprite)
	# 用户 2026-11-06：特效/粒子放到**图标最上面**（图标视频 z=1、单图 z=2）
	# ⚠ z_as_relative=false：用绝对 z，不受父节点/树序影响
	for p in [_landfall_video, _fx_eri, _fx_note_ts]:
		p.z_as_relative = false
		p.z_index = 20
	# 一次性特效：播完自己收掉
	for p in [_landfall_video, _fx_eri, _fx_note_ts]:
		p.finished.connect(func() -> void:
			p.stop()
			p.visible = false)
	GameSettings.changed.connect(_on_settings_changed)


func _make_video(node_name: String) -> VideoStreamPlayer:
	var p := VideoStreamPlayer.new()
	p.name = node_name
	p.z_index = 1
	p.expand = true
	p.visible = false
	var m := ShaderMaterial.new()
	m.shader = VIDEO_SHADER
	p.material = m
	add_child(p)
	return p


## 设置里换了方案 → 停掉旧的、按新方案重建
func _on_settings_changed() -> void:
	var variants_changed := GameSettings.tier_variants != _tier_variants_cache
	_tier_variants_cache = GameSettings.tier_variants
	if GameSettings.icon_pack == icon_pack and not variants_changed:
		return
	icon_pack = GameSettings.icon_pack
	_apply_pack_icon_size()
	_stop_icon_videos()
	_icon_video_id = ""
	_procedural_icon = false
	_icon_fade = 1.0
	_icon_fading = false
	queue_redraw()
	if live_visible:
		_update_icon()


func _stop_icon_videos() -> void:
	for p in [_icon_video, _icon_video_prev]:
		if p != null:
			p.stop()
			p.visible = false
	_video_fade = 0.0


func clear_track() -> void:
	points.clear()
	intensities.clear()
	phases.clear()
	live_visible = false
	landfall_effects.clear()
	queue_redraw()


func set_live_position(world_pos: Vector2, kt: float, phase := 0, sst := -1.0, lat := 999.0, st := false) -> void:
	live_position = world_pos
	live_intensity = kt
	live_phase = phase
	live_sst = sst
	live_lat = lat
	live_subtype_st = st
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


# ------------------------- 手动模式待投放点 -------------------------

func add_waypoint(world_pos: Vector2) -> void:
	pending_waypoints.append(world_pos)
	queue_redraw()


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


# ------------------------- 事件 ID（方案包查表用）-------------------------

## 当前应显示的事件 ID。
## ⚠ 用户 2026-11-05 规则：
##   · 南半球**一律用 .north.**（游戏端不写南半球触发条件；zip 里可以放 .south. 供玩家自定义）
##   · 扩展 ID（c5_155/170/200/250/300）是**给玩家自定义**的：zip 里有才用；
##     zip 里没有时默认「C5 图标 + 渲染变色（≥170 kt 变蓝）」，不是查扩展 ID
func current_icon_id() -> String:
	return "mainicon.icon.north.%s" % _icon_kind()


## 扩展档位（从高到低）：只有 zip 里确实存在该 ID 时才采用
const EXT_BANDS: Array = [
	["c5_300", 300.0], ["c5_250", 250.0], ["c5_200", 200.0], ["c5_170", 170.0], ["c5_155", 155.0],
]


func _icon_kind() -> String:
	# 副热带子状态：优先用 ss 图标（包内没有 → 程序化渲染兜底）
	if live_subtype_st:
		return "ss"
	# 用户 2026-11-06：**一开始变性（phase>=1）就切 EX 图标**，不要还按热带等级换
	if int(live_phase) >= 1:
		return "ex"
	# 用户 2026-11-07：档内进度用素材里的 +/- 变体（+ = 下一档配色，- = 上一档配色）
	#   ts   p>=0.5 → ts_plus（C1 配色）
	#   c2/c3 p<0.5 → c2_minus / c3_minus（上一档配色）
	#   c4   p>=0.5 → c4_plus（C5 配色）
	var base_kind := _base_icon_kind()
	if not GameSettings.tier_variants or not IconPacksLoader.has_tier_variants(icon_pack):
		return base_kind
	var prog := Const.tier_progress(live_intensity)
	match base_kind:
		"ts":
			if prog >= 0.5 and IconPacksLoader.has(icon_pack, "mainicon.icon.north.ts_plus"):
				return "ts_plus"
		"c2":
			if prog < 0.5 and IconPacksLoader.has(icon_pack, "mainicon.icon.north.c2_minus"):
				return "c2_minus"
		"c3":
			if prog < 0.5 and IconPacksLoader.has(icon_pack, "mainicon.icon.north.c3_minus"):
				return "c3_minus"
		"c4":
			if prog >= 0.5 and IconPacksLoader.has(icon_pack, "mainicon.icon.north.c4_plus"):
				return "c4_plus"
	return base_kind




## 基础档位（不含 ST / EX / 变体）
func _base_icon_kind() -> String:
		var kt := live_intensity
		if IconPacksLoader.type_of(icon_pack) == "adv_extend":
			for band in EXT_BANDS:
				if kt >= float(band[1]) and IconPacksLoader.has(icon_pack, "mainicon.icon.north." + str(band[0])):
					_icon_uses_extension = true
					return str(band[0])
		_icon_uses_extension = false
		if kt >= 137.0:
			return "c5"
		if kt >= 113.0:
			return "c4"
		if kt >= 97.0:
			return "c3"
		if kt >= 83.0:
			return "c2"
		if kt >= 64.0:
			return "c1"
		if kt >= 34.0:
			return "ts"
		if kt >= 22.0:
			return "d"
		if kt >= 15.0:
			return "l"
		return "x"


## 登陆特效 ID（TD 以下没有）
func _landfall_id(kt: float) -> String:
	if kt >= 137.0:
		return "landfall.icon.c5"
	if kt >= 113.0:
		return "landfall.icon.c4"
	if kt >= 97.0:
		return "landfall.icon.c3"
	if kt >= 83.0:
		return "landfall.icon.c2"
	if kt >= 64.0:
		return "landfall.icon.c1"
	if kt >= 34.0:
		return "landfall.icon.ts"
	if kt >= 22.0:
		return "landfall.icon.d"
	return ""


# ------------------------- 台风图标 -------------------------

## 按当前方案决定图标基准直径：内置方案用常量；文件夹方案优先用 index.json 的 icon_size
func _apply_pack_icon_size() -> void:
	if GameSettings.is_builtin_pack(icon_pack) or icon_pack == "":
		icon_diameter = ICON_DIAMETER_FALLBACK
		return
	var s := IconPacksLoader.icon_size(icon_pack)
	icon_diameter = s if s > 0.0 else ICON_DIAMETER_FALLBACK


func _update_icon() -> void:
	if not live_visible:
		return
	_apply_pack_icon_size()
	# 内置方案（不读 zip、不走 type）：Default / Advanced default
	_builtin_mode = _detect_builtin()
	if _builtin_mode > 0:
		_stop_icon_videos()
		_procedural_icon = true
		_icon_fade = 1.0
		_icon_fading = false
		if _single_sprite != null:
			_single_sprite.visible = false
		queue_redraw()
		return

	# type=single：整局只用一张图（type=single 支持 png/ogv，不旋转不变色）
	if IconPacksLoader.type_of(icon_pack) == "single":
		_show_single_icon()
		return
	if _single_sprite != null:
		_single_sprite.visible = false
	var id := current_icon_id()
	_icon_tier = id.get_slice(".", 3) if id.count(".") >= 3 else id
	var stream: VideoStream = IconPacksLoader.video(icon_pack, id)
	if stream == null:
		# 方案包没有这个 ID（或没有方案）→ 程序化渲染
		_stop_icon_videos()
		_procedural_icon = true
		_icon_fade = 1.0
		_icon_fading = false
		queue_redraw()
		return
	_procedural_icon = false
	if id != _icon_video_id or _icon_video.stream == null:
		var phase := 0.0
		if _icon_video_id != "" and _icon_video.visible:
			phase = fmod(maxf(_icon_video.stream_position, 0.0), VIDEO_PHASE_SECONDS)
		# 旧视频留到 prev 里继续播 → 0.25 s 叠化
		if _icon_video.visible and _icon_video.stream != null:
			_icon_video_prev.stream = _icon_video.stream
			_icon_video_prev.size = _icon_video.size
			_icon_video_prev.position = _icon_video.position
			_icon_video_prev.visible = true
			_icon_video_prev.play()
			_icon_video_prev.stream_position = phase
			_video_fade = 1.0
		_icon_video_id = id
		_icon_video.stream = stream
		_icon_video.play()
		_icon_video.stream_position = phase
	_icon_fade = 1.0
	_icon_fading = false
	var d := icon_diameter_for(icon_diameter, live_intensity)
	_icon_ratio = float(_icon_ratio_cache.get(id, 1.0))
	_icon_video.size = Vector2(d, d * _icon_ratio)
	# 以台风中心为中心（变高也不偏移）
	_icon_video.position = live_position - _icon_video.size * 0.5
	_icon_video.visible = true
	_reset_tint_target()
	_update_tier_bright_target()
	_apply_video_tint()
	_apply_video_alpha()
	queue_redraw()


## type=single：一张图所有强度通用（找 generic，找不到就用第一条）
func _show_single_icon() -> void:
	_stop_icon_videos()
	# type=single 只认 single.typhoon（一个点，可有简单动效；不分等级、不旋转、不变色）
	var id := "single.typhoon"
	if not IconPacksLoader.has(icon_pack, id):
		id = ""
	var tex: Texture2D = IconPacksLoader.image(icon_pack, id) if id != "" else null
	if tex == null and id != "":
		# 也可能是 ogv：当普通视频一直播
		var stream: VideoStream = IconPacksLoader.video(icon_pack, id)
		if stream != null:
			if _icon_video.stream != stream:
				_icon_video.stream = stream
				_icon_video.play()
			var d0 := icon_diameter_for(icon_diameter, live_intensity)
			_icon_video.size = Vector2(d0, d0)
			_icon_video.position = live_position - Vector2(d0, d0) * 0.5
			_icon_video.visible = true
			_icon_video_id = id
			_procedural_icon = false
			if _single_sprite != null:
				_single_sprite.visible = false
			_apply_video_tint()
			_apply_video_alpha()
			queue_redraw()
			return
	if tex == null:
		_procedural_icon = true
		if _single_sprite != null:
			_single_sprite.visible = false
		queue_redraw()
		return
	_procedural_icon = false
	if _single_sprite != null:
		_single_sprite.texture = tex
		var d := icon_diameter_for(icon_diameter, live_intensity)
		var side := float(tex.get_width())
		var k := d / side if side > 0.0 else 1.0
		_single_sprite.position = live_position
		_single_sprite.scale = Vector2(k, k)
		_single_sprite.visible = true
	_icon_video_id = id
	queue_redraw()


## 当前是不是内置方案：1 = Default，2 = Advanced default，0 = 用方案包
func _detect_builtin() -> int:
	if icon_pack == GameSettings.DEFAULT_PACK:
		return 1
	if icon_pack == "Advanced default":
		return 2
	return 0


## 视频图标随强度微调大小'（>200 kt 放大，最多 1.8×）——用户手动改 icon_diameter 是基准
static func icon_diameter_for(base: float, kt: float) -> float:
	if kt <= 200.0:
		return base
	var k := clampf((kt - 200.0) / 100.0, 0.0, 0.8)
	return base * (1.0 + k)


## 调色：**只来自方案包的 effect**（用户 2026-11-06：删掉写死的 170+ 变色）
## effect 规则见 IconPacks.effect_for：图标命中后，speed ≤ 当前风速才生效。
## gradient > 0 时用 _process 每帧向目标颜色线性逼近。
var _tint_shown := Color.WHITE
var _tint_target := Color.WHITE
var _tint_gradient := 0.0
## 档内颜色渐变（用户 2026-11-07）：目标与平滑值（度）
var _tier_hue_target := 0.0
var _tier_hue_shown := 0.0
## 色相旋转（度）当前/目标/过渡时长
var _hue_shown := 0.0
var _hue_target := 0.0


func _target_tint() -> Dictionary:
	var id := current_icon_id()
	var e := IconPacksLoader.effect_for(icon_pack, id, live_intensity)
	if e.is_empty():
		return {"color": Color.WHITE, "hue": 0.0, "gradient": 0.0}
	var tint := Color.WHITE
	var color_str := str(e.get("color", "")).strip_edges()
	var brightness := float(e.get("brightness", 0.0))
	if color_str != "":
		tint = Color.from_string(color_str, Color.WHITE)
	if brightness <= -100.0:
		tint = Color.BLACK
	elif brightness >= 100.0:
		tint = Color.WHITE
	elif brightness != 0.0:
		var k := clampf(1.0 + brightness / 100.0, 0.0, 2.0)
		tint = Color(tint.r * k, tint.g * k, tint.b * k, tint.a)
	return {
		"color": tint,
		"hue": float(e.get("hue_shift", 0.0)),
		"gradient": maxf(0.0, float(e.get("gradient", 0.0))),
	}


## 重新计算目标色（图标切换时调用）
func _reset_tint_target() -> void:
	var t := _target_tint()
	_tint_target = t["color"]
	_hue_target = float(t.get("hue", 0.0))
	_tint_gradient = float(t["gradient"])
	if _tint_gradient <= 0.0:
		_tint_shown = _tint_target
		_hue_shown = _hue_target


func _apply_video_tint() -> void:
	for p in [_icon_video, _icon_video_prev]:
		if p != null and p.material is ShaderMaterial:
			(p.material as ShaderMaterial).set_shader_parameter("tint", _tint_shown)
			(p.material as ShaderMaterial).set_shader_parameter("hue_shift_deg", _hue_shown)
			(p.material as ShaderMaterial).set_shader_parameter("tier_hue_deg", _tier_hue_shown)


func _apply_video_alpha() -> void:
	if _icon_video != null:
		var a := (1.0 - _video_fade) * _icon_fade
		_icon_video.modulate = Color(1, 1, 1, clampf(a, 0.0, 1.0))
	if _icon_video_prev != null:
		_icon_video_prev.modulate = Color(1, 1, 1, clampf(_video_fade * _icon_fade, 0.0, 1.0))


## 档内颜色渐变（只对 advanced/adv_extend 的视频图标；single/内置不生效）
func _update_tier_bright_target() -> void:
	var t := IconPacksLoader.type_of(icon_pack)
	if t != "advanced" and t != "adv_extend":
		_tier_hue_target = 0.0
		return
	_tier_hue_target = Const.tier_hue_shift(live_intensity)


func _advance_video_fade(delta: float) -> void:
	if _video_fade <= 0.0:
		return
	_video_fade = maxf(0.0, _video_fade - delta / VIDEO_FADE_SECONDS)
	_apply_video_alpha()
	if _video_fade <= 0.0 and _icon_video_prev != null:
		_icon_video_prev.stop()
		_icon_video_prev.visible = false
		_icon_video_prev.stream = null


func _begin_icon_fade() -> void:
	var any_on := (_icon_video != null and _icon_video.visible) or _procedural_icon
	if not any_on:
		return
	_icon_fading = true


func _hide_icon() -> void:
	if _icon_video != null:
		_icon_video.stop()
		_icon_video.visible = false
	if _icon_video_prev != null:
		_icon_video_prev.stop()
		_icon_video_prev.visible = false
	_icon_video_prev.stream = null
	_video_fade = 0.0
	_icon_fade = 0.0
	_icon_fading = false
	_procedural_icon = false
	queue_redraw()


func _process(delta: float) -> void:
	_advance_video_fade(delta)
	# 视频尺寸纠正：VideoStream 没有宽高 API，只能等第一帧纹理出来再读。
	# EX 素材 400×600 → 比例 1.5；其它 400×400 → 1.0（用户 2026-11-08）。
	if _icon_video != null and _icon_video.visible and _icon_video.stream != null and _icon_video_id != "":
		var tex := _icon_video.get_video_texture()
		if tex != null:
			var sz := tex.get_size()
			if sz.x > 0.0:
				var ratio := sz.y / sz.x
				if absf(ratio - float(_icon_ratio_cache.get(_icon_video_id, -1.0))) > 0.01:
					_icon_ratio_cache[_icon_video_id] = ratio
					var d2 := icon_diameter_for(icon_diameter, live_intensity)
					_icon_ratio = ratio
					_icon_video.size = Vector2(d2, d2 * ratio)
					_icon_video.position = live_position - _icon_video.size * 0.5

	# 档内颜色平滑（0.25 s，避免跨档时闪一下）
	if absf(_tier_hue_shown - _tier_hue_target) > 0.05:
		_tier_hue_shown = lerpf(_tier_hue_shown, _tier_hue_target, minf(1.0, delta / 0.25))
		if absf(_tier_hue_shown - _tier_hue_target) <= 0.05:
			_tier_hue_shown = _tier_hue_target
		_apply_video_tint()

	# effect 的 gradient：每帧向目标色线性逼近（用户 2026-11-06）
	var tint_diff := not _tint_shown.is_equal_approx(_tint_target)
	var hue_diff := absf(_hue_shown - _hue_target) > 0.01
	if tint_diff or hue_diff:
		if _tint_gradient > 0.0:
			var k := minf(1.0, delta / _tint_gradient)
			_tint_shown = _tint_shown.lerp(_tint_target, k)
			_hue_shown = lerpf(_hue_shown, _hue_target, k)
			if _tint_shown.is_equal_approx(_tint_target):
				_tint_shown = _tint_target
			if absf(_hue_shown - _hue_target) <= 0.01:
				_hue_shown = _hue_target
		else:
			_tint_shown = _tint_target
			_hue_shown = _hue_target
		_apply_video_tint()
	if _icon_fading:
		_icon_fade = maxf(0.0, _icon_fade - delta / ICON_FADE_SECONDS)
		_apply_video_alpha()
		queue_redraw()
		if _icon_fade <= 0.0:
			_hide_icon()
	# 程序化登陆特效（兜底）计时
	if landfall_effects.is_empty():
		return
	for fx in landfall_effects:
		fx["age"] = float(fx["age"]) + delta
	landfall_effects = landfall_effects.filter(func(fx): return float(fx["age"]) < float(fx["ttl"]))
	queue_redraw()


# ------------------------- 登陆特效 -------------------------

func spawn_landfall_effect(world_pos: Vector2, kt: float) -> void:
	# type=single 的登陆特效固定用 single.landfall
	var id := "single.landfall" if IconPacksLoader.type_of(icon_pack) == "single" else _landfall_id(kt)
	var stream: VideoStream = IconPacksLoader.video(icon_pack, id) if id != "" else null
	if stream != null and _landfall_video != null:
		_landfall_video.stream = stream
		_landfall_video.size = Vector2(LANDFALL_VIDEO_DIAMETER, LANDFALL_VIDEO_DIAMETER)
		_landfall_video.position = world_pos - _landfall_video.size * 0.5
		_landfall_video.visible = true
		_landfall_video.play()
		return
	# 兜底：程序化两圈扩散弧
	landfall_effects.append({"pos": world_pos, "kt": kt, "age": 0.0, "ttl": 1.4})
	queue_redraw()


# ------------------------- 粒子 / 瞬间特效 -------------------------

## 播放粒子特效：kind = "eri" / "note_ts"（事件 ID = particle.<kind>）
## ⚠ note_ts 不需要相位对齐（TD/L 图标没有悬臂，本来就不用对齐）
func play_effect_video(kind: String, world_pos: Vector2) -> void:
	var id := "particle." + kind
	var stream: VideoStream = IconPacksLoader.video(icon_pack, id)
	if stream == null:
		return
	var player: VideoStreamPlayer = null
	var size := 0.0
	match kind:
		"eri":
			player = _fx_eri
			size = FX_ERI_SIZE
		"note_ts":
			player = _fx_note_ts
			size = FX_NOTE_TS_SIZE
		_:
			return
	if player == null:
		return
	player.stream = stream
	player.size = Vector2(size, size)
	player.position = world_pos - Vector2(size, size) * 0.5
	player.visible = true
	player.play()


# ------------------------- 绘制 -------------------------

## 路径点圆点半径
const POINT_RADIUS := 7.0
const POINT_COLOR := Color(1.0, 0.85, 0.1)
const POINT_OUTLINE := Color(0.15, 0.10, 0.0, 0.9)
## 路径线宽
const TRACK_WIDTH := 2.5
## 变性中 / 已变性的路径线：白色虚线
const EXTRA_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const EXTRA_DASH := 9.0
const EXTRA_GAP := 7.0
## 变性中：偏白的浅蓝
const TRANSITION_COLOR := Color(0.82, 0.88, 1.0, 0.95)


func _draw() -> void:
	_draw_track()

	# ② 手动模式：待投放的路径点
	if not pending_waypoints.is_empty():
		for i in pending_waypoints.size():
			if i > 0:
				draw_dashed_line(pending_waypoints[i - 1], pending_waypoints[i],
					Color(1.0, 0.95, 0.4, 0.7), 2.0, 8.0)
		for p in pending_waypoints:
			draw_circle(p, POINT_RADIUS + 1.5, POINT_OUTLINE)
			draw_circle(p, POINT_RADIUS, POINT_COLOR)

	# ③ 风圈 + 程序化兜底图标
	if live_visible:
		var c := _track_color_at(live_intensity, live_phase)
		# 风圈：内置方案（Default / Advanced default）画；方案包（SMCY 等）不画（用户 2026-10-31）
		if _builtin_mode > 0:
			# 先画圆盘，再画风圈 → 风圈在圆盘上面，不会被盖住（用户 2026-11-06）
			_draw_procedural_icon(c)
			var ring_r := wind_ring_diameter(live_intensity) * 0.5
			draw_arc(live_position, ring_r * 0.45, 0.0, TAU, 48, Color(c, 0.5 * _icon_fade), 1.5, true)
			draw_arc(live_position, ring_r, 0.0, TAU, 72, Color(c, 0.28 * _icon_fade), 1.5, true)
		elif _procedural_icon or (_icon_video != null and not _icon_video.visible and not _icon_fading):
			_draw_procedural_icon(c)

	# ④ 程序化登陆特效（视频缺失时）
	for fx in landfall_effects:
		var t := float(fx["age"]) / float(fx["ttl"])
		var pos: Vector2 = fx["pos"]
		var kt := float(fx["kt"])
		var col := Const.track_color(kt)
		draw_arc(pos, 12.0 + 70.0 * t, 0.0, TAU, 48, Color(col.r, col.g, col.b, (1.0 - t) * 0.9), 4.0, true)
		draw_arc(pos, 6.0 + 34.0 * t, 0.0, TAU, 32, Color(1, 1, 1, (1.0 - t) * 0.7), 2.0, true)


## 程序化图标：
##   mode 1（Default）= 1.1.1 观感：**12 px 小点**（draw_circle 半径 6），无圆盘无文字
##   mode 2（Advanced default）= 彩色大圆盘 + 白环 + 等级文字（连续变色）
##   mode 0 = 方案包查不到该 ID 时的兜底（用 Advanced 那套）
func _draw_procedural_icon(c: Color) -> void:
	if _builtin_mode == 1:
		# 1.1.1 原版：`draw_circle(live_position, 6.0, c)`
		draw_circle(live_position, 6.0, Color(c, _icon_fade))
		return
	var d := icon_diameter_for(icon_diameter, live_intensity)
	# 用户 2026-11-06：Advanced default 的圆盘缩小（0.5→0.41 直径），别盖住最内层风圈
	var r := d * 0.27
	draw_circle(live_position, r, Color(c, 0.85 * _icon_fade))
	draw_arc(live_position, r, 0.0, TAU, 48, Color(1, 1, 1, 0.9 * _icon_fade), 2.0, true)
	var label := _procedural_label()
	if label == "":
		return
	var font := ThemeDB.fallback_font
	var fs := maxi(12, int(r * 0.9))
	var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
	var pos := live_position + Vector2(-w * 0.5, fs * 0.35)
	draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
		Color(1, 1, 1, _icon_fade))


func _procedural_label() -> String:
	if live_subtype_st:
		return "ST"
	if live_intensity >= 155.0:
		return "%d" % int(roundf(live_intensity))
	return Const.category_short(Const.category_from_wind(live_intensity))


## 已走过的路径：按变性阶段分段
func _draw_track() -> void:
	if points.size() < 2:
		return
	var i := 1
	while i < points.size():
		var phase := phases[i] if i < phases.size() else 0
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
			2:
				for k in range(1, run.size()):
					draw_dashed_line(run[k - 1], run[k], Color(1.0, 1.0, 1.0),
						TRACK_WIDTH, EXTRA_DASH)
			1:
				for k in range(1, run.size()):
					draw_dashed_line(run[k - 1], run[k], Color(1.0, 1.0, 1.0), TRACK_WIDTH, EXTRA_DASH)
			_:
				var cols := PackedColorArray()
				for k in range(i, j + 1):
					cols.append(Const.track_color(intensities[k] if k < intensities.size() else 0.0))
				draw_polyline_colors(run, cols, TRACK_WIDTH, true)
		i = j + 1


## 当前位置的颜色：变性后用白/浅蓝，否则按强度
func _track_color_at(kt: float, phase: int) -> Color:
	# 用户 2026-11-07：变性中（1）+ 变性后（2）轨迹段**统一纯白**
	# （不再用 RGB-EX 表，那个表 90 kt 是橙色，用户看橙色不对）
	if phase >= 1:
		return Color(1.0, 1.0, 1.0)
	return Const.track_color(kt)


## 34 kt 风圈的**物理半径**（km）
static func r34_radius_km(kt: float) -> float:
	return clampf(300.0 - 1.3 * (kt - 34.0), 100.0, 300.0)


## 1 世界像素 = 多少 km
const KM_TO_WORLD_PX := 0.0973
## 视觉放大系数
const WIND_RING_VISUAL_SCALE := 3.0
## 视觉直径下限（世界像素）
const WIND_RING_MIN_DIAMETER := 90.0


## 风圈在屏幕上的视觉直径（世界像素）
static func wind_ring_diameter(kt: float) -> float:
	return maxf(
		r34_radius_km(kt) * 2.0 * KM_TO_WORLD_PX * WIND_RING_VISUAL_SCALE,
		WIND_RING_MIN_DIAMETER)
