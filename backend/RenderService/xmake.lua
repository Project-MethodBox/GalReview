includes("build_support/cpp/xmake.lua")

-- RenderService 的交付物是浏览器 WebAssembly 运行时核心（contract.md §8.3）。
-- 默认平台显式定为 wasm，防止把宿主可执行文件误当成服务本体来构建；
-- 宿主平台（xmake f -p windows / linux / macosx）只用于单元自检与校验 CLI。
set_defaultplat("wasm")

add_rules("toolchains.auto", "gcc.features", "gcc.modules")
add_rules("mode.debug", "mode.release")

local runtime_exports = {
    "_initialize", "_loadPackage", "_startSession", "_dispatchInput",
    "_renderFrame", "_serializeState", "_getLastError", "_dispose",
    "_rtAbiVersion", "_rtVersion", "_rtAlloc", "_rtFree",
}

-- WASM reactor：仅核心 + ABI，无 main，导出 §8.3 冻结函数。
-- 直接用 emcc 构建的等价命令见 scripts/build-wasm.ps1（当前发布产物来源）。
target("GalReview.RenderService.Runtime")
    set_enabled(is_plat("wasm", "emscripten"))
    set_kind("binary")
    set_languages("clatest", "c++26")
    set_encodings("source:utf-8", "target:utf-8")
    set_warnings("allextra")
    add_files("src/core/**.cpp", "src/abi/**.cpp", {public = true})
    add_ldflags("-sSTANDALONE_WASM=1", "-sALLOW_MEMORY_GROWTH=1", "--no-entry",
                "-sEXPORTED_FUNCTIONS=" .. table.concat(runtime_exports, ","),
                {force = true})

-- 宿主自检二进制：核心 + ABI + 单元测试 + `--validate <file>` CLI。
-- Docker 构建阶段编译并执行它作为镜像门禁。
target("GalReview.RenderService")
    set_enabled(not is_plat("wasm", "emscripten"))
    set_kind("binary")
    set_languages("clatest", "c++26")
    set_encodings("source:utf-8", "target:utf-8")
    set_warnings("allextra")
    add_files("src/**.cpp", {public = true})
