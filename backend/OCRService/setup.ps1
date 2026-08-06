param(
    [string]$Python = $env:OCR_PYTHON
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

$serviceRoot = $PSScriptRoot
$packageIndex = "https://pypi.tuna.tsinghua.edu.cn/simple"
$logDirectory = Join-Path $serviceRoot "logs"
$transcriptStarted = $false
$exitCode = 0

function Test-SupportedPython([string]$Command, [string[]]$Arguments) {
    try {
        $version = (& $Command @Arguments -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)) { return $false }

        $parts = $version.Split('.')
        return $parts.Count -eq 2 -and $parts[0] -eq '3' -and [int]$parts[1] -ge 9
    }
    catch {
        return $false
    }
}

function Assert-LastExitCode([string]$Action) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Action 失败，退出码：$LASTEXITCODE。请查看 logs 目录中的最新 setup 日志。"
    }
}

try {
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    Start-Transcript -Path (Join-Path $logDirectory ("setup-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))) -Append | Out-Null
    $transcriptStarted = $true
    Set-Location -LiteralPath $serviceRoot

    $pythonCommand = $null
    $pythonArguments = @()

    if (-not [string]::IsNullOrWhiteSpace($Python)) {
        if (-not (Test-Path -LiteralPath $Python)) {
            throw "指定的 Python 路径不存在：$Python"
        }

        if (-not (Test-SupportedPython $Python @())) {
            throw "Python 版本必须为 3.9 或更高：$Python"
        }

        $pythonCommand = $Python
    }
    else {
        $pythonOnPath = Get-Command python -ErrorAction SilentlyContinue
        if ($null -ne $pythonOnPath -and (Test-SupportedPython $pythonOnPath.Source @())) {
            $pythonCommand = $pythonOnPath.Source
        }
        else {
            $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
            if ($null -ne $pyLauncher) {
                foreach ($candidate in @('3', '3.13', '3.12', '3.11', '3.10', '3.9')) {
                    $arguments = @("-$candidate")
                    if (Test-SupportedPython $pyLauncher.Source $arguments) {
                        $pythonCommand = $pyLauncher.Source
                        $pythonArguments = $arguments
                        break
                    }
                }
            }
        }
    }

    if ($null -eq $pythonCommand) {
        throw "未找到 Python 3.9 或更高版本。请安装 Python 并勾选 Add Python to PATH 选项，或使用：.\setup.ps1 -Python C:\Path\To\python.exe"
    }

    $selectedVersion = (& $pythonCommand @pythonArguments -c "import sys; print(sys.version)").Trim()
    Assert-LastExitCode '读取 Python 版本'
    Write-Host "使用 Python：$selectedVersion" -ForegroundColor Cyan

    Write-Host '正在创建或更新虚拟环境...' -ForegroundColor Cyan
    & $pythonCommand @pythonArguments -m venv .venv
    Assert-LastExitCode '创建虚拟环境'

    $venvPython = Join-Path $serviceRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython)) {
        throw "虚拟环境创建后未找到 Python：$venvPython"
    }

    Write-Host '正在安装 OCR 依赖...' -ForegroundColor Cyan
    & $venvPython -m pip install --upgrade pip
    Assert-LastExitCode '升级 pip'

    & $venvPython -m pip install --index-url $packageIndex --retries 5 --timeout 90 -r requirements.txt
    Assert-LastExitCode '安装 OCR 依赖'

    Write-Host '正在下载快速、标准 OCR 与公式识别模型，请耐心等待...' -ForegroundColor Cyan
    & $venvPython -c "import app; app.engine('quick'); app.engine('standard'); app.formula_engine(); print('OCR 和公式识别模型已准备完成。')"
    Assert-LastExitCode '下载 OCR 模型'

    Write-Host 'OCRService 环境配置完成。' -ForegroundColor Green
}
catch {
    $exitCode = 1
    Write-Host ''
    Write-Host "OCRService 配置失败：$($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }

    Write-Host ''
    Read-Host '按 Enter 键关闭此窗口'
}

exit $exitCode
