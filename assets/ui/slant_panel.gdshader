shader_type canvas_item;
render_mode blend_mix;

// 2.0 界面的「斜切」基础。整块背景用同一条分界线：分界线斜率 = slant，
// 与菜单按钮左右边的斜率完全一致，保证视觉上是同一套几何。
//
// mode = 0 → 保留分界线**左侧**（深色操作区 / 遮罩）
// mode = 1 → 保留分界线**右侧**（卫星云图 / 背景大图形）
// reveal 0→1 时整块图形沿分界线向右滑出（菜单切换时「背景的大图形消失」）
//
// ⚠ 边界一律用 SCREEN_UV 计算：节点自身怎么放大/平移都不影响分界线的位置，
//   UV 只用来采样纹理（这样 Sprite2D 能随便摆位置）。

uniform int mode = 0;
uniform float bottom_x = 0.30;      // 分界线在画面底部的 x（0..1，相对屏幕宽度）
uniform float slant = 0.45;         // 每 1 px 高度对应的水平偏移（与按钮同一斜率）
uniform float softness_px = 1.2;    // 边缘抗锯齿
uniform float reveal : hint_range(0.0, 1.2) = 0.0;
uniform vec4 tint : source_color = vec4(0.02, 0.03, 0.05, 0.92);
uniform vec4 line_color : source_color = vec4(0.62, 0.90, 1.0, 0.55);
uniform float line_px = 0.0;        // >0 时沿分界线画一条亮线
uniform float line_alpha = 1.0;
uniform float grain = 0.0;          // 轻微颗粒，防止纯色区域出现色带
uniform bool use_texture = false;   // 用节点自身纹理（云图）
uniform float brightness = 1.0;     // 纹理亮度
uniform float saturation = 1.0;     // 纹理饱和度
uniform float contrast = 1.0;       // 纹理对比度
uniform vec4 color_shift : source_color = vec4(1.0, 1.0, 1.0, 1.0);  // 纹理偏色（冷/暖）

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// 分界线在给定屏幕高度处的 x（0..1）。
// ⚠ 内建变量（SCREEN_PIXEL_SIZE 等）只能在 fragment 里直接读，
//   自定义函数必须由调用方传进来。
float edge_x(float screen_y, vec2 px_size) {
	float h_over_w = max(px_size.x, 1e-6) / max(px_size.y, 1e-6);
	float dx_uv = slant * h_over_w;
	return bottom_x + (1.0 - screen_y) * dx_uv + reveal * 1.35;
}

void fragment() {
	vec2 suv = SCREEN_UV;
	float bx = edge_x(suv.y, SCREEN_PIXEL_SIZE);

	float aa = softness_px * SCREEN_PIXEL_SIZE.x;
	float d = suv.x - bx;                            // >0 在右侧

	float keep;
	if (mode == 0) {
		keep = 1.0 - smoothstep(-aa, aa, d);
	} else {
		keep = smoothstep(-aa, aa, d);
	}

	vec4 col;
	if (use_texture) {
		col = texture(TEXTURE, UV);
		float g = dot(col.rgb, vec3(0.299, 0.587, 0.114));
		col.rgb = mix(vec3(g), col.rgb, saturation);
		col.rgb = (col.rgb - 0.5) * contrast + 0.5;
		col.rgb *= color_shift.rgb;
		col.rgb *= brightness;
	} else {
		col = tint;
	}

	if (grain > 0.0) {
		float n = hash(floor(suv / SCREEN_PIXEL_SIZE)) - 0.5;
		col.rgb += n * grain;
	}

	if (line_px > 0.0 && line_alpha > 0.0) {
		float lw = line_px * SCREEN_PIXEL_SIZE.x;
		float line = 1.0 - smoothstep(lw * 0.5, lw * 0.5 + aa, abs(d));
		col = mix(col, vec4(line_color.rgb, line_color.a * line_alpha), line);
	}

	col.a *= keep;
	if (col.a <= 0.002) {
		discard;
	}
	COLOR = col;
}
