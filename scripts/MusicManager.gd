extends Node
## ⚠ 说明：这是 autoload（MusicManager）。由 project.godot 的 [autoload] 注册。
## 背景音乐播放器（用户 2026-11-06）：
##   标题画面 → music.titlescreen
##   模拟过程 → 从 music.ty.1 .. ty.20 里**随机抽一首**，避免连续重复，一曲结束自动下一曲
##   音量走 Music 总线（设置里的「音乐音量」滑块；没有音乐 ID 时滑块隐藏）
## 素材来自**当前方案包**（IconPacks）；方案包没有 music.* → 静音。

var _title: AudioStreamPlayer = null
var _sim: AudioStreamPlayer = null
var _last_ty_id := ""


func _ready() -> void:
	_title = _make_player()
	_sim = _make_player()
	_sim.finished.connect(_play_next_sim_track)


func _make_player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = GameSettings.BUS_MUSIC
	add_child(p)
	return p


## 当前方案包里的所有音乐 ID
func music_ids() -> Array[String]:
	var out: Array[String] = []
	for id in IconPacks.objects(GameSettings.icon_pack).keys():
		if str(id).begins_with("music."):
			out.append(str(id))
	out.sort()
	return out


## 方案包有没有任何音乐（→ 决定设置里「音乐音量」滑块显示/隐藏）
func has_music() -> bool:
	return not music_ids().is_empty()


func _sim_track_ids() -> Array[String]:
	var out: Array[String] = []
	for id in music_ids():
		if id.begins_with("music.ty."):
			out.append(id)
	return out


func play_title() -> void:
	_sim.stop()
	var st := IconPacks.audio(GameSettings.icon_pack, "music.titlescreen")
	if st == null:
		_title.stop()
		return
	_title.stream = st
	_title.play()


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
