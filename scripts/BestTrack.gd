class_name BestTrackRecorder
extends RefCounted
## 最佳路径数据集：**记录器**（采样 / 归档 / 跨年写盘）。
##
## 具体写成什么格式交给 `scripts/best_track/` 下的 writer：
##   · `CmaWriter`  —— 中国气象局《CMA 最佳路径数据集》（1.0/1.1 的老格式，输出保持不变）
##   · `NoaaWriter` —— NOAA IBTrACS v04r01 CSV（1.2.0 起默认）
## 本类**不碰格式细节**（声明块 / 表头 / 数据行 / 文件名主体全在 writer 里），
## 所以加新格式不用动这里的公共接口。
##
## 用户 2026-10-17 的规则：
##   · 勾选后开始记录「此后新诞生的每个台风」；勾选时正在跑的那个不记
##   · 风季模式**强制开启**
##   · 游戏内一年结束（12月30日）时写成一个文件
##   · 跨年台风**按生成年份归档、不拆分**

## 默认导出格式：1.2.0 起是 NOAA/IBTrACS
const DEFAULT_FORMAT := "noaa"

## 默认导出目录名：桌面放在游戏根（exe 旁 / 工程根）下，安卓放在 user:// 下
const BEST_TRACK_DIR_NAME := "BestTrack"

## 格式 id → writer 脚本。加新格式只要在这里加一行
const WRITERS := {
	"cma": preload("res://scripts/best_track/CmaWriter.gd"),
	"noaa": preload("res://scripts/best_track/NoaaWriter.gd"),
}

## 当前格式，由 `TyphoonSim._sync_best_track_state()` 从 GameSettings 同步过来
var format_id := DEFAULT_FORMAT

## 导出相关的提示（写盘失败 / 目录回退 / 延后补写完成）。`TyphoonSim` 把它接到游戏内 notice。
signal export_notice(message: String)

## 记录是否开启
var recording := false

## 游戏内年份计数（1 起，每走完一年 +1）
var year_index := 1

## 已结束、待写盘的台风
var tracks: Array[Dictionary] = []

## 正在记录的台风（正常同时只有 1 个，留成数组以便将来多台模式）
var _active: Array[Dictionary] = []

## 上一次写盘的文件路径（UI/调试显示用）
var last_written_path := ""
## 上一次写盘是否**回退到了默认目录**（配置的目录不可写）。TyphoonSim 用它做一次性提示 + 修正设置。
var last_dir_was_fallback := false

## 被延后的写盘（跨年台风还没结束时）
var _pending_flush_year := 0
var _pending_flush_dir := ""


## 按 format_id 取一个 writer 实例（每次新建，writer 无状态）
func writer() -> RefCounted:
	var script: Variant = WRITERS.get(format_id, null)
	if script == null:
		push_warning("[BestTrack] 未知导出格式 '%s'，回退 %s" % [format_id, DEFAULT_FORMAT])
		script = WRITERS[DEFAULT_FORMAT]
	return (script as Script).new()


## 有没有「出生于某一年」的台风还在跑
func _has_active_born_in(year: int) -> bool:
	for t in _active:
		if int(t["birth_year"]) == year:
			return true
	return false


## 延后的那一年现在能写了吗（台风结束后由 `end_track()` 调）
func _write_pending_flush() -> void:
	if _pending_flush_year <= 0:
		return
	var y := _pending_flush_year
	var dir := _pending_flush_dir
	_pending_flush_year = 0
	_pending_flush_dir = ""
	if _flush_tracks(dir, y) != "":
		print("[BestTrack] 第 %d 年（延后）补写完成" % y)


## 真正写盘：把「出生于 year」的台风取出来交给 writer。
## 同一份逻辑给 `flush_year()` 和 `_write_pending_flush()` 共用（以前是两份几乎一样的代码）。
##
## ⚠ **导出目录不可写时要回退到默认目录**（1.2.0 修「游戏好像没法导出」）：
##   玩家在「模拟设置 → 导出路径」里可能选到了**盘根 / 只读目录**（实测用户的
##   `settings.cfg` 里是 `best_track_dir="G:/"`），旧代码写盘失败只 push_warning，
##   游戏内没有任何提示 → 看起来就是「勾了最佳路径，一年跑完却什么文件都没有」。
##   现在：失败 → 换 `default_export_dir()`（exe 旁边 BestTrack/）再试一次；
##   回退成功就发 `export_notice` 让游戏内提示玩家「已改存到这里」。
func _flush_tracks(export_dir: String, year: int) -> String:
	var year_tracks: Array[Dictionary] = []
	var remain: Array[Dictionary] = []
	for t in tracks:
		if int(t["birth_year"]) == year:
			year_tracks.append(t)
		else:
			remain.append(t)
	if year_tracks.is_empty():
		return ""
	tracks = remain
	var path := _pick_file_path(export_dir, year)
	if _write_file(path, year_tracks, year):
		last_written_path = path
		last_dir_was_fallback = false
		print("[BestTrack] 第 %d 年导出 %d 个台风（格式 %s）" % [year, year_tracks.size(), format_id])
		return path

	# ① 配置的目录写不了 → 回退默认目录（exe 旁边的 BestTrack/）
	var fallback := default_export_dir()
	if fallback != export_dir:
		var p2 := _pick_file_path(fallback, year)
		if _write_file(p2, year_tracks, year):
			last_written_path = p2
			last_dir_was_fallback = true
			var msg := "导出目录不可写（%s），已改存到 %s" % [export_dir, fallback]
			push_warning("[BestTrack] " + msg)
			export_notice.emit(msg)
			return p2

	# ② 连默认目录都写不了（只读介质 / 权限）→ 放回待写列表，明确提示，别静默丢数据
	tracks.append_array(year_tracks)
	var fail_msg := "最佳路径写入失败：%s" % export_dir
	push_error("[BestTrack] " + fail_msg)
	export_notice.emit(fail_msg)
	return ""


func reset() -> void:
	recording = false
	year_index = 1
	tracks.clear()
	_active.clear()
	last_written_path = ""
	last_dir_was_fallback = false


## 开始记录一个台风。记录关闭时直接返回。
func begin_track(storm) -> void:
	if not recording:
		return
	if _index_of(storm) >= 0:
		return
	_active.append({
		"dep_number": int(storm.depression_number),
		"storm_number": int(storm.storm_number),
		"name_en": "(nameless)",
		"birth_year": year_index,
		"birth_month": SimClock.month,
		"birth_day": SimClock.day,
		"samples": [],
		"end_code": 0,
		"last_segment": -1,
	})
	sample(storm)


## 采样。**节流靠 storm.segment**：台风每 1 真实秒走一个路径点，而每个路径点
## 正好代表 6 模拟小时 —— 所以 segment 变一次就是一个 6 小时采样点。
##
## ⚠ 不能用 SimClock.sim_days() 算节流：它只有**天分辨率**（整数），
##   永远差不到 6 小时，结果整场台风只会记 1 个点。
func sample(storm) -> void:
	var idx := _index_of(storm)
	if idx < 0:
		return
	var d: Dictionary = _active[idx]
	var seg := int(storm.segment)
	if seg == int(d["last_segment"]):
		return
	d["last_segment"] = seg

	# 台风中途增强到有编号/有名字时，这里跟着更新（头记录要用最终值）
	if int(storm.storm_number) > 0:
		d["storm_number"] = int(storm.storm_number)
	if str(storm.storm_name) != "":
		d["name_en"] = str(storm.storm_name)

	var ll: Vector2 = storm.current_lonlat()
	(d["samples"] as Array).append({
		# 年份必须**逐点**记：跨年台风按生成年份归档、不拆分，写盘时的 write_year
		# 只是文件名/头记录的年份，数据行要按采样当时的年份算（IBTrACS 的 ISO_TIME 用得到）
		"year": year_index,
		"day": SimClock.day,
		"month": SimClock.month,
		"hour": (seg * 6) % 24,
		"lat": float(ll.y),
		"lon": float(ll.x),
		"pres": float(storm.central_pressure),
		"kt": float(storm.wind_kt),
		# 变性阶段（int(Storm.Phase)：0 热带 / 1 变性中 / 2 温带）。
		# IBTrACS 的 NATURE 要从这里取；CMA 的 marker 由 CmaWriter 用 (kt, phase) 现算。
		"phase": int(storm.phase),
	})


## 台风结束：归档。end_code 按参考的 F 字段语义，我们能填 0/2/3。
func end_track(storm) -> void:
	var idx := _index_of(storm)
	if idx < 0:
		return
	var d: Dictionary = _active[idx]
	_active.remove_at(idx)
	if (d["samples"] as Array).is_empty():
		return
	# F 字段：0=消散。我们目前没有"合并/准静止"的可靠判定，统一记 0。
	# （用户说 0/2/3 能填、1 酌情；先只做 0，留好位置。）
	d["end_code"] = 0
	tracks.append(d)
	# 如果这一年的文件因为「有同年台风还在跑」被延后了，现在看看能不能补写
	if _pending_flush_year > 0 and not _has_active_born_in(_pending_flush_year):
		_write_pending_flush()


## 年份切换时调一次：把「生成于这一年」的台风写盘。
## ⚠ 跨年台风**按生成年份归档、不拆分** —— 所以如果还有同年出生的台风在跑，
##   就先把写盘**延后**，等它结束再写（否则它的轨迹会被截断）。
##
## ⚠ P0 bug（2026-10-25 修）：以前 `year_index += 1` 写在成功分支 `return path` 之后，
##   写盘成功就**永远执行不到** → 从第 2 年起年份索引一直停在 1（文件名靠重名后缀变成 `-1_2`，
##   数据行的年份也全是 0001）。现在改成**开头先抓 this_year、立刻自增**，各分支不再自增。
func flush_year(export_dir: String) -> String:
	var this_year := year_index
	year_index += 1
	if _has_active_born_in(this_year):
		_pending_flush_year = this_year
		_pending_flush_dir = export_dir
		print("[BestTrack] 第 %d 年还有同年台风在跑，写盘延后" % this_year)
		return ""
	return _flush_tracks(export_dir, this_year)


# ============================ 内部 ============================

func _index_of(storm) -> int:
	for i in _active.size():
		if int(_active[i]["dep_number"]) == int(storm.depression_number):
			return i
	return -1


## 文件名主体 + 重名后缀（扩展名由 writer 决定）
##
## `export_dir` 的解析规则（用户 2026-10-30：UI 不给选，但 `config/simulation.cfg`
## 的 `[export] best_track_dir` 可以调）：
##   · 空字符串 → 游戏根目录下的 `BestTrack/`（= default_export_dir()）
##   · **相对路径** → 按「游戏根目录」解析（exe 旁 / 工程根；安卓 = user://）
##   · 绝对路径 → 原样使用（安卓上外部绝对路径通常不可写 → 会自动回退 user://BestTrack）
func _pick_file_path(export_dir: String, for_year: int) -> String:
	var dir := export_dir.strip_edges()
	if dir == "":
		dir = default_export_dir()
	elif not dir.is_absolute_path():
		dir = _game_root().path_join(dir)
	# user://（安卓）/ res:// 是引擎虚拟路径，建目录前先转成真实绝对路径（更稳妥）
	var mk_dir := dir
	if mk_dir.begins_with("user://") or mk_dir.begins_with("res://"):
		mk_dir = ProjectSettings.globalize_path(mk_dir)
	DirAccess.make_dir_recursive_absolute(mk_dir)
	var stamp := Time.get_datetime_dict_from_system()
	var ymd := "%02d%02d%02d" % [int(stamp["year"]) % 100, int(stamp["month"]), int(stamp["day"])]
	var w := writer()
	var base: String = w.file_base(dir, ymd, for_year)
	var ext: String = w.extension
	var p: String = base + ext
	var n := 2
	while FileAccess.file_exists(p):
		p = "%s_%d%s" % [base, n, ext]
		n += 1
	return p


## 游戏根目录：导出版 = exe 所在目录；编辑器/直接跑 = 工程根。
## ⚠ 必须用 `OS.has_feature("template")` 区分（1.2.0 修）：
##   导出版里 `ProjectSettings.globalize_path("res://")` 返回的是**空串**（res:// 在 pck 里）。
## ⚠ 安卓（2026-11-06 移植）：APK 内的 res:// 只读、也没有可写的「exe 同目录」，
##   唯一的可写位置是 `user://`（= 应用私有目录 data/data/<包名>/files）。
##   返回 `user://` 而不是绝对路径，让调用方拼接后仍是 user:// 路径（FileAccess 认）。
func _game_root() -> String:
	if OS.has_feature("android"):
		return "user://"
	var root := ""
	if OS.has_feature("template"):
		root = OS.get_executable_path().get_base_dir()
	else:
		root = ProjectSettings.globalize_path("res://")
	if root == "":
		root = OS.get_executable_path().get_base_dir()
	return root


## 默认导出目录：游戏根目录下的 BestTrack/
## 桌面 = exe 旁的 `BestTrack/`；安卓 = `user://BestTrack`（APK 目录不可写）
func default_export_dir() -> String:
	if OS.has_feature("android"):
		return "user://" + BEST_TRACK_DIR_NAME
	return _game_root().path_join(BEST_TRACK_DIR_NAME)


## 写盘：格式全交给 writer
func _write_file(path: String, year_tracks: Array[Dictionary], write_year: int) -> bool:
	if not writer().write_file(path, year_tracks, write_year):
		return false
	print("[BestTrack] 已导出 %d 个台风 → %s" % [year_tracks.size(), path])
	return true


func track_count() -> int:
	return tracks.size() + _active.size()
