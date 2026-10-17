class_name BestTrackRecorder
extends RefCounted
## 最佳路径数据集：记录器 + 导出器
##
## 格式参照**中国气象局热带气旋资料中心《CMA 最佳路径数据集》**
## （tcdata.typhoon.org.cn/zjljsjj.html，2026-10-17 版说明）。
## 规范里给的字段全部照搬，**填不了的按用户决定处理**：
##   · EEEE（我国编号）→ `0000`（真实文件里 1949 年那份也是这个值）
##   · OWD（沿海大风/南海最大风速）→ 每行末尾一个 `-`
##
## ⚠ 和真实数据的关键区别：本文件是**模拟器生成的**，开头有中英双语声明。
##
## 用户 2026-10-17 的规则：
##   · 勾选后开始记录「此后新诞生的每个台风」；勾选时正在跑的那个不记
##   · 风季模式**强制开启**
##   · 游戏内一年结束（12月30日）时写成一个文件
##   · 跨年台风**按生成年份归档，不拆分**
##   · 文件名：`Best Track <系统时间YYMMDD>-<游戏内年份计数>.txt`

## 采样间隔（模拟小时）。CMA 是每 6 小时一个点。
const SAMPLE_HOURS := 6.0

## 1 kt = 多少 m/s（CMA 的 WND 用 m/s）
const KT_TO_MS := 0.514444

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

## 被延后的写盘（跨年台风还没结束时）
var _pending_flush_year := 0
var _pending_flush_dir := ""


## 有没有「出生于某一年」的台风还在跑
func _has_active_born_in(year: int) -> bool:
	for t in _active:
		if int(t["birth_year"]) == year:
			return true
	return false


## 延后的那一年现在能写了吗
func _write_pending_flush() -> void:
	if _pending_flush_year <= 0:
		return
	var y := _pending_flush_year
	_pending_flush_year = 0
	var year_tracks: Array[Dictionary] = []
	var remain: Array[Dictionary] = []
	for t in tracks:
		if int(t["birth_year"]) == y:
			year_tracks.append(t)
		else:
			remain.append(t)
	if year_tracks.is_empty():
		return
	tracks = remain
	var path := _pick_file_path(_pending_flush_dir, y)
	if _write_file(path, year_tracks, y):
		last_written_path = path
		print("[BestTrack] 第 %d 年（延后）导出 %d 个台风" % [y, year_tracks.size()])


func reset() -> void:
	recording = false
	year_index = 1
	tracks.clear()
	_active.clear()
	last_written_path = ""


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
		"day": SimClock.day,
		"month": SimClock.month,
		"hour": (seg * 6) % 24,
		"lat": float(ll.y),
		"lon": float(ll.x),
		"pres": float(storm.central_pressure),
		"kt": float(storm.wind_kt),
		"marker": _marker_for(storm),
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
func flush_year(export_dir: String) -> String:
	var this_year := year_index
	if _has_active_born_in(this_year):
		_pending_flush_year = this_year
		_pending_flush_dir = export_dir
		year_index += 1
		return ""
	var year_tracks: Array[Dictionary] = []
	var remain: Array[Dictionary] = []
	for t in tracks:
		if int(t["birth_year"]) == this_year:
			year_tracks.append(t)
		else:
			remain.append(t)
	if year_tracks.is_empty():
		year_index += 1
		return ""
	tracks = remain
	var path := _pick_file_path(export_dir, this_year)
	if _write_file(path, year_tracks, this_year):
		last_written_path = path
		print("[BestTrack] 第 %d 年导出 %d 个台风" % [this_year, year_tracks.size()])
		return path
	year_index += 1
	return path


# ============================ 内部 ============================

func _index_of(storm) -> int:
	for i in _active.size():
		if int(_active[i]["dep_number"]) == int(storm.depression_number):
			return i
	return -1


## GB/T 19201-2006 强度标记（按 m/s）
func _marker_for(storm) -> int:
	# 变性：第一个 9 表示变性完成
	if storm.phase == Storm.Phase.EXTRATROPICAL:
		return 9
	var ms: float = float(storm.wind_kt) * KT_TO_MS
	if ms < 10.8:
		return 0
	if ms <= 17.1:
		return 1
	if ms <= 24.4:
		return 2
	if ms <= 32.6:
		return 3
	if ms <= 41.4:
		return 4
	if ms <= 50.9:
		return 5
	return 6


func _pick_file_path(export_dir: String, for_year: int) -> String:
	var dir := export_dir
	if dir == "":
		dir = default_export_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_dict_from_system()
	var ymd := "%02d%02d%02d" % [int(stamp["year"]) % 100, int(stamp["month"]), int(stamp["day"])]
	var base := dir.path_join("Best Track %s-%d" % [ymd, for_year])
	var p := base + ".txt"
	var n := 2
	while FileAccess.file_exists(p):
		p = "%s_%d.txt" % [base, n]
		n += 1
	return p


## 默认导出目录：游戏根目录下的 BestTrack/
func default_export_dir() -> String:
	var root := ProjectSettings.globalize_path("res://")
	if root == "":
		root = OS.get_executable_path().get_base_dir()
	return root.path_join("BestTrack")


func _write_file(path: String, year_tracks: Array[Dictionary], write_year: int) -> bool:
	var lines: PackedStringArray = []

	# ---- 中英双语声明（用户要求：和真实数据区分开）----
	lines.append("# ============================================================")
	lines.append("# 本文件由「台风模拟器」生成，**不是真实观测资料**，不可用于科研或业务。")
	lines.append("# This file is generated by a TYPHOON SIMULATOR and is NOT real")
	lines.append("# observational data. Do not use it for research or operations.")
	lines.append("# 格式仿照 CMA 最佳路径数据集，但内容全部为模拟结果。")
	lines.append("# Format mimics the CMA Best Track dataset; all content is simulated.")
	lines.append("# ============================================================")

	for t in year_tracks:
		lines.append(_header_line(t))
		for s in (t["samples"] as Array):
			lines.append(_data_line(s, write_year))

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[BestTrack] 写不了文件：%s" % path)
		return false
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("[BestTrack] 已导出 %d 个台风 → %s" % [year_tracks.size(), path])
	return true


## 头记录。用户决定：名字字段用规范写的 **20** 字符（真实文件里是 35）。
## 字段顺序和宽度（合计 58）：
##   AAAAA(5) BBBB(4) CCC(3) DDDD(4) EEEE(4) F(1) G(1) H(20) I(8)
func _header_line(t: Dictionary) -> String:
	var samples: Array = t["samples"]
	# BBBB = 年份后两位 + 两位编号。没有国际编号（没到 TS）时是 0000。
	var bbbb := 0
	if int(t["storm_number"]) > 0:
		bbbb = (int(t["birth_year"]) % 100) * 100 + (int(t["storm_number"]) % 100)
	var ccc := samples.size()
	var dddd := int(t["dep_number"])
	var eeee := 0                                  # 我国编号：我们填不了
	var f_code := int(t["end_code"])
	var g := 6
	var hh := str(t["name_en"]).substr(0, 20)
	# I...I = 数据集形成的日期。**按用户要求用游戏内时间**（不是系统时间）：
	#   游戏内年份计数 + 月 + 日，例如 00010815。
	#   ⚠ 文件名里的 YYMMDD 才是系统时间（见 _pick_file_path）。
	var ii := "%04d%02d%02d" % [int(t["birth_year"]), int(t["birth_month"]), int(t["birth_day"])]
	return "%s %s %s %s %s %d %d %s %s" % [
		"66666",
		"%04d" % bbbb,
		"%3d" % ccc,
		"%04d" % dddd,
		"%04d" % eeee,
		f_code,
		g,
		hh.rpad(20, " "),
		ii,
	]


## 数据记录：
##   YYYYMMDDHH(10) I(1) LAT(3) LONG(4) PRES(4) WND(8) 然后把 OWD 写成 `-`
func _data_line(s: Dictionary, write_year: int) -> String:
	var yyyy := "%04d" % write_year
	var mm := "%02d" % int(s["month"])
	var dd := "%02d" % int(s["day"])
	var hh := "%02d" % int(s["hour"])
	var lat := int(roundf(float(s["lat"]) * 10.0))
	var lon := int(roundf(float(s["lon"]) * 10.0))
	var pres := int(roundf(float(s["pres"])))
	var ms := int(roundf(float(s["kt"]) * KT_TO_MS))
	# 规范：WND=9 表示 <10 m/s，WND=0 表示缺测
	if ms < 10:
		ms = 9
	var head := "%s%s%s%s %d %3d %4d %4d%8d" % [
		yyyy, mm, dd, hh, int(s["marker"]), lat, lon, pres, ms]
	return head + " -"


func track_count() -> int:
	return tracks.size() + _active.size()
