# Rebuilds the RenderService WASM reactor with emcc and refreshes the
# committed service/runtime.wasm.base64 artifact the HTTP shell serves.
# Requires emsdk 4.0.13+ (`emcc` on PATH). Equivalent xmake lane:
#   xmake f -p wasm && xmake build GalReview.RenderService.Runtime
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'build/wasm'
$out = Join-Path $outDir 'runtime.wasm'
New-Item -ItemType Directory -Force $outDir | Out-Null

$sources = @(
    'src/core/json.cpp',
    'src/core/package.cpp',
    'src/core/runtime.cpp',
    'src/abi/render_abi.cpp'
) | ForEach-Object { Join-Path $root $_ }

$exports = @(
    '_initialize', '_loadPackage', '_startSession', '_dispatchInput',
    '_renderFrame', '_serializeState', '_getLastError', '_dispose',
    '_rtAbiVersion', '_rtVersion', '_rtAlloc', '_rtFree'
) -join ','

emcc @sources -std=c++23 -Oz -flto --no-entry `
    -sSTANDALONE_WASM=1 -sALLOW_MEMORY_GROWTH=1 `
    "-sEXPORTED_FUNCTIONS=$exports" `
    -o $out
if ($LASTEXITCODE -ne 0) { throw "emcc failed with exit code $LASTEXITCODE" }

$bytes = [IO.File]::ReadAllBytes($out)
$base64Path = Join-Path $root 'service/runtime.wasm.base64'
[IO.File]::WriteAllText($base64Path, [Convert]::ToBase64String($bytes) + "`n")

$hash = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
Write-Host "runtime.wasm: $($bytes.Length) bytes, sha256 $hash"
Write-Host "updated: $base64Path"
