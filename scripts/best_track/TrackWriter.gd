extends RefCounted
## 最佳路径导出的**格式抽象基类**：把「组装文本」和「落盘」分开。
##
## 为什么这么抽：`BestTrackRecorder` 里的采样 / 归档 / 跨年 / 重名后缀全是格式无关的，
## 只有「一行文本长什么样」是格式专有的。抽出来之后加新格式（NOAA/IBTrACS）只要再写一个子类，
## 记录器公共接口（begin_track / sample / end_track / flush_year / reset）一行都不用改。
##
## ⚠ **故意不用 `class_name`**：1.1.0 踩过「新增 class_name 必须先 `--import` 才进全局类缓存」的坑。
##   writer 只在 recorder 内部按字典取用、不需要全局可见，用 `preload` + 路径式 `extends` 最省事。
##   代价：类型标注只能写 `RefCounted`，调用是动态的。
##
## ⚠ `build_text()` 是**纯函数**（不碰文件系统）——这样 headless 里可以拿它和黄金文本逐字节比对，
##   不必真的写盘。所有子类都必须保持这个性质。

## 格式标识，必须与 `GameSettings.BEST_TRACK_FORMATS` 里的字符串一致
var id := "base"

## 扩展名（含点）
var extension := ".txt"


## 组装整份文件的内容（含末尾换行）。**纯函数、不落盘**
func build_text(tracks: Array, write_year: int) -> String:
	var parts := PackedStringArray()
	parts.append_array(preamble_lines())
	for t in tracks:
		parts.append_array(track_header_lines(t))
		for s in (t["samples"] as Array):
			parts.append(sample_line(s, t, write_year))
	return "\n".join(parts) + "\n"


## 落盘。默认实现：建不了文件就返回 false（调用方负责提示），成功返回 true。
func write_file(path: String, tracks: Array, write_year: int) -> bool:
	ensure_sidecar(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[BestTrack] 写不了文件：%s" % path)
		return false
	f.store_string(build_text(tracks, write_year))
	f.close()
	return true


## 目录级附加物（默认什么都不做）。IBTrACS 用它写「本目录是模拟数据」的 README-SIM.txt，
## CMA 的声明直接写在文件里、不需要额外的文件。
func ensure_sidecar(_dir: String) -> void:
	pass


## 文件开头的全局部分（CMA：中英双语声明；IBTrACS：列名 + 单位两行）
func preamble_lines() -> PackedStringArray:
	return PackedStringArray()


## 每个台风开始前的行（CMA：58 字符头记录；IBTrACS：无）
func track_header_lines(_t: Dictionary) -> PackedStringArray:
	return PackedStringArray()


## 一个时次的数据行。同时收到 sample（时刻/位置/强度）和 track（编号/名字/年份）：
## CMA 只用 sample，IBTrACS 每行还要写 SID/NAME/SEASON 这些台风级字段。
func sample_line(_s: Dictionary, _t: Dictionary, _write_year: int) -> String:
	return ""


## 文件名主体（不含扩展名、不含重名后缀）。子类可覆写。
func file_base(dir: String, ymd: String, year_index: int) -> String:
	return dir.path_join("Best Track %s-%d" % [ymd, year_index])
