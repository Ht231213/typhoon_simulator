shader_type canvas_item;
// 视频素材抠像（用户 2026-11-05 定的规则）：
//   「我的视频素材背景是黑的，大胆裁吧！亮度 < 50% (#888888) 的都扣掉！」
// 亮度用 ITU-R BT.601：luma = 0.299R + 0.587G + 0.114B
// luma < 0.45 → 全透明；0.45~0.55 之间软过渡（避免硬边锯齿）；> 0.55 → 不透明。
// ⚠ 不再有「黑底/白底」两套（旧的 key_white 已删）。
uniform float low_cut : hint_range(0.0, 1.0) = 0.45;
uniform float high_cut : hint_range(0.0, 1.0) = 0.55;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float luma = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
	float a = smoothstep(low_cut, high_cut, luma);
	// COLOR 此时是 modulate（用来做淡入淡出/叠化），乘上去保留它的 alpha
	COLOR = vec4(tex.rgb, tex.a * a) * COLOR;
}
