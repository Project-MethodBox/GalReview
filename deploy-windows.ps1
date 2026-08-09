[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Deploy', 'Build', 'Start', 'Stop', 'Restart', 'Status', 'Check', 'Proxy', 'Direct')]
    [string]$Action = 'Menu',
    [string]$EnvironmentFile = '.env.windows.production',
    [string]$PublicUrl = '',
    [string]$CertificateThumbprint = '',
    [switch]$InitializeOnly,
    [switch]$RequireRunning
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 otherwise decodes UTF-8 native command output with
# the legacy system code page, which turns dotnet/npm logs into mojibake.
$consoleUtf8 = [System.Text.UTF8Encoding]::new($false)
try {
    [Console]::InputEncoding = $consoleUtf8
    [Console]::OutputEncoding = $consoleUtf8
}
catch {
    # Non-interactive hosts may not expose a writable console encoding.
}
$OutputEncoding = $consoleUtf8
[Environment]::SetEnvironmentVariable('DOTNET_CLI_UI_LANGUAGE', 'en-US', [EnvironmentVariableTarget]::Process)

$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$productionRoot = Join-Path $projectRoot '.production'
$releasesRoot = Join-Path $productionRoot 'releases'
$logsRoot = Join-Path $productionRoot 'logs'
$manifestPath = Join-Path $productionRoot 'processes.json'
$currentReleasePath = Join-Path $productionRoot 'current-release.txt'
$script:settings = @{}

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

function Resolve-ProjectPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

function Read-EnvironmentFile {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = Resolve-ProjectPath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Production environment file was not found: $resolved`nRun this script without -Action so it can initialize the file from deploy\.env.windows.production.example."
    }

    $values = @{}
    foreach ($rawLine in Get-Content -LiteralPath $resolved -Encoding utf8) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) { throw "Invalid environment line in ${resolved}: $rawLine" }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($value.Length -ge 2) {
            $first = $value[0]
            $last = $value[$value.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $values[$key] = $value
    }
    return $values
}

function Get-Setting {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ''
    )
    if ($script:settings.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$script:settings[$Name])) {
        return [string]$script:settings[$Name]
    }
    return $Default
}

function Set-EnvironmentSetting {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    if ($Value -match "[`r`n]") { throw "Environment value '$Name' must be a single line." }
    $path = Resolve-ProjectPath $EnvironmentFile
    $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
    $pattern = '(?m)^' + [Regex]::Escape($Name) + '=.*$'
    $replacement = "$Name=$Value"
    if ([Regex]::IsMatch($content, $pattern)) {
        $content = [Regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement })
    }
    else {
        $content = $content.TrimEnd() + "`r`n$replacement`r`n"
    }
    Set-Content -LiteralPath $path -Value $content -Encoding utf8 -NoNewline
    $script:settings[$Name] = $Value
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-PublicEndpoint {
    $candidate = $PublicUrl.Trim()
    if (-not $candidate) { $candidate = Get-Setting 'ACCOUNT_FRONTEND_BASE_URL' }
    if (-not $candidate -or $candidate -match 'CHANGE_ME') {
        if ($Action -ne 'Menu') {
            throw 'ACCOUNT_FRONTEND_BASE_URL is not configured. Pass -PublicUrl http://your-public-ip or set the production environment value first.'
        }
        $candidate = (Read-Host '请输入公网地址，例如 http://203.0.113.10 或 https://example.com').Trim()
    }

    $uri = $null
    if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
        throw "Invalid public URL '$candidate'. Use an absolute HTTP or HTTPS URL."
    }
    if ($uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
        throw 'The public URL must contain only the scheme and host, without a path, query string, credentials, or fragment.'
    }
    if ($uri.Host -in @('localhost', '127.0.0.1', '::1')) {
        throw 'The reverse proxy public URL cannot use a loopback host.'
    }
    $parsedAddress = $null
    if ([Net.IPAddress]::TryParse($uri.Host, [ref]$parsedAddress) -and $parsedAddress.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
        throw 'The one-click IIS binding currently supports public IPv4 addresses or domain names, not a literal IPv6 URL.'
    }
    $expectedPort = if ($uri.Scheme -eq 'https') { 443 } else { 80 }
    $frontendPort = [int](Get-Setting 'FRONTEND_PORT' '5120')
    $legacyFrontendPorts = @($frontendPort, 5120, 5121, 5122) | Select-Object -Unique
    $migratedLegacyPort = $false
    if (-not $uri.IsDefaultPort -and $uri.Port -ne $expectedPort) {
        if ($uri.Port -in $legacyFrontendPorts) {
            $legacyPort = $uri.Port
            $builder = [UriBuilder]::new($uri)
            $builder.Port = -1
            $uri = $builder.Uri
            $migratedLegacyPort = $true
            Write-Host "已将旧的前端端口 $legacyPort 自动迁移为公网标准 $expectedPort 端口。" -ForegroundColor Cyan
        }
        else {
            throw "公网地址端口 $($uri.Port) 不受支持。HTTP 请使用 80，HTTPS 请使用 443；不要填写开发或内部前端端口。"
        }
    }

    $normalized = $uri.GetLeftPart([UriPartial]::Authority).TrimEnd('/')
    return [PSCustomObject]@{
        Url = $normalized
        Scheme = $uri.Scheme
        Host = $uri.Host
        UseHttps = $uri.Scheme -eq 'https'
        IsIpAddress = $null -ne $parsedAddress
        UpdateEnvironment = [bool]($PublicUrl -or $migratedLegacyPort -or (Get-Setting 'ACCOUNT_FRONTEND_BASE_URL') -match 'CHANGE_ME')
    }
}

function Resolve-DirectPublicEndpoint {
    $frontendPort = [int](Get-Setting 'FRONTEND_PORT' '5120')
    $candidate = $PublicUrl.Trim()
    if (-not $candidate) { $candidate = Get-Setting 'ACCOUNT_FRONTEND_BASE_URL' }
    if (-not $candidate -or $candidate -match 'CHANGE_ME') {
        if ($Action -ne 'Menu') {
            throw "ACCOUNT_FRONTEND_BASE_URL is not configured. Pass -PublicUrl http://your-public-ip:$frontendPort."
        }
        $candidate = (Read-Host "请输入公网 IP 或域名，例如 http://203.0.113.10:$frontendPort").Trim()
    }

    $uri = $null
    if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
        throw "Invalid direct public URL '$candidate'."
    }
    if ($uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
        throw 'The direct public URL must contain only the scheme and host.'
    }
    if ($uri.Host -in @('localhost', '127.0.0.1', '::1')) {
        throw 'Direct public access cannot use a loopback host.'
    }
    if ($PublicUrl -and $uri.Scheme -ne 'http') {
        throw 'The built-in frontend on port 5120 provides HTTP only. Use an http:// URL, not https://.'
    }

    $builder = [UriBuilder]::new($uri)
    $builder.Scheme = 'http'
    $builder.Port = $frontendPort
    return $builder.Uri.GetLeftPart([UriPartial]::Authority).TrimEnd('/')
}

function Install-IisServerRole {
    if (-not (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue)) {
        throw 'Install-WindowsFeature is unavailable. This action must run on Windows Server with the ServerManager module.'
    }
    $feature = Get-WindowsFeature -Name Web-Server
    if (-not $feature.Installed) {
        Write-Host 'Installing the IIS Web Server role...' -ForegroundColor Cyan
        $result = Install-WindowsFeature Web-Server -IncludeManagementTools
        if (-not $result.Success) { throw 'The IIS Web Server role installation failed.' }
        if ($result.RestartNeeded -eq 'Yes') {
            throw 'IIS was installed, but Windows requires a restart. Restart the server and run this action again.'
        }
    }
}

function Test-IisConfigurationSection {
    param([Parameter(Mandatory)][string]$Section)
    $appCmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
    if (-not (Test-Path -LiteralPath $appCmd -PathType Leaf)) { return $false }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $appCmd list config "/section:$Section" 2>&1 | Out-Null
        return $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Save-MicrosoftInstaller {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        Write-Host "Downloading $(Split-Path -Leaf $Destination)..." -ForegroundColor Cyan
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Destination
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "Installer signature validation failed: $Destination"
    }
}

function Install-MsiPackage {
    param([Parameter(Mandatory)][string]$Path)
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$Path`" /quiet /norestart" -Wait -PassThru
    if ($process.ExitCode -notin @(0, 1641, 3010)) {
        throw "MSI installation failed with exit code $($process.ExitCode): $Path"
    }
    if ($process.ExitCode -in @(1641, 3010)) {
        throw 'An IIS component was installed, but Windows requires a restart. Restart the server and run this action again.'
    }
}

function Install-IisProxyModules {
    $installerRoot = Join-Path $productionRoot 'installers'
    New-Item -ItemType Directory -Force -Path $installerRoot | Out-Null

    if (-not (Test-IisConfigurationSection 'system.webServer/rewrite/globalRules')) {
        $rewriteInstaller = Join-Path $installerRoot 'rewrite_amd64_en-US.msi'
        Save-MicrosoftInstaller 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi' $rewriteInstaller
        Write-Host 'Installing IIS URL Rewrite 2.1...' -ForegroundColor Cyan
        Install-MsiPackage $rewriteInstaller
    }
    if (-not (Test-IisConfigurationSection 'system.webServer/proxy')) {
        $arrInstaller = Join-Path $installerRoot 'requestRouter_amd64.msi'
        Save-MicrosoftInstaller 'https://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi' $arrInstaller
        Write-Host 'Installing IIS Application Request Routing 3...' -ForegroundColor Cyan
        Install-MsiPackage $arrInstaller
    }
    if (-not (Test-IisConfigurationSection 'system.webServer/rewrite/globalRules') -or
        -not (Test-IisConfigurationSection 'system.webServer/proxy')) {
        throw 'IIS URL Rewrite or Application Request Routing is unavailable after installation. Restart Windows and run this action again.'
    }
}

function Find-IisCertificate {
    param([Parameter(Mandatory)][string]$HostName)
    $requestedThumbprint = $CertificateThumbprint.Replace(' ', '')
    $certificates = @(Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and $_.NotBefore -le (Get-Date) })
    if ($requestedThumbprint) {
        return $certificates | Where-Object { $_.Thumbprint -eq $requestedThumbprint } | Select-Object -First 1
    }

    foreach ($certificate in $certificates) {
        $dnsNames = @($certificate.DnsNameList | ForEach-Object { $_.Unicode })
        if ($dnsNames.Count -eq 0 -and $certificate.Subject -match '(?:^|,\s*)CN=([^,]+)') {
            $dnsNames = @($Matches[1])
        }
        foreach ($dnsName in $dnsNames) {
            if ($dnsName -eq $HostName) { return $certificate }
            if ($dnsName.StartsWith('*.') -and $HostName.EndsWith($dnsName.Substring(1), [StringComparison]::OrdinalIgnoreCase)) {
                return $certificate
            }
        }
    }
    return $null
}

function Add-ReverseProxyFirewallRule {
    param([Parameter(Mandatory)][int]$Port)
    $displayName = "GalReview reverse proxy TCP $Port"
    if (-not (Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $displayName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
    }
}

function Add-DirectFrontendFirewallRule {
    param([Parameter(Mandatory)][int]$Port)
    $displayName = "GalReview direct frontend TCP $Port"
    if (-not (Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $displayName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
    }
}

function Enable-DirectFrontendAccess {
    if (-not (Test-IsAdministrator)) {
        throw 'Direct public access setup requires an elevated PowerShell window.'
    }
    $script:settings = Read-EnvironmentFile $EnvironmentFile
    $directUrl = Resolve-DirectPublicEndpoint
    $frontendPort = [int](Get-Setting 'FRONTEND_PORT' '5120')

    Set-EnvironmentSetting 'ACCOUNT_FRONTEND_BASE_URL' $directUrl
    Set-EnvironmentSetting 'CORS_ORIGINS' $directUrl
    Set-EnvironmentSetting 'FRONTEND_BIND_ADDRESS' '0.0.0.0'
    Add-DirectFrontendFirewallRule $frontendPort
    $script:settings = Read-EnvironmentFile $EnvironmentFile

    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Write-Host '正在切换为公网直连模式并重启正式环境...' -ForegroundColor Cyan
        Stop-ProductionServices
        Start-ProductionServices
    }
    else {
        $hasCurrentRelease = $false
        if (Test-Path -LiteralPath $currentReleasePath -PathType Leaf) {
            $releaseCandidate = (Get-Content -LiteralPath $currentReleasePath -Raw -Encoding utf8).Trim()
            $hasCurrentRelease = $releaseCandidate -and (Test-Path -LiteralPath $releaseCandidate -PathType Container)
        }
        if ($hasCurrentRelease) {
            Start-ProductionServices
        }
        else {
            Write-Warning '直连配置已经保存，但尚未构建生产版本。请执行菜单 1（首次部署 / 更新版本）。'
        }
    }

    Write-Host "公网直连模式已启用：$directUrl" -ForegroundColor Green
    Write-Host "请在云安全组中放行 TCP $frontendPort；该模式不提供 HTTPS，也不能替代 ICP 备案。" -ForegroundColor Yellow
}

function Grant-IisReadAccess {
    param([Parameter(Mandatory)][string]$Path)
    # S-1-5-32-568 is the built-in IIS_IUSRS group and is independent of the
    # localized Windows display name.
    $iisUsers = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-568')
    $rights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
        [Security.AccessControl.FileSystemRights]::Synchronize
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $iisUsers,
        $rights,
        $inheritance,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-IisReverseProxyEndpoint {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [switch]$ExpectHttpsRedirect
    )
    # Windows PowerShell 5.1 treats Host as a restricted header and may reject
    # Invoke-WebRequest -Headers. HttpWebRequest.Host performs the same local
    # binding check without DNS, system-proxy, or hairpin-network dependencies.
    $request = [Net.HttpWebRequest]::Create('http://127.0.0.1/healthz')
    $request.Host = $HostName
    $request.Proxy = $null
    $request.AllowAutoRedirect = $false
    $request.Timeout = 5000
    $response = $null
    try {
        $response = [Net.HttpWebResponse]$request.GetResponse()
        $statusCode = [int]$response.StatusCode
        if ($ExpectHttpsRedirect) {
            if ($statusCode -notin @(301, 302, 307, 308)) {
                throw "IIS returned HTTP $statusCode instead of an HTTPS redirect."
            }
        }
        elseif ($statusCode -lt 200 -or $statusCode -ge 400) {
            throw "IIS returned HTTP $statusCode."
        }
        return $statusCode
    }
    catch [Net.WebException] {
        $errorResponse = $_.Exception.Response
        if ($errorResponse) {
            $statusCode = [int]$errorResponse.StatusCode
            throw "IIS returned HTTP $statusCode for Host $HostName."
        }
        throw "IIS request failed for Host ${HostName}: $($_.Exception.Message)"
    }
    finally {
        if ($response) { $response.Dispose() }
    }
}

function Configure-IisReverseProxy {
    if (-not (Test-IsAdministrator)) {
        throw 'Reverse proxy setup requires an elevated PowerShell window. Run deploy-windows.ps1 as Administrator.'
    }
    $script:settings = Read-EnvironmentFile $EnvironmentFile
    $endpoint = Resolve-PublicEndpoint
    $wasDirectFrontend = (Get-Setting 'FRONTEND_BIND_ADDRESS' '127.0.0.1') -eq '0.0.0.0'
    $certificate = $null
    if ($endpoint.UseHttps) {
        $certificate = Find-IisCertificate $endpoint.Host
        if (-not $certificate) {
            throw "No valid LocalMachine certificate was found for $($endpoint.Host). Import the certificate first, use -CertificateThumbprint, or configure an HTTP public URL temporarily."
        }
    }

    Install-IisServerRole
    Install-IisProxyModules

    $frontendPort = [int](Get-Setting 'FRONTEND_PORT' '5120')
    $siteName = 'GalReviewProxy'
    $poolName = 'GalReviewProxy'
    # IIS must not read distributed configuration from an Administrator profile:
    # user-profile ACLs commonly cause HTTP 500.19/0x80070005. Keep the tiny
    # proxy-only web.config under the conventional IIS content root instead.
    $siteRoot = Join-Path $env:SystemDrive 'inetpub\GalReviewProxy'
    New-Item -ItemType Directory -Force -Path $siteRoot | Out-Null
    $redirectRule = if ($endpoint.UseHttps) {
@'
        <rule name="Redirect HTTP to HTTPS" stopProcessing="true">
          <match url="(.*)" />
          <conditions><add input="{HTTPS}" pattern="off" /></conditions>
          <action type="Redirect" url="https://{HTTP_HOST}/{R:1}" redirectType="Permanent" />
        </rule>
'@
    }
    else { '' }
    $webConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
$redirectRule        <rule name="GalReview reverse proxy" stopProcessing="true">
          <match url="(.*)" />
          <action type="Rewrite" url="http://127.0.0.1:$frontendPort/{R:1}" appendQueryString="true" />
        </rule>
      </rules>
    </rewrite>
  </system.webServer>
</configuration>
"@
    Set-Content -LiteralPath (Join-Path $siteRoot 'web.config') -Value $webConfig -Encoding utf8
    Grant-IisReadAccess $siteRoot

    $administrationAssembly = Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll'
    if (-not ('Microsoft.Web.Administration.ServerManager' -as [type])) {
        Add-Type -Path $administrationAssembly
    }
    # HTTP.sys does not reliably route a literal public IP used as an IIS host
    # header (especially when the cloud public address is NATed). IP access must
    # use a wildcard binding; DNS names continue to use host-header isolation.
    $bindingHost = if ($endpoint.IsIpAddress) { '' } else { $endpoint.Host }
    $manager = [Microsoft.Web.Administration.ServerManager]::new()
    try {
        $pool = $manager.ApplicationPools[$poolName]
        if ($null -eq $pool) { $pool = $manager.ApplicationPools.Add($poolName) }
        $pool.ManagedRuntimeVersion = ''

        if ($endpoint.IsIpAddress) {
            foreach ($otherSite in @($manager.Sites | Where-Object { $_.Name -ne $siteName })) {
                $conflicts = @($otherSite.Bindings | Where-Object {
                    $_.Protocol -eq 'http' -and $_.BindingInformation -match '^(?:\*|0\.0\.0\.0):80:$'
                })
                if ($conflicts.Count -eq 0) { continue }

                $defaultRoot = [IO.Path]::GetFullPath((Join-Path $env:SystemDrive 'inetpub\wwwroot'))
                $otherRoot = [Environment]::ExpandEnvironmentVariables(
                    [string]$otherSite.Applications['/'].VirtualDirectories['/'].PhysicalPath
                )
                $isUnusedDefaultSite = $otherSite.Name -eq 'Default Web Site' -and
                    [IO.Path]::GetFullPath($otherRoot).TrimEnd('\') -eq $defaultRoot.TrimEnd('\')
                if (-not $isUnusedDefaultSite) {
                    throw "IIS site '$($otherSite.Name)' already owns the wildcard HTTP port 80 binding. Remove or change that binding before configuring IP access."
                }

                if ([string]$otherSite.State -eq 'Started') { [void]$otherSite.Stop() }
                $otherSite.ServerAutoStart = $false
                foreach ($conflict in $conflicts) { [void]$otherSite.Bindings.Remove($conflict) }
                Write-Host '已停用 Default Web Site，并释放其通配 80 端口绑定。' -ForegroundColor Cyan
            }
        }

        $site = $manager.Sites[$siteName]
        if ($null -eq $site) {
            $site = $manager.Sites.Add($siteName, 'http', "*:80:$bindingHost", $siteRoot)
        }
        else {
            $site.Applications['/'].VirtualDirectories['/'].PhysicalPath = $siteRoot
            $site.Bindings.Clear()
            [void]$site.Bindings.Add("*:80:$bindingHost", 'http')
        }
        $site.Applications['/'].ApplicationPoolName = $poolName
        $site.ServerAutoStart = $true

        if ($endpoint.UseHttps) {
            $httpsBinding = $site.Bindings.Add("*:443:$bindingHost", 'https')
            $httpsBinding.CertificateHash = $certificate.GetCertHash()
            $httpsBinding.CertificateStoreName = 'My'
            $httpsBinding.SetAttributeValue('sslFlags', $(if ($endpoint.IsIpAddress) { 0 } else { 1 }))
        }

        $configuration = $manager.GetApplicationHostConfiguration()
        $proxySection = $configuration.GetSection('system.webServer/proxy')
        $proxySection.SetAttributeValue('enabled', $true)
        $preserveHostAttribute = $proxySection.GetAttribute('preserveHostHeader')
        if ($null -ne $preserveHostAttribute) { $preserveHostAttribute.Value = $true }
        $timeoutAttribute = $proxySection.GetAttribute('timeout')
        if ($null -ne $timeoutAttribute) { $timeoutAttribute.Value = [TimeSpan]::FromMinutes(20) }
        $manager.CommitChanges()
    }
    finally {
        $manager.Dispose()
    }

    Add-ReverseProxyFirewallRule 80
    if ($endpoint.UseHttps) { Add-ReverseProxyFirewallRule 443 }
    & (Join-Path $env:windir 'System32\iisreset.exe') /restart | Out-Null
    Start-Sleep -Milliseconds 500
    $siteManager = [Microsoft.Web.Administration.ServerManager]::new()
    try {
        $proxySite = $siteManager.Sites[$siteName]
        if ($null -eq $proxySite) { throw "IIS site $siteName was not found after configuration." }
        if ([string]$proxySite.State -ne 'Started') {
            [void]$proxySite.Start()
        }
    }
    finally {
        $siteManager.Dispose()
    }

    if ($endpoint.UpdateEnvironment) {
        Set-EnvironmentSetting 'ACCOUNT_FRONTEND_BASE_URL' $endpoint.Url
        Set-EnvironmentSetting 'CORS_ORIGINS' $endpoint.Url
    }
    Set-EnvironmentSetting 'FRONTEND_BIND_ADDRESS' '127.0.0.1'
    if ($endpoint.UpdateEnvironment -or $wasDirectFrontend) {
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            Write-Host 'Restarting the production environment to apply the public URL...' -ForegroundColor Cyan
            $script:settings = Read-EnvironmentFile $EnvironmentFile
            Stop-ProductionServices
            Start-ProductionServices
        }
    }

    $hasCurrentRelease = $false
    if (Test-Path -LiteralPath $currentReleasePath -PathType Leaf) {
        $releaseCandidate = (Get-Content -LiteralPath $currentReleasePath -Raw -Encoding utf8).Trim()
        $hasCurrentRelease = $releaseCandidate -and (Test-Path -LiteralPath $releaseCandidate -PathType Container)
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        if ($hasCurrentRelease) {
            Write-Host '检测到已构建但尚未运行的生产版本，正在自动启动...' -ForegroundColor Cyan
            $script:settings = Read-EnvironmentFile $EnvironmentFile
            Start-ProductionServices
        }
    }

    $healthUri = "http://127.0.0.1:$frontendPort/healthz"
    try {
        [void](Invoke-WebRequest -UseBasicParsing -Uri $healthUri -TimeoutSec 5)
    }
    catch {
        if (-not $hasCurrentRelease) {
            Write-Warning 'IIS 反向代理已经配置完成，但尚未构建生产版本。请返回菜单执行 1（首次部署 / 更新版本）。'
        }
        else {
            Write-Warning "IIS 反向代理已经配置完成，但正式前端 $healthUri 未响应。请执行菜单 2（启动当前版本），并检查 .production\logs\frontend.err.log。"
        }
        return
    }

    try {
        [void](Test-IisReverseProxyEndpoint -HostName $endpoint.Host -ExpectHttpsRedirect:$endpoint.UseHttps)
    }
    catch {
        Write-Warning "正式前端已经正常运行，但 IIS 反向代理检查失败：$($_.Exception.Message) 请在 IIS 管理器检查 GalReviewProxy 的绑定和日志。"
        return
    }

    Write-Host "IIS reverse proxy is ready: $($endpoint.Url) -> http://127.0.0.1:$frontendPort" -ForegroundColor Green
    Write-Host 'Remember to allow the same public port in the cloud security group.' -ForegroundColor Yellow
}

function New-SecureServiceKey {
    $bytes = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $generator.Dispose()
    }
}

function Initialize-ProductionEnvironment {
    $resolvedEnvironmentPath = Resolve-ProjectPath $EnvironmentFile
    $environmentCreated = $false
    if (-not (Test-Path -LiteralPath $resolvedEnvironmentPath -PathType Leaf)) {
        $examplePath = Join-Path $projectRoot 'deploy\.env.windows.production.example'
        if (-not (Test-Path -LiteralPath $examplePath -PathType Leaf)) {
            throw "找不到生产配置模板：$examplePath"
        }
        Copy-Item -LiteralPath $examplePath -Destination $resolvedEnvironmentPath
        $environmentCreated = $true
    }

    $keyNames = @(
        'GATEWAY_KEY', 'USER_SERVICE_KEY', 'AUTH_SERVICE_KEY', 'FILE_SERVICE_KEY',
        'KNOWLEDGE_SERVICE_KEY', 'GALGAME_SERVICE_KEY', 'RENDER_SERVICE_KEY',
        'PRACTICE_SERVICE_KEY', 'CREDIT_SERVICE_KEY'
    )
    $content = Get-Content -LiteralPath $resolvedEnvironmentPath -Raw -Encoding utf8
    if ($content -match '(?m)^DSAPI=' -and $content -notmatch '(?m)^DEEPSEEK_API_KEY=') {
        $content = [Regex]::Replace($content, '(?m)^DSAPI=', 'DEEPSEEK_API_KEY=')
        Set-Content -LiteralPath $resolvedEnvironmentPath -Value $content -Encoding utf8 -NoNewline
    }
    $generatedCount = 0
    foreach ($name in $keyNames) {
        $pattern = '(?m)^' + [Regex]::Escape($name) + '=(.*)$'
        $match = [Regex]::Match($content, $pattern)
        if (-not $match.Success) {
            $content = $content.TrimEnd() + "`r`n$name=$(New-SecureServiceKey)`r`n"
            $generatedCount++
            continue
        }
        $currentValue = $match.Groups[1].Value.Trim()
        if (-not $currentValue -or $currentValue -match 'CHANGE_ME') {
            $content = [Regex]::Replace($content, $pattern, "$name=$(New-SecureServiceKey)")
            $generatedCount++
        }
    }
    if ($generatedCount -gt 0) {
        Set-Content -LiteralPath $resolvedEnvironmentPath -Value $content -Encoding utf8 -NoNewline
    }

    return [PSCustomObject]@{
        Path = $resolvedEnvironmentPath
        Created = $environmentCreated
        GeneratedKeyCount = $generatedCount
    }
}

function Edit-ProductionEnvironment {
    param([Parameter(Mandatory)][string]$Path)
    Start-Process -FilePath 'notepad.exe' -ArgumentList @($Path) -Wait
}

function Wait-ForUser {
    Write-Host
    [void](Read-Host '按 Enter 键继续')
}

function Write-EnvironmentCheck {
    param(
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')]
        [string]$Status,
        [string]$Message,
        [switch]$Concise
    )
    if ($Status -eq 'FAIL') { $script:environmentCheckFailures++ }
    if ($Status -eq 'WARN') { $script:environmentCheckWarnings++ }
    if ($Concise -and $Status -in @('PASS', 'INFO')) { return }

    $color = switch ($Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Cyan' }
    }
    Write-Host ("[{0}] {1}" -f $Status, $Message) -ForegroundColor $color
}

function Find-InstalledService {
    param([string[]]$Patterns)
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object {
            $serviceName = $_.Name
            $displayName = $_.DisplayName
            @($Patterns | Where-Object { $serviceName -match $_ -or $displayName -match $_ }).Count -gt 0
        } |
        Select-Object -First 1
}

function Test-InstalledComponent {
    param(
        [string]$Name,
        [string[]]$CommandNames,
        [string[]]$ServicePatterns,
        [string]$AdditionalPath,
        [switch]$AcceptMissing,
        [switch]$Concise
    )
    $command = $CommandNames |
        ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    $service = Find-InstalledService $ServicePatterns
    $pathExists = $AdditionalPath -and (Test-Path -LiteralPath $AdditionalPath)
    if ($command -or $service -or $pathExists) {
        $evidence = if ($service) { "Windows service $($service.Name) ($($service.Status))" }
            elseif ($command) { "command $($command.Source)" }
            else { "directory $AdditionalPath" }
        Write-EnvironmentCheck PASS "$Name detected: $evidence." -Concise:$Concise
        return
    }
    if ($AcceptMissing) {
        Write-EnvironmentCheck INFO "$Name installation was not identified, but its configured endpoint is reachable." -Concise:$Concise
    }
    else {
        Write-EnvironmentCheck FAIL "$Name was not detected." -Concise:$Concise
    }
}

function Get-ListeningProcess {
    param([int]$Port)
    try {
        $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1
        if (-not $connection) { return $null }
        $processInfo = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            ProcessId = [int]$connection.OwningProcess
            Name = if ($processInfo) { $processInfo.ProcessName } else { 'unknown' }
            Address = $connection.LocalAddress
        }
    }
    catch { return $null }
}

function Test-EnvironmentEndpoint {
    param(
        [string]$Name,
        [string]$HostName,
        [int]$Port,
        [switch]$Infrastructure,
        [switch]$RequireEndpoint,
        [switch]$Concise
    )
    if (Test-TcpPort $HostName $Port) {
        $localHostNames = @('127.0.0.1', 'localhost', '::1')
        $listener = if ($HostName -in $localHostNames) { Get-ListeningProcess $Port } else { $null }
        $detail = if ($listener) { "process $($listener.Name), PID $($listener.ProcessId)" } else { "$HostName`:$Port reachable" }
        Write-EnvironmentCheck PASS "$Name endpoint is ready ($detail)." -Concise:$Concise
        return
    }
    if ($Infrastructure -and $RequireEndpoint) {
        Write-EnvironmentCheck FAIL "$Name endpoint $HostName`:$Port is not reachable." -Concise:$Concise
    }
    elseif ($Infrastructure) {
        Write-EnvironmentCheck WARN "$Name endpoint $HostName`:$Port is not reachable." -Concise:$Concise
    }
    else {
        Write-EnvironmentCheck INFO "$Name project port $Port is not listening." -Concise:$Concise
    }
}

function Invoke-EnvironmentCheck {
    param(
        [switch]$RequireInfrastructure,
        [switch]$Concise
    )
    $script:environmentCheckFailures = 0
    $script:environmentCheckWarnings = 0
    if (-not $Concise) {
        Write-Host '千知万理 Windows 生产环境检查' -ForegroundColor White
        Write-Host
    }

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        Write-EnvironmentCheck FAIL '.NET SDK was not found; .NET 10 is required.' -Concise:$Concise
    }
    else {
        $sdks = @(& dotnet --list-sdks 2>$null)
        $sdk10 = $sdks | Where-Object { $_ -match '^10\.\d+\.\d+' } | Select-Object -First 1
        if ($sdk10) { Write-EnvironmentCheck PASS ".NET 10 SDK detected: $($sdk10.Trim())" -Concise:$Concise }
        else { Write-EnvironmentCheck FAIL '.NET is installed, but the .NET 10 SDK is missing.' -Concise:$Concise }
    }

    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        Write-EnvironmentCheck PASS "Node.js detected: $((& node --version 2>$null).Trim())" -Concise:$Concise
    }
    else { Write-EnvironmentCheck FAIL 'Node.js was not found on PATH.' -Concise:$Concise }
    if (Get-Command 'npm.cmd' -ErrorAction SilentlyContinue) {
        Write-EnvironmentCheck PASS 'npm detected.' -Concise:$Concise
    }
    else { Write-EnvironmentCheck FAIL 'npm.cmd was not found on PATH.' -Concise:$Concise }

    $infrastructure = @(
        @{ Name = 'MySQL'; Host = Get-Setting 'MYSQL_HOST' '127.0.0.1'; Port = [int](Get-Setting 'MYSQL_PORT' '3306'); Commands = @('mysql', 'mysqld'); Services = @('^MySQL', 'MySQL'); Path = '' },
        @{ Name = 'MongoDB'; Host = Get-Setting 'MONGO_HOST' '127.0.0.1'; Port = [int](Get-Setting 'MONGO_PORT' '27017'); Commands = @('mongod', 'mongosh'); Services = @('^MongoDB$', 'MongoDB'); Path = '' },
        @{ Name = 'Neo4j'; Host = Get-Setting 'NEO4J_HOST' '127.0.0.1'; Port = [int](Get-Setting 'NEO4J_PORT' '7687'); Commands = @('neo4j'); Services = @('^neo4j', 'Neo4j'); Path = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.Neo4jDesktop2') }
    )
    foreach ($item in $infrastructure) {
        $endpointReachable = Test-TcpPort $item.Host $item.Port
        if ($item.Host -in @('127.0.0.1', 'localhost', '::1')) {
            Test-InstalledComponent $item.Name $item.Commands $item.Services $item.Path -AcceptMissing:$endpointReachable -Concise:$Concise
        }
        else {
            Write-EnvironmentCheck INFO "$($item.Name) uses remote host $($item.Host); local installation check skipped." -Concise:$Concise
        }
        Test-EnvironmentEndpoint $item.Name $item.Host $item.Port -Infrastructure -RequireEndpoint:$RequireInfrastructure -Concise:$Concise
    }

    $projectPorts = @(
        @{ Name = 'Gateway'; Port = [int](Get-Setting 'GATEWAY_PORT' '5000') },
        @{ Name = 'UserService'; Port = 5101 }, @{ Name = 'AuthService'; Port = 5102 },
        @{ Name = 'FileService'; Port = 5103 }, @{ Name = 'KnowledgeService'; Port = 5104 },
        @{ Name = 'GalGameService'; Port = 5105 }, @{ Name = 'RenderService'; Port = 5106 },
        @{ Name = 'PracticeService'; Port = 5107 }, @{ Name = 'CreditService'; Port = 5108 },
        @{ Name = 'OCRService'; Port = 5110 },
        @{ Name = 'Frontend'; Port = [int](Get-Setting 'FRONTEND_PORT' '5120') }
    )
    foreach ($item in $projectPorts) {
        Test-EnvironmentEndpoint $item.Name '127.0.0.1' $item.Port -Concise:$Concise
    }

    $passed = $script:environmentCheckFailures -eq 0
    $summary = if ($passed) {
        "Environment check passed with $($script:environmentCheckWarnings) warning(s)."
    }
    else {
        "Environment check failed: $($script:environmentCheckFailures) failure(s), $($script:environmentCheckWarnings) warning(s)."
    }
    Write-Host $summary -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
    return [PSCustomObject]@{
        Passed = $passed
        Failures = $script:environmentCheckFailures
        Warnings = $script:environmentCheckWarnings
    }
}

function Assert-ProductionSettings {
    $required = @(
        'GATEWAY_KEY', 'USER_SERVICE_KEY', 'AUTH_SERVICE_KEY', 'FILE_SERVICE_KEY',
        'KNOWLEDGE_SERVICE_KEY', 'GALGAME_SERVICE_KEY', 'RENDER_SERVICE_KEY',
        'PRACTICE_SERVICE_KEY', 'CREDIT_SERVICE_KEY', 'USER_DATABASE_CONNECTION',
        'AUTH_DATABASE_CONNECTION', 'CREDIT_DATABASE_CONNECTION', 'MONGO_CONNECTION_STRING',
        'NEO4J_PASSWORD', 'GALREVIEW_ADMIN_USERNAME', 'GALREVIEW_ADMIN_PASSWORD',
        'ACCOUNT_FRONTEND_BASE_URL', 'CORS_ORIGINS'
    )

    foreach ($name in $required) {
        $value = Get-Setting $name
        if ([string]::IsNullOrWhiteSpace($value) -or $value -match 'CHANGE_ME' -or $value -eq 'moonstone-local-gateway-key') {
            throw "Production setting '$name' is missing or still uses an insecure example value."
        }
    }

    $serviceKeyNames = @(
        'GATEWAY_KEY', 'USER_SERVICE_KEY', 'AUTH_SERVICE_KEY', 'FILE_SERVICE_KEY',
        'KNOWLEDGE_SERVICE_KEY', 'GALGAME_SERVICE_KEY', 'RENDER_SERVICE_KEY',
        'PRACTICE_SERVICE_KEY', 'CREDIT_SERVICE_KEY'
    )
    $uniqueKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($name in $serviceKeyNames) { [void]$uniqueKeys.Add((Get-Setting $name)) }
    if ($uniqueKeys.Count -ne $serviceKeyNames.Count) {
        throw 'Every production service key must be unique. Do not reuse GATEWAY_KEY or another service key.'
    }

    $rootMySqlConnections = @(
        'USER_DATABASE_CONNECTION',
        'AUTH_DATABASE_CONNECTION',
        'CREDIT_DATABASE_CONNECTION'
    ) | Where-Object {
        (Get-Setting $_) -match '(?i)(?:User ID|Uid)\s*=\s*root\s*;' -and
        (Get-Setting $_) -match '(?i)(?:Password|Pwd)\s*=\s*root(?:;|$)'
    }
    if ($rootMySqlConnections.Count -gt 0) {
        Write-Warning 'MySQL is using the root/root account. This is convenient for initial setup but unsafe for a public production server.'
    }
}

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not available on PATH."
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )
    Push-Location $WorkingDirectory
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Keep successful build output concise. Native stderr is captured as
        # text and only surfaced when the command actually fails.
        $ErrorActionPreference = 'Continue'
        $commandOutput = @(& $FilePath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $commandExitCode = $LASTEXITCODE
        if ($commandExitCode -ne 0) {
            $diagnosticTail = @($commandOutput | Select-Object -Last 80) -join [Environment]::NewLine
            $message = "Command failed with exit code ${commandExitCode}: $FilePath $($Arguments -join ' ')"
            if ($diagnosticTail) { $message += [Environment]::NewLine + $diagnosticTail }
            throw $message
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

function Remove-NonRuntimeNodeArtifacts {
    param([Parameter(Mandatory)][string]$Directory)
    Get-ChildItem -LiteralPath $Directory -Recurse -File |
        Where-Object { $_.Name -like '*.map' -or $_.Name -like '*.d.ts' } |
        Remove-Item -Force
}

function Copy-NodeBuildSource {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $excludedDirectories = @('node_modules', 'dist', 'coverage', '.git')
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($item.PSIsContainer -and $item.Name -in $excludedDirectories) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Build-ProductionRelease {
    Assert-Command 'dotnet'
    Assert-Command 'node'
    Assert-Command 'npm.cmd'

    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'backend\PracticeService\Resources') -PathType Container)) {
        throw 'PracticeService Resources are missing. Run scripts\download-practice-resources.ps1 before building.'
    }

    New-Item -ItemType Directory -Force -Path $releasesRoot | Out-Null
    $releaseId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $releaseRoot = Join-Path $releasesRoot $releaseId
    if (Test-Path -LiteralPath $releaseRoot) { $releaseRoot += '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) }
    New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null

    Write-Host "Building production release $([IO.Path]::GetFileName($releaseRoot))..." -ForegroundColor Cyan

    $dotnetServices = @(
        @{ Name = 'user-service'; Project = 'backend\UserService\GalGame.UserService.csproj' },
        @{ Name = 'auth-service'; Project = 'backend\AuthService\GalGame.AuthService.csproj' },
        @{ Name = 'file-service'; Project = 'backend\FileService\GalGame.FileService.csproj' },
        @{ Name = 'knowledge-service'; Project = 'backend\KnowledgeService\KnowledgeService.API\KnowledgeService.API.csproj' },
        @{ Name = 'galgame-service'; Project = 'backend\GalGameService\GalGame.GalGameService.csproj' },
        @{ Name = 'practice-service'; Project = 'backend\PracticeService\PracticeService.API\PracticeService.API.csproj' },
        @{ Name = 'credit-service'; Project = 'backend\CreditService\CreditService.API\CreditService.API.csproj' }
    )

    Write-Host '  [1/4] Publishing .NET services...' -ForegroundColor DarkCyan
    foreach ($service in $dotnetServices) {
        $destination = Join-Path $releaseRoot ("services\" + $service.Name)
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        Invoke-NativeCommand 'dotnet' @(
            'publish', (Join-Path $projectRoot $service.Project), '-c', 'Release',
            '-o', $destination, '--nologo'
        ) $projectRoot
    }
    Write-Host '        7 backend services published.' -ForegroundColor DarkGreen

    Write-Host '  [2/4] Building API Gateway...' -ForegroundColor DarkCyan
    $gatewaySource = Join-Path $projectRoot 'gateway'
    $gatewayBuildSource = Join-Path $releaseRoot '.build\gateway'
    Copy-NodeBuildSource $gatewaySource $gatewayBuildSource
    Invoke-NativeCommand 'npm.cmd' @('ci', '--no-audit', '--no-fund') $gatewayBuildSource
    Invoke-NativeCommand 'npm.cmd' @('run', 'build') $gatewayBuildSource
    $gatewayDestination = Join-Path $releaseRoot 'gateway'
    New-Item -ItemType Directory -Force -Path $gatewayDestination | Out-Null
    Copy-Item -LiteralPath (Join-Path $gatewayBuildSource 'package.json'), (Join-Path $gatewayBuildSource 'package-lock.json') -Destination $gatewayDestination
    Copy-DirectoryContents (Join-Path $gatewayBuildSource 'dist') (Join-Path $gatewayDestination 'dist')
    Remove-NonRuntimeNodeArtifacts (Join-Path $gatewayDestination 'dist')
    Invoke-NativeCommand 'npm.cmd' @('ci', '--omit=dev', '--no-audit', '--no-fund') $gatewayDestination
    Write-Host '        Gateway production package ready.' -ForegroundColor DarkGreen

    Write-Host '  [3/4] Building RenderService...' -ForegroundColor DarkCyan
    $renderSource = Join-Path $projectRoot 'backend\RenderService\service'
    $renderBuildSource = Join-Path $releaseRoot '.build\render-service'
    Copy-NodeBuildSource $renderSource $renderBuildSource
    Invoke-NativeCommand 'npm.cmd' @('ci', '--no-audit', '--no-fund') $renderBuildSource
    Invoke-NativeCommand 'npm.cmd' @('run', 'build') $renderBuildSource
    $renderDestination = Join-Path $releaseRoot 'render-service'
    Copy-DirectoryContents (Join-Path $renderBuildSource 'dist') (Join-Path $renderDestination 'dist')
    Copy-DirectoryContents (Join-Path $renderBuildSource 'demo') (Join-Path $renderDestination 'demo')
    Copy-Item -LiteralPath (Join-Path $renderBuildSource 'runtime.wasm.base64') -Destination $renderDestination
    Remove-NonRuntimeNodeArtifacts (Join-Path $renderDestination 'dist')
    Write-Host '        RenderService production package ready.' -ForegroundColor DarkGreen

    Write-Host '  [4/4] Building frontend...' -ForegroundColor DarkCyan
    $frontendSource = Join-Path $projectRoot 'frontend'
    $frontendBuildSource = Join-Path $releaseRoot '.build\frontend'
    Copy-NodeBuildSource $frontendSource $frontendBuildSource
    Invoke-NativeCommand 'npm.cmd' @('ci', '--no-audit', '--no-fund') $frontendBuildSource
    Invoke-NativeCommand 'npm.cmd' @('run', 'build') $frontendBuildSource
    $frontendDestination = Join-Path $releaseRoot 'frontend'
    New-Item -ItemType Directory -Force -Path $frontendDestination | Out-Null
    Copy-Item -LiteralPath (Join-Path $frontendBuildSource 'server.mjs') -Destination $frontendDestination
    Copy-DirectoryContents (Join-Path $frontendBuildSource 'dist') (Join-Path $frontendDestination 'dist')
    $exposedSourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $frontendDestination 'dist') -Recurse -File |
        Where-Object { $_.Extension -in @('.map', '.ts', '.tsx') })
    if ($exposedSourceFiles.Count -gt 0) {
        throw 'Frontend production output unexpectedly contains source or source-map files.'
    }
    Write-Host '        Frontend production assets ready.' -ForegroundColor DarkGreen

    Remove-Item -LiteralPath (Join-Path $releaseRoot '.build') -Recurse -Force

    Set-Content -LiteralPath $currentReleasePath -Value $releaseRoot -Encoding utf8
    Write-Host "Production release built: $releaseRoot" -ForegroundColor Green
    return $releaseRoot
}

function Get-CurrentRelease {
    if (-not (Test-Path -LiteralPath $currentReleasePath -PathType Leaf)) {
        throw 'No production release exists. Run .\deploy-windows.ps1 -Action Build first.'
    }
    $releaseRoot = (Get-Content -LiteralPath $currentReleasePath -Raw -Encoding utf8).Trim()
    if (-not $releaseRoot -or -not (Test-Path -LiteralPath $releaseRoot -PathType Container)) {
        throw "The current production release is unavailable: $releaseRoot"
    }
    return [IO.Path]::GetFullPath($releaseRoot)
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 1500
    )
    try {
        $client = [Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) { $client.Dispose(); return $false }
        $client.Dispose()
        return $true
    }
    catch { return $false }
}

function Test-HttpEndpoint {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = 3000
        $request.Proxy = $null
        $response = $request.GetResponse()
        $status = [int]$response.StatusCode
        $response.Dispose()
        return $status -ge 200 -and $status -lt 400
    }
    catch { return $false }
}

function Use-TemporaryEnvironment {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][scriptblock]$ActionBlock
    )
    $previous = @{}
    try {
        foreach ($entry in $Environment.GetEnumerator()) {
            $previous[$entry.Key] = [Environment]::GetEnvironmentVariable([string]$entry.Key, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, [EnvironmentVariableTarget]::Process)
        }
        & $ActionBlock
    }
    finally {
        foreach ($entry in $previous.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [EnvironmentVariableTarget]::Process)
        }
    }
}

function Start-ProductionProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$HealthUrl,
        [Parameter(Mandatory)][int]$StartupTimeoutSeconds
    )
    New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stdout = Join-Path $logsRoot "$timestamp-$Name.out.log"
    $stderr = Join-Path $logsRoot "$timestamp-$Name.error.log"
    $process = Use-TemporaryEnvironment $Environment {
        $startParameters = @{
            FilePath = $FilePath
            WorkingDirectory = $WorkingDirectory
            WindowStyle = 'Hidden'
            RedirectStandardOutput = $stdout
            RedirectStandardError = $stderr
            PassThru = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
            $startParameters.ArgumentList = $Arguments
        }
        Start-Process @startParameters
    }

    if ($null -eq $process) { throw "Failed to start $Name." }
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { break }
        if (Test-HttpEndpoint $HealthUrl) {
            Write-Host ("  [OK] {0} -> {1}" -f $Name, $HealthUrl) -ForegroundColor Green
            return [PSCustomObject]@{
                Name = $Name
                ProcessId = $process.Id
                ProcessName = $process.ProcessName
                StartedAtUtc = $process.StartTime.ToUniversalTime().ToString('O')
                HealthUrl = $HealthUrl
                StandardOutput = $stdout
                StandardError = $stderr
            }
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    Write-Host "--- $Name stdout ---" -ForegroundColor DarkYellow
    if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Tail 80 }
    Write-Host "--- $Name stderr ---" -ForegroundColor DarkYellow
    if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Tail 80 }
    throw "$Name did not become healthy within $StartupTimeoutSeconds seconds."
}

function Write-ProcessManifest {
    param([Parameter(Mandatory)][array]$Processes)
    New-Item -ItemType Directory -Force -Path $productionRoot | Out-Null
    $Processes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8
}

function Stop-ProductionServices {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-Host 'No Windows production process manifest was found.' -ForegroundColor DarkYellow
        return
    }

    # Windows PowerShell 5.1 returns a top-level JSON array as one Object[]
    # pipeline item. Assign first, then wrap, so each process becomes an entry.
    $parsedEntries = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $entries = @($parsedEntries)
    for ($index = $entries.Count - 1; $index -ge 0; $index--) {
        $entry = $entries[$index]
        $process = Get-Process -Id ([int]$entry.ProcessId) -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        $expected = [DateTimeOffset]::Parse([string]$entry.StartedAtUtc).UtcDateTime
        $actual = $process.StartTime.ToUniversalTime()
        if ([Math]::Abs(($actual - $expected).TotalSeconds) -gt 5) {
            Write-Warning "PID $($entry.ProcessId) for $($entry.Name) was reused; it will not be stopped."
            continue
        }
        Stop-Process -Id $process.Id -Force
        Write-Host ("  [STOP] {0} (PID {1})" -f $entry.Name, $process.Id)
    }
    Remove-Item -LiteralPath $manifestPath -Force
}

function Show-ProductionStatus {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-Host 'Windows production services are not recorded as running.' -ForegroundColor DarkYellow
        return
    }
    $parsedEntries = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $entries = @($parsedEntries)
    $rows = foreach ($entry in $entries) {
        $process = Get-Process -Id ([int]$entry.ProcessId) -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Service = $entry.Name
            PID = $entry.ProcessId
            Running = $null -ne $process
            Healthy = if ($null -ne $process) { Test-HttpEndpoint ([string]$entry.HealthUrl) } else { $false }
            Endpoint = $entry.HealthUrl
        }
    }
    $rows | Format-Table -AutoSize
}

function Assert-ExternalDependencies {
    $dependencies = @(
        @{ Name = 'MySQL'; Host = Get-Setting 'MYSQL_HOST' '127.0.0.1'; Port = [int](Get-Setting 'MYSQL_PORT' '3306') },
        @{ Name = 'MongoDB'; Host = Get-Setting 'MONGO_HOST' '127.0.0.1'; Port = [int](Get-Setting 'MONGO_PORT' '27017') },
        @{ Name = 'Neo4j'; Host = Get-Setting 'NEO4J_HOST' '127.0.0.1'; Port = [int](Get-Setting 'NEO4J_PORT' '7687') }
    )
    foreach ($dependency in $dependencies) {
        if (-not (Test-TcpPort $dependency.Host $dependency.Port)) {
            throw "$($dependency.Name) is not reachable at $($dependency.Host):$($dependency.Port)."
        }
    }
}

function Start-ProductionServices {
    Assert-ProductionSettings
    Assert-ExternalDependencies
    Assert-Command 'node'
    $releaseRoot = Get-CurrentRelease
    $startupTimeout = [int](Get-Setting 'STARTUP_TIMEOUT_SECONDS' '120')
    $gatewayPort = [int](Get-Setting 'GATEWAY_PORT' '5000')
    $frontendPort = [int](Get-Setting 'FRONTEND_PORT' '5120')
    $frontendBindAddress = Get-Setting 'FRONTEND_BIND_ADDRESS' '127.0.0.1'
    if ($frontendBindAddress -notin @('127.0.0.1', '0.0.0.0')) {
        throw "FRONTEND_BIND_ADDRESS must be 127.0.0.1 or 0.0.0.0, but was '$frontendBindAddress'."
    }
    $gatewayBaseUrl = "http://127.0.0.1:$gatewayPort"

    $ports = @(5101, 5102, 5103, 5104, 5105, 5106, 5107, 5108, $gatewayPort, $frontendPort) | Select-Object -Unique
    foreach ($port in $ports) {
        if (Test-TcpPort '127.0.0.1' $port 300) {
            throw "TCP port $port is already in use. Stop the existing service before starting production."
        }
    }

    $commonAspNet = @{ ASPNETCORE_ENVIRONMENT = 'Production' }
    $mongoConnection = Get-Setting 'MONGO_CONNECTION_STRING'
    $processes = @()
    try {
        $serviceDefinitions = @(
            @{
                Name = 'credit-service'; File = Join-Path $releaseRoot 'services\credit-service\CreditService.API.exe'; Work = Join-Path $releaseRoot 'services\credit-service'; Health = 'http://127.0.0.1:5108/readyz';
                Env = $commonAspNet + @{ ASPNETCORE_URLS = 'http://127.0.0.1:5108'; Gateway__ServiceKey = Get-Setting 'CREDIT_SERVICE_KEY'; ConnectionStrings__CreditDatabase = Get-Setting 'CREDIT_DATABASE_CONNECTION'; CreditStore__Provider = 'MySQL' }
            },
            @{
                Name = 'user-service'; File = Join-Path $releaseRoot 'services\user-service\GalGame.UserService.exe'; Work = Join-Path $releaseRoot 'services\user-service'; Health = 'http://127.0.0.1:5101/readyz';
                Env = $commonAspNet + @{ ASPNETCORE_URLS = 'http://127.0.0.1:5101'; MOONSTONE_MODE = Get-Setting 'USER_SERVICE_MODE' 'MySql'; Gateway__ServiceKey = Get-Setting 'USER_SERVICE_KEY'; ConnectionStrings__UserDatabase = Get-Setting 'USER_DATABASE_CONNECTION' }
            },
            @{
                Name = 'file-service'; File = Join-Path $releaseRoot 'services\file-service\GalGame.FileService.exe'; Work = Join-Path $releaseRoot 'services\file-service'; Health = 'http://127.0.0.1:5103/readyz';
                Env = $commonAspNet + @{ ASPNETCORE_URLS = 'http://127.0.0.1:5103'; Gateway__ServiceKey = Get-Setting 'FILE_SERVICE_KEY'; ConnectionStrings__FileDatabase = $mongoConnection; MongoDb__Database = 'qzwl_file'; InternalAccess__ExtractedTextAllowedServices__0 = 'KnowledgeService'; InternalAccess__ExtractedTextAllowedServices__1 = 'PracticeService'; Ocr__BaseUrl = Get-Setting 'OCR_BASE_URL' 'http://127.0.0.1:5110/'; Ocr__TimeoutMinutes = Get-Setting 'OCR_TIMEOUT_MINUTES' '20' }
            },
            @{
                Name = 'knowledge-service'; File = Join-Path $releaseRoot 'services\knowledge-service\KnowledgeService.API.exe'; Work = Join-Path $releaseRoot 'services\knowledge-service'; Health = 'http://127.0.0.1:5104/readyz';
                Env = $commonAspNet + @{ ASPNETCORE_URLS = 'http://127.0.0.1:5104'; Neo4j__Uri = Get-Setting 'NEO4J_URI' 'bolt://127.0.0.1:7687'; Neo4j__Username = Get-Setting 'NEO4J_USERNAME' 'neo4j'; Neo4j__Password = Get-Setting 'NEO4J_PASSWORD'; Neo4j__Database = Get-Setting 'NEO4J_DATABASE' 'neo4j'; GatewayMaterialText__BaseUrl = $gatewayBaseUrl; GatewayMaterialText__ServiceName = 'KnowledgeService'; GatewayMaterialText__ServiceKey = Get-Setting 'KNOWLEDGE_SERVICE_KEY'; Gateway__ServiceKey = Get-Setting 'KNOWLEDGE_SERVICE_KEY' }
            },
            @{
                Name = 'galgame-service'; File = Join-Path $releaseRoot 'services\galgame-service\GalGame.GalGameService.exe'; Work = Join-Path $releaseRoot 'services\galgame-service'; Health = 'http://127.0.0.1:5105/readyz';
                Env = $commonAspNet + @{ ASPNETCORE_URLS = 'http://127.0.0.1:5105'; Gateway__BaseUrl = $gatewayBaseUrl; Gateway__ServiceKey = Get-Setting 'GALGAME_SERVICE_KEY'; InternalAccess__ValidationAllowedServices__0 = 'RenderService'; InternalAccess__PackageReaderAllowedServices__0 = 'RenderService'; ConnectionStrings__GameDatabase = $mongoConnection; MongoDb__Database = 'qzwl_galgame'; GalGameStore__Provider = 'MongoDB'; NarrativeGeneration__Enabled = Get-Setting 'GALGAME_NARRATIVE_ENABLED' 'true'; NarrativeGeneration__ApiKey = Get-Setting 'DEEPSEEK_API_KEY'; NarrativeGeneration__Endpoint = Get-Setting 'GALGAME_NARRATIVE_ENDPOINT' 'https://api.deepseek.com/chat/completions'; NarrativeGeneration__Model = Get-Setting 'GALGAME_NARRATIVE_MODEL' 'deepseek-v4-pro'; NarrativeGeneration__PromptVersion = 'galgame-narrative-v3'; VoiceSynthesis__Enabled = Get-Setting 'GALGAME_VOICE_ENABLED' 'false'; VoiceSynthesis__ApiKey = Get-Setting 'MIMO_API_KEY'; VoiceSynthesis__Endpoint = Get-Setting 'MIMO_TTS_ENDPOINT' 'https://api.xiaomimimo.com/v1/chat/completions'; VoiceSynthesis__Model = 'mimo-v2.5-tts'; VoiceSynthesis__MaxConcurrency = Get-Setting 'MIMO_TTS_MAX_CONCURRENCY' '2' }
            },
            @{
                Name = 'render-service'; File = (Get-Command 'node').Source; Arguments = 'dist/server.js'; Work = Join-Path $releaseRoot 'render-service'; Health = 'http://127.0.0.1:5106/healthz';
                Env = @{ NODE_ENV = 'production'; PORT = '5106'; RENDER_HOST = '127.0.0.1'; Gateway__BaseUrl = $gatewayBaseUrl; Gateway__ServiceName = 'RenderService'; Gateway__ServiceKey = Get-Setting 'RENDER_SERVICE_KEY' }
            },
            @{
                Name = 'practice-service'; File = Join-Path $releaseRoot 'services\practice-service\PracticeService.API.exe'; Work = Join-Path $releaseRoot 'services\practice-service'; Health = 'http://127.0.0.1:5107/readyz';
                Env = $commonAspNet + @{ ASPNETCORE_URLS = 'http://127.0.0.1:5107'; Gateway__BaseUrl = $gatewayBaseUrl; Gateway__ServiceName = 'PracticeService'; Gateway__ServiceKey = Get-Setting 'PRACTICE_SERVICE_KEY'; ConnectionStrings__PracticeDatabase = $mongoConnection; MongoDb__Database = 'qzwl_practice'; PracticeStore__Provider = 'MongoDB'; QuestionGeneration__ApiKey = Get-Setting 'DEEPSEEK_API_KEY'; QuestionGeneration__Endpoint = Get-Setting 'PRACTICE_QUESTION_ENDPOINT' 'https://api.deepseek.com/chat/completions'; QuestionGeneration__Model = Get-Setting 'PRACTICE_QUESTION_MODEL' 'deepseek-v4-flash'; QuestionGeneration__Parallelism = Get-Setting 'PRACTICE_QUESTION_PARALLELISM' '4' }
            },
            @{
                Name = 'auth-service'; File = Join-Path $releaseRoot 'services\auth-service\GalGame.AuthService.exe'; Work = Join-Path $releaseRoot 'services\auth-service'; Health = 'http://127.0.0.1:5102/readyz';
                Env = $commonAspNet + @{ ASPNETCORE_URLS = 'http://127.0.0.1:5102'; MOONSTONE_MODE = Get-Setting 'AUTH_SERVICE_MODE' 'MySql'; Gateway__BaseUrl = $gatewayBaseUrl; Gateway__ServiceKey = Get-Setting 'AUTH_SERVICE_KEY'; Admin__Username = Get-Setting 'GALREVIEW_ADMIN_USERNAME'; Admin__Password = Get-Setting 'GALREVIEW_ADMIN_PASSWORD'; Email__SmtpHost = Get-Setting 'SMTP_HOST'; Email__SmtpPort = Get-Setting 'SMTP_PORT' '465'; Email__UseSsl = Get-Setting 'SMTP_USE_SSL' 'true'; Email__Username = Get-Setting 'SMTP_USERNAME'; Email__Password = Get-Setting 'SMTP_PASSWORD'; Email__FromAddress = Get-Setting 'SMTP_FROM_ADDRESS'; Email__FromName = Get-Setting 'SMTP_FROM_NAME' '千知万理'; AccountFrontend__BaseUrl = Get-Setting 'ACCOUNT_FRONTEND_BASE_URL'; ConnectionStrings__AuthDatabase = Get-Setting 'AUTH_DATABASE_CONNECTION' }
            }
        )

        foreach ($definition in $serviceDefinitions) {
            if (-not (Test-Path -LiteralPath $definition.File -PathType Leaf)) { throw "Runtime file is missing: $($definition.File)" }
            $arguments = if ($definition.ContainsKey('Arguments')) { [string]$definition.Arguments } else { '' }
            $processes += Start-ProductionProcess $definition.Name $definition.File $arguments $definition.Work $definition.Env $definition.Health $startupTimeout
            Write-ProcessManifest $processes
        }

        $gatewayEnvironment = @{
            NODE_ENV = 'production'; GATEWAY_HOST = '127.0.0.1'; GATEWAY_PORT = [string]$gatewayPort;
            GATEWAY_KEY = Get-Setting 'GATEWAY_KEY'; USER_SERVICE_KEY = Get-Setting 'USER_SERVICE_KEY'; AUTH_SERVICE_KEY = Get-Setting 'AUTH_SERVICE_KEY'; FILE_SERVICE_KEY = Get-Setting 'FILE_SERVICE_KEY'; KNOWLEDGE_SERVICE_KEY = Get-Setting 'KNOWLEDGE_SERVICE_KEY'; GALGAME_SERVICE_KEY = Get-Setting 'GALGAME_SERVICE_KEY'; RENDER_SERVICE_KEY = Get-Setting 'RENDER_SERVICE_KEY'; PRACTICE_SERVICE_KEY = Get-Setting 'PRACTICE_SERVICE_KEY'; CREDIT_SERVICE_KEY = Get-Setting 'CREDIT_SERVICE_KEY';
            USER_SERVICE_URL = 'http://127.0.0.1:5101'; AUTH_SERVICE_URL = 'http://127.0.0.1:5102'; FILE_SERVICE_URL = 'http://127.0.0.1:5103'; KNOWLEDGE_SERVICE_URL = 'http://127.0.0.1:5104'; GALGAME_SERVICE_URL = 'http://127.0.0.1:5105'; RENDER_SERVICE_URL = 'http://127.0.0.1:5106'; PRACTICE_SERVICE_URL = 'http://127.0.0.1:5107'; CREDIT_SERVICE_URL = 'http://127.0.0.1:5108';
            READINESS_SERVICES = 'userService,authService,fileService,knowledgeService,galGameService,renderService,practiceService,creditService'; DEFAULT_TIMEOUT_MS = Get-Setting 'DEFAULT_TIMEOUT_MS' '30000'; UPLOAD_TIMEOUT_MS = Get-Setting 'UPLOAD_TIMEOUT_MS' '120000'; TRUST_PROXY = Get-Setting 'TRUST_PROXY' 'loopback'; CORS_ORIGINS = Get-Setting 'CORS_ORIGINS'
        }
        $gatewayRoot = Join-Path $releaseRoot 'gateway'
        $processes += Start-ProductionProcess 'gateway' (Get-Command 'node').Source 'dist/index.js' $gatewayRoot $gatewayEnvironment "$gatewayBaseUrl/readyz" $startupTimeout
        Write-ProcessManifest $processes

        $publicFrontendUri = [Uri](Get-Setting 'ACCOUNT_FRONTEND_BASE_URL')
        $frontendEnvironment = @{ NODE_ENV = 'production'; HOST = $frontendBindAddress; PORT = [string]$frontendPort; GATEWAY_UPSTREAM = $gatewayBaseUrl; TRUST_REVERSE_PROXY = 'loopback'; PUBLIC_SCHEME = $publicFrontendUri.Scheme }
        $frontendRoot = Join-Path $releaseRoot 'frontend'
        $processes += Start-ProductionProcess 'frontend' (Get-Command 'node').Source 'server.mjs' $frontendRoot $frontendEnvironment "http://127.0.0.1:$frontendPort/healthz" $startupTimeout
        Write-ProcessManifest $processes
        $frontendDisplayUrl = if ($frontendBindAddress -eq '0.0.0.0') { Get-Setting 'ACCOUNT_FRONTEND_BASE_URL' } else { "http://127.0.0.1:$frontendPort" }
        Write-Host "Windows production site is ready at $frontendDisplayUrl" -ForegroundColor Green
    }
    catch {
        if ($processes.Count -gt 0) { Write-ProcessManifest $processes; Stop-ProductionServices }
        throw
    }
}

function Invoke-DeploymentAction {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Deploy', 'Build', 'Start', 'Stop', 'Restart', 'Status', 'Check', 'Proxy', 'Direct')]
        [string]$SelectedAction
    )

    switch ($SelectedAction) {
        'Direct' { Enable-DirectFrontendAccess; break }
        'Proxy' { Configure-IisReverseProxy; break }
        'Check' {
            $environmentPath = Resolve-ProjectPath $EnvironmentFile
            if (Test-Path -LiteralPath $environmentPath -PathType Leaf) {
                $script:settings = Read-EnvironmentFile $EnvironmentFile
            }
            $checkResult = Invoke-EnvironmentCheck -RequireInfrastructure:$RequireRunning
            if (-not $checkResult.Passed) {
                throw "Environment check reported $($checkResult.Failures) failure(s)."
            }
            break
        }
        'Status' { Show-ProductionStatus; break }
        'Stop' { Stop-ProductionServices; break }
        'Build' { [void](Build-ProductionRelease); break }
        'Start' {
            $script:settings = Read-EnvironmentFile $EnvironmentFile
            Start-ProductionServices
            break
        }
        'Restart' {
            $script:settings = Read-EnvironmentFile $EnvironmentFile
            Stop-ProductionServices
            Start-ProductionServices
            break
        }
        'Deploy' {
            $script:settings = Read-EnvironmentFile $EnvironmentFile
            Assert-ProductionSettings
            $checkResult = Invoke-EnvironmentCheck -RequireInfrastructure -Concise
            if (-not $checkResult.Passed) {
                throw "Production environment check reported $($checkResult.Failures) failure(s)."
            }
            $previousRelease = ''
            if (Test-Path -LiteralPath $currentReleasePath -PathType Leaf) {
                $candidate = (Get-Content -LiteralPath $currentReleasePath -Raw -Encoding utf8).Trim()
                if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
                    $previousRelease = [IO.Path]::GetFullPath($candidate)
                }
            }
            $previousWasRunning = Test-Path -LiteralPath $manifestPath -PathType Leaf
            $newRelease = Build-ProductionRelease
            Stop-ProductionServices
            try {
                Start-ProductionServices
            }
            catch {
                $deploymentError = $_
                if ($previousRelease -and $previousRelease -ne $newRelease) {
                    Set-Content -LiteralPath $currentReleasePath -Value $previousRelease -Encoding utf8
                    if ($previousWasRunning) {
                        Write-Warning "The new release failed. Attempting to restore $previousRelease."
                        try { Start-ProductionServices }
                        catch { Write-Warning "The previous release could not be restarted: $($_.Exception.Message)" }
                    }
                }
                throw $deploymentError
            }
            break
        }
    }
}

function Start-InteractiveMenu {
    $initialization = Initialize-ProductionEnvironment
    if ($initialization.Created -or $initialization.GeneratedKeyCount -gt 0) {
        if ($initialization.Created) {
            Write-Host '首次配置：已创建 .env.windows.production。' -ForegroundColor Cyan
        }
        else {
            Write-Host '已补全生产配置中的服务密钥。' -ForegroundColor Cyan
        }
        Write-Host "已自动生成 $($initialization.GeneratedKeyCount) 个独立的高强度服务密钥。" -ForegroundColor Green
        Write-Host '服务密钥无需修改；请继续填写 Neo4j 密码、域名和管理员信息。'
        if ($InitializeOnly) { return }
        Edit-ProductionEnvironment $initialization.Path
    }
    elseif ($InitializeOnly) {
        return
    }

    while ($true) {
        Clear-Host
        Write-Host '========================================' -ForegroundColor DarkCyan
        Write-Host '  千知万理 - Windows 正式环境管理' -ForegroundColor Cyan
        Write-Host '========================================' -ForegroundColor DarkCyan
        Write-Host
        Write-Host '  1. 首次部署 / 更新版本'
        Write-Host '  2. 启动当前版本'
        Write-Host '  3. 重启当前版本'
        Write-Host '  4. 查看运行状态'
        Write-Host '  5. 停止正式环境'
        Write-Host '  6. 仅构建生产版本'
        Write-Host '  7. 检查运行环境'
        Write-Host '  8. 编辑生产配置'
        Write-Host '  9. 一键配置 IIS 公网反向代理'
        Write-Host ' 10. 启动公网直连模式（端口 5120）'
        Write-Host '  0. 退出'
        Write-Host

        $choice = Read-Host '请选择操作'
        $selectedAction = switch ($choice) {
            '1' { 'Deploy' }
            '2' { 'Start' }
            '3' { 'Restart' }
            '4' { 'Status' }
            '5' { 'Stop' }
            '6' { 'Build' }
            '7' { 'Check' }
            '8' { Edit-ProductionEnvironment $initialization.Path; $null }
            '9' { 'Proxy' }
            '10' { 'Direct' }
            '0' { return }
            default { Write-Host '请输入 0 到 10 之间的数字。' -ForegroundColor Yellow; Wait-ForUser; $null }
        }
        if (-not $selectedAction) { continue }

        Write-Host
        Write-Host "正在执行：$selectedAction" -ForegroundColor Cyan
        Write-Host
        try {
            Invoke-DeploymentAction $selectedAction
            Write-Host
            Write-Host "$selectedAction 执行成功。" -ForegroundColor Green
        }
        catch {
            Write-Host
            Write-Host "操作失败：$($_.Exception.Message)" -ForegroundColor Red
            Write-Host '窗口会保持打开，请根据上方信息修正配置或依赖。' -ForegroundColor Yellow
        }
        Wait-ForUser
    }
}

Normalize-ProcessPath
New-Item -ItemType Directory -Force -Path $productionRoot, $releasesRoot, $logsRoot | Out-Null

if ($Action -eq 'Menu') {
    try { Start-InteractiveMenu }
    catch {
        Write-Host
        Write-Host "部署脚本无法继续：$($_.Exception.Message)" -ForegroundColor Red
        if (-not $InitializeOnly) { Wait-ForUser }
        exit 1
    }
}
else {
    Invoke-DeploymentAction $Action
}
