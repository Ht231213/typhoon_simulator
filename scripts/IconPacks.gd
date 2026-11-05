class_name IconPacks
extends RefCounted
## 图标「方案包」加载器（用户 2026-11-06 最终版：**只用文件夹**）。
##
## 一个方案 = `<游戏目录>/assets/icons/<方案名>/` 文件夹：
##   index.json + mainicon/ landfall/ particle/
## 游戏目录：打包版 = exe 所在目录；编辑器 = 工程根。
##
## index.json 最终格式：
##   {
##     "version": 1,                       // 1.2.0 起 1，每发一版 +1；不匹配 → 设置里方案名标黄
##     "type": "advanced",                 // single / advanced / adv_extend（pack 级，必填）
##     "object": [ {"mainicon.icon.north.c1": "mainicon/c1_north.ogv"}, ... ]
##   }
## 兼容：无 version/type → version=1、type=advanced；老 `objects` 复数当 `object`。
## `ext` / 对象级 type 一律忽略（已作废）。
##
## ⚠ 不打包进 pck；文件直接读磁盘（外部文件没经过 import 流程，**不能用 load()**）：
##   .ogv → VideoStreamTheora.new(); .file = 绝对路径
##   .ogg → AudioStreamOggVorbis.load_from_file()
##   .png → Image.load_from_file() → ImageTexture

const EXT_DIR := "assets/icons"
## 游戏支持的 index.json 版本（不匹配只标黄，不报错）
const SUPPORTED_VERSION := 1

# ------------------------- 扫描 -------------------------

static func pack_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://").path_join(EXT_DIR)
	return OS.get_executable_path().get_base_dir().path_join(EXT_DIR)


## 所有方案名 = 含 index.json 的子目录（按名字排序）
static func pack_names() -> Array[String]:
	var names: Array[String] = []
	var dir := pack_dir()
	var d := DirAccess.open(dir)
	print("[IconPacks] 方案目录=%s exists=%s dir_ok=%s" % [
		dir, str(DirAccess.dir_exists_absolute(dir)), str(d != null)])
	if d == null:
		return names
	var dirs := d.get_directories()
	print("[IconPacks] 子目录=%s" % str(dirs))
	for sub in dirs:
		if FileAccess.file_exists(dir.path_join(sub).path_join("index.json")):
			names.append(sub)
	names.sort()
	print("[IconPacks] 有效方案=%s" % str(names))
	return names


static func pack_root(pack: String) -> String:
	return pack_dir().path_join(pack)


# ------------------------- index -------------------------

static var _index_cache: Dictionary = {}


## 解析结果：{"version": int, "type": String, "objects": {ID: {"path": String}}}
static func load_index(pack: String) -> Dictionary:
	var empty := {"version": SUPPORTED_VERSION, "type": "advanced", "objects": {}}
	if pack == "":
		return empty
	var root := pack_root(pack)
	var idx_path := root.path_join("index.json")
	if not FileAccess.file_exists(idx_path):
		return empty
	var stamp := "%d|%d" % [FileAccess.get_modified_time(idx_path), FileAccess.get_file_as_string(idx_path).length()]
	var cached: Dictionary = _index_cache.get(pack, {})
	if cached.get("stamp", "") == stamp:
		return cached.get("data", empty)
	var text := FileAccess.get_file_as_string(idx_path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[IconPacks] %s/index.json 解析失败" % pack)
		return empty
	var rootd: Dictionary = parsed
	var version := clampi(int(rootd.get("version", SUPPORTED_VERSION)), 0, 999)
	var type := str(rootd.get("type", "advanced")).strip_edges().to_lower()
	if type == "":
		type = "advanced"
	if type not in ["single", "advanced", "adv_extend"]:
		push_warning("[IconPacks] %s 的 type=%s 不认识，按 advanced 处理" % [pack, type])
		type = "advanced"
	var table := {}
	var raw: Variant = rootd.get("object", null)
	if raw == null:
		raw = rootd.get("objects", [])
		if typeof(raw) == TYPE_ARRAY:
			push_warning("[IconPacks] %s 用的是老格式 objects（复数），仍兼容" % pack)
	if typeof(raw) == TYPE_DICTIONARY:
		var dict_raw: Dictionary = raw
		for k in dict_raw.keys():
			var v: Variant = dict_raw[k]
			if v is String and str(v) != "":
				table[str(k)] = {"path": str(v)}
	elif typeof(raw) == TYPE_ARRAY:
		var arr: Array = raw
		for item in arr:
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var item_d: Dictionary = item
			for k in item_d.keys():
				var v2: Variant = item_d[k]
				if v2 is String and str(v2) != "" and not table.has(str(k)):
					table[str(k)] = {"path": str(v2)}
	var icon_size := float(rootd.get("icon_size", 0.0))
	var data := {"version": version, "type": type, "icon_size": icon_size, "objects": table}
	_index_cache[pack] = {"stamp": stamp, "data": data}
	print("[IconPacks] index %s：version=%d type=%s 条目=%d" % [pack, version, type, table.size()])
	# type=single 只允许两个 ID（用户 2026-11-06）
	if type == "single":
		for eid in table.keys():
			if eid not in ["single.typhoon", "single.landfall"]:
				push_warning("[IconPacks] %s：type=single 包里的 %s 会被忽略（只认 single.typhoon / single.landfall）" % [pack, eid])
	# 类型与素材格式的 warning（不阻止加载）
	for eid in table.keys():
		var ext: String = str(table[eid]["path"]).get_extension().to_lower()
		if type == "single" and ext == "ogv":
			push_warning("[IconPacks] %s：type=single 却用 .ogv（视频不旋转不变色没意义）：%s" % [pack, eid])
		elif type == "advanced" and ext in ["png", "jpg", "jpeg"]:
			push_warning("[IconPacks] %s：type=advanced 却用静态图：%s" % [pack, eid])
	return data


## 方案自带的图标直径（index.json 的 icon_size；没有 = 0，调用方用常量兜底）
static func icon_size(pack: String) -> float:
	var s := float(load_index(pack).get("icon_size", 0.0))
	return s if s > 0.0 else 0.0


static func version_of(pack: String) -> int:
	return int(load_index(pack).get("version", SUPPORTED_VERSION))


static func type_of(pack: String) -> String:
	return str(load_index(pack).get("type", "advanced"))


static func version_ok(pack: String) -> bool:
	return version_of(pack) == SUPPORTED_VERSION


static func objects(pack: String) -> Dictionary:
	return load_index(pack).get("objects", {})


static func has(pack: String, id: String) -> bool:
	return objects(pack).has(id)


static func entry(pack: String, id: String) -> Dictionary:
	return objects(pack).get(id, {})


## 方案里第一个 ID（type=single 的兜底）
static func first_id(pack: String) -> String:
	for k in objects(pack).keys():
		return str(k)
	return ""


## 包内相对路径 → 绝对路径（不存在返回 ""）
static func path_of(pack: String, id: String) -> String:
	var e := entry(pack, id)
	if e.is_empty():
		return ""
	var p := pack_root(pack).path_join(str(e["path"]))
	return p if FileAccess.file_exists(p) else ""


## 取视频（外部文件：VideoStreamTheora.file 直接指磁盘）
static func video(pack: String, id: String) -> VideoStream:
	var abs := path_of(pack, id)
	if abs == "":
		return null
	var v := VideoStreamTheora.new()
	v.file = abs
	return v


## 取图片（单图方案）
static func image(pack: String, id: String) -> Texture2D:
	var abs := path_of(pack, id)
	if abs == "":
		return null
	var img := Image.new()
	if img.load(abs) != OK:
		return null
	return ImageTexture.create_from_image(img)


## 取音频（外部文件：load_from_file）
static func audio(pack: String, id: String) -> AudioStream:
	var abs := path_of(pack, id)
	if abs == "":
		return null
	var ext := abs.get_extension().to_lower()
	if ext == "ogg":
		return AudioStreamOggVorbis.load_from_file(abs)
	if ext == "wav":
		return AudioStreamWAV.load_from_file(abs)
	return null
