extends Node
## [autoload: Game] 一局游戏的状态、设置、存档。
##
## 负责三件事：
##   ① 保存「玩家在开始菜单选的设置」，让场景切换后还能读到
##   ② 一局模拟里的统计数据（台风战报列表、总 ACE）
##   ③ 把 ACE 成绩写入本地存档文件（user:// 目录）

# ============================ 设置 ============================
## 模拟模式。对应设置界面的下拉框。
enum Mode { MANUAL, AUTO, CINEMATIC }
var mode: Mode = Mode.MANUAL
## 风季模式：true = 只模拟 12 个月；false = 无限模拟
var season_mode := false

## 兼容旧调用：手动/自动
var auto_mode: bool:
	get: return mode == Mode.AUTO
	set(value): mode = Mode.AUTO if value else Mode.MANUAL


func mode_name() -> String:
	match mode:
		Mode.AUTO: return "自动模式"
		Mode.CINEMATIC: return "电影模式"
	return "手动模式"


func mode_label() -> String:
	return "%s + %s" % [mode_name(), "风季" if season_mode else "非风季"]


## 存档分类。手动系模式归入「单台-手动」，自动归入「单台-自动」。
func save_category() -> String:
	return "单台-自动" if mode == Mode.AUTO else "单台-手动"


# ============================ 一局的数据 ============================

## 一场台风的战报
class StormRecord extends RefCounted:
	var storm_name := ""
	var number_text := ""
	var peak_wind_kt := 0.0
	var min_pressure := 1000.0
	var ace := 0.0
	var start_day := 0.0
	var end_day := 0.0

	func to_dict() -> Dictionary:
		return {
			"name": storm_name,
			"number": number_text,
			"peak_kt": snappedf(peak_wind_kt, 0.01),
			"min_pressure": snappedf(min_pressure, 0.1),
			"ace": snappedf(ace, 0.01),
			"start_day": snappedf(start_day, 0.01),
			"end_day": snappedf(end_day, 0.01),
		}

## 本局所有已结束的台风
var records: Array[StormRecord] = []
## 本局累计 ACE（每场台风「正常结束」时累加；点「停止模拟」的不计入）
var total_ace := 0.0
## 台风总计数：只统计「正常结束」的台风，与编号系统分开管理。
## 对应原工程的「台风名累计」，是命名/统计用的总场次。
## 它跨局累计（不随 begin_session 清零），点「停止模拟」的也不增加。
var storm_total := 0
## 台风名游标（对应原工程的「台风名累计」）
var name_cursor := Const.NAME_CURSOR_START
## 本局是否已经开始过
var session_active := false

# ---- 编号计数器（两套独立计数，各自循环）----
## 台风胚胎编号：90 → 99 → 90
var depression_cursor := Const.DEPRESSION_NUMBER_START
## 热带风暴编号：1 → 99 → 1
var storm_cursor := Const.STORM_NUMBER_START


func begin_session() -> void:
	records.clear()
	total_ace = 0.0
	name_cursor = Const.NAME_CURSOR_START
	depression_cursor = Const.DEPRESSION_NUMBER_START
	storm_cursor = Const.STORM_NUMBER_START
	session_active = true


## 取下一个台风胚胎编号（90–99 循环）
func next_depression_number() -> int:
	var value := depression_cursor
	depression_cursor += 1
	if depression_cursor > Const.DEPRESSION_NUMBER_END:
		depression_cursor = Const.DEPRESSION_NUMBER_START
	return value


## 取下一个热带风暴编号（1–99 循环）
func next_storm_number() -> int:
	var value := storm_cursor
	storm_cursor += 1
	if storm_cursor > Const.STORM_NUMBER_END:
		storm_cursor = Const.STORM_NUMBER_START
	return value


## 记录一场「正常结束」的台风：累计 ACE + 存入战报列表。
## 台风总计数由 TyphoonSim 在结束时 +1（与编号系统分开管理）。
## 本次要显示的台风列表。
## 默认只列「达到热带风暴级及以上」（峰值 >= 30 kt）的场次；
## 打开「记录热带扰动和低压」（GameSettings.record_disturbances）后，
## **连 <30 kt 的热带扰动/热带低压也一并列出**。
## ⚠ 只影响列表显示，不影响 ACE 排行榜（ACE 本身就只在台风级及以上累计）。
func visible_records() -> Array[StormRecord]:
	if GameSettings.record_disturbances:
		return records
	var out: Array[StormRecord] = []
	for r in records:
		if r.peak_wind_kt >= Const.STORM_NUMBER_THRESHOLD_KT:
			out.append(r)
	return out

func add_record(rec: StormRecord) -> void:
	records.append(rec)
	total_ace += rec.ace


## 预看下一个台风名（不消耗游标）
func peek_next_storm_name() -> String:
	return Const.STORM_NAMES[(name_cursor - 1) % Const.STORM_NAMES.size()]


## 确认消耗一个名字（台风增强到台风级正式命名时调用）
func commit_storm_name() -> String:
	var value := peek_next_storm_name()
	name_cursor += 1
	if name_cursor > Const.STORM_NAMES.size():
		name_cursor = 1
	return value


## 退还刚消耗的名字（「停止模拟」时调用，让这个名字等于没被用过）
func rollback_storm_name() -> void:
	name_cursor -= 1
	if name_cursor < 1:
		name_cursor = Const.STORM_NAMES.size()


## 兼容旧调用
func next_storm_name() -> String:
	return peek_next_storm_name()


# ============================ 存档读写 ============================

const SAVE_PATH := "user://ace_records.json"

## 存档结构：
## {
##   "version": 1,
##   "categories": {
##     "单台-手动": [ { "saved_at": <unix>, "total_ace": 12.3, "storms": [...] }, ... ],
##     "单台-自动": [ ... ]
##   }
## }

func load_save() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {"version": 1, "categories": {}}
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		push_warning("无法读取存档：%s" % SAVE_PATH)
		return {"version": 1, "categories": {}}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("存档格式损坏，已忽略：%s" % SAVE_PATH)
		return {"version": 1, "categories": {}}
	var data: Dictionary = parsed
	if not data.has("categories"):
		data["categories"] = {}
	return data


## 把本局成绩追加进存档，返回是否成功
func commit_session_to_save() -> bool:
	if records.is_empty():
		return false
	var data := load_save()
	var categories: Dictionary = data["categories"]
	var category := save_category()
	var list: Array = categories.get(category, [])
	var storms: Array = []
	for rec in records:
		storms.append(rec.to_dict())
	list.append({
		"saved_at": int(Time.get_unix_time_from_system()),
		"mode": mode_label(),
		"total_ace": snappedf(total_ace, 0.01),
		"storm_count": records.size(),
		"storms": storms,
	})
	categories[category] = list
	data["categories"] = categories

	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("无法写入存档：%s" % SAVE_PATH)
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return true


## 取某个分类下的历史记录（给以后做排行榜用）
func history(category: String) -> Array:
	var data := load_save()
	var categories: Dictionary = data.get("categories", {})
	return categories.get(category, [])


func save_path_absolute() -> String:
	return ProjectSettings.globalize_path(SAVE_PATH)


# ============================ 格式化 ============================

## 台风列表的一行，例如 "C5  03W  Haiyan       170Kt  895mB  ACE19.70"
static func format_record(rec: StormRecord) -> String:
	var cat := Const.category_from_wind(rec.peak_wind_kt)
	var name_part := rec.storm_name if rec.storm_name != "" else "（实际为空）"
	return "%-2s  %-5s %-12s %3dKt  %4dmB  ACE%.2f" % [
		Const.category_short(cat),
		rec.number_text if rec.number_text != "" else "----",
		name_part,
		int(roundf(rec.peak_wind_kt)),
		int(roundf(rec.min_pressure)),
		rec.ace,
	]
