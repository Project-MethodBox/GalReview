[CmdletBinding()]
param(
    [string]$DestinationPath,
    [string]$Endpoint = 'https://fgws3-ocloud.ihep.ac.cn',
    [string]$Bucket = '20277-gal-res',
    [string]$RemotePrefix = '',
    [string]$Region = 'us-east-1',
    [string]$ManifestPath,
    [switch]$SkipHashVerification
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

$awsCommand = Get-Command aws -ErrorAction SilentlyContinue
if (-not $awsCommand) {
    throw 'AWS CLI was not found. Install AWS CLI v2, then rerun this script. Do not use aws configure with the shared OSCA key.'
}

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

function Invoke-OsCaAws([string[]]$Arguments) {
    $output = & $script:awsCommand.Source @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw (Protect-CommandError "OSCA S3 request failed: $($output.Trim())")
    }
    return $output
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
    @"
[default]
region = $Region
output = json
s3 =
    addressing_style = path
    signature_version = s3v4
"@ | Set-Content -LiteralPath $temporaryConfig -Encoding utf8NoBOM

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
