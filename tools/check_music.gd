extends SceneTree
## 校验背景音乐的循环点：loop_end 必须覆盖整首（不是一半）。

func _initialize() -> void:
	var mm := root.get_node_or_null("MusicManager")
	var st: AudioStream = null
	if mm != null:
		st = mm.call("custom_title_stream")
	if st == null:
		print("[music] no custom stream")
		quit()
		return
	print("[music] class=", st.get_class(), " length=", snappedf(st.get_length(), 0.01), " s")
	if st is AudioStreamWAV:
		var w := st as AudioStreamWAV
		var bps := 2 if w.format == AudioStreamWAV.FORMAT_16_BITS else 1
		var bpf := bps * (2 if w.stereo else 1)
		var frames := w.data.size() / bpf
		var mix_rate := w.mix_rate
		print("[music] loop_mode=", w.loop_mode, " begin=", w.loop_begin, " end=", w.loop_end,
			" frames=", frames, " mix_rate=", mix_rate)
		print("[music] loop covers ", snappedf(float(w.loop_end) / float(mix_rate), 0.01), " s of ",
			snappedf(float(frames) / float(mix_rate), 0.01), " s")
	quit()
