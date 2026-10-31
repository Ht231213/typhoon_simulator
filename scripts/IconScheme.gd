extends RefCounted
## 图标 / 登陆特效「方案」的扫描、元数据与贴图加载（1.2.1）。
##
## 方案 = `assets/<kind>/<方案名>/` 下一个文件夹（kind = `icons` / `effects`），
## 里面放贴图 + 可选的 `scheme.cfg`。用户想要「像音频方案那样」可以自己加，
## 所以这里**每次调用都重新扫目录**（不做启动时缓存，代价可忽略）。
##
## 查找顺序（从高到低）：
##   ① 外部目录 `<exe 目录>/assets/<kind>/<方案>/`   ← 导出后用户在 exe 旁边放
##   ② 内置 `res://assets/<kind>/<方案>/`            ← 随包
##   ③ 内置默认方案 `res://assets/<kind>/default/`   ← 缺档回退
##   web 版没有外部文件系统 → ① 为空字符串，自动跳过（不会报错）。
##
## ⚠ 故意不用 `class_name`：1.1.0 踩过「新 class_name 必须先 --import」的坑，
##   这里用 `preload("res://scripts/IconScheme.gd")` 静态调用就够了。

const KIND_ICONS := "icons"
const KIND_EFFECTS := "effects"
const DEFAULT_SCHEME := "default"
## 兜底档位：连 default 方案都没有对应档时用它（通用白环）
const TIER_GENERIC := "generic"

## 方案元数据缺省值（scheme.cfg 里可以覆盖）
const DEFAULT_ROTATION_DEG_PER_SEC := 72.0
const DEFAULT_ICON_WORLD_DIAMETER := 100.0
const DEFAULT_CANVAS := 256.0
const DEFAULT_EFFECT_WORLD_SIZE := 26.0
const DEFAULT_EFFECT_FADE_SECONDS := 1.4
const DEFAULT_EFFECT_FADE_SCALE := 2.2

## 贴图缓存：绝对/资源路径 → Texture2D（避免每帧/每换档重复读盘）
static var _texture_cache: Dictionary = {}


## 外部资源根目录。web 版没有本地文件系统 → 返回空串（调用方跳过）。
##   · 导出后（template）：exe 所在目录
##   · 编辑器 / 直接跑工程：工程根
static func external_root() -> String:
	if OS.has_feature("web"):
		return ""
	if OS.has_feature("template"):
		return OS.get_executable_path().get_base_dir()
	return ProjectSettings.globalize_path("res://")


## 某类方案的「查找根」列表（外部在前、内置在后）
static func scheme_roots(kind: String) -> PackedStringArray:
	var roots := PackedStringArray()
	var ext := external_root()
	if ext != "":
		roots.append(ext.path_join("assets").path_join(kind))
	roots.append("res://assets/%s" % kind)
	return roots


## 扫出所有方案名。`default` 永远在第一个（即使目录缺失，UI 也总有个可选项）。
static func scan_schemes(kind: String) -> Array[String]:
	var found: Dictionary = {}
	for root in scheme_roots(kind):
		var dir := DirAccess.open(root)
		if dir == null:
			continue
		for sub in dir.get_directories():
			if found.has(sub):
				continue
			if _looks_like_scheme(root.path_join(sub)):
				found[sub] = true
	var names: Array[String] = [DEFAULT_SCHEME]
	for name in found.keys():
		if name != DEFAULT_SCHEME:
			names.append(name)
	names.sort()
	# sort() 会把 default 排到中间，重新把它挪到第一位
	names.erase(DEFAULT_SCHEME)
	names.insert(0, DEFAULT_SCHEME)
	return names


## 一个文件夹算不算「方案」：有 scheme.cfg，或者至少有一张标准档位贴图。
## ⚠ 导出后 png 会变成 remap 资源，`DirAccess` 列目录未必看得到原始 png
##   → 用几个标准档位名 + `texture_exists()` 探测（会走 ResourceLoader 的 remap）。
static func _looks_like_scheme(dir_path: String) -> bool:
	if FileAccess.file_exists(dir_path.path_join("scheme.cfg")):
		return true
	for probe in ["c1_outer.png", "td_outer.png", "generic_outer.png"]:
		if texture_exists(dir_path.path_join(probe)):
			return true
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return false
	for f in dir.get_files():
		if f.get_extension().to_lower() == "png":
			return true
	return false


## 读方案元数据：先找方案自己的 scheme.cfg，找不到就用 default 方案的。
static func scheme_cfg(kind: String, scheme: String) -> ConfigFile:
	var cfg := ConfigFile.new()
	for root in scheme_roots(kind):
		var p := root.path_join(scheme).path_join("scheme.cfg")
		if FileAccess.file_exists(p) and cfg.load(p) == OK:
			return cfg
	# 方案自己没写 cfg → 用默认方案的（保证转速/世界直径等有值）
	for root in scheme_roots(kind):
		var p := root.path_join(DEFAULT_SCHEME).path_join("scheme.cfg")
		if FileAccess.file_exists(p) and cfg.load(p) == OK:
			return cfg
	return cfg


static func meta_float(kind: String, scheme: String, key: String, fallback: float) -> float:
	var cfg := scheme_cfg(kind, scheme)
	return float(cfg.get_value("meta", key, fallback))


static func meta_string(kind: String, scheme: String, key: String, fallback: String) -> String:
	var cfg := scheme_cfg(kind, scheme)
	return str(cfg.get_value("meta", key, fallback))


## 游戏内强度分类 → scheme.cfg `[category]` 里的键名
static func category_key(cat: int) -> String:
	match cat:
		Const.CAT_UNKNOWN:
			return "unknown"
		Const.CAT_EXTRATROPICAL:
			return "extratropical"
		Const.CAT_WEAK:
			return "weak"
		Const.CAT_DISTURBANCE:
			return "disturbance"
		Const.CAT_DEPRESSION:
			return "depression"
		Const.CAT_TROPICAL_STORM:
			return "tropical_storm"
		Const.CAT_C1:
			return "c1"
		Const.CAT_C2:
			return "c2"
		Const.CAT_C3:
			return "c3"
		Const.CAT_C4:
			return "c4"
		Const.CAT_C5:
			return "c5"
	return "unknown"


## 分类 → 档位名。方案里没写这个分类（或写了空）→ 用 generic 兜底。
static func tier_for_category(kind: String, scheme: String, cat: int) -> String:
	var cfg := scheme_cfg(kind, scheme)
	var key := category_key(cat)
	var tier := str(cfg.get_value("category", key, "")).strip_edges()
	return tier if tier != "" else TIER_GENERIC


## 形态（15 档，`Const.icon_form()`）→ 档位名（1.2.0）。
##
## 优先读方案自己的 `[form]` 段；没写就按「形态 → 旧分类」回退 `[category]`
## （保证用户自己做的老方案不改也能用）；都没有 → generic。
static func tier_for_form(kind: String, scheme: String, form: int) -> String:
	var cfg := scheme_cfg(kind, scheme)
	var tier := str(cfg.get_value("form", str(form), "")).strip_edges()
	if tier != "":
		return tier
	return tier_for_category(kind, scheme, Const.form_to_category(form))


## 判断一个路径上有没有这张贴图。
##
## ⚠ **不能用 `FileAccess.file_exists()` 判断 `res://` 下的贴图**（1.2.1 web 打包踩到）：
##   导出时 png 会被转成 `.godot/imported/*.ctex` + 一份 remap，pck 里**并不存在
##   `res://xxx.png` 这个原始文件** → `FileAccess.file_exists` 返回 false，
##   于是 web/桌面导出版全都"找不到图标"（编辑器里因为在真实磁盘上所以正常）。
##   `ResourceLoader.exists()` 会走 remap，导出前后都正确。
static func texture_exists(path: String) -> bool:
	if path.begins_with("res://"):
		return ResourceLoader.exists(path) or FileAccess.file_exists(path)
	return FileAccess.file_exists(path)


## 找一张贴图的真实路径（外部 → 内置方案 → 内置默认）。找不到返回 ""。
static func find_texture(kind: String, scheme: String, file_name: String) -> String:
	for root in scheme_roots(kind):
		var p := root.path_join(scheme).path_join(file_name)
		if texture_exists(p):
			return p
	# 缺档 → 回退默认方案的同一张
	for root in scheme_roots(kind):
		var p2 := root.path_join(DEFAULT_SCHEME).path_join(file_name)
		if texture_exists(p2):
			return p2
	return ""


## 加载贴图（带缓存）。res:// 用 load()；外部绝对路径用 Image 读进来再包成 ImageTexture。
static func load_texture(path: String) -> Texture2D:
	if path == "":
		return null
	if _texture_cache.has(path):
		return _texture_cache[path]
	var tex: Texture2D = null
	if path.begins_with("res://"):
		tex = load(path) as Texture2D
	else:
		var img := Image.new()
		var err := img.load(path)
		if err == OK and not img.is_empty():
			tex = ImageTexture.create_from_image(img)
	_texture_cache[path] = tex
	return tex


## 取一个档位的图标贴图：{ "outer": Texture2D, "inner": Texture2D, "tier": String }
## 回退顺序：外部方案 → 内置同方案 → 内置 default 同一档 → 内置 default 的 generic。
## 全都没有时返回 null（调用方回退到程序化圆点，不会出现"台风不见了"）。
static func load_icon_textures(scheme: String, tier: String) -> Dictionary:
	var used: String = tier
	var outer := load_texture(find_texture(KIND_ICONS, scheme, "%s_outer.png" % tier))
	var inner := load_texture(find_texture(KIND_ICONS, scheme, "%s_inner.png" % tier))
	if outer == null and tier != TIER_GENERIC:
		used = TIER_GENERIC
		outer = load_texture(find_texture(KIND_ICONS, DEFAULT_SCHEME, "%s_outer.png" % TIER_GENERIC))
		inner = load_texture(find_texture(KIND_ICONS, DEFAULT_SCHEME, "%s_inner.png" % TIER_GENERIC))
	return {"outer": outer, "inner": inner, "tier": used}


## 取一个分类的登陆标记贴图（找不到返回 null）
static func load_effect_marker(scheme: String, cat: int) -> Texture2D:
	var marker := tier_for_category(KIND_EFFECTS, scheme, cat)
	if marker == "":
		return null
	return load_texture(find_texture(KIND_EFFECTS, scheme, "%s.png" % marker))
