[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$MinimumPort = 5000,

    [ValidateRange(1, 65535)]
    [int]$MaximumPort = 5300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($MinimumPort -gt $MaximumPort) {
    throw 'MinimumPort cannot be greater than MaximumPort.'
}

$repositoryRoot = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to determine the Git repository root.'
}
$repositoryRoot = $repositoryRoot.Trim()

# The firewall policy applies only to the host/published side of Docker port
# mappings. Container targets, EXPOSE metadata, service URLs, connection
# strings, SMTP/proxy protocols and test listeners keep their native semantics.
$composePathRegex = [regex]::new(
    '(?i)(?:^|/)(?:compose(?:\.[^/]*)?\.ya?ml|docker-compose(?:\.[^/]*)?\.ya?ml)$')
$binaryExtensions = @(
    '.7z', '.a', '.avif', '.bin', '.bmp', '.class', '.dll', '.doc', '.docx',
    '.dylib', '.eot', '.exe', '.gif', '.gz', '.ico', '.jar', '.jpeg', '.jpg',
    '.lib', '.mp3', '.mp4', '.nupkg', '.otf', '.pdf', '.png', '.pdb', '.ppt',
    '.pptx', '.pyc', '.so', '.tar', '.ttc', '.ttf', '.wasm', '.webm', '.webp',
    '.woff', '.woff2', '.xls', '.xlsx', '.zip'
)

$variableValue = '\$\{[A-Za-z_][A-Za-z0-9_]*(?::-(?<default>\d{1,5}))?\}'
$publishedValue = "(?:$variableValue|\d{1,5})"
$bindAddress = '(?:\$\{[^}]+\}|(?:\d{1,3}\.){3}\d{1,3}|localhost|\[[0-9A-Fa-f:]+\])'
$shortMappingRegex = [regex]::new(
    "^(?:(?:$bindAddress):)?(?<published>$publishedValue):(?<target>\d{1,5})(?:/(?:tcp|udp))?$",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$inlineMappingRegex = [regex]::new(
    "(?<![A-Za-z0-9_])(?:(?:$bindAddress):)?(?<published>$publishedValue):(?<target>\d{1,5})(?:/(?:tcp|udp))?",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$hostPortSettingRegex = [regex]::new(
    '(?<![A-Za-z0-9_])(?<name>[A-Za-z_][A-Za-z0-9_]*_HOST_PORT)\s*(?:=|:)\s*["'']?(?<value>\d{1,5})\b',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$hostPortDefaultRegex = [regex]::new(
    '\$\{(?<name>[A-Za-z_][A-Za-z0-9_]*_HOST_PORT):-(?<value>\d{1,5})\}',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$dockerPublishRegex = [regex]::new(
    '(?i)(?:^|\s)(?:-p(?:=|\s+)|--publish(?:=|\s+))["'']?(?<mapping>[^\s"'']+)')
$portsHeaderRegex = [regex]::new('^(?<indent>\s*)ports\s*:', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$leadingWhitespaceRegex = [regex]::new('^(?<indent>\s*)')
$longPublishedRegex = [regex]::new(
    '^\s*(?:-\s*)?published\s*:\s*["'']?(?<published>[^\s"'']+)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$shortListRegex = [regex]::new('^\s*-\s*["'']?(?<mapping>[^"''#]+?)["'']?\s*(?:#.*)?$')

$violations = [System.Collections.Generic.List[object]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new()

function Add-Violation {
    param([string]$Path, [int]$Line, [int]$Port, [string]$Context, [string]$Match)
    if ($Port -ge $MinimumPort -and $Port -le $MaximumPort) { return }
    $key = "$Path`:$Line`:$Port"
    if (-not $seen.Add($key)) { return }
    $violations.Add([pscustomobject]@{
        File = $Path; Line = $Line; Port = $Port; Context = $Context; Match = $Match.Trim()
    })
}

function Test-PublishedValue {
    param([string]$Path, [int]$Line, [string]$Value, [string]$Context)
    $normalized = $Value.Trim().Trim('"', "'")
    if ($normalized -match '^\d{1,5}$') {
        Add-Violation $Path $Line ([int]$normalized) $Context $Value
        return
    }
    $fallback = [regex]::Match($normalized, '^\$\{[A-Za-z_][A-Za-z0-9_]*:-(?<port>\d{1,5})\}$')
    if ($fallback.Success) {
        Add-Violation $Path $Line ([int]$fallback.Groups['port'].Value) "$Context default" $Value
    }
}

$paths = @(& git -c core.quotepath=false -C $repositoryRoot ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate Git files.' }

foreach ($relativePath in $paths) {
    if ($binaryExtensions -contains [IO.Path]::GetExtension($relativePath).ToLowerInvariant()) { continue }
    $absolutePath = Join-Path $repositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) { continue }
    try { $lines = [IO.File]::ReadAllLines($absolutePath) }
    catch { throw "Unable to read '$relativePath': $($_.Exception.Message)" }

    $isCompose = $composePathRegex.IsMatch(($relativePath -replace '\\', '/'))
    $insidePorts = $false
    $portsIndent = -1

    for ($lineIndex = 0; $lineIndex -lt $lines.Length; $lineIndex++) {
        $line = $lines[$lineIndex]
        $lineNumber = $lineIndex + 1

        foreach ($match in $hostPortSettingRegex.Matches($line)) {
            Add-Violation $relativePath $lineNumber ([int]$match.Groups['value'].Value) `
                '*_HOST_PORT setting' $match.Value
        }
        foreach ($match in $hostPortDefaultRegex.Matches($line)) {
            Add-Violation $relativePath $lineNumber ([int]$match.Groups['value'].Value) `
                '*_HOST_PORT default' $match.Value
        }

        foreach ($publish in $dockerPublishRegex.Matches($line)) {
            $mapping = $publish.Groups['mapping'].Value.Trim().TrimEnd('"', "'", ';', ',')
            $parsed = $shortMappingRegex.Match($mapping)
            if ($parsed.Success) {
                Test-PublishedValue $relativePath $lineNumber $parsed.Groups['published'].Value `
                    'Docker published host port'
            }
        }

        if (-not $isCompose) { continue }

        $header = $portsHeaderRegex.Match($line)
        if ($header.Success) {
            $insidePorts = $true
            $portsIndent = $header.Groups['indent'].Value.Length
            foreach ($parsed in $inlineMappingRegex.Matches($line)) {
                Test-PublishedValue $relativePath $lineNumber $parsed.Groups['published'].Value `
                    'Compose published host port'
            }
            continue
        }

        if ($insidePorts -and $line -notmatch '^\s*(?:#.*)?$') {
            $currentIndent = $leadingWhitespaceRegex.Match($line).Groups['indent'].Value.Length
            if ($currentIndent -le $portsIndent) { $insidePorts = $false }
        }
        if (-not $insidePorts) { continue }

        $long = $longPublishedRegex.Match($line)
        if ($long.Success) {
            Test-PublishedValue $relativePath $lineNumber $long.Groups['published'].Value `
                'Compose published host port'
            continue
        }

        $item = $shortListRegex.Match($line)
        if ($item.Success) {
            $parsed = $shortMappingRegex.Match($item.Groups['mapping'].Value.Trim())
            if ($parsed.Success) {
                Test-PublishedValue $relativePath $lineNumber $parsed.Groups['published'].Value `
                    'Compose published host port'
            }
        }
    }
}

if ($violations.Count -gt 0) {
    foreach ($violation in ($violations | Sort-Object File, Line, Port, Context)) {
        Write-Host ('{0}:{1}: published host port {2} [{3}] {4}' -f
            $violation.File, $violation.Line, $violation.Port, $violation.Context, $violation.Match)
    }
    throw "Found $($violations.Count) published host port values outside $MinimumPort-$MaximumPort."
}

Write-Host "Published host port policy passed: defaults and mappings stay within $MinimumPort-$MaximumPort."
