[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [switch]$IncludeEditors,

    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "[stop] $Message" -ForegroundColor Cyan
}

function Test-TextContainsPath {
    param(
        [AllowNull()][string]$Text,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return $Text.IndexOf($Path, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-PathInsideProject {
    param(
        [AllowNull()][string]$Candidate,
        [string]$RootWithSeparator
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $false
    }

    return $Candidate.StartsWith($RootWithSeparator, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ProjectListeners {
    param([int[]]$Ports)

    $listeners = @()

    try {
        $listeners = @(
            Get-NetTCPConnection -State Listen -ErrorAction Stop |
                Where-Object { $Ports -contains $_.LocalPort } |
                ForEach-Object {
                    [pscustomobject]@{
                        Port      = [int]$_.LocalPort
                        ProcessId = [int]$_.OwningProcess
                    }
                }
        )
    }
    catch {
        $listeners = @()
        $lines = @(& netstat.exe -ano -p TCP 2>$null)
        foreach ($line in $lines) {
            if ($line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$') {
                $port = [int]$Matches[1]
                if ($Ports -contains $port) {
                    $listeners += [pscustomobject]@{
                        Port      = $port
                        ProcessId = [int]$Matches[2]
                    }
                }
            }
        }
    }

    return @($listeners | Sort-Object Port, ProcessId -Unique)
}

$resolvedRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
$rootWithSeparator = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
$startScript = Join-Path $resolvedRoot 'start_dev.ps1'

if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
    throw "Refusing to continue: '$resolvedRoot' does not look like the GalReview project root."
}

# Never keep this PowerShell process inside the directory that the user wants
# to release. All paths used below are absolute.
$temporaryDirectory = [IO.Path]::GetTempPath()
Set-Location -LiteralPath $temporaryDirectory

$projectPorts = @(5000, 5101, 5102, 5103, 5104, 5105, 5106, 5107, 5108, 5120, 5121, 5122)
$listenerProcessNames = @(
    'node',
    'dotnet',
    'esbuild',
    'vite',
    'GalGame.AuthService',
    'GalGame.FileService',
    'GalGame.UserService',
    'GalGame.GalGameService',
    'KnowledgeService.API',
    'PracticeService.API',
    'CreditService.API'
)
$editorProcessNames = @(
    'Code',
    'Cursor',
    'devenv',
    'idea64',
    'rider64',
    'codex',
    'explorer',
    'WindowsTerminal'
)
$protectedInfrastructureProcessNames = @(
    # Neo4j runs on the JVM; protect both console and service forms.
    'java',
    'javaw',
    'neo4j',
    # MongoDB server processes.
    'mongod',
    'mongos',
    # MySQL and MariaDB server processes.
    'mysqld',
    'mysqld-nt',
    'mariadbd'
)

$targetReasons = @{}
$skippedEditorProcesses = [Collections.Generic.List[object]]::new()
$reportedInfrastructureProcessIds = [Collections.Generic.HashSet[int]]::new()

function Add-TargetProcess {
    param(
        [int]$ProcessId,
        [string]$Reason
    )

    if ($ProcessId -le 0) {
        return
    }

    $candidateProcess = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -ne $candidateProcess -and $protectedInfrastructureProcessNames -contains $candidateProcess.ProcessName) {
        if ($reportedInfrastructureProcessIds.Add($ProcessId)) {
            Write-Host "[keep] Infrastructure process $($candidateProcess.ProcessName) ($ProcessId) will not be stopped." -ForegroundColor DarkGreen
        }
        return
    }

    if (-not $targetReasons.ContainsKey($ProcessId)) {
        $targetReasons[$ProcessId] = [Collections.Generic.List[string]]::new()
    }

    if (-not $targetReasons[$ProcessId].Contains($Reason)) {
        $targetReasons[$ProcessId].Add($Reason)
    }
}

Write-Step "Scanning project processes under $resolvedRoot"

$processSnapshot = @()
try {
    $processSnapshot = @(
        Get-CimInstance Win32_Process -ErrorAction Stop |
            Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine
    )
}
catch {
    $cimError = $_.Exception.Message
    try {
        $processSnapshot = @(
            Get-WmiObject -Class Win32_Process -ErrorAction Stop |
                Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine
        )
    }
    catch {
        Write-Warning "Process command lines are unavailable (CIM: $cimError; WMI: $($_.Exception.Message)). PID, executable path, and port cleanup will still be used."
    }
}

$processById = @{}
foreach ($item in $processSnapshot) {
    $processById[[int]$item.ProcessId] = $item
}

# Protect this PowerShell process and every ancestor (especially stop.cmd's
# cmd.exe). Their command lines contain the project path but they must stay
# alive until cleanup and reporting are finished.
$protectedProcessIds = [Collections.Generic.HashSet[int]]::new()
$currentProcessId = [int]$PID
[void]$protectedProcessIds.Add($currentProcessId)
while ($processById.ContainsKey($currentProcessId)) {
    $parentId = [int]$processById[$currentProcessId].ParentProcessId
    if ($parentId -le 0 -or -not $protectedProcessIds.Add($parentId)) {
        break
    }
    $currentProcessId = $parentId
}

foreach ($item in $processSnapshot) {
    $processId = [int]$item.ProcessId
    if ($protectedProcessIds.Contains($processId)) {
        continue
    }

    $ownedByPath = (Test-PathInsideProject -Candidate ([string]$item.ExecutablePath) -RootWithSeparator $rootWithSeparator) -or
        (Test-TextContainsPath -Text ([string]$item.CommandLine) -Path $resolvedRoot)

    if (-not $ownedByPath) {
        continue
    }

    $processName = [IO.Path]::GetFileNameWithoutExtension([string]$item.Name)
    if (-not $IncludeEditors -and $editorProcessNames -contains $processName) {
        Write-Host "[skip] Editor process $processName ($processId). Use stop.cmd --include-editors to stop it too." -ForegroundColor DarkYellow
        $skippedEditorProcesses.Add([pscustomobject]@{ Name = $processName; ProcessId = $processId })
        continue
    }

    Add-TargetProcess -ProcessId $processId -Reason 'command or executable references the project'
}

# Executables installed inside the repository (notably Vite's esbuild helper)
# can keep files locked without opening a TCP port. This fallback also works
# when Windows denies access to Win32_Process command lines.
foreach ($runningProcess in @(Get-Process -ErrorAction SilentlyContinue)) {
    $runningProcessId = [int]$runningProcess.Id
    if ($protectedProcessIds.Contains($runningProcessId)) {
        continue
    }

    $executablePath = $null
    try {
        $executablePath = [string]$runningProcess.Path
    }
    catch {
        $executablePath = $null
    }

    if (-not (Test-PathInsideProject -Candidate $executablePath -RootWithSeparator $rootWithSeparator)) {
        continue
    }

    if (-not $IncludeEditors -and $editorProcessNames -contains $runningProcess.ProcessName) {
        if (-not ($skippedEditorProcesses | Where-Object { $_.ProcessId -eq $runningProcessId })) {
            Write-Host "[skip] Editor process $($runningProcess.ProcessName) ($runningProcessId). Use stop.cmd --include-editors to stop it too." -ForegroundColor DarkYellow
            $skippedEditorProcesses.Add([pscustomobject]@{ Name = $runningProcess.ProcessName; ProcessId = $runningProcessId })
        }
        continue
    }

    Add-TargetProcess -ProcessId $runningProcessId -Reason 'executable is inside the project'
}

# PIDs recorded by start_dev.ps1 are the most reliable way to stop npm/cmd/dotnet
# wrappers whose command lines do not necessarily include their working folder.
$manifestPath = Join-Path $resolvedRoot '.runtime\project-processes.json'
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
        # Windows PowerShell 5.1 preserves a JSON array as one pipeline object
        # when ConvertFrom-Json is wrapped directly in @(...). Assign first so
        # the following array expression enumerates each service record.
        $parsedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifestItems = @($parsedManifest)
        foreach ($manifestItem in $manifestItems) {
            $manifestProcessId = [int]$manifestItem.ProcessId
            if ($manifestProcessId -le 0 -or $protectedProcessIds.Contains($manifestProcessId)) {
                continue
            }

            $runningProcess = Get-Process -Id $manifestProcessId -ErrorAction SilentlyContinue
            if ($null -eq $runningProcess) {
                continue
            }

            # Prevent a stale PID file from terminating a later, unrelated
            # process that happens to reuse the same numeric PID.
            $manifestStartTime = [DateTime]::MinValue
            $hasManifestStartTime = [DateTime]::TryParse(
                [string]$manifestItem.StartedAtUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$manifestStartTime
            )
            $startTimeMatches = $false
            if ($hasManifestStartTime) {
                try {
                    $actualStartTime = $runningProcess.StartTime.ToUniversalTime()
                    $startTimeMatches = [Math]::Abs(($actualStartTime - $manifestStartTime.ToUniversalTime()).TotalSeconds) -le 5
                }
                catch {
                    $startTimeMatches = $false
                }
            }

            if ($startTimeMatches) {
                Add-TargetProcess -ProcessId $manifestProcessId -Reason "recorded service: $($manifestItem.Name)"
            }
        }
    }
    catch {
        Write-Warning "Could not read process manifest '$manifestPath': $($_.Exception.Message)"
    }
}

$listeners = @(Get-ProjectListeners -Ports $projectPorts)
foreach ($listener in $listeners) {
    $listenerProcessId = [int]$listener.ProcessId
    if ($protectedProcessIds.Contains($listenerProcessId)) {
        continue
    }

    $listenerProcess = Get-Process -Id $listenerProcessId -ErrorAction SilentlyContinue
    if ($null -eq $listenerProcess) {
        continue
    }

    $knownProjectProcess = $listenerProcessNames -contains $listenerProcess.ProcessName
    $ownedByPath = $false
    if ($processById.ContainsKey($listenerProcessId)) {
        $snapshotItem = $processById[$listenerProcessId]
        $ownedByPath = (Test-PathInsideProject -Candidate ([string]$snapshotItem.ExecutablePath) -RootWithSeparator $rootWithSeparator) -or
            (Test-TextContainsPath -Text ([string]$snapshotItem.CommandLine) -Path $resolvedRoot)
    }

    if ($knownProjectProcess -or $ownedByPath) {
        Add-TargetProcess -ProcessId $listenerProcessId -Reason "listening on project port $($listener.Port)"
    }
    else {
        Write-Warning "Port $($listener.Port) is held by unrelated-looking process '$($listenerProcess.ProcessName)' ($listenerProcessId); it was not stopped."
    }
}

# Stop full child trees. This catches Vite/esbuild, dotnet app hosts, and Node
# processes spawned below npm.cmd even when only the wrapper PID was recorded.
if ($processSnapshot.Count -gt 0) {
    $addedDescendant = $true
    while ($addedDescendant) {
        $addedDescendant = $false
        foreach ($item in $processSnapshot) {
            $processId = [int]$item.ProcessId
            $parentId = [int]$item.ParentProcessId
            if ($protectedProcessIds.Contains($processId)) {
                continue
            }
            if ($targetReasons.ContainsKey($parentId) -and -not $targetReasons.ContainsKey($processId)) {
                Add-TargetProcess -ProcessId $processId -Reason "child of project process $parentId"
                $addedDescendant = $true
            }
        }
    }
}

$depthCache = @{}
function Get-ProcessDepth {
    param([int]$ProcessId)

    if ($depthCache.ContainsKey($ProcessId)) {
        return [int]$depthCache[$ProcessId]
    }

    $depth = 0
    $seen = [Collections.Generic.HashSet[int]]::new()
    $cursor = $ProcessId
    while ($processById.ContainsKey($cursor) -and $seen.Add($cursor)) {
        $cursor = [int]$processById[$cursor].ParentProcessId
        $depth++
    }
    $depthCache[$ProcessId] = $depth
    return $depth
}

$targets = @(
    $targetReasons.Keys |
        ForEach-Object {
            $processId = [int]$_
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                [pscustomobject]@{
                    ProcessId = $processId
                    Name      = $process.ProcessName
                    Depth     = Get-ProcessDepth -ProcessId $processId
                    Reasons   = [string]::Join('; ', $targetReasons[$processId])
                }
            }
        } |
        Sort-Object Depth -Descending
)

if ($targets.Count -eq 0) {
    if ($skippedEditorProcesses.Count -gt 0) {
        Write-Warning 'Project services are stopped, but an editor still references the project. Close it, or run stop.cmd --include-editors.'
        exit 3
    }
    Write-Host '[ok] No running GalReview processes were found. The project directory is released.' -ForegroundColor Green
    exit 0
}

foreach ($target in $targets) {
    if ($WhatIf) {
        Write-Host "[dry-run] Would stop $($target.Name) ($($target.ProcessId)): $($target.Reasons)" -ForegroundColor Yellow
        continue
    }

    try {
        Write-Host "[kill] $($target.Name) ($($target.ProcessId)): $($target.Reasons)"
        Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop
    }
    catch {
        if (Get-Process -Id $target.ProcessId -ErrorAction SilentlyContinue) {
            Write-Warning "Could not stop $($target.Name) ($($target.ProcessId)): $($_.Exception.Message)"
        }
    }
}

if ($WhatIf) {
    Write-Host '[dry-run] No processes were stopped.' -ForegroundColor Yellow
    exit 0
}

$deadline = [DateTime]::UtcNow.AddSeconds(5)
do {
    $remainingTargets = @(
        $targets | Where-Object { $null -ne (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue) }
    )
    if ($remainingTargets.Count -eq 0) {
        break
    }
    Start-Sleep -Milliseconds 200
} while ([DateTime]::UtcNow -lt $deadline)

$remainingListeners = @(Get-ProjectListeners -Ports $projectPorts)
if ($remainingTargets.Count -gt 0 -or $remainingListeners.Count -gt 0) {
    foreach ($remainingTarget in $remainingTargets) {
        Write-Warning "Process still running: $($remainingTarget.Name) ($($remainingTarget.ProcessId))"
    }
    foreach ($remainingListener in $remainingListeners) {
        Write-Warning "Port still listening: $($remainingListener.Port), PID $($remainingListener.ProcessId)"
    }
    Write-Error 'Some project resources are still in use. Run this script from an elevated terminal, or close the listed process manually.' -ErrorAction Continue
    exit 2
}

if ($skippedEditorProcesses.Count -gt 0) {
    Write-Warning 'Project services have stopped, but an editor still references the project. Close it, or run stop.cmd --include-editors before deleting the folder.'
    exit 3
}

Write-Host '[ok] GalReview services and child processes have stopped.' -ForegroundColor Green
Write-Host "[ok] Current directory is outside the project: $temporaryDirectory" -ForegroundColor Green
Write-Host '[ok] You can now close this window and delete the whole project folder.' -ForegroundColor Green
exit 0
