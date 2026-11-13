class_name Backdrop
extends Control
## 2.0 的共享背景层：一张卫星云图 + 斜切深色操作区，分界线斜率固定。
## 主界面与所有子界面都挂这一份；切换菜单时「背景的大图形消失」就是改这里的 reveal。

const SKY_TEXTURE := "res://assets/images/2630_Champi.jpg"

## 台风眼在屏幕上的相对位置（0..1）
@export var eye_anchor := Vector2(0.66, 0.47)
@export var sky_scale := 0.64
@export var sky_brightness := 0.60
@export var sky_saturation := 0.48
@export var sky_contrast := 1.18
## 冷色偏色：把云图压向蓝灰，和冰蓝 accent 统一
@export var sky_shift := Color(0.86, 0.95, 1.06, 1.0)
## 左侧深色操作区的浓度
@export var veil_alpha := 0.90
## 分界线上那条细亮线
@export var edge_line_px := 2.0
## 分界线在画面底部的 x（相对屏幕宽度）。主界面 0.30（窄操作区），子界面 0.52（宽操作区）
@export_range(0.0, 1.0, 0.01) var edge_bottom_x := 0.30
## 右侧额外的暗化（子界面用；0 = 不压暗）
@export_range(0.0, 1.0, 0.01) var dim := 0.0

var _sky: Sprite2D = null
var _sky_mat: ShaderMaterial = null
var _veil: ColorRect = null
var _veil_mat: ShaderMaterial = null
var _dim_rect: ColorRect = null
var _dim_mat: ShaderMaterial = null
var _reveal := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	resized.connect(_layout)
	_layout()


func _build() -> void:
	# --- 云图 ---
	var tex: Texture2D = load(SKY_TEXTURE) if ResourceLoader.exists(SKY_TEXTURE) else null
	_sky = Sprite2D.new()
	_sky.name = "Sky"
	if tex != null:
		_sky.texture = tex
	_sky.centered = true
	_sky.scale = Vector2(sky_scale, sky_scale)
	_sky_mat = UiKit.slant_material(1, edge_bottom_x, Color(0.02, 0.03, 0.05, 1.0), edge_line_px)
	_sky_mat.set_shader_parameter("use_texture", true)
	_sky_mat.set_shader_parameter("brightness", sky_brightness)
	_sky_mat.set_shader_parameter("saturation", sky_saturation)
	_sky_mat.set_shader_parameter("contrast", sky_contrast)
	_sky_mat.set_shader_parameter("color_shift", sky_shift)
	_sky.material = _sky_mat
	add_child(_sky)

	# --- 左侧深色斜切区 ---
	_veil = ColorRect.new()
	_veil.name = "Veil"
	_veil.color = Color.WHITE
	_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_veil_mat = UiKit.slant_material(0, edge_bottom_x, Color(UiKit.INK.r, UiKit.INK.g, UiKit.INK.b, veil_alpha), 0.0)
	_veil_mat.set_shader_parameter("grain", 0.012)
	_veil.material = _veil_mat
	_veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_veil)

	# --- 右侧暗化（子界面用）---
	# ⚠ 不能用 modulate 控制浓度：自定义 shader 里直接赋值 COLOR 会覆盖 modulate，
	#   所以浓度必须走 tint 的 alpha uniform。
	_dim_rect = ColorRect.new()
	_dim_rect.name = "Dim"
	_dim_rect.color = Color.WHITE
	_dim_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim_mat = UiKit.slant_material(1, edge_bottom_x, Color(0.01, 0.02, 0.03, dim), 0.0)
	_dim_rect.material = _dim_mat
	_dim_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_dim_rect)
	_apply_dim(dim)


func _layout() -> void:
	if _sky != null:
		_sky.position = size * eye_anchor
		_sky.scale = Vector2(sky_scale, sky_scale)


func set_dim(value: float, animated_time: float = 0.35) -> void:
	var to := clampf(value, 0.0, 1.0)
	var from := dim
	dim = to
	if _dim_mat == null:
		return
	if animated_time <= 0.0:
		_apply_dim(to)
		return
	# 单调缓动（in_out）：压暗不抖
	var tw := create_tween()
	tw.tween_method(func(u: float) -> void:
		_apply_dim(lerpf(from, to, UiKit.ease_named(&"in_out", u)))
	, 0.0, 1.0, animated_time)


func _apply_dim(value: float) -> void:
	if _dim_mat == null:
		return
	_dim_mat.set_shader_parameter("tint", Color(0.01, 0.02, 0.03, clampf(value, 0.0, 1.0)))


## 大图形沿分界线向右滑出（0 = 完整，1 = 消失）
func set_reveal(value: float) -> void:
	_reveal = value
	for m in [_sky_mat, _veil_mat, _dim_mat]:
		if m != null:
			m.set_shader_parameter("reveal", _reveal)


func reveal_tween(to: float, dur: float, ease_name: StringName = &"in_cubic", delay: float = 0.0) -> Tween:
	var from := _reveal
	var tw := create_tween()
	if delay > 0.0:
		tw.tween_interval(delay)
	tw.tween_method(func(u: float) -> void:
		set_reveal(lerpf(from, to, UiKit.ease_named(ease_name, u)))
	, 0.0, 1.0, dur)
	return tw
