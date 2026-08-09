# Minimal local launcher for the MoonStone development stack.
param(
    [switch]$Verify,
    [switch]$GalGameMock
)

$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$backendRoot = Join-Path $projectRoot 'backend'
$runtimeDirectory = Join-Path $projectRoot '.runtime'
$bugReportDirectory = Join-Path $projectRoot 'logs'
$gatewayPort = 5000
$gatewayBaseUrl = "http://127.0.0.1:$gatewayPort"
$moonStonePorts = $gatewayPort, 5101, 5102, 5103, 5104, 5105, 5106, 5107, 5108, 5121
$isMockMode = [string]::Equals($env:MOONSTONE_MODE, 'Mock', [System.StringComparison]::OrdinalIgnoreCase)
$useGalGameMock = $isMockMode -or $GalGameMock
$neo4jPassword = if ([string]::IsNullOrWhiteSpace($env:NEO4J_PASSWORD)) { 'knowledge-dev-password' } else { $env:NEO4J_PASSWORD }

function Normalize-ProcessPath {
    $environment = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
    $pathValues = @($environment.GetEnumerator() | Where-Object { [string]$_.Key -ieq 'PATH' } | ForEach-Object { [string]$_.Value })
    if ($pathValues.Count -le 1) { return }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $segments = foreach ($value in $pathValues) {
        foreach ($segment in ($value -split ';')) {
            $trimmed = $segment.Trim()
            if ($trimmed -and $seen.Add($trimmed)) { $trimmed }
        }
    }

    [Environment]::SetEnvironmentVariable('PATH', $null, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('Path', ($segments -join ';'), [EnvironmentVariableTarget]::Process)
}

function Stop-MoonStoneServices {
    $resolvedProjectRoot = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/')
    $rootWithSeparator = $resolvedProjectRoot + [IO.Path]::DirectorySeparatorChar
    $processSnapshot = @{}
    try {
        foreach ($item in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            $processSnapshot[[int]$item.ProcessId] = $item
        }
    }
    catch {
        Write-Warning "Process ownership details are unavailable; generic Node and dotnet processes will be preserved. $($_.Exception.Message)"
    }

    $recordedProcessIds = [System.Collections.Generic.HashSet[int]]::new()
    $manifestPath = Join-Path $runtimeDirectory 'project-processes.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $parsedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            foreach ($manifestItem in @($parsedManifest)) {
                $manifestProcessId = [int]$manifestItem.ProcessId
                $runningProcess = Get-Process -Id $manifestProcessId -ErrorAction SilentlyContinue
                if ($null -eq $runningProcess) { continue }

                $manifestStartTime = [DateTime]::MinValue
                $hasStartTime = [DateTime]::TryParse(
                    [string]$manifestItem.StartedAtUtc,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind,
                    [ref]$manifestStartTime
                )
                if (-not $hasStartTime) { continue }

                try {
                    $actualStartTime = $runningProcess.StartTime.ToUniversalTime()
                    if ([Math]::Abs(($actualStartTime - $manifestStartTime.ToUniversalTime()).TotalSeconds) -le 5) {
                        [void]$recordedProcessIds.Add($manifestProcessId)
                    }
                }
                catch {
                }
            }
        }
        catch {
            Write-Warning "Could not read process manifest '$manifestPath': $($_.Exception.Message)"
        }
    }

    function Test-IsMoonStoneProcess {
        param(
            [Parameter(Mandatory)][int]$ProcessId,
            [Parameter(Mandatory)][string]$ProcessName
        )

        $projectSpecificNames = @(
            'GalGame.AuthService',
            'GalGame.FileService',
            'GalGame.UserService',
            'GalGame.GalGameService',
            'KnowledgeService.API',
            'PracticeService.API',
            'CreditService.API'
        )
        if ($projectSpecificNames -contains $ProcessName) { return $true }

        $cursor = $ProcessId
        $seen = [System.Collections.Generic.HashSet[int]]::new()
        while ($cursor -gt 0 -and $seen.Add($cursor)) {
            if ($recordedProcessIds.Contains($cursor)) { return $true }
            if (-not $processSnapshot.ContainsKey($cursor)) { break }
            $cursor = [int]$processSnapshot[$cursor].ParentProcessId
        }

        if (-not $processSnapshot.ContainsKey($ProcessId)) { return $false }
        $details = $processSnapshot[$ProcessId]
        $executablePath = [string]$details.ExecutablePath
        $commandLine = [string]$details.CommandLine
        return ($executablePath -and $executablePath.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) -or
            ($commandLine -and $commandLine.IndexOf($resolvedProjectRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }

    foreach ($port in $moonStonePorts) {
        $processIds = netstat -ano -p TCP |
            ForEach-Object {
                $parts = @($_ -split '\s+' | Where-Object { $_ })
                if ($parts.Count -ge 5 -and $parts[0] -eq 'TCP' -and $parts[3] -eq 'LISTENING') {
                    $localPort = $parts[1].Substring($parts[1].LastIndexOf(':') + 1)
                    if ($localPort -eq [string]$port) { [int]$parts[4] }
                }
            } |
            Select-Object -Unique

        foreach ($processId in $processIds) {
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            $allowedNames = @('node', 'dotnet', 'GalGame.AuthService', 'GalGame.FileService', 'GalGame.UserService', 'GalGame.GalGameService', 'KnowledgeService.API', 'PracticeService.API', 'CreditService.API')
            if ($process -and $allowedNames -contains $process.ProcessName -and (Test-IsMoonStoneProcess -ProcessId $processId -ProcessName $process.ProcessName)) {
                Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            } elseif ($process -and $allowedNames -contains $process.ProcessName) {
                Write-Host ("  [KEEP] Port {0} belongs to unrelated process {1} (PID {2})." -f $port, $process.ProcessName, $processId) -ForegroundColor DarkYellow
            }
        }
    }
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port
    )

    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $client.ConnectAsync($HostName, $Port)
        if (-not $connectTask.Wait(1000)) {
            $client.Dispose()
            return $false
        }
        $client.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Start-Neo4jDependency {
    if ($isMockMode) { return }
    if (Test-TcpPort -HostName '127.0.0.1' -Port 5255) {
        Write-Host '  [OK] neo4j: bolt://127.0.0.1:5255' -ForegroundColor Green
        return
    }

    throw 'Neo4j is not listening on bolt://127.0.0.1:5255. Start Neo4j with the port specified in contract.md, then rerun .\start.ps1.'
}

function Start-LocalService {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$HealthUrl,
        [string]$WorkingDirectory = $projectRoot
    )

    $standardOutput = Join-Path $runtimeDirectory "$Name.out.log"
    $standardError = Join-Path $runtimeDirectory "$Name.error.log"
    Remove-Item -LiteralPath $standardOutput, $standardError -Force -ErrorAction SilentlyContinue

    $process = Start-Process -FilePath $FilePath `
        -ArgumentList $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Hidden `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -PassThru

    [PSCustomObject]@{
        Name = $Name
        Process = $process
        HealthUrl = $HealthUrl
        StandardOutput = $standardOutput
        StandardError = $standardError
        Command = "$FilePath $Arguments"
    }
}

function Test-ServiceHealth {
    param([Parameter(Mandatory)]$Service)

    $deadline = (Get-Date).AddSeconds(45)
    do {
        try {
            $request = [System.Net.HttpWebRequest]::Create($Service.HealthUrl)
            $request.Method = 'GET'
            $request.Timeout = 2000
            $request.Proxy = $null
            $response = $request.GetResponse()
            $statusCode = [int]$response.StatusCode
            $response.Dispose()
            if ($statusCode -ge 200 -and $statusCode -lt 400) { return $true }
        } catch {
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Write-BugReport {
    param([Parameter(Mandatory)]$Service)

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportPath = Join-Path $bugReportDirectory "$timestamp-$($Service.Name).bugreport.log"
    $stderr = if (Test-Path $Service.StandardError) { Get-Content -Raw $Service.StandardError } else { '' }
    $stdout = if (Test-Path $Service.StandardOutput) { Get-Content -Raw $Service.StandardOutput } else { '' }

    @"
MoonStone startup bug report
Generated at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')
Service: $($Service.Name)
Health endpoint: $($Service.HealthUrl)
Command: $($Service.Command)

--- standard error ---
$stderr

--- standard output ---
$stdout
"@ | Set-Content -LiteralPath $reportPath -Encoding utf8

    return $reportPath
}

function Start-MoonStoneStack {
    Stop-MoonStoneServices
    Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $runtimeDirectory, $bugReportDirectory | Out-Null

    Start-Neo4jDependency

    $env:GATEWAY_PORT = [string]$gatewayPort
    $env:GATEWAY_HOST = '127.0.0.1'
    $env:GATEWAY_URL = $gatewayBaseUrl

    $renderServiceRoot = Join-Path $backendRoot 'RenderService\service'
    Push-Location $renderServiceRoot
    try {
        & npm.cmd run build | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'RenderService build failed.' }
    }
    finally {
        Pop-Location
    }

    $services = @(
        Start-LocalService -Name 'gateway' -FilePath 'npm.cmd' -Arguments 'run dev' -HealthUrl "$gatewayBaseUrl/healthz" -WorkingDirectory (Join-Path $projectRoot 'gateway')
        Start-LocalService -Name 'auth-service' -FilePath 'dotnet' -Arguments "run --project `"$backendRoot\AuthService\GalGame.AuthService.csproj`" -- --Gateway:BaseUrl $gatewayBaseUrl" -HealthUrl 'http://127.0.0.1:5102/healthz'
        Start-LocalService -Name 'file-service' -FilePath 'dotnet' -Arguments "run --project `"$backendRoot\FileService\GalGame.FileService.csproj`"" -HealthUrl 'http://127.0.0.1:5103/healthz'
        Start-LocalService -Name 'user-service' -FilePath 'dotnet' -Arguments "run --project `"$backendRoot\UserService\GalGame.UserService.csproj`"" -HealthUrl 'http://127.0.0.1:5101/healthz'
    )

    if (-not $isMockMode) {
        $knowledgeArguments = "run --project `"$backendRoot\KnowledgeService\KnowledgeService.API\KnowledgeService.API.csproj`" -- --urls http://127.0.0.1:5104 --Neo4j:Uri bolt://127.0.0.1:5255 --Neo4j:Username neo4j --Neo4j:Password $neo4jPassword --Neo4j:Database neo4j --GatewayMaterialText:BaseUrl $gatewayBaseUrl --GatewayMaterialText:ServiceName KnowledgeService --GatewayMaterialText:ServiceKey moonstone-local-gateway-key --Gateway:ServiceKey moonstone-local-gateway-key"
        $services += Start-LocalService -Name 'knowledge-service' -FilePath 'dotnet' -Arguments $knowledgeArguments -HealthUrl 'http://127.0.0.1:5104/readyz'
    }

    $galGameArguments = "run --project `"$backendRoot\GalGameService\GalGame.GalGameService.csproj`" -- --urls http://127.0.0.1:5105 --Gateway:BaseUrl $gatewayBaseUrl --Gateway:ServiceKey moonstone-local-gateway-key"
    if ($useGalGameMock) {
        $galGameArguments += ' --MOONSTONE_MODE Mock --GalGameStore:Provider Memory'
        if ($GalGameMock) { $galGameArguments += ' --GalGameMock:UseFixedStory true' }
    }
    $services += Start-LocalService -Name 'galgame-service' -FilePath 'dotnet' -Arguments $galGameArguments -HealthUrl 'http://127.0.0.1:5105/healthz'

    $env:PORT = '5106'
    $env:RENDER_HOST = '127.0.0.1'
    $env:Gateway__BaseUrl = $gatewayBaseUrl
    $env:Gateway__ServiceName = 'RenderService'
    $env:Gateway__ServiceKey = 'moonstone-local-gateway-key'
    $services += Start-LocalService -Name 'render-service' -FilePath 'npm.cmd' -Arguments 'run start' -HealthUrl 'http://127.0.0.1:5106/healthz' -WorkingDirectory $renderServiceRoot
    $practiceArguments = "run --project `"$backendRoot\PracticeService\PracticeService.API\PracticeService.API.csproj`" -- --urls http://127.0.0.1:5107 --Gateway:BaseUrl $gatewayBaseUrl --Gateway:ServiceName PracticeService --Gateway:ServiceKey moonstone-local-gateway-key"
    if ($isMockMode) { $practiceArguments += ' --PracticeStore:Provider Memory' }
    $services += Start-LocalService -Name 'practice-service' -FilePath 'dotnet' -Arguments $practiceArguments -HealthUrl 'http://127.0.0.1:5107/healthz'
    $creditArguments = "run --project `"$backendRoot\CreditService\CreditService.API\CreditService.API.csproj`" -- --urls http://127.0.0.1:5108 --CreditStore:Provider Memory --Gateway:ServiceKey moonstone-local-gateway-key"
    $services += Start-LocalService -Name 'credit-service' -FilePath 'dotnet' -Arguments $creditArguments -HealthUrl 'http://127.0.0.1:5108/healthz'
    $services += Start-LocalService -Name 'new-frontend' -FilePath 'npm.cmd' -Arguments 'run dev' -HealthUrl 'http://127.0.0.1:5121/' -WorkingDirectory (Join-Path $projectRoot 'frontend')

    $processManifest = @(
        $services | ForEach-Object {
            $processName = $null
            $startedAtUtc = $null
            try {
                $processName = $_.Process.ProcessName
                $startedAtUtc = $_.Process.StartTime.ToUniversalTime().ToString('O')
            }
            catch {
                # A process that exits immediately is reported by the health
                # check below; keep writing the remaining process manifest.
            }
            [pscustomobject]@{
                Name         = $_.Name
                ProcessId    = $_.Process.Id
                ProcessName  = $processName
                StartedAtUtc = $startedAtUtc
            }
        }
    )
    $processManifest |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath (Join-Path $runtimeDirectory 'project-processes.json') -Encoding UTF8

    $failed = @()
    foreach ($service in $services) {
        if (Test-ServiceHealth $service) {
            Write-Host "  [OK] $($service.Name): $($service.HealthUrl)" -ForegroundColor Green
        } else {
            $report = Write-BugReport $service
            $failed += "$($service.Name) -> $report"
            Write-Host "  [FAILED] $($service.Name). Bug report: $report" -ForegroundColor Red
        }
    }

    return $failed
}

try {
    Normalize-ProcessPath
    do {
        Write-Host 'QZWL services are starting and being checked...' -ForegroundColor Yellow
        $failed = Start-MoonStoneStack
        if ($failed.Count -gt 0) {
            throw "Startup failed. Review: $($failed -join '; ')"
        }

        Write-Host ''
        Write-Host 'QZWL services are ready:' -ForegroundColor Green
        Write-Host "  Gateway:           http://localhost:$gatewayPort"
        Write-Host '  UserService:       http://localhost:5101'
        Write-Host '  AuthService:       http://localhost:5102'
        Write-Host '  FileService:       http://localhost:5103'
        Write-Host '  KnowledgeService:  http://localhost:5104'
        Write-Host '  GalGameService:    http://localhost:5105'
        Write-Host '  RenderService:     http://localhost:5106'
        Write-Host '  PracticeService:   http://localhost:5107'
        Write-Host '  CreditService:     http://localhost:5108'
        Write-Host '  Frontend:          http://localhost:5121'
        Write-Host ''
        Write-Host 'Press Ctrl+R to restart, or Enter to stop services.'

        if ($Verify) {
            $restart = $false
            Stop-MoonStoneServices
            break
        }

        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        $restart = $key.VirtualKeyCode -eq 82 -and $key.ControlKeyState.ToString() -match 'Ctrl'
        Stop-MoonStoneServices
    } while ($restart)
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($Verify) { exit 1 }
    Read-Host 'Press Enter to close this launcher window'
}
finally {
    Stop-MoonStoneServices
    Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
