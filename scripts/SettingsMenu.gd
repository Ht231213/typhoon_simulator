extends Control
## 设置界面：选项卡式（视频 / 音频），比窗口略小的半透明框，
## 顶部选项卡、底部确定 / 取消。
##
## 改动是「即时预览、确定才落盘」：
##   · 拖动滑块 / 勾选全屏 → 立刻生效（GameSettings 直接改总线与窗口）
##   · 点「确定」→ 写入配置文件
##   · 点「取消」或按 ESC → 回滚到上次保存的值
##
## 两种用法都支持：
##   ① 场景里放一个实例（主菜单用），调用 open()
##   ② 运行时 load(...).instantiate() 再加进树（ESC 菜单用）
## 本节点 process_mode = ALWAYS，所以 ESC 全暂停（get_tree().paused）时也能操作。

@onready var tab_bar: TabBar = %TabBar
@onready var pages: TabContainer = %Pages

@onready var fullscreen_check: CheckBox = %FullscreenCheck

@onready var music_slider: HSlider = %MusicSlider
@onready var music_value: Label = %MusicValue
@onready var sfx_slider: HSlider = %SfxSlider
@onready var sfx_value: Label = %SfxValue
@onready var preset_option: OptionButton = %PresetOption

@onready var back_button: Button = %BackButton
@onready var hint_label: Label = %HintLabel

## 关闭时的回调（由打开方注入）
var on_closed: Callable = Callable()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	# 用外置 TabBar 控制 TabContainer：同步标签数量 + 标题，再藏掉 TabContainer 自带的标签条
	pages.tabs_visible = false
	tab_bar.tab_count = pages.get_tab_count()
	for i in pages.get_tab_count():
		tab_bar.set_tab_title(i, pages.get_tab_title(i))
	tab_bar.tab_changed.connect(_on_tab_changed)

	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	music_slider.value_changed.connect(_on_music_changed)
	sfx_slider.value_changed.connect(_on_sfx_changed)
	preset_option.item_selected.connect(_on_preset_selected)

	back_button.pressed.connect(close)

	_setup_presets()


func _on_tab_changed(index: int) -> void:
	pages.current_tab = index


func _setup_presets() -> void:
	preset_option.clear()
	for preset in GameSettings.SFX_PRESETS:
		preset_option.add_item(preset)


# ============================ 打开 / 同步 ============================

## 打开设置界面：先把控件同步到当前设置值
func open() -> void:
	fullscreen_check.set_pressed_no_signal(GameSettings.fullscreen)
	music_slider.set_value_no_signal(GameSettings.music_volume * 100.0)
	sfx_slider.set_value_no_signal(GameSettings.sfx_volume * 100.0)
	_refresh_volume_labels()
	var idx := GameSettings.SFX_PRESETS.find(GameSettings.sfx_preset)
	preset_option.select(maxi(idx, 0))

	# 回到第一个选项卡。用 tab_count 判断，避免标签还没同步时报越界
	if tab_bar.tab_count > 0:
		tab_bar.current_tab = 0
	if pages.get_tab_count() > 0:
		pages.current_tab = 0
	hint_label.text = "改动已即时保存到 %s" % GameSettings.save_path_absolute()
	visible = true


func _refresh_volume_labels() -> void:
	music_value.text = "%d%%" % int(roundf(music_slider.value))
	sfx_value.text = "%d%%" % int(roundf(sfx_slider.value))


# ============================ 各控件回调 ============================
# 全部都「即时生效 + 立即保存」，所以没有确定/取消按钮，只有一个「返回」。

func _on_fullscreen_toggled(value: bool) -> void:
	var ok: bool = GameSettings.set_fullscreen(value)
	# 没生效（编辑器内嵌窗口）→ 把勾选框拉回去，并说明原因，别让它显示成已开
	fullscreen_check.set_pressed_no_signal(GameSettings.fullscreen)
	if ok:
		hint_label.text = "已保存：全屏 = %s" % ("开" if GameSettings.fullscreen else "关")
	else:
		hint_label.text = "当前环境不支持全屏——编辑器里请在「编辑器设置 → 运行 → 窗口」关掉「嵌入游戏窗口」，或直接运行导出的 exe"


func _on_music_changed(value: float) -> void:
	GameSettings.set_music_volume(value / 100.0)
	_refresh_volume_labels()
	hint_label.text = "已保存：音乐音量 %d%%" % int(roundf(value))


func _on_sfx_changed(value: float) -> void:
	GameSettings.set_sfx_volume(value / 100.0)
	_refresh_volume_labels()
	hint_label.text = "已保存：音效音量 %d%%" % int(roundf(value))


func _on_preset_selected(index: int) -> void:
	if index >= 0 and index < GameSettings.SFX_PRESETS.size():
		GameSettings.set_sfx_preset(GameSettings.SFX_PRESETS[index])
		hint_label.text = "已保存：音效预设 %s" % GameSettings.sfx_preset


# ============================ 关闭 ============================

## 「返回」按钮：改动早就保存了，这里只关掉界面
func close() -> void:
	visible = false
	if on_closed.is_valid():
		on_closed.call()


## ESC 等同于点「返回」
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
