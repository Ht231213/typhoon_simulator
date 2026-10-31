shader_type canvas_item;
// 把视频图标里的**黑底抠成透明**（1.2.0 视频图标方案）。
//
// 素材是黑底 h264，没有 alpha 通道；`.ogv` 也不带 alpha。做法和当初抽 PNG 时一致：
//   亮度 → alpha（黑 = 0，亮 = 1）。这样叠在卫星底图上不会出现一块黑方块。
// 参数说明：
//   floor_luma：低于它的亮度直接当 0（压掉压缩噪点）
//   boost     ：alpha 曲线指数，>1 让边缘更"干净"，<1 让云系更实
uniform float floor_luma : hint_range(0.0, 0.3) = 0.04;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float luma = max(max(tex.r, tex.g), tex.b);
	float a = smoothstep(floor_luma, floor_luma + 0.12, luma);
	// COLOR 此时是 modulate（我们在 GDScript 里用它做强度着色/消散淡出）
	COLOR = vec4(tex.rgb, a) * COLOR;
}
