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

## 视觉/音效「方案」（用户 2026-10-30 决定拆两套）。
## 一个方案同时决定三样东西（A3）：
##   · 图标   `assets/icons/<方案>/`
##   · 登陆特效 `assets/effects/<方案>/`
##   · 登陆音效 `assets/sfx/<方案>/landfall/*.wav`
## ⚠ Default 是旧版「简单圆圈」，SMCY1.3 是图标库那套 —— **互斥，不能混用**。
const PRESET_SCHEMES: Array[String] = ["default", "smcy13"]
const PRESET_LABELS := {
	"default": "Default（简单圆圈）",
	"smcy13": "SMCY1.3（图标库）",
}
const DEFAULT_PRESET_SCHEME := "default"

# ------------------------- 设置项 -------------------------
## 音乐音量 0..1（线性，写入总线时转 dB）
var music_volume := 0.8
## 音效音量 0..1
var sfx_volume := 1.0
## 是否全屏
var fullscreen := false
## 音效预设名（跟随方案，见 PRESET_SCHEMES）
var sfx_preset := DEFAULT_PRESET_SCHEME

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
## 最佳路径导出格式："noaa"（IBTrACS，1.2.0 起默认）/ "cma"（中国气象局）
var best_track_format := "noaa"
## 允许的格式值 + UI 下拉顺序的**唯一真源**（sim 设置下拉按这个顺序建项，别处别抄）
const BEST_TRACK_FORMATS: Array[String] = ["noaa", "cma"]
## 风速显示单位：0=kt 1=m/s 2=km/h（对应 TyphoonSim.WIND_UNITS）
var wind_unit_index := 0

# ------------------------- 图标 / 登陆特效方案（1.2.1 新增）-------------------------
# 值就是 `assets/icons/<名字>/` 或 `assets/effects/<名字>/` 的文件夹名。
# 设置界面每次打开都**重新扫描**（外部目录 + 内置），所以用户新放一个文件夹就多一个选项；
# 文件夹被删也不用管——取素材时找不到会自动回退 `default` 方案。
## 台风图标方案
var icon_scheme := "default"
## 登陆特效方案
var effect_scheme := "default"
## 「170 kt+ 亮蓝扩展」（B4）：勾上才把 ≥170 kt 的图标提亮/变白；
## 默认关（变白后 SMCY 图标上的数字/闪电看不清）。只在方案 = smcy13 时显示这个勾选框。
var icon_bright_ext := false
## 当前方案名（图标/特效/音效统一由它决定，见 PRESET_SCHEMES）
var preset_scheme := DEFAULT_PRESET_SCHEME


## 切换方案：图标/特效/音效一起换（A3 要求"跟随同一个方案选择"）
func set_preset_scheme(name: String) -> void:
	if not PRESET_SCHEMES.has(name):
		name = DEFAULT_PRESET_SCHEME
	if name == preset_scheme:
		return
	preset_scheme = name
	icon_scheme = name
	effect_scheme = name
	sfx_preset = name
	_save()
	changed.emit()


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
	if PRESET_SCHEMES.has(preset) and preset != sfx_preset:
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


## 登陆音效路径。index：0 = TS，1..5 = C1..C5。
## ⚠ 两种素材格式：默认方案是 `.wav`，SMCY1.3 是官方 `.ogg` → 先找 ogg 再找 wav。
func landfall_sfx_path(index: int) -> String:
	const FILES: Array[String] = ["TS", "c1", "c2", "c3", "c4", "c5"]
	var base := sfx_root() + "landfall/" + FILES[clampi(index, 0, FILES.size() - 1)]
	return _first_existing([base + ".ogg", base + ".wav"])


## 事件音效（2026-10-30 新增）：form 形成 / intensify 增强 / weaken 减弱 / dissipate 消散。
## 素材**目前没有**（SMCY 库里只有 landfall 音效）→ 返回 ""，游戏里就是静音，以后放了素材自动生效。
func event_sfx_path(kind: String) -> String:
	var base := sfx_root() + kind
	return _first_existing([base + ".ogg", base + ".wav"])


func _first_existing(paths: Array) -> String:
	for p in paths:
		if ResourceLoader.exists(p):
			return p
	return ""


# ============================ 存档 ============================

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "music_volume", music_volume)
	cfg.set_value("audio", "sfx_volume", sfx_volume)
	cfg.set_value("audio", "sfx_preset", sfx_preset)
	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.set_value("video", "preset_scheme", preset_scheme)
	cfg.set_value("video", "icon_bright_ext", icon_bright_ext)
	cfg.set_value("video", "icon_scheme", icon_scheme)
	cfg.set_value("video", "effect_scheme", effect_scheme)
	# 模拟设置
	cfg.set_value("sim", "mean_sst", mean_sst)
	cfg.set_value("sim", "seasonal_amplitude", seasonal_amplitude)
	cfg.set_value("sim", "record_disturbances", record_disturbances)
	cfg.set_value("sim", "best_track_enabled", best_track_enabled)
	cfg.set_value("sim", "best_track_dir", best_track_dir)
	cfg.set_value("sim", "best_track_format", best_track_format)
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
	# 方案（图标+特效+音效一起）。旧的 `sfx_preset="zmrtysimu"` 视同 Default（旧版那套素材）。
	var scheme := str(cfg.get_value("video", "preset_scheme", ""))
	if scheme == "":
		scheme = str(cfg.get_value("audio", "sfx_preset", DEFAULT_PRESET_SCHEME))
	if scheme == "zmrtysimu":
		scheme = "default"
	if not PRESET_SCHEMES.has(scheme):
		scheme = DEFAULT_PRESET_SCHEME
	preset_scheme = scheme
	icon_scheme = scheme
	effect_scheme = scheme
	sfx_preset = scheme
	icon_bright_ext = bool(cfg.get_value("video", "icon_bright_ext", icon_bright_ext))
	# 模拟设置（夹到界面允许的范围，防止手改配置文件搞出离谱值）
	mean_sst = clampf(float(cfg.get_value("sim", "mean_sst", mean_sst)), 20.0, 100.0)
	seasonal_amplitude = clampf(
		float(cfg.get_value("sim", "seasonal_amplitude", seasonal_amplitude)), 0.0, 4.0)
	record_disturbances = bool(cfg.get_value("sim", "record_disturbances", record_disturbances))
	best_track_enabled = bool(cfg.get_value("sim", "best_track_enabled", best_track_enabled))
	best_track_dir = str(cfg.get_value("sim", "best_track_dir", best_track_dir))
	# 白名单校验：手改坏的 settings.cfg 不能直接把任意字符串塞进 writer 字典
	var fmt := str(cfg.get_value("sim", "best_track_format", best_track_format))
	if BEST_TRACK_FORMATS.has(fmt):
		best_track_format = fmt
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
