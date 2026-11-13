extends SceneTree
## 一次性校验：所有缓动函数必须在 0..1 上单调递增，且端点严格是 0 和 1。
## 只要有一个不单调，动画就会「来回抖」——这正是之前波浪感的来源。

const NAMES := ["out_cubic", "out_quint", "out_quad", "out_expo", "out_sine",
	"in_cubic", "in_quad", "in_out", "linear", "unknown_name"]


func _initialize() -> void:
	var bad := 0
	for n in NAMES:
		var prev := -1.0
		var monotonic := true
		var max_jump := 0.0
		for i in 201:
			var t := float(i) / 200.0
			var v: float = UiKit.ease_named(StringName(n), t)
			if v < prev - 1e-6:
				monotonic = false
			max_jump = maxf(max_jump, absf(v - prev))
			prev = v
		var a: float = UiKit.ease_named(StringName(n), 0.0)
		var b: float = UiKit.ease_named(StringName(n), 1.0)
		var endpoints_ok := absf(a) < 1e-6 and absf(b - 1.0) < 1e-6
		if not monotonic or not endpoints_ok:
			bad += 1
		print("[ease] %-13s monotonic=%s endpoints=%s (0=>%.3f, 1=>%.3f) max_step=%.3f" % [
			n, str(monotonic), str(endpoints_ok), a, b, max_jump])
	print("[ease] ", "ALL OK" if bad == 0 else ("FAILED: %d" % bad))
	quit()
