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
## 游戏端支持的 index.json 版本区间（v1~v3，向下兼容；用户 2026-11-07）
##   v3 新增可选字段 tier_variants；老包没有 → 默认 false，不影响加载。
const ICON_PACK_VERSION_MIN := 1
const ICON_PACK_VERSION_MAX := 5

# ------------------------- 扫描 -------------------------

static func pack_dir() -> String:
	# ① 外置目录（桌面版：exe 旁的 assets/icons）
	if not OS.has_feature("editor"):
		var ext := OS.get_executable_path().get_base_dir().path_join(EXT_DIR)
		if DirAccess.dir_exists_absolute(ext):
			return ext
	# ② 打包进 pck（安卓版 / 桌面版内置）
	if DirAccess.dir_exists_absolute("res://" + EXT_DIR):
		return "res://" + EXT_DIR
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
	var empty := {"version": ICON_PACK_VERSION_MAX, "type": "advanced", "objects": {}}
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
	# version：整数（只支持该版本）或 [最小, 最大]（支持区间）
	var version_raw: Variant = rootd.get("version", ICON_PACK_VERSION_MAX)
	var vmin := ICON_PACK_VERSION_MAX
	var vmax := ICON_PACK_VERSION_MAX
	if typeof(version_raw) == TYPE_ARRAY:
		var arr_v: Array = version_raw
		if arr_v.size() >= 2:
			vmin = clampi(int(arr_v[0]), 0, 999)
			vmax = clampi(int(arr_v[1]), 0, 999)
			if vmin > vmax:
				var tmp := vmin
				vmin = vmax
				vmax = tmp
		elif arr_v.size() == 1:
			vmin = clampi(int(arr_v[0]), 0, 999)
			vmax = vmin
	else:
		vmin = clampi(int(version_raw), 0, 999)
		vmax = vmin
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
	# 作者声明本包有 +/- 变体图标（默认 false；设置里据此决定是否显示勾选框）
	var tier_variants := bool(rootd.get("tier_variants", false))
	# effect：只有 adv_extend 才认；一个 ID 可以有多条（按 speed 从高到低匹配）
	# 图标 ID 的条目还可带可选字段 "bgs"：该图标显示时循环播放哪个背景音效事件 ID
	# （用户 2026-11-08：音效像 effect 标签一样绑到图标 ID，游戏端不再按 phase 判断）
	var effects: Dictionary = {}
	var raw_eff: Variant = rootd.get("effect", null)
	if raw_eff != null:
		if type != "adv_extend":
			push_warning("[IconPacks] %s：type=%s 不支持 effect，已忽略" % [pack, type])
		elif typeof(raw_eff) == TYPE_ARRAY:
			for item in (raw_eff as Array):
				if typeof(item) != TYPE_DICTIONARY:
					continue
				for eid in (item as Dictionary).keys():
					var spec: Variant = (item as Dictionary)[eid]
					if typeof(spec) != TYPE_DICTIONARY:
						continue
					var sd: Dictionary = spec
					var has_color := str(sd.get("color", "")).strip_edges() != ""
					var has_bright := sd.has("brightness")
					var has_hue := sd.has("hue_shift")
					var is_bgs := str(eid).begins_with("mainicon.bgs.")
					var has_gradient := sd.has("gradient")
					var has_bgs_field := str(sd.get("bgs", "")).strip_edges() != ""
					if is_bgs and has_gradient:
						# bgs 只允许 gradient；出现 color/brightness/hue_shift → warning 并忽略
						if has_color or has_bright or has_hue:
							push_warning("[IconPacks] %s：bgs 条目只能带 gradient，其它字段已忽略：%s" % [pack, str(eid)])
					elif not has_color and not has_bright and not has_hue and not has_bgs_field:
						push_warning("[IconPacks] %s：effect %s 缺 color/brightness，已忽略" % [pack, str(eid)])
						continue
					if not effects.has(str(eid)):
						effects[str(eid)] = []
					(effects[str(eid)] as Array).append({
						"speed": float(sd.get("speed", -1.0)),
						"color": str(sd.get("color", "")),
						"brightness": float(sd.get("brightness", 0.0)),
						"hue_shift": float(sd.get("hue_shift", 0.0)),
						"gradient": maxf(0.0, float(sd.get("gradient", 0.0))),
						"bgs": str(sd.get("bgs", "")).strip_edges(),
					})
	var data := {"version": "%d~%d" % [vmin, vmax], "vmin": vmin, "vmax": vmax,
		"tier_variants": tier_variants,
		"type": type, "icon_size": icon_size, "objects": table, "effects": effects}
	_index_cache[pack] = {"stamp": stamp, "data": data}
	print("[IconPacks] index %s：version=%d~%d type=%s 条目=%d effect=%d" % [pack, vmin, vmax, type, table.size(), effects.size()])
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
	return int(load_index(pack).get("vmin", ICON_PACK_VERSION_MAX))


static func type_of(pack: String) -> String:
	return str(load_index(pack).get("type", "advanced"))


## 包的版本区间和游戏支持的 [ICON_PACK_VERSION_MIN, ICON_PACK_VERSION_MAX] 是否有交集。
## 包写整数 v → 区间 [v,v]；包写 [a,b] → 区间 [a,b]。
## 实测：1 ✓ / 3 ✓ / [1,3] ✓ / 99 ✗（黄色）
static func version_ok(pack: String) -> bool:
	var idx := load_index(pack)
	var pmin := int(idx.get("vmin", ICON_PACK_VERSION_MAX))
	var pmax := int(idx.get("vmax", ICON_PACK_VERSION_MAX))
	return pmin <= ICON_PACK_VERSION_MAX and pmax >= ICON_PACK_VERSION_MIN


## 某个图标的 effect：**先看图标是否命中**（调用的地方已经用当前图标 ID），
## 再按 speed 从高到低取第一条 speed ≤ kt；没有 speed 的那条作为兜底。
## 返回 {} = 没有 effect（不变色）。speed 写错就不生效，不做兜底校验（用户 2026-11-06）。
static func effect_for(pack: String, id: String, kt: float) -> Dictionary:
	var idx := load_index(pack)
	var effs: Dictionary = idx.get("effects", {})
	if not effs.has(id):
		return {}
	var list: Array = effs[id]
	var best: Dictionary = {}
	var fallback: Dictionary = {}
	for e in list:
		var ed: Dictionary = e
		var speed := float(ed.get("speed", -1.0))
		if speed < 0.0:
			if fallback.is_empty():
				fallback = ed
			continue
		if kt >= speed:
			if best.is_empty() or speed > float(best.get("speed", -1.0)):
				best = ed
	if not best.is_empty():
		return best
	return fallback


## 作者是否声明「本包有 +/- 变体图标」（index.json 的 tier_variants）
## ⚠ 声明 true 但实际一个变体 ID 都没有 → warning 并当 false（用户 2026-11-07）
static func has_tier_variants(pack: String) -> bool:
	var idx := load_index(pack)
	if not bool(idx.get("tier_variants", false)):
		return false
	var objs: Dictionary = idx.get("objects", {})
	for id in ["ts_plus", "c2_minus", "c3_minus", "c4_plus"]:
		if objs.has("mainicon.icon.north." + id):
			return true
	push_warning("[IconPacks] %s：声明了 tier_variants=true 但没有任何变体 ID，已按 false 处理" % pack)
	return false


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
	if p.begins_with("res://"):
		return p if ResourceLoader.exists(p) else ""
	return p if FileAccess.file_exists(p) else ""


## 统一视频加载：res:// 走 load()（导入资源），外部路径用 VideoStreamTheora.file
static func _load_video(path: String) -> VideoStream:
	if path.begins_with("res://"):
		return load(path) as VideoStream
	var v := VideoStreamTheora.new()
	v.file = path
	return v


## 取视频
static func video(pack: String, id: String) -> VideoStream:
	var abs := path_of(pack, id)
	if abs == "":
		return null
	return _load_video(abs)


## 统一图片加载：res:// 走 load()，外部路径走 Image.load
static func _load_texture(path: String) -> Texture2D:
	if path.begins_with("res://"):
		return load(path) as Texture2D
	var img := Image.new()
	if img.load(path) != OK:
		return null
	return ImageTexture.create_from_image(img)


## 取图片（单图方案）
static func image(pack: String, id: String) -> Texture2D:
	var abs := path_of(pack, id)
	if abs == "":
		return null
	return _load_texture(abs)


## 统一音频加载：res:// 走 load()（已导入），外部路径用 load_from_file
static func _load_audio(path: String) -> AudioStream:
	if path.begins_with("res://"):
		return load(path) as AudioStream
	var ext := path.get_extension().to_lower()
	if ext == "ogg":
		return AudioStreamOggVorbis.load_from_file(path)
	if ext == "wav":
		return AudioStreamWAV.load_from_file(path)
	return null


## 取音频
static func audio(pack: String, id: String) -> AudioStream:
	var abs := path_of(pack, id)
	if abs == "":
		return null
	return _load_audio(abs)
