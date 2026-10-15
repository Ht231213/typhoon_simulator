extends Control
## 风季结束的结果面板：显示台风列表 + 总 ACE，并提示存档结果。

@onready var title_label: Label = %ResultTitle
@onready var summary_label: Label = %ResultSummary
@onready var storm_list: ItemList = %StormList
@onready var save_label: Label = %SaveLabel
@onready var again_button: Button = %AgainButton
@onready var menu_button: Button = %MenuButton


func _ready() -> void:
	again_button.pressed.connect(_on_again)
	menu_button.pressed.connect(_on_menu)
	visible = false


func show_results(saved: bool) -> void:
	title_label.text = "风季结束 · %s" % Game.mode_label()
	summary_label.text = "共生成 %d 场台风    总 ACE %.2f" % [Game.records.size(), Game.total_ace]

	storm_list.clear()
	for i in Game.records.size():
		storm_list.add_item(Game.format_record(Game.records[i]))

	if Game.records.is_empty():
		save_label.text = "本局没有生成任何台风，未写入存档。"
	elif saved:
		save_label.text = "✔ 已写入存档：%s\n分类「%s」" % [Game.save_path_absolute(), Game.save_category()]
	else:
		save_label.text = "⚠ 存档写入失败，请检查 %s" % Game.save_path_absolute()

	visible = true


func _on_again() -> void:
	visible = false
	get_tree().reload_current_scene()


func _on_menu() -> void:
	get_tree().change_scene_to_file("res://TitleScreen.tscn")
