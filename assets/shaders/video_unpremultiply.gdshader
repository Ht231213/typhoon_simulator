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
// 额外整体透明度（叠加在 modulate 的 alpha 上，用于淡入淡出/叠化）
uniform float fade : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float a = max(c.r, max(c.g, c.b));
	vec3 rgb = c.rgb / max(a, 0.004);
	// 先按反预乘后的亮色乘调色，再重新预乘
	rgb *= tint.rgb;
	float out_a = a * fade * COLOR.a;   // COLOR 此时是 modulate
	COLOR = vec4(rgb * out_a, out_a);
}
