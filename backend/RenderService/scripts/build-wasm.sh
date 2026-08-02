#!/usr/bin/env sh
# Rebuilds the RenderService WASM reactor with emcc and refreshes the
# committed service/runtime.wasm.base64 artifact the HTTP shell serves.
# Requires emsdk 4.0.13+ (`emcc` on PATH).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="$root/build/wasm"
out="$out_dir/runtime.wasm"
mkdir -p "$out_dir"

exports='_initialize,_loadPackage,_startSession,_dispatchInput,_renderFrame,_serializeState,_getLastError,_dispose,_rtAbiVersion,_rtVersion,_rtAlloc,_rtFree'

emcc \
    "$root/src/core/json.cpp" \
    "$root/src/core/package.cpp" \
    "$root/src/core/runtime.cpp" \
    "$root/src/abi/render_abi.cpp" \
    -std=c++23 -Oz -flto --no-entry \
    -sSTANDALONE_WASM=1 -sALLOW_MEMORY_GROWTH=1 \
    "-sEXPORTED_FUNCTIONS=$exports" \
    -o "$out"

base64 -w0 "$out" > "$root/service/runtime.wasm.base64"
printf '\n' >> "$root/service/runtime.wasm.base64"
echo "runtime.wasm: $(wc -c < "$out") bytes"
echo "updated: $root/service/runtime.wasm.base64"
