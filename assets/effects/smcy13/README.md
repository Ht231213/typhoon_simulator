# 登陆特效方案（effect schemes）

> 素材来自用户提供的 **SMCY1.3 图标库**（`landfall/`）。

## 文件约定

```
assets/effects/<方案名>/
├─ scheme.cfg          ← 可选。没有就用内置默认值
├─ <名字>.png          ← 登陆标记贴图（默认方案：td / ts / c1..c5 / sts / top / supertop / bsc）
└─ README.md
```

- `scheme.cfg` 的 `[category]` 段把「游戏内强度分类」映射到标记文件名
- 标记是**带 alpha 的 PNG**（默认方案是 40×40 的菱形标记，运行时放大到约 26 px）
- 播放方式：从 `world_size` 放大到 `world_size × fade_scale`，同时淡出，时长 `fade_seconds`

## 回退规则

和图标方案一样：

```
外部 <exe目录>/assets/effects/<方案>/  →  内置 res://assets/effects/<方案>/
        →  内置 res://assets/effects/default/ 的同档
        →  该分类不画额外标记（保留游戏原有的程序化特效）
```

## 自定义方案怎么做

1. 在 exe 旁边新建 `assets/effects/我的方案/`
2. 放进你自己的 `<名字>.png`（任何尺寸、带 alpha 的标记图都行）
3. 想改大小/时长就复制本目录的 `scheme.cfg` 改数值
4. 游戏里「设置 → 视频 → 登陆特效方案」下拉会自动多出「我的方案」

## V1 范围说明

- 本版**只做标记贴图**；素材里还有 `landfall-C1..C5.mp4`（512×512、11 秒的登陆冲击动画），
  体量大、且需要逐帧/视频转码，留到以后（可能会以 `.ogv` 或抽帧序列的形式加进同一方案目录）。
- 音效不在这里管：登陆音效一直是 `assets/sfx/<音效预设>/landfall/*.wav`（设置 → 音频 → 音效预设）。
