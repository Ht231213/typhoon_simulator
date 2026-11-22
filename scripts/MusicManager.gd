extends Node
## ⚠ 说明：这是 autoload（MusicManager）。由 project.godot 的 [autoload] 注册。
## 背景音乐播放器：
##   标题画面 → 优先 2.0 内置的 theme（assets/audio/title_loop.*），
##              没有就退回方案包的 music.titlescreen
##   模拟过程 → 从 music.simu.1 .. simu.20 里**随机抽一首**，避免连续重复，一曲结束自动下一曲
##   音量走 Music 总线（设置里的「音乐音量」滑块；没有任何音乐时滑块隐藏）
## 素材来自**当前方案包**（IconPacks），方案包没有 music.* 就静音（2.0 的内置标题曲除外）。

const BUS_MUSIC := "Music"

## 2.0 内置曲子：**启动动画和主界面共用同一个文件**，播完循环的也是它。
## 想换成别的：把音频放成 assets/audio/title_loop.ogg（会优先使用，且启动动画也用它）。
const CUSTOM_TITLE_CANDIDATES: Array[String] = [
	"res://assets/audio/title_loop.ogg",
	"res://assets/audio/boot_theme.wav",
]
## 统一音量（曲子母带接近 0 dBFS，压一点给音效留头）
const MUSIC_DB := -3.0

var _title: AudioStreamPlayer = null
var _sim: AudioStreamPlayer = null
var _last_ty_id := ""
## 启动动画开始播过之后，主界面要**接着播**同一首，不从头再来
var _boot_started := false


func _ready() -> void:
	_title = _make_player()
	_sim = _make_player()
	_sim.finished.connect(_play_next_sim_track)


func _make_player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = GameSettings.BUS_MUSIC
	add_child(p)
	return p


## 内置标题曲（没有则 null）
func custom_title_stream() -> AudioStream:
	for path in CUSTOM_TITLE_CANDIDATES:
		if not ResourceLoader.exists(path):
			continue
		var st: AudioStream = load(path)
		if st == null:
			continue
		# 让 wav 循环播放（ogg 的循环在导入设置里，这里兜底再开一次）
		if st is AudioStreamOggVorbis:
			st.loop = true
		elif st is AudioStreamWAV:
			st.loop_mode = AudioStreamWAV.LOOP_FORWARD
			# ⚠ loop_end 的单位是「采样帧」。用 get_length() × 采样率算，
			#   不要按 data.size() 去除 —— wav 可能被导入成 QOA/ADPCM 压缩，
			#   那样字节数不等于 PCM 长度，循环点会落在半首歌的地方（听起来只有几十秒）。
			st.loop_begin = 0
			st.loop_end = int(round(st.get_length() * float(st.mix_rate)))
		return st
	return null


## 当前方案包里的所有音乐 ID
func music_ids() -> Array[String]:
	var out: Array[String] = []
	for id in IconPacks.objects(GameSettings.icon_pack).keys():
		if str(id).begins_with("music."):
			out.append(str(id))
	out.sort()
	return out


## 有没有音乐可播（→ 决定设置里「音乐音量」滑块显示/隐藏）
func has_music() -> bool:
	if custom_title_stream() != null:
		return true
	return not music_ids().is_empty()


func _sim_track_ids() -> Array[String]:
	var out: Array[String] = []
	for id in music_ids():
		if id.begins_with("music.simu."):
			out.append(id)
	return out


func play_title() -> void:
	_sim.stop()
	var st := custom_title_stream()
	if st == null:
		st = IconPacks.audio(GameSettings.icon_pack, "music.titlescreen")
	if st == null:
		_title.stop()
		return
	_title.stream = st
	_title.volume_db = MUSIC_DB
	_title.play()
	_boot_started = true


## 启动动画：同一首曲子从 0 开始播（它是循环流，播完自己会接回曲头）
func play_boot() -> void:
	_sim.stop()
	var st := custom_title_stream()
	if st == null:
		return
	_title.stream = st
	_title.volume_db = MUSIC_DB
	_title.play()
	_boot_started = true


## 音乐当前播放位置（启动动画拿它当时间轴，好卡在鼓点上）
func boot_position() -> float:
	if _title == null or not _title.playing:
		return -1.0
	return _title.get_playback_position()


## 跳到指定位置（启动动画「任意键跳过」用）
func seek_title(sec: float) -> void:
	if _title == null or _title.stream == null:
		return
	if not _title.playing:
		_title.play()
	_title.seek(maxf(sec, 0.0))


func is_boot_playing() -> bool:
	return _boot_started and _title != null and _title.playing


## 主界面：启动那段音乐还在放就接着放，别重新开始
func continue_title() -> void:
	if is_boot_playing():
		_sim.stop()
		return
	play_title()


func play_sim() -> void:
	# 用户 2026-11-06：进入模拟场景时标题音乐必须停
	_title.stop()
	_last_ty_id = ""
	_play_next_sim_track()


func _play_next_sim_track() -> void:
	var ids := _sim_track_ids()
	if ids.is_empty():
		_sim.stop()
		return
	# 随机抽，排除上一首（避免连续重复）
	var pick := ids[randi() % ids.size()]
	if ids.size() > 1 and pick == _last_ty_id:
		pick = ids[(ids.find(pick) + 1) % ids.size()]
	_last_ty_id = pick
	var st := IconPacks.audio(GameSettings.icon_pack, pick)
	if st == null:
		return
	_sim.stream = st
	_sim.play()


func stop_sim() -> void:
	_sim.stop()


## 方案包换了 → 重新开始播（标题画面/模拟中调用方各自再触发一次）
func refresh_pack() -> void:
	_title.stop()
	_sim.stop()
	_last_ty_id = ""
