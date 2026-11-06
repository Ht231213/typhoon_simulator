# 安卓版构建脚本（android 分支专用）
#
# 用法（在 PowerShell 里）：
#   powershell -ExecutionPolicy Bypass -File .\build_android.ps1
#   powershell -ExecutionPolicy Bypass -File .\build_android.ps1 -SkipImport   # 资源没变时跳过 import
#   powershell -ExecutionPolicy Bypass -File .\build_android.ps1 -Output D:\typhoon.apk
#   # 下次发版的版本号规范：<桌面版版本号>-android（正式版如 1.2.0-android）
#   powershell -ExecutionPolicy Bypass -File .\build_android.ps1 -Version "1.2.0-Beta.3-android" -VersionCode 3 -SkipImport
#
# 版本号会同时写进：project.godot 的 config/version（主菜单左下角标签自动跟随）
# 和 export_presets.cfg 的 version/name + version/code（APK 的 versionName/versionCode）。
#
# 前提（本机已装好）：
#   · Godot 4.7.2-stable + 安卓导出模板（%APPDATA%\Godot\export_templates\4.7.2.stable）
#   · Android SDK：C:\AndroidSdk（Godot 编辑器设置里指向的旧路径已用目录 junction 指过去）
#   · JDK 21：C:\Program Files\Java\jdk-21
#   · 签名文件：G:\typhoon\mygame-release.keystore，别名 typhoon_simulator，
#     口令在 G:\typhoon\keystore password.txt（脚本自动读取；命令行参数可覆盖）
#
# 说明：
#   · 按本机限制，Godot 只能写 G: 盘，所以临时目录重定向到 G:\typhoon\tmp。
#   · 导出预设 export_presets.cfg 的 [preset.2] "Android" 已配好：
#     图标方案包 assets/icons/** 与 config/* 打进 pck、_dev/* 排除。
#   · 脚本用环境变量 GODOT_ANDROID_KEYSTORE_RELEASE_* 把发布 keystore 交给 Godot 签名，
#     这样不需要写 export_credentials.cfg，也不会把口令提交进 git。
#   · Godot 会把「user:// 写不了 / editor settings 存不了」等无害信息打到 stderr，
#     所以每一步用 Start-Process 重定向到日志文件，只看退出码和产物，不用 $ErrorActionPreference。

param(
    [string]$ProjectDir = $PSScriptRoot,
    [string]$Godot = "G:\typhoon\godot.exe",
    [string]$Preset = "Android",
    [string]$Output = "",
    [string]$Version = "",
    [string]$VersionCode = "",
    [string]$Keystore = "G:\typhoon\mygame-release.keystore",
    [string]$KeystorePasswordFile = "G:\typhoon\keystore password.txt",
    [string]$Alias = "typhoon_simulator",
    [string]$AndroidSdk = "C:\AndroidSdk",
    [string]$TempDir = "G:\typhoon\tmp",
    [switch]$SkipImport
)

$ErrorActionPreference = "Continue"

function Step($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }

# 运行 Godot / 工具并捕获输出到文件，返回退出码。
# （不用管道 2>&1：PS5.1 会把原生程序的 stderr 当 ErrorRecord，容易误判成脚本错误）
function Invoke-Tool {
    param([string]$Exe, [string[]]$ToolArgs, [string]$LogBase)
    $outFile = "$LogBase.out"
    $errFile = "$LogBase.err"
    $p = Start-Process -FilePath $Exe -ArgumentList $ToolArgs -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    return $p.ExitCode
}

# ---------- 0. 环境检查 ----------
Step "环境检查"
if (-not (Test-Path $Godot)) { throw "找不到 Godot：$Godot" }
if (-not (Test-Path (Join-Path $ProjectDir "project.godot"))) { throw "不是 Godot 工程目录：$ProjectDir" }
if (-not (Test-Path $Keystore)) { throw "找不到签名文件：$Keystore" }
if (-not (Test-Path $KeystorePasswordFile)) { throw "找不到签名口令文件：$KeystorePasswordFile" }
if (-not (Test-Path (Join-Path $AndroidSdk "build-tools"))) { throw "找不到 Android SDK：$AndroidSdk" }

# 本机 Godot 只能写工作盘：临时目录重定向
New-Item -ItemType Directory -Force $TempDir | Out-Null
$env:TEMP = $TempDir
$env:TMP = $TempDir
New-Item -ItemType Directory -Force "$TempDir\build-logs" | Out-Null
$logBase = "$TempDir\build-logs\build"

# 目录 junction：Godot 编辑器设置里记的是旧 SDK 路径，指向 C:\AndroidSdk
$legacySdk = "C:\Users\$env:USERNAME\AppData\Local\Android\Sdk"
if (-not (Test-Path (Join-Path $legacySdk "build-tools"))) {
    Write-Host "创建 SDK 目录 junction：$legacySdk -> $AndroidSdk"
    New-Item -ItemType Directory -Force (Split-Path $legacySdk) | Out-Null
    cmd /c "mklink /J `"$legacySdk`" `"$AndroidSdk`"" | Out-Null
}

# 签名口令（keystore 与 key 用同一个口令）
$password = (Get-Content $KeystorePasswordFile -Raw).Trim()
if ($password -eq "") { throw "签名口令文件是空的：$KeystorePasswordFile" }
$env:GODOT_ANDROID_KEYSTORE_RELEASE_PATH = (Resolve-Path $Keystore).Path
$env:GODOT_ANDROID_KEYSTORE_RELEASE_USER = $Alias
$env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD = $password

# ---------- 版本号（可选，下次发版用） ----------
# 规范：安卓版本号 = `<桌面版版本号>-android`
#   · 开发/测试版：如 `1.2.0-Beta.3-android`
#   · 正式版：   如 `1.2.0-android`
# 传 -Version 会同时改：
#   · project.godot 的 config/version      → 主菜单左下角标签直接读它，自动跟随
#   · export_presets.cfg 的 version/name   → APK versionName
# 传 -VersionCode 会改 export_presets.cfg 的 version/code（每次发版 +1）
# 用法：build_android.ps1 -Version "1.2.0-Beta.3-android" -VersionCode 3
if ($Version -ne "" -or $VersionCode -ne "") {
    $projFile = Join-Path $ProjectDir "project.godot"
    $projText = [System.IO.File]::ReadAllText($projFile, [System.Text.Encoding]::UTF8)
    if ($Version -ne "") {
        $projText = [regex]::Replace($projText, '(?m)^config/version="[^"\r\n]*"',
            'config/version="' + $Version + '"')
        [System.IO.File]::WriteAllText($projFile, $projText, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "版本号：$Version（主菜单左下角标签会自动显示）"
    }
    $presetFile = Join-Path $ProjectDir "export_presets.cfg"
    $presetText = [System.IO.File]::ReadAllText($presetFile, [System.Text.Encoding]::UTF8)
    if ($Version -ne "") {
        $presetText = [regex]::Replace($presetText, '(?m)^version/name="[^"\r\n]*"',
            'version/name="' + $Version + '"')
    }
    if ($VersionCode -ne "") {
        if (-not ($VersionCode -match '^\d+$')) { throw "-VersionCode 必须是整数：$VersionCode" }
        $presetText = [regex]::Replace($presetText, '(?m)^version/code=\d+', 'version/code=' + $VersionCode)
    }
    [System.IO.File]::WriteAllText($presetFile, $presetText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "（版本号改动要记得 git commit：project.godot / export_presets.cfg）"
}

# 输出路径：没显式指定时，按版本号自动命名（空格换成 -，方便在资源管理器里找）
if ($Output -eq "") {
    if ($Version -ne "") {
        $safeName = ($Version -replace '\s+', '-')
        $Output = "G:\typhoon\游戏导出\APKS\typhoon$safeName.apk"
    } else {
        $Output = "G:\typhoon\游戏导出\APKS\typhoon1.2.0-android.2.apk"
    }
}

New-Item -ItemType Directory -Force (Split-Path $Output) | Out-Null
if (Test-Path $Output) { Remove-Item $Output -Force }

Write-Host "工程：$ProjectDir"
Write-Host "输出：$Output"
Write-Host "签名：$Keystore（别名 $Alias）"

# ---------- 1. 导入资源 ----------
if (-not $SkipImport) {
    Step "导入资源（--import）"
    $code = Invoke-Tool -Exe $Godot -ToolArgs @("--headless", "--path", $ProjectDir, "--import") -LogBase "$logBase-import"
    Get-Content "$logBase-import.err" -ErrorAction SilentlyContinue | Select-Object -Last 6
    # Godot 退出码可能是 1（editor settings 存不进去），只看 .godot 是否就绪
    if (-not (Test-Path (Join-Path $ProjectDir ".godot"))) { throw "import 失败：没有 .godot 目录" }
}

# ---------- 2. 导出 release APK（Godot 内签名） ----------
# ⚠ 已知坑（技术文档里也记了）：headless 导出安卓偶尔「跑到一半静默退出」，不报错也不出包。
#   这里最多重试 3 次，只有真的生成 APK 才算成功。
Step "导出 Android release APK"
$maxExportAttempts = 3
for ($attempt = 1; $attempt -le $maxExportAttempts; $attempt++) {
    if (Test-Path $Output) { Remove-Item $Output -Force }
    Write-Host "第 $attempt 次导出..."
    $code = Invoke-Tool -Exe $Godot -ToolArgs @("--headless", "--path", $ProjectDir, "--export-release", $Preset, $Output) -LogBase "$logBase-export"
    Get-Content "$logBase-export.out" -ErrorAction SilentlyContinue | Select-Object -Last 6
    $errLines = Get-Content "$logBase-export.err" -ErrorAction SilentlyContinue
    if ($errLines) { $errLines | Where-Object { $_ -match "Project export for preset|导出失败" } | Select-Object -Last 4 }
    if (Test-Path $Output) {
        break
    }
    Write-Host "第 $attempt 次导出没有生成 APK（headless 导出已知不稳定），重试…" -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}
if (-not (Test-Path $Output)) { throw "导出失败：重试 $maxExportAttempts 次都没有生成 $Output（完整日志：$logBase-export.out/.err）" }
$apk = Get-Item $Output
Write-Host ("生成：{0}  {1:N1} MB" -f $apk.Name, ($apk.Length / 1MB))

# ---------- 3. 校验签名与清单 ----------
Step "校验签名"
$buildTools = Get-ChildItem (Join-Path $AndroidSdk "build-tools") -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
$apksigner = Join-Path $buildTools.FullName "apksigner.bat"
$aapt2 = Join-Path $buildTools.FullName "aapt2.exe"

$code = Invoke-Tool -Exe $apksigner -ToolArgs @("verify", "--print-certs", $Output) -LogBase "$logBase-apksigner"
$signerOut = Get-Content "$logBase-apksigner.out" -ErrorAction SilentlyContinue
$signerOut | Select-Object -First 6
if ($code -ne 0 -or -not ($signerOut -match "certificate SHA-256 digest")) {
    throw "APK 签名校验失败（退出码 $code，日志：$logBase-apksigner.out/.err）"
}

Step "包信息"
$code = Invoke-Tool -Exe $aapt2 -ToolArgs @("dump", "badging", $Output) -LogBase "$logBase-aapt2"
Get-Content "$logBase-aapt2.out" -ErrorAction SilentlyContinue |
    Select-String -Pattern "^package:|^sdkVersion|^targetSdkVersion|^application-label:|^native-code:" |
    ForEach-Object { $_.Line }

# ---------- 4. 写 SHA256 校验文件（和 APK 同目录） ----------
$sha = (Get-FileHash $Output -Algorithm SHA256).Hash
$shaFile = "$Output.sha256"
Set-Content -Path $shaFile -Value ("{0}  {1}" -f $sha, (Split-Path $Output -Leaf)) -Encoding ASCII
Write-Host "SHA256：$sha"

Write-Host "`n构建完成：$Output" -ForegroundColor Green
Write-Host "校验文件：$shaFile" -ForegroundColor Green
