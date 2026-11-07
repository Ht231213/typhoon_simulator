extends Node
## [autoload: GameSettings] 应用级设置：视频 / 音频。
##
## 与 Game.gd 的分工：
##   · Game      = 一局模拟的状态（模式、台风数据、ACE 存档）
##   · GameSettings = 应用设置（音量、全屏、方案），存到游戏目录的 settings.cfg
##
## 音频走两个独立总线：
##   Music 总线 → 背景音乐
##   SFX   总线 → 音效（登陆音效等）

signal changed

## 默认设置模板（打包进 pck）。第一次启动复制到游戏目录的 settings.cfg
const TEMPLATE_PATH := "res://config/settings_default.cfg"
## 设置文件名（放在**游戏目录**下，用户可直接编辑）
const SAVE_FILE_NAME := "settings.cfg"
## 方案包扫描（老配置迁移时要用）
const IconPacksLoader := preload("res://scripts/IconPacks.gd")


## 游戏目录：打包版 = exe 所在目录；编辑器 = 工程根
static func game_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://")
	return OS.get_executable_path().get_base_dir()


## 设置文件绝对路径（游戏目录/settings.cfg）
static func save_path() -> String:
	return game_dir().path_join(SAVE_FILE_NAME)


## 第一次启动：把模板复制到游戏目录
static func ensure_default_file() -> void:
	var dst := save_path()
	if FileAccess.file_exists(dst):
		return
	if not FileAccess.file_exists(TEMPLATE_PATH):
		return
	var data := FileAccess.get_file_as_bytes(TEMPLATE_PATH)
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		push_warning("无法创建默认设置文件：%s" % dst)
		return
	f.store_buffer(data)
	f.close()
const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"

## 图标「方案包」（用户 2026-11-05 定）：
##   一个 zip = 一套方案（图标 + 登陆特效 + 登陆音效全在里面）。
##   方案包放在 `<游戏目录>/assets/icons/<方案名>.zip`，**不打包进 pck**；
##   游戏启动时扫这个目录，`IconPacks` 负责读 index.json / 解压缓存。
##   下拉的选项 = 内置 Default（程序化渲染）+ 扫描到的 zip/文件夹方案。
## 内置方案（用户 2026-11-06）：两个都是代码内建、不读 zip、不走 type。
##   Default          = 1.1.1 观感：风圈 + 12 px 小点（无彩色大圆盘、无文字）
##   Advanced default = 当前这套：彩色大圆盘 + 等级文字 + 连续变色
const BUILTIN_PACKS: Array[String] = ["Default", "Advanced default"]
## 默认选中的内置方案（用户建议 Default，1.1.1 最朴素观感）
const DEFAULT_PACK := "Default"
const NO_PACK := DEFAULT_PACK

# ------------------------- 设置项 -------------------------
## 音乐音量 0..1（线性，写入总线时转 dB）
var music_volume := 0.8
## 音效音量 0..1
var sfx_volume := 1.0
## 是否全屏
var fullscreen := false

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

# ------------------------- 图标方案包（2026-11-05）-------------------------
## 启用「等级扩展图标」（+/- 变体）：默认开（用户 2026-11-07 要求做成游戏内勾选框）。
var tier_variants := true
## 当前选中的方案包名（= `assets/icons/<名字>.zip` 的文件名，不含扩展名）。
## "" = 不用方案包（全部程序化渲染）。
var icon_pack := DEFAULT_PACK


## 切换方案包。名字必须真的存在（扫描目录里有的 zip），否则忽略。
## 下拉选项：内置 Default 永远第一，后面是扫描到的 zip/文件夹方案（按名字排序）
func pack_options() -> Array[String]:
	var out: Array[String] = []
	out.append_array(BUILTIN_PACKS)
	for n in IconPacksLoader.pack_names():
		if not BUILTIN_PACKS.has(n):
			out.append(n)
	return out


## 是不是内置方案（内置方案不读 zip / 不走 type）
static func is_builtin_pack(name: String) -> bool:
	return BUILTIN_PACKS.has(name)


func set_tier_variants(enabled: bool) -> void:
	if enabled == tier_variants:
		return
	tier_variants = enabled
	_save()
	changed.emit()


func set_icon_pack(name: String) -> void:
	if name == icon_pack:
		return
	if not is_builtin_pack(name) and not IconPacksLoader.pack_names().has(name):
		return
	icon_pack = name
	_save()
	changed.emit()


func _ready() -> void:
	ensure_default_file()
	_ensure_buses()
	_route_music_players()
	_load()
	# ⚠ 临时诊断（B 阶段排错用，定位完删）
	print("[IconPacks] 启动扫描：packs=%s selected=%s" % [str(IconPacksLoader.pack_names()), icon_pack])
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


# ============================ 方案包内的音效 ============================
# 音效事件 ID 见 docs/图标方案-ZIP格式规范.md §六：
#   landfall.sound.{ts,c1..c5}         登陆音效
#   mainicon.sound.{eri,ts,suty,disperse,c4,c5_170}   事件音效
# 取不到（zip 里没有这个 ID）→ 静音，不报错。

## 登陆音效 ID：0 = TS，1..5 = C1..C5（热带低压没有专用音效）
func landfall_sound_id(index: int) -> String:
	const IDS: Array[String] = ["landfall.sound.ts", "landfall.sound.c1", "landfall.sound.c2",
		"landfall.sound.c3", "landfall.sound.c4", "landfall.sound.c5"]
	return IDS[clampi(index, 0, IDS.size() - 1)]


# ============================ 存档 ============================

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "music_volume", music_volume)
	cfg.set_value("audio", "sfx_volume", sfx_volume)
	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.set_value("video", "icon_pack", icon_pack)
	cfg.set_value("video", "tier_variants", tier_variants)
	# 模拟设置
	cfg.set_value("sim", "mean_sst", mean_sst)
	cfg.set_value("sim", "seasonal_amplitude", seasonal_amplitude)
	cfg.set_value("sim", "record_disturbances", record_disturbances)
	cfg.set_value("sim", "best_track_enabled", best_track_enabled)
	cfg.set_value("sim", "best_track_dir", best_track_dir)
	cfg.set_value("sim", "best_track_format", best_track_format)
	cfg.set_value("sim", "wind_unit_index", wind_unit_index)
	var err := cfg.save(save_path())
	if err != OK:
		push_warning("设置写入失败：%s" % save_path())


## 老「方案名」→ 新「方案包名」：旧的 default/smcy1_3/smcy13 → 扫描到的 SMCY 包（没有就空）
static func _migrate_scheme_to_pack(old: String) -> String:
	var packs := IconPacksLoader.pack_names()
	if old in ["smcy1_3", "smcy13", "SMCY1.3", "SMCY"]:
		for n in packs:
			if n.to_lower().begins_with("smcy"):
				return n
		return ""
	if packs.has(old):
		return old
	return ""


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(save_path()) != OK:
		return                                  # 没有存档就用默认值
	music_volume = clampf(float(cfg.get_value("audio", "music_volume", music_volume)), 0.0, 1.0)
	sfx_volume = clampf(float(cfg.get_value("audio", "sfx_volume", sfx_volume)), 0.0, 1.0)
	fullscreen = bool(cfg.get_value("video", "fullscreen", fullscreen))
	# 方案包（2026-11-05）。老配置迁移：以前选的图标方案名是 default/smcy1_3，
	# 对应现在的方案包文件名 → 优先沿用，找不到就留空（程序化渲染）。
	var saved_pack := str(cfg.get_value("video", "icon_pack", ""))
	if saved_pack == "":
		var old_scheme := str(cfg.get_value("video", "icon_scheme", ""))
		if old_scheme == "" or old_scheme == "default":
			old_scheme = str(cfg.get_value("audio", "sfx_preset", ""))
		saved_pack = _migrate_scheme_to_pack(old_scheme)
	# ⚠ 默认 = 内置 Default（1.1.1 观感）。保存过且合法（内置或真实存在的 zip）才沿用。
	var packs := IconPacksLoader.pack_names()
	icon_pack = saved_pack if (is_builtin_pack(saved_pack) or packs.has(saved_pack)) else DEFAULT_PACK
	tier_variants = bool(cfg.get_value("video", "tier_variants", tier_variants))
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
	return save_path()
