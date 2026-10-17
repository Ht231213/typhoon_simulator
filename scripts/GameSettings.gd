extends Node
## [autoload: GameSettings] 应用级设置：视频 / 音频。
##
## 与 Game.gd 的分工：
##   · Game      = 一局模拟的状态（模式、台风数据、ACE 存档）
##   · GameSettings = 应用设置（音量、全屏、音效预设），存到 user://settings.cfg
##
## 音频走两个独立总线：
##   Music 总线 → 背景音乐
##   SFX   总线 → 音效（登陆音效等）

signal changed

const SAVE_PATH := "user://settings.cfg"
const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"

## 音效素材根目录下的所有预设（每个预设是一个子目录，里面有 landfall/*.wav）
const SFX_PRESETS: Array[String] = ["zmrtysimu"]
const DEFAULT_SFX_PRESET := "zmrtysimu"

# ------------------------- 设置项 -------------------------
## 音乐音量 0..1（线性，写入总线时转 dB）
var music_volume := 0.8
## 音效音量 0..1
var sfx_volume := 1.0
## 是否全屏
var fullscreen := false
## 音效预设名（对应 assets/sfx/<名字>/）
var sfx_preset := DEFAULT_SFX_PRESET

# ------------------------- 模拟设置（1.1.0 新增）-------------------------
# ⚠ 这些不是"玩家偏好"，而是**影响模拟结果的参数**。
#   和 Const 里的出厂默认值分开存，因为玩家可以在「模拟设置」里改。
#   出厂默认值本身来自 Const，保证只有一处定义。
#
# 海温：SimClock.seasonal_sst_amplitude() 直接用这两个值：
#   海温增幅（最终）= sin((月份−5)×30) × seasonal_amplitude + (mean_sst − 30)
## 平均海温（℃）。默认 = Const.MEAN_SST。可设 20~100（用户 2026-10-17：大数值增加可玩性）
var mean_sst := Const.MEAN_SST
## 季节海温增幅（℃）。默认 = Const.SEASONAL_AMPLITUDE
var seasonal_amplitude := Const.SEASONAL_AMPLITUDE
## 是否把热带扰动和热带低压（<30 kt）也记进台风列表。
## ⚠ **不影响 ACE 排行榜** —— ACE 只统计台风级（≥34 kt）及以上。
var record_disturbances := false
## 是否记录最佳路径数据集
var best_track_enabled := false
## 最佳路径导出目录。空字符串 = 用默认目录（游戏根目录下的 BestTrack/）
var best_track_dir := ""
## 风速显示单位：0=kt 1=m/s 2=km/h（对应 TyphoonSim.WIND_UNITS）
var wind_unit_index := 0


func _ready() -> void:
	_ensure_buses()
	_route_music_players()
	_load()
	apply_all()


## 把「播放音乐」的播放器挂到 Music 总线上。
##
## ⚠ 为什么要在代码里做，而不是在场景里把 `bus` 设成 Music：
##   `AudioStreamPlayer.bus` 是普通属性，但 Godot 编辑器保存场景时会把它丢掉
##   （实测 `TitleScreen.tscn` 里的 `bus = &"Music"` 被编辑器重写两次都消失了），
##   结果就是「音乐音量滑块怎么拖都没反应」——滑块改的是 Music 总线，
##   而 BGM 还挂在 Master 上。改成代码设置后编辑器不会再碰。
##
## 用法：想让某个播放器受音乐音量控制，给它加进 `music` 组即可，
## 或者在节点上加个 `is_music` 元数据。
const MUSIC_GROUP := "music"


func _route_music_players() -> void:
	var idx := AudioServer.get_bus_index(BUS_MUSIC)
	if idx < 0:
		return
	var found := 0
	for node in get_tree().get_nodes_in_group(MUSIC_GROUP):
		register_music_player(node)
		found += 1
	if found > 0:
		print("[GameSettings] 已把 %d 个音频播放器挂到 Music 总线" % found)


## 确保 Music / SFX 两条总线存在（autoload 先于所有场景运行，所以在这里建最稳）
func _ensure_buses() -> void:
	# Music 总线插在 Master 之前，方便整体再被 Master 音量统管
	if AudioServer.get_bus_index(BUS_MUSIC) < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, BUS_MUSIC)
		AudioServer.set_bus_send(AudioServer.bus_count - 1, "Master")
	if AudioServer.get_bus_index(BUS_SFX) < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, BUS_SFX)
		AudioServer.set_bus_send(AudioServer.bus_count - 1, "Master")


# ============================ 应用 ============================

func apply_all() -> void:
	_apply_bus(BUS_MUSIC, music_volume)
	_apply_bus(BUS_SFX, sfx_volume)
	_apply_fullscreen(fullscreen)
	changed.emit()


## 以下 setter 都是「改动立即保存」——设置界面没有确定按钮，
## 唯一的「返回」只是关掉界面，所以每次改动都要落盘。
func set_music_volume(value: float) -> void:
	music_volume = clampf(value, 0.0, 1.0)
	_apply_bus(BUS_MUSIC, music_volume)
	_save()
	changed.emit()


func set_sfx_volume(value: float) -> void:
	sfx_volume = clampf(value, 0.0, 1.0)
	_apply_bus(BUS_SFX, sfx_volume)
	_save()
	changed.emit()


## 切换全屏。**会验证是否真的生效**——编辑器内嵌窗口不支持全屏，
## `window_set_mode` 会被静默忽略。这种情况把状态改回去，别让勾选框骗人。
## 返回值：true = 生效，false = 当前环境不支持（已回滚）
func set_fullscreen(value: bool) -> bool:
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if value else DisplayServer.WINDOW_MODE_WINDOWED
	_apply_fullscreen(value)
	var real := DisplayServer.window_get_mode()
	var ok := real == want
	fullscreen = value if ok else not value
	_save()
	changed.emit()
	return ok


func set_sfx_preset(preset: String) -> void:
	if SFX_PRESETS.has(preset) and preset != sfx_preset:
		sfx_preset = preset
		_save()
		changed.emit()


## 供场景在运行时登记音乐播放器（比依赖场景里的 bus 属性可靠）
func register_music_player(player: Node) -> void:
	if player is AudioStreamPlayer:
		(player as AudioStreamPlayer).bus = BUS_MUSIC
	elif player is AudioStreamPlayer2D:
		(player as AudioStreamPlayer2D).bus = BUS_MUSIC
	elif player is AudioStreamPlayer3D:
		(player as AudioStreamPlayer3D).bus = BUS_MUSIC


## 线性音量 → 总线 dB。0 直接静音（dB 的 -inf 不好处理）
func _apply_bus(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.001)))


## 全屏切换：直接调用，不做任何环境判断
func _apply_fullscreen(value: bool) -> void:
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if value else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)


# ============================ 音效预设路径 ============================

func sfx_root() -> String:
	return "res://assets/sfx/%s/" % sfx_preset


## 登陆音效路径。index：0 = TS，1..5 = C1..C5
func landfall_sfx_path(index: int) -> String:
	const FILES: Array[String] = ["TS.wav", "c1.wav", "c2.wav", "c3.wav", "c4.wav", "c5.wav"]
	return sfx_root() + "landfall/" + FILES[clampi(index, 0, FILES.size() - 1)]


# ============================ 存档 ============================

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "music_volume", music_volume)
	cfg.set_value("audio", "sfx_volume", sfx_volume)
	cfg.set_value("audio", "sfx_preset", sfx_preset)
	cfg.set_value("video", "fullscreen", fullscreen)
	# 模拟设置
	cfg.set_value("sim", "mean_sst", mean_sst)
	cfg.set_value("sim", "seasonal_amplitude", seasonal_amplitude)
	cfg.set_value("sim", "record_disturbances", record_disturbances)
	cfg.set_value("sim", "best_track_enabled", best_track_enabled)
	cfg.set_value("sim", "best_track_dir", best_track_dir)
	cfg.set_value("sim", "wind_unit_index", wind_unit_index)
	var err := cfg.save(SAVE_PATH)
	if err != OK:
		push_warning("设置写入失败：%s" % SAVE_PATH)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return                                  # 没有存档就用默认值
	music_volume = clampf(float(cfg.get_value("audio", "music_volume", music_volume)), 0.0, 1.0)
	sfx_volume = clampf(float(cfg.get_value("audio", "sfx_volume", sfx_volume)), 0.0, 1.0)
	fullscreen = bool(cfg.get_value("video", "fullscreen", fullscreen))
	var preset := str(cfg.get_value("audio", "sfx_preset", sfx_preset))
	if SFX_PRESETS.has(preset):
		sfx_preset = preset
	# 模拟设置（夹到界面允许的范围，防止手改配置文件搞出离谱值）
	mean_sst = clampf(float(cfg.get_value("sim", "mean_sst", mean_sst)), 20.0, 100.0)
	seasonal_amplitude = clampf(
		float(cfg.get_value("sim", "seasonal_amplitude", seasonal_amplitude)), 0.0, 4.0)
	record_disturbances = bool(cfg.get_value("sim", "record_disturbances", record_disturbances))
	best_track_enabled = bool(cfg.get_value("sim", "best_track_enabled", best_track_enabled))
	best_track_dir = str(cfg.get_value("sim", "best_track_dir", best_track_dir))
	wind_unit_index = clampi(int(cfg.get_value("sim", "wind_unit_index", wind_unit_index)), 0, 2)


## 改海温相关参数后调一次：广播变化让各系统重新取用
func set_sim_sst(mean_value: float, season_value: float) -> void:
	mean_sst = clampf(mean_value, 20.0, 100.0)
	seasonal_amplitude = clampf(season_value, 0.0, 4.0)
	_save()
	changed.emit()


## 风速单位（0=kt 1=m/s 2=km/h）。TyphoonSim.wind_unit_index 会转发到这里。
func set_wind_unit_index(index: int) -> void:
	var v := clampi(index, 0, 2)
	if v == wind_unit_index:
		return
	wind_unit_index = v
	_save()
	changed.emit()


## 兼容旧调用：现在每次改动就写盘了，commit 只是再存一次
func commit() -> void:
	_save()


func save_path_absolute() -> String:
	return ProjectSettings.globalize_path(SAVE_PATH)
