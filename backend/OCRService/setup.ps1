param(
    [string]$Python = $env:OCR_PYTHON
)

$ErrorActionPreference = "Stop"
$serviceRoot = $PSScriptRoot
$packageIndex = "https://pypi.tuna.tsinghua.edu.cn/simple"
$logDirectory = Join-Path $serviceRoot "logs"
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
Start-Transcript -Path (Join-Path $logDirectory ("setup-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))) -Append | Out-Null
Set-Location -LiteralPath $serviceRoot

function Test-SupportedPython([string]$Command, [string[]]$Arguments) {
    try {
        $version = (& $Command @Arguments -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)) { return $false }
        $parts = $version.Split('.')
        return $parts.Count -eq 2 -and $parts[0] -eq '3' -and [int]$parts[1] -ge 9 -and [int]$parts[1] -le 12
    }
    catch { return $false }
}

$pythonCommand = $null
$pythonArguments = @()

if (-not [string]::IsNullOrWhiteSpace($Python)) {
    if (-not (Test-Path -LiteralPath $Python)) { throw "The Python path does not exist: $Python" }
    if (-not (Test-SupportedPython $Python @())) { throw "Python must be version 3.9 through 3.12: $Python" }
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
            foreach ($candidate in @('3.12', '3.11', '3.10', '3.9')) {
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
    throw "Python 3.9-3.12 was not found. Install Python and add it to PATH, or run setup.ps1 -Python <path-to-python.exe>."
}

$selectedVersion = (& $pythonCommand @pythonArguments -c "import sys; print(sys.version)").Trim()
Write-Host "Using Python: $selectedVersion"
& $pythonCommand @pythonArguments -m venv .venv
& .\.venv\Scripts\python.exe -m pip install --upgrade pip
& .\.venv\Scripts\python.exe -m pip install --index-url $packageIndex --retries 5 --timeout 90 -r requirements.txt
Stop-Transcript | Out-Null
