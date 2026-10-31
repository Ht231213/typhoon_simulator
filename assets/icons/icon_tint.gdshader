shader_type canvas_item;
// 台风图标的「色相 + 亮度」调制（1.2.0）。
//
// 参考工程（Scratch）用的是两个图形特效：
//   · COLOR      = 色相偏移（0–200 一圈，负值反向 → 往蓝紫）
//   · BRIGHTNESS = 明度偏移
// 参考公式（SMCY 风格 C5 段，见 docs/参考_图标伪代码.md §5）：
//   COLOR      = 0.75 × (135 − Kt)        → 负值 = 蓝紫，单位是 Scratch 的 0–200
//   BRIGHTNESS = 1.25 × (Kt − 170)        （169–200 kt 档）
//              = 1.50 × (Kt − 170)        （199+ kt 档）
// 下面把这些换算成 shader 参数：hue_shift 是「圈数」（= COLOR / 200），
// bright 是明度增量（= BRIGHTNESS / 100），blue_mix 是为了让 ≥170 kt 明确偏蓝，
// 在色相旋转之外再往蓝紫方向混一点（纯色相旋转在橙色上会转到绿/青，观感不够"冷"）。

uniform float hue_shift : hint_range(-1.0, 1.0) = 0.0;
uniform float bright : hint_range(0.0, 1.5) = 0.0;
uniform float blue_mix : hint_range(0.0, 1.0) = 0.0;
// 「≥260 kt 白色阶段」开关（2026-10-30 用户：亮蓝保留、只关最后的白色）：
//   0 = 提亮的目标色是**最亮的蓝**（不会把图标上的数字/闪电吃掉）
//   1 = 参考工程原版：往纯白推（≥260 kt 会变白，看不清图案）
uniform float white_allow : hint_range(0.0, 1.0) = 0.0;
// 底色（简单圆圈方案用：白圈乘上强度色；SMCY 方案保持白色 = 不变）
uniform vec4 base_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// 整体不透明度（用于消散时的淡出，1 = 正常）
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
	vec3 rgb = clamp(abs(mod(c.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
	return c.z * mix(vec3(1.0), rgb, c.y);
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	vec3 rgb = tex.rgb;
	float a = tex.a;

	// ① 色相旋转（Scratch COLOR 的等效）
	if (abs(hue_shift) > 0.0001) {
		vec3 hsv = rgb2hsv(rgb);
		hsv.x = fract(hsv.x + hue_shift);
		rgb = hsv2rgb(hsv);
	}

	// ② ≥170 kt 往蓝紫偏（色相旋转 + 这个混色一起才是"亮蓝"的观感）
	if (blue_mix > 0.0001) {
		// 目标冷色：亮蓝偏紫
		vec3 cold = vec3(0.55, 0.80, 1.0);
		rgb = mix(rgb, cold * max(max(rgb.r, rgb.g), rgb.b), blue_mix);
	}

	// ③ 提亮（Scratch BRIGHTNESS 的等效）。
	//    默认往「最亮的蓝」提 —— 亮蓝保留，但不会把数字/闪电烧成白色；
	//    只有打开「白色阶段」才推到纯白（参考工程原版行为）。
	vec3 lift = mix(vec3(0.62, 0.85, 1.0), vec3(1.0), white_allow);
	rgb = mix(rgb, lift, clamp(bright, 0.0, 1.0) * 0.55);
	rgb = min(rgb * (1.0 + bright * 0.35), vec3(1.0));

	rgb *= base_tint.rgb;
	COLOR = vec4(rgb, a * fade);
}
