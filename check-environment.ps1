[CmdletBinding()]
param(
    # 将未启动的基础设施端口也视为失败，而不只是提示警告。
    [switch]$RequireRunning
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

$script:FailureCount = 0
$script:WarningCount = 0

function Write-Check {
    param(
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')]
        [string]$Status,
        [string]$Message
    )

    $color = switch ($Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Cyan' }
    }

    Write-Host ("[{0}] {1}" -f $Status, $Message) -ForegroundColor $color

    if ($Status -eq 'FAIL') { $script:FailureCount++ }
    if ($Status -eq 'WARN') { $script:WarningCount++ }
}

function Find-Service {
    param([string[]]$Patterns)

    Get-Service -ErrorAction SilentlyContinue |
        Where-Object {
            $name = $_.Name
            $displayName = $_.DisplayName
            $Patterns | Where-Object { $name -match $_ -or $displayName -match $_ }
        } |
        Select-Object -First 1
}

function Test-CommandOrService {
    param(
        [string]$Name,
        [string[]]$CommandNames,
        [string[]]$ServicePatterns,
        [string]$AdditionalPath
    )

    $command = $CommandNames |
        ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    $service = Find-Service -Patterns $ServicePatterns
    $pathExists = -not [string]::IsNullOrWhiteSpace($AdditionalPath) -and (Test-Path -LiteralPath $AdditionalPath)

    if ($command -or $service -or $pathExists) {
        $evidence = if ($service) {
            "Windows 服务：$($service.Name)（$($service.Status)）"
        }
        elseif ($command) {
            "命令：$($command.Source)"
        }
        else {
            "目录：$AdditionalPath"
        }
        Write-Check PASS "已检测到 $Name（$evidence）。"
        return $true
    }

    Write-Check FAIL "未检测到 $Name。"
    return $false
}

function Get-ListeningProcess {
    param([int]$Port)

    try {
        $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
            Select-Object -First 1
        if (-not $connection) { return $null }

        $processInfo = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        [pscustomobject]@{
            ProcessId = $connection.OwningProcess
            Name      = if ($processInfo) { $processInfo.ProcessName } else { 'unknown' }
            Address   = $connection.LocalAddress
        }
    }
    catch {
        return $null
    }
}

function Test-ExpectedPort {
    param(
        [string]$Name,
        [int]$Port,
        [bool]$Infrastructure = $false
    )

    $listener = Get-ListeningProcess -Port $Port
    if ($listener) {
        Write-Check PASS ("{0}：约定端口 {1} 正在监听（进程 {2}，PID {3}，地址 {4}）。" -f $Name, $Port, $listener.Name, $listener.ProcessId, $listener.Address)
        return
    }

    if ($Infrastructure -and $RequireRunning) {
        Write-Check FAIL "${Name}：约定端口 $Port 未监听。"
        return
    }

    if ($Infrastructure) {
        Write-Check WARN "${Name}：约定端口 $Port 未监听（可能尚未启动，或端口配置不一致）。"
        return
    }

    Write-Check INFO "${Name}：项目端口 $Port 当前未监听。"
}

Write-Host '千知万理 运行环境检测' -ForegroundColor White
Write-Host '基础设施约定端口：MySQL 3306、MongoDB 27017、Neo4j Bolt 5255。' -ForegroundColor DarkGray
Write-Host ''

Write-Host '.NET 与 Node.js' -ForegroundColor White
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) {
    Write-Check FAIL '未在 PATH 中找到 .NET SDK；项目需要 .NET 10。'
}
else {
    $sdks = & dotnet --list-sdks 2>$null
    if ($sdks -match '(?m)^10\.\d+\.\d+') {
        $sdk10 = ($sdks | Where-Object { $_ -match '^10\.\d+\.\d+' } | Select-Object -First 1).Trim()
        Write-Check PASS "已检测到 .NET 10 SDK：$sdk10"
    }
    else {
        Write-Check FAIL '已找到 .NET，但未安装 .NET 10 SDK。'
    }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Check FAIL '未在 PATH 中找到 Node.js。'
}
else {
    $nodeVersion = (& node --version 2>$null).Trim()
    Write-Check PASS "已检测到 Node.js：$nodeVersion"
}

Write-Host ''
Write-Host '基础设施安装与端口状态' -ForegroundColor White
Test-CommandOrService -Name 'MySQL' -CommandNames @('mysql', 'mysqld') -ServicePatterns @('^MySQL', 'MySQL') | Out-Null
Test-ExpectedPort -Name 'MySQL' -Port 3306 -Infrastructure $true

Test-CommandOrService -Name 'MongoDB' -CommandNames @('mongod', 'mongosh') -ServicePatterns @('^MongoDB$', 'MongoDB') | Out-Null
Test-ExpectedPort -Name 'MongoDB' -Port 27017 -Infrastructure $true

Test-CommandOrService -Name 'Neo4j' -CommandNames @('neo4j') -ServicePatterns @('^neo4j', 'Neo4j') -AdditionalPath (Join-Path $env:USERPROFILE '.Neo4jDesktop2') | Out-Null
Test-ExpectedPort -Name 'Neo4j Bolt' -Port 5255 -Infrastructure $true

Write-Host ''
Write-Host '千知万理服务端口（仅显示当前状态）' -ForegroundColor White
$servicePorts = @(
    @{ Name = 'Gateway'; Port = 5000 },
    @{ Name = 'UserService'; Port = 5101 },
    @{ Name = 'AuthService'; Port = 5102 },
    @{ Name = 'FileService'; Port = 5103 },
    @{ Name = 'KnowledgeService'; Port = 5104 },
    @{ Name = 'GalGameService'; Port = 5105 },
    @{ Name = 'RenderService'; Port = 5106 },
    @{ Name = 'OCRService'; Port = 5110 },
    @{ Name = 'Frontend'; Port = 5121 }
)

foreach ($servicePort in $servicePorts) {
    Test-ExpectedPort -Name $servicePort.Name -Port $servicePort.Port
}

Write-Host ''
if ($FailureCount -gt 0) {
    Write-Host "环境检测未通过：$FailureCount 项失败，$WarningCount 项警告。" -ForegroundColor Red
    Read-Host '按 Enter 键关闭此窗口'
    exit 1
}

Write-Host "环境检测完成：$WarningCount 项警告。" -ForegroundColor Green
Read-Host '按 Enter 键关闭此窗口'
exit 0
