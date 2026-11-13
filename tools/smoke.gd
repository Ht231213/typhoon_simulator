extends SceneTree
## 冒烟测试（headless）：把关键场景逐个实例化，确认脚本/场景不报错。
##
## 用法：godot --headless --path . -s res://tools/smoke.gd

const SCENES := [
	"res://BootIntro.tscn",
	"res://TitleScreen.tscn",
	"res://AppSettingsPanel.tscn",
	"res://SettingsMenu.tscn",
	"res://SimSettings.tscn",
	"res://GameRoot.tscn",
	"res://PauseLayer.tscn",
	"res://ResultsPanel.tscn",
]

var _i := -1
var _wait := 0
var _loaded: Node = null


func _initialize() -> void:
	_next()


func _next() -> void:
	if _loaded != null:
		_loaded.queue_free()
		_loaded = null
	_i += 1
	if _i >= SCENES.size():
		print("[smoke] all scenes loaded OK")
		quit(0)
		return
	var path: String = SCENES[_i]
	var packed: PackedScene = load(path)
	if packed == null:
		printerr("[smoke] FAIL load ", path)
		quit(1)
		return
	_loaded = packed.instantiate()
	if _loaded == null:
		printerr("[smoke] FAIL instantiate ", path)
		quit(1)
		return
	root.add_child(_loaded)
	_wait = 4
	print("[smoke] ok ", path)


func _process(_delta: float) -> bool:
	if _loaded == null:
		return false
	_wait -= 1
	if _wait <= 0:
		_next()
	return false
