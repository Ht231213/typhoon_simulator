extends SceneTree
## 临时探针：打印启动动画进度 + 白光触发时的音乐位置。
## ⚠ -s 运行的脚本编译期拿不到 autoload 名字，这里统一走 /root/MusicManager 节点；
##   节点子项也要在第一帧之后才去取（_initialize 时场景还没 _ready）。

var _boot: Node = null
var _mm: Node = null
var _t := 0.0
var _flash = null
var _reported := false
var _grabbed := false


func _initialize() -> void:
	_boot = load("res://BootIntro.tscn").instantiate()
	root.add_child(_boot)


func _pos() -> float:
	if _mm == null:
		return -1.0
	return float(_mm.call("boot_position"))


func _process(delta: float) -> bool:
	_t += delta
	if _boot == null:
		return true
	if not _grabbed:
		_grabbed = true
		_mm = root.get_node_or_null("MusicManager")
		_flash = _boot.get("_flash")
		print("[sync] grabbed flash=", _flash, " music_node=", _mm)
		return false
	if _flash == null:
		print("[sync] no flash node")
		quit()
		return true
	var a: float = _flash.modulate.a
	if int(_t * 2.0) != int((_t - delta) * 2.0):
		print("[sync] t=", snappedf(_t, 0.1), " music=", snappedf(_pos(), 0.01),
			" flash_a=", snappedf(a, 0.01), " impact=", _boot.get("_impact_done"))
	if a >= 0.5 and not _reported:
		_reported = true
		print("[sync] >>> white flash at music pos = ", snappedf(_pos(), 0.01), " (target 8.0)")
	if _t > 11.0:
		quit()
		return true
	return false
