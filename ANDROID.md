# 安卓版（android 分支）移植说明

> 生成日期：2026-11-06
> 版本：`1.2.0-android.2`（versionCode 2）
> 包名：`com.example.typhoon`，应用名 `Typhoon`
> 签名：`G:\typhoon\mygame-release.keystore`（别名 `typhoon_simulator`，口令在 `G:\typhoon\keystore password.txt`）
> 架构：`arm64-v8a`，minSdk 24（Android 7.0），targetSdk 36
> 渲染：Godot 4.7.2 mobile 渲染器（Vulkan）

---

## 一、目录与分支关系（重要）

| 目录 | 内容 | 说明 |
|---|---|---|
| `G:\typhoon\project` | **桌面版**工程 | 主线，本次移植**一个文件都没改** |
| `G:\typhoon\git` | 真实 git 仓库 | `project\.git` 是指向它的文件 |
| `G:\typhoon\android-port` | **安卓版**工程 | `android` 分支的独立工作树（`git worktree`），所有安卓改动都在这里 |
| `G:\typhoon\android-build` | 构建中间产物/验证报告 | 截图、校验报告、构建日志 |
| `G:\typhoon\游戏导出\APKS` | **安卓 APK 交付目录** | 打好的 release APK + `.sha256` 都放这里（方便在压缩包堆里找） |

两个工程目录互相独立：桌面版继续在 `project`（`main` 分支）开发，安卓版在 `android-port`（`android` 分支）开发。
**不要把安卓改动写回 `project`**，否则会污染桌面主线。

> ⚠ 游戏底层逻辑（`TyphoonSim.gd` / `Storm.gd` / `OceanField.gd` / `SimClock.gd` / `config/simulation.cfg` 的物理参数）
> **完全没有改**。本分支只改「资源路径、UI、返回键、打包、签名、音频缓冲」这些平台适配层。

---

## 二、相对桌面版的改动

### 1. 工程配置 `project.godot`

| 项 | 值 | 原因 |
|---|---|---|
| `display/window/handheld/orientation` | `4`（sensor_landscape） | 锁定横屏，兼容左右横放 |
| `display/window/stretch/aspect` | `expand` | 手机 20:9 屏幕铺满，逻辑高度仍 720，不拉伸变形 |
| `input_devices/pointing/emulate_mouse_from_touch` | `true` | 触摸自动转鼠标事件，原有点击逻辑不用改 |
| `config/quit_on_go_back` | `false` | 安卓返回键交给 `AndroidCompat` 分发，而不是直接退出 |
| `audio/driver/output_latency` | `30` | 音频缓冲从默认 15ms 加到 30ms，缓解手机上的音效卡顿/爆音 |
| `audio/driver/mix_rate` | `48000` | 多数安卓设备原生 48kHz，避免重采样 |
| `renderer/rendering_method(.mobile)` | `mobile` | Vulkan（沿用 1.2.0 桌面版的渲染管线） |
| `[autoload] AndroidCompat` | 新增 | 见下 |
| `config/version` | `1.2.0-android.2` | 和 APK versionName 一致 |

### 2. 新增 `scripts/android/AndroidCompat.gd`（autoload）

- **安全区**：`safe_insets()` 把 `DisplayServer.get_display_safe_area()` 的物理像素换算成逻辑像素 inset；
  `register_safe_area(margin_container)` 给注册过的 `MarginContainer` 叠加四边 margin（原始值存在节点 meta 上，重复注册不会叠加两次），窗口尺寸/旋转变化自动重算。桌面 inset 恒为 0。
- **返回键分发**（安卓没有实体返回键，全屏手势用户全靠它）：
  1. 先关最上层弹窗（ACE 排行榜 / 调整日期等 `AcceptDialog`）
  2. 关可见的设置覆盖层
  3. 暂停中 → 恢复
  4. 游戏中 → 弹出暂停菜单
  5. 主菜单 → **第一次只显示「再返回一次退出应用」提示，2 秒内再返回才退出**（防误触）
- **全屏兜底**：启动 / 从后台回来 / 获得焦点时，如果窗口模式不是全屏就 `window_set_mode(FULLSCREEN)`，并每 2 秒兜底检查一次（部分机型启动后会把状态栏弹回来）。
- **平台判断**：`is_android()`。

### 3. 全屏 / 状态栏（安卓导出关键）

Godot 安卓的「沉浸式全屏」由**两段配合**实现：

1. 导出预设 `screen/immersive_mode=true` → `assets/_cl_` 里写入 `--fullscreen`，
   安卓 Java 层会调 `WindowInsetsControllerCompat.hide(systemBars)` 隐藏状态栏 + 导航栏；
2. 导出预设 `screen/edge_to_edge=true` → `--edge_to_edge`，内容铺到系统栏下面（draw behind），
   配合 App 自己的安全区 inset，即使系统栏短暂出现也不会把画面「顶小」。

`AndroidCompat` 再从 GDScript 侧兜底请求一次全屏（`DisplayServer.window_set_mode(FULLSCREEN)`）。
三管齐下，实测构建出的 APK 里 `assets/_cl_` 已带 `--fullscreen` + `--edge_to_edge`。

### 4. 资源路径（桌面是外置文件夹，安卓必须打进 pck）

APK 里没有「exe 同目录」这种可浏览/可写的外部目录，Godot 安卓导出把 pck 内容平铺在 APK 的 `assets/` 下，只能用 `res://` 读：

| 文件 | 改动 |
|---|---|
| `scripts/IconPacks.gd` | 安卓走 `res://assets/icons`：导入资源（.ogv/.ogg/.png）用 `ResourceLoader.load()`，`index.json` 用 `FileAccess`；**存在性判断对 res:// 必须用 `ResourceLoader.exists()`**（pck 里 .ogg 源文件不存在，只有 remap）。桌面外置文件夹逻辑原样保留。 |
| `scripts/Constants.gd` | 安卓跳过「exe 同目录 sst.txt / simulation.cfg 覆盖」，只用打包进 pck 的 `res://config/*`（**物理数值不变**）。 |
| `scripts/BestTrack.gd` | 安卓最佳路径数据写到 `user://BestTrack`（APK 目录不可写）。 |
| `scripts/SimSettings.gd` | 同上，新增 `display_best_track_dir()` 把 `user://` 转成实际路径供 UI 显示。 |

### 5. UI 触摸适配

- 所有可点控件触摸目标 ≥ 44 逻辑像素（按钮 48~66、标签页 48、滑块 48 高 + 32px 圆形抓手、侧栏按钮 48~52、暂停菜单 64、对话框按钮 52）。
- 设置菜单 / 暂停菜单 / 标题画面的模拟设置面板：外面加 `Frame` 居中行，宽屏（逻辑宽度 >1280）时面板限宽 1280 居中，桌面 16:9 时与改动前逐像素一致；外框 `MarginContainer` 注册安全区。
- 主游戏场景加 `SafeArea` 外框包住「地图 + 右侧栏」，刘海/手势条不会挡侧栏按钮。
- 安卓隐藏「全屏显示」行和整个「视频」页（全屏由系统决定）；桌面保留。
- 标题画面按钮从「宽度百分比锚点」改成固定像素列，背景卫星图按视口等比放大铺满，宽屏不漂移。
- 返回键分组：`PauseLayer` → `pause_layer`；`SettingsMenu` / 标题画面 `AppSettings` / `SettingsPanel` → `settings_overlay`（都实现 `close()`）；`GameRoot` → `game_root`；`AcceptDialog` 由 `AndroidCompat` 用 `find_children("*", "Window")` 关掉。
- 两个 `AcceptDialog`（ACE 排行榜 / 调整日期）的内置按钮文案本地化为「确定」。

### 6. 导出预设 `export_presets.cfg` 的 `[preset.2] "Android"`

```ini
export_filter="all_resources"
include_filter="config/*,assets/icons/*/index.json"    # 非导入文件必须显式包含
exclude_filter="_dev/*,assets/android/*,*.md,*.log"     # 测试脚本/图标源文件不打包
architectures/arm64-v8a=true                            # 只出 arm64
launcher_icons/main_192x192="res://assets/android/launcher_192.png"
launcher_icons/adaptive_foreground_432x432="res://assets/android/launcher_fg_432.png"
launcher_icons/adaptive_background_432x432="res://assets/android/launcher_bg_432.png"
package/unique_name="com.example.typhoon"
version/code=2
version/name="1.2.0-android.2"
screen/immersive_mode=true                              # → _cl_ 写 --fullscreen（隐藏系统栏）
screen/edge_to_edge=true                                # → _cl_ 写 --edge_to_edge（内容铺到系统栏下）
screen/background_color=Color(0, 0, 0, 1)
```

- `assets/icons/SMCY1.3/`（43.8 MB，57 个文件）现在**打进 pck**，所以 APK 从 46 MB 涨到约 89 MB。
- 启动图标由 `_dev/gen_launcher_icons.gd` 从 `assets/images/2630_Champi.jpg`（台风卫星云图）生成，产物在 `assets/android/`。

---

## 三、构建

```powershell
powershell -ExecutionPolicy Bypass -File G:\typhoon\android-port\build_android.ps1
# 资源没变、只改了 gd 脚本时可以跳过 import：
powershell -ExecutionPolicy Bypass -File G:\typhoon\android-port\build_android.ps1 -SkipImport
```

脚本做的事：

1. 检查环境（Godot / 导出模板 / Android SDK / JDK / keystore）；
2. 把 `TEMP`/`TMP` 指向 `G:\typhoon\tmp`（本机 Godot 只能写 G: 盘）；
3. 若缺 `AppData\Local\Android\Sdk` 就建目录 junction 指向 `C:\AndroidSdk`（Godot 编辑器设置里记的是旧路径）；
4. 从 `keystore password.txt` 读口令，通过 `GODOT_ANDROID_KEYSTORE_RELEASE_PATH / _USER / _PASSWORD` 交给 Godot 签名（不需要 `export_credentials.cfg`，口令不进 git）；
5. `godot --headless --import` → `godot --headless --export-release "Android" <out.apk>`；
   **导出最多重试 3 次**——headless 导出安卓有已知概率「跑到一半静默退出」，只有真的生成 APK 才算成功；
6. 用 `apksigner verify --print-certs` 与 `aapt2 dump badging` 自检；
7. 把 APK 的 `SHA256` 写进同名 `.sha256` 文件。

产物默认：`G:\typhoon\游戏导出\APKS\typhoon1.2.0-android.2.apk`（同目录会写一个 `.sha256` 校验文件）。

> ⚠ 脚本必须保存为 **UTF-8 with BOM**：Windows PowerShell 5.1 会把「无 BOM 的 UTF-8」当 ANSI 读，中文注释会导致解析失败。
> 如果用编辑器改过 `build_android.ps1`，请确认编码仍是 UTF-8 with BOM（或直接用 PowerShell 7 运行）。

### 版本号规范（从下一版开始）

安卓版本号统一为 **`<桌面版版本号>-android`**：

| 版本 | 版本号字符串 |
|---|---|
| 开发/测试版（例） | `1.2.0-Beta.3-android` |
| 正式版（例） | `1.2.0-android` |

- **主菜单左下角**显示 `v<config/version>`，直接读 `project.godot` 的 `config/version`，改版本号后自动跟随（`TitleScrBtnClk.gd` 不写死版本）。
- 一条命令改版本 + 出包（脚本会自动把 `-Version`/`-VersionCode` 写进工程和导出预设，并按版本号命名 APK）：

  ```powershell
  powershell -ExecutionPolicy Bypass -File G:\typhoon\android-port\build_android.ps1 `
      -Version "1.2.0-Beta.3-android" -VersionCode 3 -SkipImport
  ```

  产物：`G:\typhoon\游戏导出\APKS\typhoon1.2.0-Beta.3-android.apk` + 同名 `.sha256`（文件名里的空格会换成 `-`）。
- 手动改也可以，但**三处必须一致**：`project.godot` 的 `config/version`、`export_presets.cfg` 的 `version/name` 和 `version/code`
  （`versionCode` 每次发行必须 +1，否则手机无法覆盖升级）。
- 本次第一版沿用 `1.2.0-android.2`（versionCode 2），从下一版开始按上面的规范。

---

## 四、安装 / 运行

- 要求：Android 7.0+（minSdk 24）、arm64（armeabi-v7a/x86 没打包）、支持 Vulkan 1.0 的 GPU（近几年的主流手机都满足）。
- 手机直接装：把 APK 传到手机，允许「安装未知来源应用」后安装；已装过 `1.2.0-android.1` 的可以直接覆盖升级（versionCode 2）。
- 或用 adb：
  ```cmd
  C:\AndroidSdk\platform-tools\adb.exe install -r G:\typhoon\游戏导出\APKS\typhoon1.2.0-android.2.apk
  ```
- 旧的无签名 beta 包（`typhoon1.2.0-beta.3-android.apk`）签名不同，装新包前先卸载。

---

## 五、图标方案包（SMCY1.3）

- 设置 → 「预设」页 → 「方案」下拉：`Default` / `Advanced default`（代码程序化渲染）+ `SMCY1.3`（打进 APK 的视频方案包）。
- 默认仍是 `Default`（最稳）；想看视频图标就切到 `SMCY1.3`，设置会立即生效并存到 `user://settings.cfg`。
- 方案包目录格式与桌面版完全一致（`index.json` + `mainicon/` + `landfall/` + `particle/` + `sound/`）。
- **图标大小**：`assets/icons/SMCY1.3/index.json` 里的 `"icon_size"` 控制图标世界直径（逻辑像素），当前 **130**（原 100，用户反馈偏小）。
  改这个数字后重新构建即可；桌面版用的外置 `assets/icons` 文件夹同理（改那边的 `index.json`）。
  没有 `icon_size` 的其它方案回退到 `scripts/PathLayer.gd` 的 `ICON_DIAMETER_FALLBACK`（100）。

---

## 六、验证记录（本机，2026-11-06）

| 项目 | 结果 |
|---|---|
| headless 导出 + Godot 内签名 | 通过（`apksigner`：v2/v3 有效，证书 SHA-256 `A7:5B:25:...:39:B9`，DN `CN=Ht231213`） |
| APK 清单 | 包名 `com.example.typhoon`、versionName `1.2.0-android.2`、versionCode 2、minSdk 24、targetSdk 36、`native-code: arm64-v8a`、`screenOrientation=11`（锁横屏） |
| 全屏参数 | `assets/_cl_` 含 `--fullscreen` + `--edge_to_edge`（沉浸式 + 边到边） |
| pck 内容 | `SMCY1.3/index.json`（`icon_size=130`）+ 22 个 .ogv + 12 个 .ogg 导入产物 + `config/sst.txt` + `config/simulation.cfg` 全在包内 |
| 打包洁净度 | 无 `_dev/*`、`_build/*`、`*.log`、`*.md` |
| 启动图标 | `res/mipmap-anydpi-v26/icon.xml` 等 25 个资源（普通/自适应/单色） |
| 图标方案 res:// 链路 | `_dev/icon_res_test.gd` 32 项 PASS；并用**真实 pck 挂载**做等价验证（.ogg 只有 remap、必须走 ResourceLoader） |
| 返回键自检 | `_dev/back_test.tscn` PASS=13 FAIL=0：弹窗优先关闭、主菜单两次返回、暂停/恢复、设置 close()、安全区不叠加 |
| UI 自检（headless） | `_dev/ui_audit.gd` PASS=92 FAIL=0：触摸目标 ≥44、1280/1560/2000/2340x1080 宽屏布局、模拟安全区 inset、安卓平台分支、返回键分组 |
| 桌面窗口实跑 | 标题/设置/暂停/游戏截图正常，退出码 0，无脚本错误 |

截图与校验报告在 `G:\typhoon\android-build\screens\` 与 `G:\typhoon\android-build\VERIFY.md`。

---

## 七、已知限制 / 待办

1. **没有真机验证**：本机没有连接安卓设备、也没装模拟器。`OS.has_feature("android")` 分支、安全区真实数值、Theora 视频图标在手机上的播放效果、返回键手势，都需要装到真机确认。
2. **Vulkan**：mobile 渲染器要求 Vulkan；极老/低端机可能不支持。若需要更广兼容，可把 `renderer/rendering_method` 改回 `gl_compatibility` 另出一版。
3. **键盘快捷键失效**：`G/T/R/F3~F6` 等调试快捷键在手机上无用（调试面板默认隐藏，不影响正常玩）。
4. **最佳路径导出**：写到应用私有目录 `user://BestTrack`（≈ `/sdcard/Android/data/com.example.typhoon/files/BestTrack` 不可直接访问，需要 adb pull 或文件管理器进应用私有目录）。这是 Android 10+ 分区存储的必然结果。
5. **触摸尺寸换算**：按技术文档「≥44 逻辑像素」实现（实际 48~66）。但要说明：`1280x720` 设计分辨率铺满手机横屏后，1 逻辑像素约等于 0.5 dp，
   也就是说这些按钮的**物理尺寸**约 4.5~6.5 mm，比 Material 的 48dp（约 7.6 mm）标准偏小（这是「720p 设计直接铺满手机」的固有结果，桌面版同样如此）。
   如果实际用起来觉得小，最省事的调法是加大 `project.godot` 的 `gui/theme/default_theme_scale`（当前 1.31）并同步调大各控件 `custom_minimum_size`；或者给 `window/stretch/scale` 设 <1 的值整体放大。
6. **音频**：已把缓冲加到 30ms、采样率 48kHz。如果某些机型仍有杂音/卡顿，可以继续加大 `audio/driver/output_latency`（如 40~60）；如果切换 SMCY1.3 视频图标时卡顿明显，多半是 Theora 软解吃 CPU，可先切回 Default 方案对比。
7. **全屏开关**：安卓上已隐藏；桌面版仍保留。
8. `com.example.typhoon` 是按技术文档沿用的示例包名；将来要上应用商店前应改成自己的正式包名（改 `export_presets.cfg` 的 `package/unique_name` 后重新构建，换包名 = 新应用，旧数据不迁移）。
9. 桌面版后续更新同步到安卓版：在 `G:\typhoon\android-port` 里 `git merge main`，冲突大概率集中在本说明「二、相对桌面版的改动」列出的文件上；改完重新跑 `build_android.ps1`。

---

## 八、改动文件清单

```
新增：
  scripts/android/AndroidCompat.gd        安卓适配层（安全区/返回键/全屏兜底/平台判断）
  build_android.ps1                       一键构建脚本（含 headless 导出重试）
  assets/android/launcher_192.png         启动图标（普通）
  assets/android/launcher_fg_432.png      启动图标（自适应前景）
  assets/android/launcher_bg_432.png      启动图标（自适应背景）
  ANDROID.md                              本文档

修改：
  project.godot                           横屏/aspect/触摸/返回键/音频缓冲/autoload/version
  export_presets.cfg                      Android 预设：图标与 config 打进 pck、排除 _dev、全屏/边到边、图标/版本
  assets/icons/SMCY1.3/index.json         图标直径 icon_size 100 → 130
  scripts/IconPacks.gd                    安卓 res:// 加载方案包
  scripts/Constants.gd                    安卓跳过 exe 同目录覆盖
  scripts/BestTrack.gd                    安卓写 user://BestTrack
  scripts/SimSettings.gd                  安卓导出目录
  scripts/SettingsMenu.gd                  触摸/安全区/宽屏/隐藏全屏页
  scripts/PauseLayer.gd                    安全区/宽屏/返回键分组
  scripts/GameRoot.gd                      安全区外框
  scripts/TitleScrBtnClk.gd                宽屏按钮列/背景/对话框按钮中文
  scripts/Sidebar.gd                       触摸目标/对话框按钮中文
  scripts/SettingsPanel.gd                 安全区/close()
  SettingsMenu.tscn PauseLayer.tscn TitleScreen.tscn GameRoot.tscn
  SimSettings.tscn ResultsPanel.tscn       UI 结构与触摸尺寸
  assets/icons/SMCY1.3/sound/*.ogg.import  补提交导入配置（安卓分支原来只提交了 ogg 本体）
```
