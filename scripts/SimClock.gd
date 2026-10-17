extends Node
## [autoload: SimClock] 模拟时钟。对应原 Scratch 角色「基础系统//时间轴」。
##
## 设计（照原项目那样，只有「天」和「月」两个变量）：
##   · 正常速度：4 真实秒 → 天 +1
##   · 空闲加速：1 真实秒 → 天 +1
##   · 天满 30 进月，月满 12 回 1 月
##
## `sim_days` 不再是独立累加的变量，而是**从 month/day 派生**出来的
## 「年内第几天」。这样它永远不会和界面上显示的日期对不上。

signal day_advanced
signal month_changed(month: int)
## 走完一整年（12月30日 → 下一年）
signal year_completed
## 每帧都发一次，让 UI 能连续刷新（台风信息、日期）
signal clock_ticked

# ------------------------- 日历常量 -------------------------
const DAYS_PER_MONTH := Const.DAYS_PER_MONTH
const MONTHS_PER_YEAR := Const.MONTHS_PER_YEAR
const DAYS_PER_YEAR := DAYS_PER_MONTH * MONTHS_PER_YEAR      # 360

# ⚠ 日长**不在这里写死** —— 统一从 `Const` 拿，而 `Const` 又是从
#   `config/simulation.cfg` 读的。以前这里另写了一份 4.0 / 1.0，
#   和 `Const.SECONDS_PER_DAY` 是两份，改一个不改另一个就会错位。

# ------------------------- 状态 -------------------------
var month := Const.START_MONTH
var day := Const.START_DAY
var running := false

## true = 空闲加速（1 秒/天）；false = 正常（4 秒/天）。
## 由 TyphoonSim 根据「有没有活跃台风」设置。
var idle_boost := false
## 到 12月30日 之后是否停在原地不回到 1 月（风季模式用，避免跨年回绕把结算漏掉）
var clamp_at_year_end := false

var _day_accumulator := 0.0


## 当前速度：每「天」需要多少真实秒。值来自 `config/simulation.cfg`
func seconds_per_day() -> float:
	return Const.SECONDS_PER_DAY_IDLE if idle_boost else Const.SECONDS_PER_DAY


## 从 month/day 派生的「年内第几天」，1月1日 = 0，12月30日 = 359
func sim_days() -> float:
	return float((month - 1) * DAYS_PER_MONTH + (day - 1))


## ⚠ 必须跑在**物理帧**（`_physics_process`）上，不能跑渲染帧（`_process`）。
##
## 为什么：台风本体在 `TyphoonSim._physics_process` 里推进，用的是物理帧的 delta；
## 日期时钟如果跑渲染帧，两者就是**两个不同的时基**。正常情况两边都累计真实时间、
## 看不出差别，但**渲染卡顿时会分家**——Godot 每帧最多跑
## `max_physics_steps_per_frame`（默认 8）次物理步，超了就丢时间，
## 于是物理那边慢了、渲染这边照常走，**日期会跑到台风前面**。
## 放在同一个时基上就永远是自洽的。
func _physics_process(delta: float) -> void:
	if not running:
		return

	_day_accumulator += delta
	var spd := seconds_per_day()
	var guard := 0
	while _day_accumulator >= spd and guard < 256:
		_day_accumulator -= spd
		guard += 1
		_advance_day()

	clock_ticked.emit()


## 天 +1；满 30 进月；满 12 月则回到 1 月（或按 clamp_at_year_end 停住）
func _advance_day() -> void:
	if day >= DAYS_PER_MONTH:
		if month >= MONTHS_PER_YEAR:
			# 已经是 12月30日，再走一天就是新的一年
			year_completed.emit()
			if clamp_at_year_end:
				return                       # 停在 12月30日，等结算
			month = 1
			month_changed.emit(month)
		else:
			month += 1
			month_changed.emit(month)
		day = 1
	else:
		day += 1
	day_advanced.emit()


## 开局 / 重开：重置日历并开始走表
func begin() -> void:
	reset()
	running = true


## 暂停时间轴：只停表，**不重置日期**
## （之前这里误用了会 reset 的 start()，导致每次「继续」都跳回 1月1日）
func pause() -> void:
	running = false


## 暂停后继续：接着走，不重置
func resume() -> void:
	running = true


func reset() -> void:
	month = Const.START_MONTH
	day = Const.START_DAY
	_day_accumulator = 0.0
	idle_boost = false


## 手动改日期（右侧栏的「调整日期」，风季模式下会被禁用）
func set_date(month_value: int, day_value: int) -> void:
	month = clampi(month_value, 1, MONTHS_PER_YEAR)
	day = clampi(day_value, 1, DAYS_PER_MONTH)


## 物理层用：真实秒 → 模拟天。
## ⚠ 这里目前仍按「当前速度」换算。因为 idle_boost 只在没有活跃台风时为真，
##   实际运行时物理永远走 4 秒/天这一档，不会和日历打架。
##   将来若要加「全局加速」按钮（有台风时也加速），必须把这行改成恒定档，
##   否则台风会在几秒内从 20kt 冲到 170kt。
func days_from_seconds(seconds: float) -> float:
	return seconds / seconds_per_day()


func date_text() -> String:
	return "%d 月 %d 日" % [month, day]


func is_idle_speed() -> bool:
	return idle_boost


## 海温的季节变化幅度。对应原角色「基础系统//海温季节变化」：
## 海温增幅（最终）= sin((月份 - 5) * 30) * 季节海温变化幅度 + (平均海温 - 30)
func seasonal_sst_amplitude() -> float:
	return sin(deg_to_rad((month - 5) * 30.0)) * Const.SEASONAL_AMPLITUDE + (Const.MEAN_SST - 30.0)
