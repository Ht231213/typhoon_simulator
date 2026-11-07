shader_type canvas_item;
// 视频素材抠像：**反预乘（un-premultiply）+ 预乘 alpha 混合**（用户 2026-11-05 定案）
//
// 为什么不用亮度阈值：素材是「半透明动画叠在黑底上」导出的，像素 C = A × F（已被乘过透明度），
// 半透明处天然偏暗。按亮度 <50% 抠会把整圈光晕砍掉（边缘发硬、变暗）。
//
// 正确做法（背景是纯黑，所以最大通道 ≈ 原图 alpha）：
//     a   = max(C.r, C.g, C.b)          // ≈ 原 alpha
//     rgb = C.rgb / max(a, 0.004)       // 反预乘：恢复原本亮度
//     COLOR = vec4(rgb * a, a)          // 输出**预乘**颜色
// 并且必须用预乘混合（blend_premul_alpha），否则半透明处又会变暗 —— 等于没修。
render_mode blend_premul_alpha;

// 可选调色（在反预乘之后乘，避免被 alpha 干扰）；默认白色 = 不调
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// 色相旋转（度）：保持饱和度和亮度，白色像素（低饱和）不受影响
uniform float hue_shift_deg : hint_range(-180.0, 180.0) = 0.0;
// 档内颜色渐变（用户 2026-11-07）：朝下一档官方色的色相偏移（度），叠加在 hue_shift 之后
uniform float tier_hue_deg : hint_range(-180.0, 180.0) = 0.0;
// 额外整体透明度（叠加在 modulate 的 alpha 上，用于淡入淡出/叠化）
uniform float fade : hint_range(0.0, 1.0) = 1.0;


vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}


vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float a = max(c.r, max(c.g, c.b));
	vec3 rgb = c.rgb / max(a, 0.004);
	// 先按反预乘后的亮色乘调色，再重新预乘
	rgb *= tint.rgb;
	if (abs(hue_shift_deg) > 0.001) {
		vec3 hsv = rgb2hsv(rgb);
		hsv.x = fract(hsv.x + hue_shift_deg / 360.0);
		rgb = hsv2rgb(hsv);
	}
	// 顺序：反预乘 → tint → effect hue_shift → 档内颜色渐变（最后）
	if (abs(tier_hue_deg) > 0.001) {
		vec3 hsv2 = rgb2hsv(rgb);
		hsv2.x = fract(hsv2.x + tier_hue_deg / 360.0);
		rgb = hsv2rgb(hsv2);
	}
	float out_a = a * fade * COLOR.a;   // COLOR 此时是 modulate
	COLOR = vec4(rgb * out_a, out_a);
}
