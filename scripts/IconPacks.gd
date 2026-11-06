class_name IconPacks
extends RefCounted
## 图标「方案包」加载器（用户 2026-11-06 最终版：**只用文件夹**）。
##
## 一个方案 = `<游戏目录>/assets/icons/<方案名>/` 文件夹：
##   index.json + mainicon/ landfall/ particle/
## 游戏目录：打包版 = exe 所在目录；编辑器 = 工程根。
##
## ⚠ 安卓（2026-11-06 移植）：
##   APK 里没有「exe 同目录」这种可以浏览的外部文件夹 —— 安卓导出把 pck 内容
##   平铺在 APK 的 `assets/` 下，运行时只能通过 `res://` 读。所以图标方案包在
##   安卓上**必须打进 pck**，路径 = `res://assets/icons/...`，读法也不一样：
##     · 导入资源（.ogv / .ogg / .png …）→ `ResourceLoader.load()`，
##       .ogv → VideoStream、.ogg → AudioStream、.png → Texture2D
##     · index.json 这类非导入文件 → `FileAccess.get_file_as_string()`
##       （必须写在导出预设的 include_filter 里，否则不在 pck 里）
##     · 目录列表 → `DirAccess.open("res://assets/icons")`（pck 内可列子目录）
##   判断走哪条路：`OS.has_feature("android")`；桌面验证链路可用测试钩子 `force_res`。
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
## ⚠ 桌面：方案包**不打包进 pck**，文件直接读磁盘（外部文件没经过 import 流程，**不能用 load()**）：
##   .ogv → VideoStreamTheora.new(); .file = 绝对路径
##   .ogg → AudioStreamOggVorbis.load_from_file()
##   .png → Image.load_from_file() → ImageTexture
## 安卓：一律走 res:// 资源加载（见上方文件头说明）。

const EXT_DIR := "assets/icons"
## 安卓 pck 内的方案包根目录（res:// 前缀 → 走资源加载链路）
const EXT_RES_DIR := "res://" + EXT_DIR
## 游戏支持的 index.json 版本（不匹配只标黄，不报错）
const SUPPORTED_VERSION := 1

## 测试钩子（仅 _dev / 调试用）：桌面 / 编辑器上强制走 res:// 加载链路，
## 用来验证安卓分支（安卓上 `OS.has_feature("android")` 本来就为 true）。
## 正式运行不要设它。
static var force_res := false


## 是否使用 pck 内的 res:// 资源路径（安卓 / 测试钩子）
static func uses_res() -> bool:
	return force_res or OS.has_feature("android")


## 这个路径是不是 pck 内资源路径（res:// 前缀），用来和「桌面外部绝对路径」区分
static func is_res_path(p: String) -> bool:
	return p.begins_with("res://")


# ------------------------- 扫描 -------------------------

static func pack_dir() -> String:
	if uses_res():
		return EXT_RES_DIR
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
	var text := FileAccess.get_file_as_string(idx_path)
	# pck 内文件没有可靠的 mtime（安卓整包只读，内容也不会变）→ 只用长度做缓存戳
	var mtime := 0
	if not is_res_path(idx_path):
		mtime = FileAccess.get_modified_time(idx_path)
	var stamp := "%d|%d" % [mtime, text.length()]
	var cached: Dictionary = _index_cache.get(pack, {})
	if cached.get("stamp", "") == stamp:
		return cached.get("data", empty)
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


## 包内相对路径 → 可加载路径（不存在返回 ""）。
## 桌面 = 外部绝对路径；安卓 = pck 内的 res:// 路径。
static func path_of(pack: String, id: String) -> String:
	var e := entry(pack, id)
	if e.is_empty():
		return ""
	var p := pack_root(pack).path_join(str(e["path"]))
	return p if _exists(p) else ""


## 文件是否存在。
## ⚠ pck 内的导入资源（.ogg / .png …）**源文件本身可能不在 pck 里**（只有 .import
##   指向的导入产物），此时 `FileAccess.file_exists("res://x.ogg")` 为 false，
##   但 `ResourceLoader.load("res://x.ogg")` 能成功 → 所以 res:// 用 ResourceLoader 判定。
static func _exists(p: String) -> bool:
	if is_res_path(p):
		return ResourceLoader.exists(p) or FileAccess.file_exists(p)
	return FileAccess.file_exists(p)


## 取视频。
## 桌面（外部磁盘 .ogv）：VideoStreamTheora.file 直接指磁盘
## 安卓（pck 内 .ogv）：ResourceLoader.load → VideoStreamTheora
static func video(pack: String, id: String) -> VideoStream:
	var p := path_of(pack, id)
	if p == "":
		return null
	if is_res_path(p):
		var res: Variant = ResourceLoader.load(p)
		if res is VideoStream:
			return res
		return null
	var v := VideoStreamTheora.new()
	v.file = p
	return v


## 取图片（单图方案）。
## 桌面：Image.load_from_file；安卓：ResourceLoader.load → Texture2D
static func image(pack: String, id: String) -> Texture2D:
	var p := path_of(pack, id)
	if p == "":
		return null
	if is_res_path(p):
		var res: Variant = ResourceLoader.load(p)
		if res is Texture2D:
			return res
		return null
	var img := Image.new()
	if img.load(p) != OK:
		return null
	return ImageTexture.create_from_image(img)


## 取音频。
## 桌面（外部磁盘）：load_from_file；安卓（pck 内）：ResourceLoader.load → AudioStream
static func audio(pack: String, id: String) -> AudioStream:
	var p := path_of(pack, id)
	if p == "":
		return null
	if is_res_path(p):
		var res: Variant = ResourceLoader.load(p)
		if res is AudioStream:
			return res
		return null
	var ext := p.get_extension().to_lower()
	if ext == "ogg":
		return AudioStreamOggVorbis.load_from_file(p)
	if ext == "wav":
		return AudioStreamWAV.load_from_file(p)
	return null
