$ErrorActionPreference = "Stop"
$serviceRoot = $PSScriptRoot
$python = Join-Path $serviceRoot ".venv\Scripts\python.exe"
$logDirectory = Join-Path $serviceRoot "logs"
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$serviceLog = Join-Path $logDirectory ("service-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

try {
    Set-Location -LiteralPath $serviceRoot
    if (-not (Test-Path -LiteralPath $python)) {
        throw "OCR dependencies are missing. Run setup.ps1 first."
    }

    $listener = Get-NetTCPConnection -LocalPort 5110 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $listener) {
        Write-Host "OCR service is already running at http://127.0.0.1:5110 (PID $($listener.OwningProcess))."
        Read-Host "Press Enter to close"
        exit 0
    }

    Write-Host "Starting OCR service at http://127.0.0.1:5110 ..."
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $python -m uvicorn app:app --host 127.0.0.1 --port 5110 2>&1 | Tee-Object -FilePath $serviceLog -Append
    $serviceExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($serviceExitCode -ne 0) { throw "OCR service stopped with exit code $serviceExitCode." }
    Write-Host "OCR service stopped."
}
catch {
    Add-Content -LiteralPath $serviceLog -Value "[$(Get-Date -Format o)] OCR service could not start: $($_.Exception.Message)"
    Write-Host "OCR service could not start: $($_.Exception.Message)" -ForegroundColor Red
}

Read-Host "Press Enter to close"
