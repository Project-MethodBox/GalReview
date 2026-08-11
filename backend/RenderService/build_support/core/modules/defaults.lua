-- Single machine-readable source for every pinned upstream URL/version the
-- managed toolchains use. Modules import this; the ONE remaining textual
-- mirror is build_support/languages/cpp/options.lua, whose option defaults
-- must evaluate before any module can load (the documented description-scope
-- bootstrap exception) -- check_options_file() below keeps that mirror
-- honest at configure time instead of trusting comments.

import("errors")

local DEFAULTS = {
    -- pinned gcc master snapshot 2026-07-07; see the bump protocol note in
    -- options.lua next to default_ref
    ref = "4790838765e8a4b0580b11ba0d8c6671d7c3fc95",
    gcc_git_url = "https://github.com/gcc-mirror/gcc.git",
    -- pinned master-wip-apple-si revision validated end-to-end on the macOS
    -- test host 2026-07-11 (toolchain build + engine test targets green).
    -- The upstream branch is a rebased work-in-progress line, so a floating
    -- name can silently move or even lose this exact revision; see the bump
    -- protocol note in options.lua next to default_darwin_arm64_gcc_ref.
    darwin_arm64_gcc_ref = "f4e36f15b1ce1c46926f9cbce847625336d01615",
    darwin_arm64_gcc_git_url = "https://github.com/iains/gcc-darwin-arm64.git",
    darwin_arm64_gcc_tracking_branch = "master-wip-apple-si",
    -- iOS minimum deployment target (owner decision, phase E1): the common
    -- App Store floor. Single source for the ios_deployment_target option
    -- default AND the ios patch family's config.gcc fallback -- the patch
    -- module reads this value; do not fork the literal there.
    ios_deployment_target = "15.0",
    -- The WebAssembly line was ported onto GCC master on 2026-08-12 and now
    -- TRACKS mainline instead of consuming a pinned upstream revision, so the
    -- pin below is a commit of that line itself and exists on no public
    -- remote: the URL keeps pointing at the upstream fork it descends from
    -- (whose branch still sits at the old revision), and the pinned commit is
    -- restored from the local git bundle in .toolchains/.cache/bundles --
    -- exactly the offline channel bundles were added for. Seed that bundle on
    -- a new machine before the first sync, or the fetch has nowhere to go.
    wasm_gcc_ref = "ee5f1859289f4ebc80d6a302e40893235f3c92ae",
    wasm_gcc_git_url = "https://forge.sourceware.org/feedable/gcc-TEST.git",
    wasm_wabt_ref = "f2d60b0532f35e13f86899f0581ab87fc029db36",
    wasm_wabt_git_url = "https://github.com/feedab1e/wabt.git",
    binutils_snapshot_url = "https://ftp.gnu.org/gnu/binutils/binutils-2.45.tar.xz",
    mingw_w64_snapshot_url = "https://downloads.sourceforge.net/project/mingw-w64/mingw-w64/mingw-w64-release/mingw-w64-v14.0.0.tar.bz2",
    musl_snapshot_url = "https://musl.libc.org/releases/musl-1.2.5.tar.gz",
    m4_url = "https://ftp.gnu.org/gnu/m4/m4-1.4.19.tar.xz",
    flex_url = "https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz",
    winflexbison_url = "https://github.com/lexxmark/winflexbison/releases/download/v2.5.25/win_flex_bison-2.5.25.zip",
    winflexbison_package = "winflexbison",
    windows_bootstrap_url = "latest",
    -- pinned known-good release used when the GitHub "latest" API is
    -- unreachable or rate-limited (unauthenticated CI/shared IPs often are)
    windows_bootstrap_fallback_url_x64 = "https://github.com/skeeto/w64devkit/releases/download/v2.8.0/w64devkit-x64-2.8.0.7z.exe",
    windows_bootstrap_fallback_url_x86 = "https://github.com/skeeto/w64devkit/releases/download/v2.8.0/w64devkit-x86-2.8.0.7z.exe",
    gcc_prerequisites_base_url = "https://gcc.gnu.org/pub/gcc/infrastructure",
    mingw_msvcrt = "msvcrt",
    -- pinned managed Emscripten toolset (languages/cpp/modules/gccemsdk.lua):
    -- emcc is only the final linker/runtime driver, but hosted libstdc++ is
    -- configured against its sysroot, so the whole archive set is pinned.
    -- 4.0.13 is the locally end-to-end validated release (2026-07-17); the
    -- releases hash comes from emsdk emscripten-releases-tags.json for that
    -- version. node/python versions mirror what upstream pairs with 4.0.13.
    -- Bump protocol: revalidate the emcc final-link smoke on one host, then
    -- update these pins AND re-establish the archive digests in checksums.lua.
    emscripten_version = "4.0.13",
    emscripten_releases_hash = "32b8ae819674cb42b8ac2191afeb9571e33ad5e2",
    emscripten_node_version = "22.16.0",
    emscripten_win_python_version = "3.13.3-0",
    emscripten_releases_base_url = "https://storage.googleapis.com/webassembly/emscripten-releases-builds",
    -- node comes from the official dist channel (signed SHASUMS256 manifest)
    -- rather than the emsdk mirror, so its digests carry the stronger
    -- assurance tier; see the checksums.lua via notes.
    emscripten_node_base_url = "https://nodejs.org/dist",
    -- managed glibc sysroot version set (languages/cpp/modules/gccglibc.lua).
    -- Policy (owner-approved 2026-07-17): the supported set carries an older
    -- distro-baseline release, a mid rung, and the latest stable release;
    -- auto resolution follows the host glibc on Linux hosts (closest
    -- supported <= host) and uses glibc_default_version elsewhere.
    --   2.39 -- baseline: Ubuntu 24.04 LTS / Fedora 40 ABI floor
    --   2.41 -- mid rung: Debian 13 (trixie) / Ubuntu 25.04
    --   2.43 -- latest stable (2026-02); exact match for the Linux test host
    -- Kernel UAPI headers come from ONE pinned kernel.org first-party full
    -- source archive shared by every entry (6.12 LTS: the Debian 13-era
    -- line; headers_install needs no configuration and newer-than-glibc
    -- headers are always acceptable). Bump protocol: revalidate the full
    -- kernel-headers -> stage1 GCC -> glibc pipeline on a Linux host, then
    -- update these pins AND re-establish the archive digests in checksums.lua.
    glibc_default_version = "2.43",
    glibc_versions = {
        ["2.39"] = {
            url = "https://ftp.gnu.org/gnu/libc/glibc-2.39.tar.xz",
            kernel_headers_url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.95.tar.xz"
        },
        ["2.41"] = {
            url = "https://ftp.gnu.org/gnu/libc/glibc-2.41.tar.xz",
            kernel_headers_url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.95.tar.xz"
        },
        ["2.43"] = {
            url = "https://ftp.gnu.org/gnu/libc/glibc-2.43.tar.xz",
            kernel_headers_url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.95.tar.xz"
        }
    },
}

-- xmake import() exposes only FUNCTIONS to importers (data globals are
-- invisible -- verified empirically), so the constants live in a local
-- table behind this getter; consumers bind it once at module top:
--   local defaults = import("defaults", {rootdir = ...}).values()
function values()
    return DEFAULTS
end


-- options.lua text patterns -> the module value each literal must equal
-- (values bind at module load; the definitions above run first)
local OPTIONS_MIRROR = {
    {pattern = 'default_ref%s*=%s*"([^"]*)"',                          field = "ref",                              value = DEFAULTS.ref},
    {pattern = 'default_gcc_git_url%s*=%s*"([^"]*)"',                  field = "gcc_git_url",                      value = DEFAULTS.gcc_git_url},
    {pattern = 'default_darwin_arm64_gcc_ref%s*=%s*"([^"]*)"',        field = "darwin_arm64_gcc_ref",             value = DEFAULTS.darwin_arm64_gcc_ref},
    {pattern = 'default_darwin_arm64_gcc_git_url%s*=%s*"([^"]*)"',    field = "darwin_arm64_gcc_git_url",          value = DEFAULTS.darwin_arm64_gcc_git_url},
    {pattern = 'default_ios_deployment_target%s*=%s*"([^"]*)"',       field = "ios_deployment_target",            value = DEFAULTS.ios_deployment_target},
    {pattern = 'default_wasm_gcc_ref%s*=%s*"([^"]*)"',                field = "wasm_gcc_ref",                     value = DEFAULTS.wasm_gcc_ref},
    {pattern = 'default_wasm_gcc_git_url%s*=%s*"([^"]*)"',            field = "wasm_gcc_git_url",                 value = DEFAULTS.wasm_gcc_git_url},
    {pattern = 'default_wasm_wabt_ref%s*=%s*"([^"]*)"',               field = "wasm_wabt_ref",                    value = DEFAULTS.wasm_wabt_ref},
    {pattern = 'default_wasm_wabt_git_url%s*=%s*"([^"]*)"',           field = "wasm_wabt_git_url",                value = DEFAULTS.wasm_wabt_git_url},
    {pattern = 'default_binutils_snapshot_url%s*=%s*"([^"]*)"',        field = "binutils_snapshot_url",            value = DEFAULTS.binutils_snapshot_url},
    {pattern = 'default_mingw_w64_snapshot_url%s*=%s*"([^"]*)"',       field = "mingw_w64_snapshot_url",           value = DEFAULTS.mingw_w64_snapshot_url},
    {pattern = 'default_musl_snapshot_url%s*=%s*"([^"]*)"',            field = "musl_snapshot_url",                value = DEFAULTS.musl_snapshot_url},
    {pattern = 'default_m4_url%s*=%s*"([^"]*)"',                       field = "m4_url",                           value = DEFAULTS.m4_url},
    {pattern = 'default_flex_url%s*=%s*"([^"]*)"',                     field = "flex_url",                         value = DEFAULTS.flex_url},
    {pattern = 'winflexbison_url%s*=%s*"([^"]*)"',                     field = "winflexbison_url",                 value = DEFAULTS.winflexbison_url},
    {pattern = 'winflexbison_package%s*=%s*"([^"]*)"',                 field = "winflexbison_package",             value = DEFAULTS.winflexbison_package},
    {pattern = 'windows_bootstrap_url%s*=%s*"([^"]*)"',                field = "windows_bootstrap_url",            value = DEFAULTS.windows_bootstrap_url},
    {pattern = 'windows_bootstrap_fallback_url_x64%s*=%s*"([^"]*)"',   field = "windows_bootstrap_fallback_url_x64", value = DEFAULTS.windows_bootstrap_fallback_url_x64},
    {pattern = 'windows_bootstrap_fallback_url_x86%s*=%s*"([^"]*)"',   field = "windows_bootstrap_fallback_url_x86", value = DEFAULTS.windows_bootstrap_fallback_url_x86},
    {pattern = 'gcc_prerequisites_base_url%s*=%s*"([^"]*)"',           field = "gcc_prerequisites_base_url",       value = DEFAULTS.gcc_prerequisites_base_url},
    {pattern = 'mingw_msvcrt%s*=%s*"([^"]*)"',                         field = "mingw_msvcrt",                     value = DEFAULTS.mingw_msvcrt},
}

local checked

-- Compares the literals inside the given options.lua against this module and
-- warns loudly on any divergence (once per process). A mismatch means option
-- defaults and module behavior silently disagree -- exactly the drift the
-- old keep-in-sync comments could not catch.
function check_options_file(options_file)
    if checked then
        return
    end
    checked = true
    local content = io.readfile(options_file)
    if not content then
        errors.warn("defaults consistency check could not read %s", tostring(options_file))
        return
    end
    local mismatches = {}
    for _, entry in ipairs(OPTIONS_MIRROR) do
        local literal = content:match(entry.pattern)
        local expected = entry.value
        if literal == nil then
            table.insert(mismatches, string.format("%s: literal not found in options.lua", entry.field))
        elseif literal ~= expected then
            table.insert(mismatches, string.format('%s: options.lua has "%s" but core/modules/defaults.lua has "%s"',
                entry.field, literal, tostring(expected)))
        end
    end
    if #mismatches > 0 then
        errors.warn("build_support default constants have drifted between options.lua and core/modules/defaults.lua:\n  %s",
            table.concat(mismatches, "\n  "))
    end
end
