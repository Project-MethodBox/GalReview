[CmdletBinding()]
param(
    [string]$ReciteHelperRoot = 'D:\Projects\ReciteHelper'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$targetRoot = Join-Path $projectRoot 'backend\PracticeService\Resources'
$runtimeResources = Join-Path $ReciteHelperRoot 'ReciteHelper.Wpf\bin\Debug\net10.0-windows7.0\Resources'
$licenseSource = Join-Path $ReciteHelperRoot 'LICENSE'
$licenseTarget = Join-Path $projectRoot 'backend\PracticeService\THIRD_PARTY_LICENSES\ReciteHelper.LICENSE'

if (-not (Test-Path -LiteralPath $runtimeResources -PathType Container)) {
    throw "ReciteHelper runtime resources were not found: $runtimeResources"
}

$expected = @{
    'Models\sbert.onnx' = '994a58868f7abacacbf2192aa0aae8f56da8c4505dbde2740c861b24426ede6b'
    'Models\xgboost_qvalue.onnx' = '53b563e2df2c6026f7a996b4d8f63e83c63bbf64d1dde5e03a3c7f9dbf688ea0'
    'vocab.txt' = '45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c'
    'tokenizer.json' = '754fbace50a65eb13073189fde35f561d96d630920b6a65bbf8dbadf9a4896c3'
}

foreach ($entry in $expected.GetEnumerator()) {
    $source = Join-Path $runtimeResources $entry.Key
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required ReciteHelper asset is missing: $source" }
    $actual = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $entry.Value) { throw "Hash mismatch for $($entry.Key): expected $($entry.Value), got $actual" }
}

New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
Get-ChildItem -LiteralPath $runtimeResources -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $targetRoot -Recurse -Force
}

if (-not (Test-Path -LiteralPath $licenseSource -PathType Leaf)) { throw "ReciteHelper license was not found: $licenseSource" }
New-Item -ItemType Directory -Path (Split-Path -Parent $licenseTarget) -Force | Out-Null
Copy-Item -LiteralPath $licenseSource -Destination $licenseTarget -Force

Write-Host "Imported and verified ReciteHelper runtime assets into $targetRoot"
Write-Host "Copied ReciteHelper AGPL-3.0 license to $licenseTarget"
