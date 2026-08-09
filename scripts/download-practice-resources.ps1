[CmdletBinding()]
param(
    [string]$DestinationPath,
    [string]$Endpoint = 'https://fgws3-ocloud.ihep.ac.cn',
    [string]$Bucket = '20277-gal-res',
    [string]$RemotePrefix = '',
    [string]$Region = 'us-east-1',
    [string]$ManifestPath,
    [switch]$SkipHashVerification,
    [switch]$SkipAwsCliInstall
)

# Repository-distributed credential restricted to read/list access for 20277-gal-res.
# It cannot access other buckets or prefixes and cannot create, replace, or delete objects.
$oscaAccessKeyId = 'ZMVBNId4c52092lL53Jg'
$oscaSecretAccessKey = 'upDcWNLGKlhe2qVSKOYG'

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    $DestinationPath = Join-Path $projectRoot 'backend/PracticeService/Resources'
}
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $projectRoot 'backend/PracticeService/resources.manifest.json'
}

$endpointUri = $null
if (-not [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$endpointUri) -or
    $endpointUri.Scheme -ne [Uri]::UriSchemeHttps) {
    throw 'Endpoint must be an absolute HTTPS URL.'
}
if ($Bucket -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$') {
    throw 'Bucket name is invalid.'
}

$normalizedPrefix = $RemotePrefix.Trim().Trim('/')
if (($normalizedPrefix -split '/' | Where-Object { $_ -in @('.', '..') }).Count -gt 0) {
    throw 'RemotePrefix cannot contain dot path segments.'
}
$prefixWithSlash = if ($normalizedPrefix) { "$normalizedPrefix/" } else { '' }

function Resolve-AwsCliV2 {
    $command = Get-Command aws.exe -ErrorAction SilentlyContinue
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Amazon\AWSCLIV2\aws.exe'),
        (Join-Path $env:ProgramFiles 'Amazon\AWSCLIV2\aws.exe'),
        $(if ($command) { $command.Source })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $versionOutput = & $candidate --version 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -and $versionOutput -match 'aws-cli/2(?:\.|\s)') {
                return [IO.Path]::GetFullPath($candidate)
            }
        }
        catch {
        }
    }

    return $null
}

function Install-AwsCliV2ForCurrentUser {
    $installerUri = 'https://awscli.amazonaws.com/AWSCLIV2-User.msi'
    $installerPath = Join-Path ([IO.Path]::GetTempPath()) ("AWSCLIV2-User-{0}.msi" -f [Guid]::NewGuid().ToString('N'))
    $previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol

    try {
        Write-Host 'AWS CLI v2 was not found. Downloading the official current-user installer...'
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $installerUri -OutFile $installerPath -UseBasicParsing

        $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
        $signerSubject = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
        if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
            $signerSubject -notmatch 'Amazon(?: Web Services|\.com)') {
            throw "The downloaded AWS CLI installer did not have a valid Amazon signature (status: $($signature.Status))."
        }

        Write-Host 'Installing AWS CLI v2 for the current Windows user...'
        $installerArguments = @('/i', "`"$installerPath`"", '/passive', '/norestart')
        $installerProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $installerArguments -Wait -PassThru
        if ($installerProcess.ExitCode -notin @(0, 3010)) {
            throw "AWS CLI installer failed with exit code $($installerProcess.ExitCode)."
        }
        if ($installerProcess.ExitCode -eq 3010) {
            Write-Warning 'AWS CLI installation requested a Windows restart. This script will still try the installed executable now.'
        }
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$awsExecutable = Resolve-AwsCliV2
if ([string]::IsNullOrWhiteSpace($awsExecutable)) {
    if ($SkipAwsCliInstall) {
        throw 'AWS CLI v2 was not found and automatic installation was disabled by -SkipAwsCliInstall.'
    }

    Install-AwsCliV2ForCurrentUser
    $awsExecutable = Resolve-AwsCliV2
    if ([string]::IsNullOrWhiteSpace($awsExecutable)) {
        throw 'AWS CLI v2 installation completed, but aws.exe could not be located. Close this window, reopen it, and run the download script again.'
    }
}

Write-Host "Using AWS CLI v2: $awsExecutable"

$accessKey = $oscaAccessKeyId
$secretKey = $oscaSecretAccessKey
if ([string]::IsNullOrWhiteSpace($accessKey) -or [string]::IsNullOrWhiteSpace($secretKey)) {
    throw 'The owner-distributed OSCA credentials are missing from the top of this script.'
}

$destinationRoot = [IO.Path]::GetFullPath($DestinationPath)
$separatorCharacters = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$destinationPrefix = $destinationRoot.TrimEnd($separatorCharacters) + [IO.Path]::DirectorySeparatorChar
$manifestFullPath = [IO.Path]::GetFullPath($ManifestPath)
$temporaryConfig = Join-Path ([IO.Path]::GetTempPath()) ("qzwl-osca-aws-{0}.ini" -f [Guid]::NewGuid().ToString('N'))
$environmentNames = @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_DEFAULT_REGION', 'AWS_CONFIG_FILE', 'AWS_EC2_METADATA_DISABLED')
$previousEnvironment = @{}
foreach ($name in $environmentNames) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
}

function Protect-CommandError([string]$message) {
    if (-not [string]::IsNullOrEmpty($script:accessKey)) { $message = $message.Replace($script:accessKey, '[REDACTED]') }
    if (-not [string]::IsNullOrEmpty($script:secretKey)) { $message = $message.Replace($script:secretKey, '[REDACTED]') }
    return $message
}

function ConvertTo-NativeCommandLineArgument([AllowEmptyString()][string]$Argument) {
    if ([string]::IsNullOrEmpty($Argument)) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    # Quote according to the Windows CommandLineToArgvW escaping rules. This is
    # required for Windows PowerShell 5.1, where ProcessStartInfo.ArgumentList
    # is not available yet.
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashCount * 2) + 1)))
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-OsCaAws([string[]]$Arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:awsExecutable
    $startInfo.Arguments = (($Arguments | ForEach-Object {
        ConvertTo-NativeCommandLineArgument ([string]$_)
    }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'The AWS CLI process did not start.' }
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    catch {
        throw (Protect-CommandError "Unable to run AWS CLI: $($_.Exception.Message)")
    }
    finally {
        $process.Dispose()
    }

    if ($exitCode -ne 0) {
        $details = @($standardError.Trim(), $standardOutput.Trim()) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $detailText = if ($details.Count -gt 0) {
            $details -join [Environment]::NewLine
        } else {
            'AWS CLI returned no diagnostic output.'
        }
        throw (Protect-CommandError "OSCA S3 request failed with exit code ${exitCode}: $detailText")
    }

    if (-not [string]::IsNullOrWhiteSpace($standardError)) {
        Write-Warning (Protect-CommandError $standardError.Trim())
    }
    return $standardOutput
}

function Resolve-SafeResourcePath([string]$relativePath) {
    if ([string]::IsNullOrWhiteSpace($relativePath)) { throw 'An empty object path was returned.' }
    $segments = $relativePath -split '/'
    $invalidCharacters = [IO.Path]::GetInvalidFileNameChars()
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..') -or $segment.IndexOfAny($invalidCharacters) -ge 0) {
            throw "Unsafe object path returned by OSCA: $relativePath"
        }
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $destinationRoot ($segments -join [IO.Path]::DirectorySeparatorChar)))
    if (-not $candidate.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Object path escapes the destination directory: $relativePath"
    }
    return $candidate
}

try {
    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    $awsConfigContent = @"
[default]
region = $Region
output = json
s3 =
    addressing_style = path
    signature_version = s3v4
"@
    # UTF8Encoding(false) works in both Windows PowerShell 5.1 and PowerShell
    # 7, while Set-Content -Encoding utf8NoBOM is unavailable in 5.1.
    $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($temporaryConfig, $awsConfigContent, $utf8WithoutBom)

    [Environment]::SetEnvironmentVariable('AWS_ACCESS_KEY_ID', $accessKey, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('AWS_SECRET_ACCESS_KEY', $secretKey, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('AWS_DEFAULT_REGION', $Region, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('AWS_CONFIG_FILE', $temporaryConfig, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('AWS_EC2_METADATA_DISABLED', 'true', [EnvironmentVariableTarget]::Process)

    $listArguments = @(
        '--endpoint-url', $endpointUri.AbsoluteUri.TrimEnd('/'),
        '--region', $Region,
        's3api', 'list-objects-v2',
        '--bucket', $Bucket,
        '--output', 'json'
    )
    if ($prefixWithSlash) { $listArguments += @('--prefix', $prefixWithSlash) }
    $listing = Invoke-OsCaAws $listArguments | ConvertFrom-Json
    $objects = @($listing.Contents | Where-Object { $_.Key -and -not $_.Key.EndsWith('/') })
    if ($objects.Count -eq 0) { throw "No resource objects were found in bucket '$Bucket' with prefix '$prefixWithSlash'." }

    foreach ($object in $objects) {
        $key = [string]$object.Key
        if ($prefixWithSlash -and -not $key.StartsWith($prefixWithSlash, [StringComparison]::Ordinal)) {
            throw "OSCA returned an object outside the requested prefix: $key"
        }
        $relativeKey = if ($prefixWithSlash) { $key.Substring($prefixWithSlash.Length) } else { $key }
        [void](Resolve-SafeResourcePath $relativeKey)
    }

    $remoteUri = "s3://$Bucket/$prefixWithSlash"
    $syncArguments = @(
        '--endpoint-url', $endpointUri.AbsoluteUri.TrimEnd('/'),
        '--region', $Region,
        's3', 'sync',
        $remoteUri, $destinationRoot,
        '--no-progress',
        '--only-show-errors'
    )
    [void](Invoke-OsCaAws $syncArguments)

    if (-not $SkipHashVerification) {
        if (-not (Test-Path -LiteralPath $manifestFullPath -PathType Leaf)) {
            throw "Resource manifest was not found: $manifestFullPath"
        }
        $manifest = Get-Content -LiteralPath $manifestFullPath -Raw | ConvertFrom-Json
        if ($manifest.schemaVersion -ne 'qzwl-practice-resources-1') { throw 'Unsupported resource manifest version.' }
        if ($manifest.bucket -ne $Bucket) { throw "Manifest bucket '$($manifest.bucket)' does not match '$Bucket'." }
        foreach ($file in $manifest.files) {
            $localPath = Resolve-SafeResourcePath ([string]$file.path)
            if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) { throw "Required resource is missing: $($file.path)" }
            $item = Get-Item -LiteralPath $localPath
            if ($item.Length -ne [long]$file.size) { throw "Resource size mismatch: $($file.path)" }
            $actualHash = (Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -ne ([string]$file.sha256).ToLowerInvariant()) { throw "Resource hash mismatch: $($file.path)" }
        }
    }

    Write-Host "PracticeService resources are ready in $destinationRoot"
    Write-Host "Downloaded object count: $($objects.Count); manifest verification: $(if ($SkipHashVerification) { 'skipped' } else { 'passed' })"
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], [EnvironmentVariableTarget]::Process)
    }
    if (Test-Path -LiteralPath $temporaryConfig) { Remove-Item -LiteralPath $temporaryConfig -Force }
    $secretKey = $null
    $oscaSecretAccessKey = $null
}
