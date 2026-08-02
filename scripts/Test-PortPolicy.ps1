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

$binaryExtensions = @(
    '.7z', '.a', '.avif', '.bin', '.bmp', '.class', '.dll', '.doc', '.docx',
    '.dylib', '.eot', '.exe', '.gif', '.gz', '.ico', '.jar', '.jpeg', '.jpg',
    '.lib', '.mp3', '.mp4', '.nupkg', '.otf', '.pdf', '.png', '.pdb', '.pyc',
    '.so', '.tar', '.ttc', '.ttf', '.wasm', '.webm', '.webp', '.woff', '.woff2',
    '.xls', '.xlsx', '.zip'
)

$portName = '(?:(?i:ports?)|[A-Z][A-Z0-9_]*_PORTS?|[a-z][a-z0-9_]*_ports?|[A-Za-z][A-Za-z0-9]*(?:Port|Ports))'
$portsName = '(?:(?i:ports)|[A-Z][A-Z0-9_]*_PORTS|[a-z][a-z0-9_]*_ports|[A-Za-z][A-Za-z0-9]*Ports)'
$composePath = '(?i)(?:^|/)(?:compose(?:\.[^/]*)?\.ya?ml|docker-compose(?:\.[^/]*)?\.ya?ml)$'
$prosePath = '(?i)\.(?:md|mdx|rst|txt)$'

$patterns = @(
    # A URI port must be followed by a URI delimiter; numeric passwords are not ports.
    @{ Name = 'URI'; Expression = '(?i)\b[a-z][a-z0-9+.-]*://[^\s"''`<>]*?:(?<port>\d{1,5})(?=[/\s"''`<>,;)?#\]}]|$)' },

    # Common Port= connection strings and SQL Server's Server=host,port form.
    @{ Name = 'connection string'; Expression = '(?i)(?:^|[;,\s"''`])Port\s*=\s*["'']?(?<port>\d{1,5})\b' },
    @{ Name = 'SQL Server connection string'; Expression = '(?i)\b(?:Server|Data\s+Source)\s*=\s*[^;,\r\n]+,(?<port>\d{1,5})(?=;|\s|$)' },

    # Variables, JSON/YAML properties, and typed declarations such as port: number = 5200.
    @{ Name = 'port list setting'; Expression = ('(?<![A-Za-z0-9_])["'']?{0}["'']?\s*(?:=|:)\s*["'']?(?:(?<port>\d{{1,5}})\s*[;,]\s*)+(?<port>\d{{1,5}})\b' -f $portsName) },
    @{ Name = 'port setting'; Expression = ('(?<![A-Za-z0-9_])["'']?{0}["'']?\s*(?:(?:=)\s*|:\s*(?:[A-Za-z_][A-Za-z0-9_.<>\[\]?]*\s*=\s*)?)["'']?(?<port>\d{{1,5}})\b' -f $portName) },
    # Shell/Compose defaults, null fallbacks, and configuration-reader defaults.
    @{ Name = 'port default'; Expression = ('(?<![A-Za-z0-9_]){0}\s*:-\s*["'']?(?<port>\d{{1,5}})\b' -f $portName) },
    @{ Name = 'port fallback'; Expression = ('(?<![A-Za-z0-9_]){0}["'']?(?:\]|\))?\s*(?:\|\||\?\?|\bor\b)\s*["'']?(?<port>\d{{1,5}})\b' -f $portName) },
    @{ Name = 'port reader default'; Expression = ('["'']{0}["'']\s*,\s*["'']?(?<port>\d{{1,5}})\b' -f $portName) },

    # Repeated captures preserve every port declared by one EXPOSE instruction.
    @{ Name = 'Docker expose'; Expression = '(?i)\bEXPOSE\s+(?:(?<port>\d{1,5})(?:/(?:tcp|udp))?\s*)+' },
    @{ Name = 'CLI port'; Expression = '(?i)(?:--(?:[a-z0-9]+-)*port|-(?:Local|Remote)?Port)\s*(?:=|\s)\s*["'']?(?<port>\d{1,5})\b' },
    @{ Name = 'listen call'; Expression = '(?i)\b(?:listen|listenAnyIP|listenLocalhost|htons)\s*\(\s*["'']?(?<port>\d{1,5})\b' },
    @{ Name = 'listen address'; Expression = '(?i)\b(?:[a-z0-9_.-]*listen[_-]*address|[a-z0-9_.-]*advertised[_-]*address)["'']?\s*(?:=|:)\s*["'']?(?:\[[^\]]+\]|[^:\s"'']*)?:(?<port>\d{1,5})\b' },
    @{ Name = 'endpoint shorthand'; PathExpression = $prosePath; Expression = '(?<![A-Za-z0-9_.:-]):(?<port>\d{4,5})(?![\d.])' },
    @{ Name = 'port narration'; Expression = '(?i)(?:(?:\b(?:listen(?:s|ing)?|bind(?:s|ing)?|expose[sd]?|ports?)\b)|(?:\u76D1\u542C|\u66B4\u9732|\u7AEF\u53E3))\s*(?:(?:on|at|to)|(?:\u4E8E|\u5728|\u4E3A|\u5230))?\s*[=:\uFF1A`"'']*\s*(?<port>\d{2,5})(?![\d.])' },
    @{ Name = 'port narration'; Expression = '(?i)(?<port>\d{2,5})(?![\d.])\s*[`"'']*\s*(?:ports?\b|\u7AEF\u53E3)' },

    # Parse short mappings only inside a Compose ports block, not arbitrary YAML number pairs.
    @{ Name = 'Compose host mapping'; PathExpression = $composePath; RequiresComposePorts = $true; Expression = '^\s*-\s*["'']?(?:(?:\$\{[^}]+\}|(?:\d{1,3}\.){3}\d{1,3}|localhost|\[[0-9a-f:]+\]):)?(?<port>\d{1,5}):\d{1,5}(?:/(?:tcp|udp))?["'']?(?:\s*#.*)?$' },
    @{ Name = 'Compose container mapping'; PathExpression = $composePath; RequiresComposePorts = $true; Expression = '^\s*-\s*["'']?.*:(?<port>\d{1,5})(?:/(?:tcp|udp))?["'']?(?:\s*#.*)?$' },
    @{ Name = 'Compose single-port mapping'; PathExpression = $composePath; RequiresComposePorts = $true; Expression = '^\s*-\s*["'']?(?<port>\d{1,5})(?:/(?:tcp|udp))?["'']?(?:\s*#.*)?$' },
    @{ Name = 'Compose long mapping'; PathExpression = $composePath; RequiresComposePorts = $true; Expression = '^\s*(?:-\s*)?(?:target|published)\s*:\s*["'']?(?<port>\d{1,5})\b' },
    @{ Name = 'Compose inline host mapping'; PathExpression = $composePath; RequiresComposePorts = $true; Expression = '^\s*ports\s*:\s*\[[^\]]*?["'']?(?<port>\d{1,5}):\d{1,5}\b' },
    @{ Name = 'Compose inline container mapping'; PathExpression = $composePath; RequiresComposePorts = $true; Expression = '^\s*ports\s*:\s*\[[^\]]*?["'']?\d{1,5}:(?<port>\d{1,5})\b' },

    # docker run/create publish arguments may also appear in README files and scripts.
    @{ Name = 'Docker publish host'; Expression = '(?i)(?:^|\s)(?:-p|--publish)(?:=|\s+)["'']?(?:(?:\$\{[^}]+\}|(?:\d{1,3}\.){3}\d{1,3}|localhost|\[[0-9a-f:]+\]):)?(?<port>\d{1,5}):\d{1,5}\b' },
    @{ Name = 'Docker publish container'; Expression = '(?i)(?:^|\s)(?:-p|--publish)(?:=|\s+)["'']?(?:(?:\$\{[^}]+\}|(?:\d{1,3}\.){3}\d{1,3}|localhost|\[[0-9a-f:]+\]):)?(?:\d{1,5}|\$\{[^}]+\}):(?<port>\d{1,5})\b' }
)

$regexOptions = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
$regexTimeout = [TimeSpan]::FromSeconds(2)
foreach ($pattern in $patterns) {
    $pattern['Regex'] = [regex]::new($pattern.Expression, $regexOptions, $regexTimeout)
    if ($pattern.ContainsKey('PathExpression')) {
        $pattern['PathRegex'] = [regex]::new($pattern.PathExpression, $regexOptions, $regexTimeout)
    }
}
$markdownRowRegex = [regex]::new('^\s*\|', $regexOptions, $regexTimeout)
$markdownSeparatorRegex = [regex]::new(
    '^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$',
    $regexOptions,
    $regexTimeout
)
$markdownPortHeaderRegex = [regex]::new(
    '(?i)\bports?\b|\u7AEF\u53E3|\u76D1\u542C|\u66B4\u9732',
    $regexOptions,
    $regexTimeout
)
$markdownNumberRegex = [regex]::new('(?<!\d)(?<port>\d{1,5})(?!\d)', $regexOptions, $regexTimeout)
$composeFileRegex = [regex]::new($composePath, $regexOptions, $regexTimeout)
$composePortsHeaderRegex = [regex]::new('^(?<indent>\s*)ports\s*:', $regexOptions, $regexTimeout)
$leadingWhitespaceRegex = [regex]::new('^(?<indent>\s*)', $regexOptions, $regexTimeout)

$repositoryRoot = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to determine the Git repository root.'
}
$repositoryRoot = $repositoryRoot.Trim()

# Scan tracked and unignored new files; ignored build outputs and artifacts are excluded.
$paths = @(& git -c core.quotepath=false -C $repositoryRoot ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to enumerate Git files.'
}

$violations = [System.Collections.Generic.List[object]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new()

function Add-PortViolation {
    param(
        [string]$RelativePath,
        [int]$LineNumber,
        [int]$Port,
        [string]$Context,
        [string]$MatchedText
    )

    if ($Port -in 3306, 27017 -or ($Port -ge $MinimumPort -and $Port -le $MaximumPort)) {
        return
    }

    $key = '{0}:{1}:{2}' -f $RelativePath, $LineNumber, $Port
    if (-not $seen.Add($key)) {
        return
    }

    $safeMatch = $MatchedText.Trim()
    $safeMatch = $safeMatch -replace '(?i)(://)[^/@\s]+@', '$1<credentials>@'
    $violations.Add([pscustomobject]@{
        File = $RelativePath
        Line = $LineNumber
        Port = $Port
        Context = $Context
        Match = $safeMatch
    })
}

foreach ($relativePath in $paths) {
    $extension = [System.IO.Path]::GetExtension($relativePath).ToLowerInvariant()
    if ($binaryExtensions -contains $extension) {
        continue
    }

    $absolutePath = Join-Path $repositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
        continue
    }

    try {
        $lines = [System.IO.File]::ReadAllLines($absolutePath)
    }
    catch {
        throw "Unable to read '$relativePath': $($_.Exception.Message)"
    }

    $markdownPortColumns = @()
    $isComposeFile = $composeFileRegex.IsMatch($relativePath)
    $composePortsIndent = -1
    $insideComposePorts = $false
    for ($lineIndex = 0; $lineIndex -lt $lines.Length; $lineIndex++) {
        $line = $lines[$lineIndex]

        if ($isComposeFile) {
            $portsHeaderMatch = $composePortsHeaderRegex.Match($line)
            if ($portsHeaderMatch.Success) {
                $composePortsIndent = $portsHeaderMatch.Groups['indent'].Value.Length
                $insideComposePorts = $true
            }
            elseif ($insideComposePorts -and $line -notmatch '^\s*(?:#.*)?$') {
                $currentIndent = $leadingWhitespaceRegex.Match($line).Groups['indent'].Value.Length
                if ($currentIndent -le $composePortsIndent) {
                    $insideComposePorts = $false
                }
            }
        }

        # Markdown tables carry port semantics in the header, while data rows may contain only numbers.
        if ($markdownRowRegex.IsMatch($line)) {
            $isSeparator = $markdownSeparatorRegex.IsMatch($line)
            $hasSeparatorNext = $lineIndex + 1 -lt $lines.Length -and
                $markdownSeparatorRegex.IsMatch($lines[$lineIndex + 1])

            $tableCells = @(($line.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() })
            if ($hasSeparatorNext) {
                $markdownPortColumns = @()
                for ($columnIndex = 0; $columnIndex -lt $tableCells.Count; $columnIndex++) {
                    if ($markdownPortHeaderRegex.IsMatch($tableCells[$columnIndex])) {
                        $markdownPortColumns += $columnIndex
                    }
                }
            }
            elseif (-not $isSeparator -and $markdownPortColumns.Count -gt 0) {
                foreach ($columnIndex in $markdownPortColumns) {
                    if ($columnIndex -ge $tableCells.Count) {
                        continue
                    }
                    foreach ($portMatch in $markdownNumberRegex.Matches($tableCells[$columnIndex])) {
                        Add-PortViolation -RelativePath $relativePath -LineNumber ($lineIndex + 1) `
                            -Port ([int]$portMatch.Groups['port'].Value) -Context 'Markdown port column' `
                            -MatchedText $tableCells[$columnIndex]
                    }
                }
            }
        }
        else {
            $markdownPortColumns = @()
        }

        foreach ($pattern in $patterns) {
            if ($pattern.ContainsKey('PathRegex') -and -not $pattern.PathRegex.IsMatch($relativePath)) {
                continue
            }
            if ($pattern.ContainsKey('RequiresComposePorts') -and -not $insideComposePorts) {
                continue
            }

            foreach ($match in $pattern.Regex.Matches($line)) {
                foreach ($portCapture in $match.Groups['port'].Captures) {
                    Add-PortViolation -RelativePath $relativePath -LineNumber ($lineIndex + 1) `
                        -Port ([int]$portCapture.Value) -Context $pattern.Name -MatchedText $match.Value
                }
            }
        }
    }
}

if ($violations.Count -gt 0) {
    foreach ($violation in ($violations | Sort-Object File, Line, Port)) {
        Write-Host ('{0}:{1}: port {2} [{3}] {4}' -f $violation.File, $violation.Line,
            $violation.Port, $violation.Context, $violation.Match)
    }
    throw "Found $($violations.Count) explicit port values outside $MinimumPort-$MaximumPort."
}

Write-Host "Port policy passed: all explicit project ports are within $MinimumPort-$MaximumPort."
