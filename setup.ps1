[CmdletBinding()]
param(
    [switch]$UseNpmInstall,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$setupFailed = $false

try {
$root = $PSScriptRoot
$frontendPath = Join-Path $root 'frontend'
$projects = @(
    @{ Name = 'Gateway'; Path = (Join-Path $root 'gateway') },
    @{ Name = 'Frontend'; Path = $frontendPath },
    @{ Name = 'RenderService'; Path = (Join-Path $root 'backend\RenderService\service') }
)

function Stop-FrontendResidue {
    $stoppedProcessIds = [System.Collections.Generic.HashSet[int]]::new()
    $listeners = Get-NetTCPConnection -LocalPort 5121, 5122 -State Listen -ErrorAction SilentlyContinue
    foreach ($listener in $listeners) {
        if ($stoppedProcessIds.Add([int]$listener.OwningProcess)) {
            Write-Host ("[Cleanup] Stopping frontend listener (PID {0}, port {1})" -f $listener.OwningProcess, $listener.LocalPort) -ForegroundColor DarkYellow
            Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
        }
    }

    $frontendNodeModules = (Join-Path $frontendPath 'node_modules').TrimEnd('\') + '\'
    $esbuildProcesses = Get-CimInstance Win32_Process -Filter "Name = 'esbuild.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($frontendNodeModules, [System.StringComparison]::OrdinalIgnoreCase) }
    foreach ($process in $esbuildProcesses) {
        if ($stoppedProcessIds.Add([int]$process.ProcessId)) {
            Write-Host ("[Cleanup] Stopping frontend esbuild (PID {0})" -f $process.ProcessId) -ForegroundColor DarkYellow
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

$npmCommand = Get-Command 'npm.cmd' -ErrorAction SilentlyContinue
if ($null -eq $npmCommand) {
    $npmCommand = Get-Command 'npm' -ErrorAction SilentlyContinue
}

if ($null -eq $npmCommand) {
    throw 'npm was not found. Install Node.js LTS, reopen PowerShell, then run this script again.'
}

Write-Host 'QZWL web dependency setup' -ForegroundColor Cyan
Write-Host ("Node.js: " + (& node --version))
Write-Host ("npm:     " + (& $npmCommand.Source --version))
Write-Host ''

Stop-FrontendResidue

foreach ($project in $projects) {
    if (-not (Test-Path -LiteralPath $project.Path -PathType Container)) {
        throw ("Missing {0} directory: {1}" -f $project.Name, $project.Path)
    }

    $packageJson = Join-Path $project.Path 'package.json'
    if (-not (Test-Path -LiteralPath $packageJson -PathType Leaf)) {
        throw ("{0} is missing package.json: {1}" -f $project.Name, $packageJson)
    }

    Push-Location -LiteralPath $project.Path
    try {
        $packageLock = Join-Path $project.Path 'package-lock.json'
        if ((Test-Path -LiteralPath $packageLock -PathType Leaf) -and -not $UseNpmInstall) {
            Write-Host ("[Install] {0} (npm ci)" -f $project.Name) -ForegroundColor Yellow
            & $npmCommand.Source ci --no-audit --no-fund
        }
        else {
            Write-Host ("[Install] {0} (npm install)" -f $project.Name) -ForegroundColor Yellow
            & $npmCommand.Source install --no-audit --no-fund
        }

        if ($LASTEXITCODE -ne 0) {
            throw ("{0} dependency installation failed with exit code {1}." -f $project.Name, $LASTEXITCODE)
        }
    }
    finally {
        Pop-Location
    }
}

Write-Host ''
Write-Host 'Done: Gateway, Frontend, and RenderService dependencies are ready.' -ForegroundColor Green
}
catch {
    Write-Host ''
    Write-Host ("Setup failed: " + $_.Exception.Message) -ForegroundColor Red
    $setupFailed = $true
}

if (-not $NoPause) {
    [void](Read-Host 'Press Enter to close this window')
}

if ($setupFailed) {
    exit 1
}
