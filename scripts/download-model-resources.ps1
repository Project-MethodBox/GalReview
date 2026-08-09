[CmdletBinding()]
param(
    [string]$DestinationPath,
    [string]$Endpoint = 'https://fgws3-ocloud.ihep.ac.cn',
    [string]$Bucket = '20277-gal-res',
    [string]$RemotePrefix = '',
    [string]$Region = 'us-east-1',
    [string]$ManifestPath,
    [string]$FallbackSourcePath,
    [switch]$SkipHashVerification,
    [switch]$SkipAwsCliInstall
)

# Credentials must be provided via environment variables.
# The OSCA S3 credentials are intentionally NOT stored in this repository.
# Set OSCA_ACCESS_KEY_ID and OSCA_SECRET_ACCESS_KEY before running this script.
$oscaAccessKeyId = $env:OSCA_ACCESS_KEY_ID
$oscaSecretAccessKey = $env:OSCA_SECRET_ACCESS_KEY
$pinnedNliRevision = '0a71e92a985b6e1ad1828cf67ce9c459639c1dca'
$pinnedNliSourcePathPrefix = "/MoritzLaurer/multilingual-MiniLMv2-L6-mnli-xnli/resolve/$pinnedNliRevision/"
$pinnedReciteHelperRevision = '21288821229eb8a1da7f5a38d248fdfd10104f80'
$pinnedReciteHelperSourcePathPrefix = "/ArabidopsisDev/ReciteHelper/$pinnedReciteHelperRevision/ReciteHelper.Wpf/Resources/"
$pinnedVocabRevision = '7f0fefb68e92311d297c558a35a2a72557031d41'
$pinnedVocabSourcePath = "/ArabidopsisDev/ReciteHelper/$pinnedVocabRevision/src/Resources/vocab.txt"

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    $DestinationPath = Join-Path $projectRoot 'backend/ModelService/Resources'
}
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $projectRoot 'backend/ModelService/resources.manifest.json'
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

$accessKey = $oscaAccessKeyId
$secretKey = $oscaSecretAccessKey
$awsExecutable = $null

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

function Test-PinnedResource([string]$path, [long]$size, [string]$sha256) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -ne $size) { return $false }
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $actualHash -eq $sha256.ToLowerInvariant()
}

function Assert-PinnedFallbackSource([object]$file) {
    $sourceUri = $null
    if (-not [Uri]::TryCreate([string]$file.fallbackUrl, [UriKind]::Absolute, [ref]$sourceUri) -or
        $sourceUri.Scheme -ne [Uri]::UriSchemeHttps) {
        throw "Fallback resource URL is not an allowed pinned HTTPS source: $($file.path)"
    }

    $isPinnedNli = $sourceUri.Host -eq 'huggingface.co' -and
        $sourceUri.AbsolutePath.StartsWith($script:pinnedNliSourcePathPrefix, [StringComparison]::Ordinal)
    $isPinnedReciteHelper = $sourceUri.Host -eq 'raw.githubusercontent.com' -and
        ($sourceUri.AbsolutePath.StartsWith($script:pinnedReciteHelperSourcePathPrefix, [StringComparison]::Ordinal) -or
         $sourceUri.AbsolutePath.Equals($script:pinnedVocabSourcePath, [StringComparison]::Ordinal))
    if (-not $isPinnedNli -and -not $isPinnedReciteHelper) {
        throw "Fallback resource URL is outside the pinned source allow-list: $($file.path)"
    }

    $transform = [string]$file.fallbackTransform
    if (-not [string]::IsNullOrWhiteSpace($transform) -and $transform -ne 'lfToCrlf') {
        throw "Unsupported fallback transform '$transform' for $($file.path)."
    }
    return $sourceUri
}

function Convert-LfToCrlf([string]$path) {
    $inputBytes = [IO.File]::ReadAllBytes($path)
    $output = [IO.MemoryStream]::new($inputBytes.Length + 4096)
    try {
        for ($index = 0; $index -lt $inputBytes.Length; $index++) {
            if ($inputBytes[$index] -eq 10 -and ($index -eq 0 -or $inputBytes[$index - 1] -ne 13)) {
                $output.WriteByte(13)
            }
            $output.WriteByte($inputBytes[$index])
        }
        [IO.File]::WriteAllBytes($path, $output.ToArray())
    }
    finally {
        $output.Dispose()
    }
}

function Save-PinnedFallback([object]$file) {
    $sourceUri = Assert-PinnedFallbackSource $file
    $localPath = Resolve-SafeResourcePath ([string]$file.path)
    if (Test-PinnedResource $localPath ([long]$file.size) ([string]$file.sha256)) { return $false }
    $parent = Split-Path -Parent $localPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $temporaryDownload = "$localPath.partial-$([Guid]::NewGuid().ToString('N'))"
        try {
            Write-Host "Downloading pinned fallback $($file.path) (attempt $attempt/3)..."
            $previousProgressPreference = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $sourceUri.AbsoluteUri -OutFile $temporaryDownload -UseBasicParsing
            }
            finally {
                $ProgressPreference = $previousProgressPreference
            }
            if ([string]$file.fallbackTransform -eq 'lfToCrlf') {
                Convert-LfToCrlf $temporaryDownload
            }
            if (-not (Test-PinnedResource $temporaryDownload ([long]$file.size) ([string]$file.sha256))) {
                throw "Downloaded fallback resource failed size or SHA-256 verification: $($file.path)"
            }
            Move-Item -LiteralPath $temporaryDownload -Destination $localPath -Force
            return $true
        }
        catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds 2
        }
        finally {
            if (Test-Path -LiteralPath $temporaryDownload) {
                Remove-Item -LiteralPath $temporaryDownload -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-InvalidPinnedFiles([object[]]$files) {
    return @($files | Where-Object {
        $path = Resolve-SafeResourcePath ([string]$_.path)
        -not (Test-PinnedResource $path ([long]$_.size) ([string]$_.sha256))
    })
}

function Copy-PinnedOfflineFallback([object]$file, [string]$sourceRoot) {
    $root = [IO.Path]::GetFullPath($sourceRoot)
    $rootPrefix = $root.TrimEnd($separatorCharacters) + [IO.Path]::DirectorySeparatorChar
    $segments = ([string]$file.path) -split '/'
    $sourcePath = [IO.Path]::GetFullPath((Join-Path $root ($segments -join [IO.Path]::DirectorySeparatorChar)))
    if (-not $sourcePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Offline fallback path escapes its root: $($file.path)"
    }
    if (-not (Test-PinnedResource $sourcePath ([long]$file.size) ([string]$file.sha256))) { return $false }

    $localPath = Resolve-SafeResourcePath ([string]$file.path)
    $parent = Split-Path -Parent $localPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporaryCopy = "$localPath.partial-$([Guid]::NewGuid().ToString('N'))"
    try {
        Copy-Item -LiteralPath $sourcePath -Destination $temporaryCopy -Force
        if (-not (Test-PinnedResource $temporaryCopy ([long]$file.size) ([string]$file.sha256))) {
            throw "Offline fallback changed during copy: $($file.path)"
        }
        Move-Item -LiteralPath $temporaryCopy -Destination $localPath -Force
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $temporaryCopy) {
            Remove-Item -LiteralPath $temporaryCopy -Force -ErrorAction SilentlyContinue
        }
    }
}

New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $manifestFullPath -PathType Leaf)) {
    throw "Resource manifest was not found: $manifestFullPath"
}
$manifest = Get-Content -LiteralPath $manifestFullPath -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 'qzwl-model-resources-1') { throw 'Unsupported resource manifest version.' }
if ($manifest.bucket -ne $Bucket) { throw "Manifest bucket '$($manifest.bucket)' does not match '$Bucket'." }
$files = @($manifest.files)
if ($files.Count -eq 0) { throw 'The resource manifest is empty.' }
foreach ($file in $files) {
    if ([string]::IsNullOrWhiteSpace([string]$file.fallbackUrl)) {
        throw "Resource has no disaster-recovery URL: $($file.path)"
    }
    [void](Assert-PinnedFallbackSource $file)
}
if ($SkipHashVerification) {
    Write-Warning '-SkipHashVerification is retained for command compatibility but ignored; disaster recovery always verifies every pinned file.'
}

$initialInvalidFiles = @(Get-InvalidPinnedFiles $files)
if ($initialInvalidFiles.Count -eq 0) {
    Write-Host "ModelService resources are already ready in $destinationRoot"
    Write-Host "Verified local cache: $($files.Count)/$($files.Count); OSCA and fallback sources were not contacted."
    return
}

$remoteRelativeKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$oscaObjectCount = 0
$oscaSucceeded = $false
$oscaFailure = $null

if ([string]::IsNullOrWhiteSpace($accessKey) -or [string]::IsNullOrWhiteSpace($secretKey)) {
    $oscaFailure = 'OSCA credentials are absent.'
    Write-Warning "$oscaFailure Continuing with pinned disaster-recovery sources."
}
else {
    try {
        $awsExecutable = Resolve-AwsCliV2
        if ([string]::IsNullOrWhiteSpace($awsExecutable) -and -not $SkipAwsCliInstall) {
            Install-AwsCliV2ForCurrentUser
            $awsExecutable = Resolve-AwsCliV2
        }
        if ([string]::IsNullOrWhiteSpace($awsExecutable)) {
            throw 'AWS CLI v2 is unavailable.'
        }
        Write-Host "Using AWS CLI v2 for the OSCA primary mirror: $awsExecutable"

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
            [void]$remoteRelativeKeys.Add($relativeKey.Replace('\', '/'))
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
        $oscaObjectCount = $objects.Count
        $oscaSucceeded = $true
    }
    catch {
        $oscaFailure = Protect-CommandError $_.Exception.Message
        Write-Warning "OSCA primary mirror failed: $oscaFailure Continuing with pinned disaster-recovery sources."
    }
    finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], [EnvironmentVariableTarget]::Process)
        }
        if (Test-Path -LiteralPath $temporaryConfig) { Remove-Item -LiteralPath $temporaryConfig -Force }
    }
}

$offlineCopyCount = 0
$invalidFiles = @(Get-InvalidPinnedFiles $files)
if ($invalidFiles.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($FallbackSourcePath)) {
    if (Test-Path -LiteralPath $FallbackSourcePath -PathType Container) {
        foreach ($file in $invalidFiles) {
            if (Copy-PinnedOfflineFallback $file $FallbackSourcePath) { $offlineCopyCount++ }
        }
    }
    else {
        Write-Warning "Offline fallback directory does not exist: $FallbackSourcePath"
    }
}

$fallbackDownloadCount = 0
$fallbackFailures = [Collections.Generic.List[string]]::new()
$invalidFiles = @(Get-InvalidPinnedFiles $files)
foreach ($file in $invalidFiles) {
    try {
        if (Save-PinnedFallback $file) { $fallbackDownloadCount++ }
    }
    catch {
        $fallbackFailures.Add("$($file.path): $($_.Exception.Message)")
        Write-Warning "Pinned fallback failed for $($file.path): $($_.Exception.Message)"
    }
}

$invalidFiles = @(Get-InvalidPinnedFiles $files)
if ($invalidFiles.Count -gt 0) {
    $missing = ($invalidFiles | ForEach-Object { [string]$_.path }) -join ', '
    $failureDetail = if ($fallbackFailures.Count -gt 0) { " Fallback errors: $($fallbackFailures -join ' | ')" } else { '' }
    throw "ModelService resource recovery failed. Invalid or missing files: $missing.$failureDetail"
}

$oscaListedPinnedCount = @($files | Where-Object {
    $remoteRelativeKeys.Contains(([string]$_.path).Replace('\', '/'))
}).Count
Write-Host "ModelService resources are ready in $destinationRoot"
Write-Host "Verified: $($files.Count)/$($files.Count); OSCA success: $oscaSucceeded; OSCA objects: $oscaObjectCount; pinned OSCA resources listed: $oscaListedPinnedCount; offline copies: $offlineCopyCount; fixed-source downloads: $fallbackDownloadCount"
if (-not [string]::IsNullOrWhiteSpace($oscaFailure)) {
    Write-Warning "OSCA recovery note: $oscaFailure"
}
$secretKey = $null
$oscaSecretAccessKey = $null
