class_name IconTint
extends RefCounted
## 图标配色：**按强度分段，用三份不同规则**（用户 2026-10-30 更正）
##
##   ┌ 强度分段 ─────────────┬ 用的规则 ──────────────────────────────────────┐
##   │ 温带气旋（EX）           │ `option/RGB-EX.txt`（**只管温带**；用在轨迹线，见 Const.ex_track_color）│
##   │ L/D/TS ~ C4（<137 kt）  │ **不染色**，直接用图标自带的颜色                 │
##   │ C5+（kt ≥ 137）          │ `option/HLS-SSHWS.xlsx`（查表，只取「5」列）     │
##   └─────────────────────────┴───────────────────────────────────────────────┘
##
## ⚠ 之前我把 HLS-SSHWS 误当成**全分类**通用表（S-/S/S+/1..5 列全用上），
##   用户纠正：**它只给 C5+ 用**。所以现在只取表里的「5」列，且从 137 kt 起生效。
##
## ⚠ RGB-EX.txt 实测结构（116 字节）：表头 `WIND R G B`，**7 行、风速 60–90（每 5 kt）**，
##   RGB 从 (100,100,100) 渐变到 (200,100,50)。它的风速范围（60–90）和 L/D 实际范围
##   （14–34 kt）**不重叠** → 这里按「把 L/D 段的 14→34 线性映射到表的 60→90」来用，
##   并把 (100,100,100) 归一化成白色（避免整体压暗）。**这是推导，不是表里写死的**。

# ------------------------- HLS-SSHWS：C5+ 段 -------------------------

## C5+ 生效起点（用户：137 kt 起）
const C5_START_KT := 137.0
## 137→145 kt 之间把色相从 0 渐入，避免在 137 处出现硬折角
const C5_EASE_KT := 8.0

## 表（只抄「5」这一列，和 WIND 对齐）：30..185，每 5 kt 一行
const C5_WINDS := [
	30.0, 35.0, 40.0, 45.0, 50.0, 55.0, 60.0, 65.0, 70.0, 75.0, 80.0, 85.0,
	90.0, 95.0, 100.0, 105.0, 110.0, 115.0, 120.0, 125.0, 130.0, 135.0,
	140.0, 145.0, 150.0, 155.0, 160.0, 165.0, 170.0, 175.0, 180.0, 185.0,
]
const C5_UNITS := [
	240.0, 225.0, 210.0, 195.0, 180.0, 160.0, 140.0, 120.0, 115.0, 110.0,
	105.0, 100.0, 95.0, 90.0, 85.0, 80.0, 75.0, 70.0, 65.0, 60.0, 45.0, 30.0,
	15.0, 0.0, -5.0, -10.0, -15.0, -20.0, -25.0, -30.0, -35.0, -40.0,
]



# ============================ 对外接口 ============================

## C5+ 段的**色相偏移**（单位：度，负值 = 偏蓝紫）。
## kt < 137 返回 0（不染色）；137~145 之间线性渐入，避免在 137 处出现硬折角。
static func hue_shift_for(kt: float) -> float:
	if kt < C5_START_KT:
		return 0.0
	var target := _c5_lookup(kt)
	var ease := clampf((kt - C5_START_KT) / C5_EASE_KT, 0.0, 1.0)
	return target * ease


## **偏蓝强度** 0~1。来自 Sheet2 的 B 通道（165→100、170→150、175→200）。
## kt < 165 返回 0（Sheet2 从 165 才开始有蓝色增益）。
static func blue_mix_for(kt: float) -> float:
	if kt <= 165.0:
		return 0.0
	var t := clampf((kt - 165.0) / 10.0, 0.0, 1.0)   # 165→175 对应 0→1
	return t


## 查 C5 表（每 5 kt 线性插值；<30 取首行；>185 按末段斜率外推）
static func _c5_lookup(kt: float) -> float:
	var n := C5_WINDS.size()
	if kt <= C5_WINDS[0]:
		return C5_UNITS[0]
	if kt >= C5_WINDS[n - 1]:
		var x0: float = C5_WINDS[n - 2]
		var x1: float = C5_WINDS[n - 1]
		var y0: float = C5_UNITS[n - 2]
		var y1: float = C5_UNITS[n - 1]
		return y1 + (y1 - y0) / (x1 - x0) * (kt - x1)
	for i in range(n - 1):
		if kt <= C5_WINDS[i + 1]:
			var xa: float = C5_WINDS[i]
			var xb: float = C5_WINDS[i + 1]
			var ya: float = C5_UNITS[i]
			var yb: float = C5_UNITS[i + 1]
			return lerpf(ya, yb, (kt - xa) / (xb - xa))
	return C5_UNITS[n - 1]
# ------------------------- L / D 段：深蓝基础色 + 色相 −100° -------------------------
#
# 用户 2026-10-31 定稿（「A 读法」）：「D 的 HSL 深蓝 + 色相 −100」= **先取深蓝基础色**，
# 再在它上面做 −100° 的色相偏移（→ 偏蓝绿），而不是直接取色环上 −100° 的那个颜色。
const D_BASE_COLOR := Color(0.20, 0.32, 0.62)   # 「HSL 深蓝」的近似（偏亮的深蓝）
const D_HUE_DEG := -100.0                        # 再往蓝绿偏 -100°
const D_MAX_KT := 34.0                           # L / D 段上限（超过就是 TS 及以上）

## L / D 段的底色（乘法 tint）；>34 kt 返回白色（不改变原图）
static func l_d_base_color(kt: float) -> Color:
	return D_BASE_COLOR if kt < D_MAX_KT else Color.WHITE


## L / D 段的色相偏移（圈数）；>34 kt 返回 0
static func l_d_hue_shift(kt: float) -> float:
	return D_HUE_DEG / 360.0 if kt < D_MAX_KT else 0.0