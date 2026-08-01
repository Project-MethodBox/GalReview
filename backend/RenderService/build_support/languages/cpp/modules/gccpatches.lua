-- Project-local GCC source patches (C++-specific): libstdc++ std-module
-- fallback preservation, PE-COFF contracts default handler wiring, the
-- module-streaming fixes (PR c++/125334 backport, PR c++/118630 tolerance,
-- keyed-entity reader fix, WebAssembly empty-record ABI state, the
-- post_load_processing lazy-load re-entrancy guard and assert_definition
-- neutralization that fix the -Os module-recursion ICE / re-export re-install
-- assert -- PR c++/124542 relatives), Mach-O comdat linkage for both
-- module-attached and module-imported/CMI class data (duplicate std exception
-- typeinfo/vtable at -Os), x86_64 Android long-double/__float128 ABI collision
-- avoidance, and generated-file invalidation. Applied
-- idempotently after every source sync; anchors that disappear upstream
-- raise drift warnings instead of failing silently.
-- The patch families live in the patches/ directory (shared helpers plus
-- the wasm, darwin, ios, and mainline profile modules); this facade
-- sequences them and owns the stamp version and the hard postcondition
-- checkpoint.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("darwin", {rootdir = path.join(os.scriptdir(), "patches")})
import("ios", {rootdir = path.join(os.scriptdir(), "patches")})
import("mainline", {rootdir = path.join(os.scriptdir(), "patches")})
import("wasm", {rootdir = path.join(os.scriptdir(), "patches")})

-- Per-source-profile patch stamp. Each profile's number bumps only when a
-- patch that affects THAT profile's source tree changes, so a wasm-only patch
-- edit re-patches and rebuilds only the WebAssembly toolchain while the
-- mainline (windows/linux/android) and darwin (macOS/iOS) toolchains stay
-- valid -- a global number forced every toolchain to rebuild on any patch edit.
-- The marker lives inside the profile's own source tree and the install gate
-- (gccbuild.lua) compares the same profile's number, so the two never disagree.
-- Bump discipline: a change to a patch that touches more than one profile's
-- tree (mainline.lua, darwin.lua) bumps every profile it affects.
local PROFILE_PATCH_STAMP = {
    ["mainline"] = 70,
    ["darwin-arm64"] = 70,
    ["wasm-experimental"] = 71,
}

function source_patch_stamp_version(target_os)
    local name = settings.gcc_source_profile(target_os).name
    return PROFILE_PATCH_STAMP[name]
        or errors.fail("no source patch stamp registered for profile '%s'", tostring(name))
end

-- Highest stamp across every profile. The source-update cleanup removes every
-- historical marker name; a superset is always safe (removing an absent marker
-- is a no-op) and keeps that list target-independent.
function source_patch_stamp_max_version()
    local highest = 0
    for _, version in pairs(PROFILE_PATCH_STAMP) do
        if version > highest then
            highest = version
        end
    end
    return highest
end

function source_patch_marker_name(target_os)
    return ".xmake-gcc-source-patched-v" .. source_patch_stamp_version(target_os)
end

function patch_gcc_source(src, target_os)
    -- Cross-module per-run state travels through this explicit context
    -- table: xmake import() exposes only functions, never module data.
    local ctx = {
        src = src,
        target_os = target_os,
        flags = {
            wasm_freestanding_std_module_changed = false,
            wasm_freestanding_include_headers_changed = false
        },
        postconditions = {}
    }
    -- Order is behavior-critical: mainline.apply() consumes the wasm
    -- freestanding flags, so wasm.apply() must run first. darwin.apply()
    -- runs for every profile; its patches are anchor self-gated. ios.apply()
    -- is profile gated to darwin-arm64 trees and must follow darwin.apply():
    -- its libgcc case reuses the t-darwin-no-eh fragment file that
    -- darwin.apply() materializes.
    wasm.apply(ctx)
    darwin.apply(ctx)
    ios.apply(ctx)
    mainline.apply(ctx)

    -- Hard patch postconditions: re-read every functional patch's fingerprint
    -- from disk before the stamp is written. The apply-site drift warnings
    -- above give context, but only this checkpoint guarantees a stamped
    -- source tree actually carries the fixes -- a lost write or an upstream
    -- anchor drift fails the sync here instead of resurfacing later as a
    -- compiler defect. The bb2601808 ADL backport is intentionally absent:
    -- its anchor disappearing means upstream already contains the fix.
    mainline.register_postconditions(ctx)
    darwin.register_postconditions(ctx)
    ios.register_postconditions(ctx)
    wasm.register_postconditions(ctx)
    local postconditions = ctx.postconditions
    local unmet = {}
    for _, condition in ipairs(postconditions) do
        local file = path.join(src, condition.file)
        local content = os.isfile(file) and io.readfile(file) or nil
        if not content or (condition.fingerprint and not content:find(condition.fingerprint, 1, true)) then
            table.insert(unmet, string.format("%s (%s)", condition.what, condition.file))
        end
    end
    if #unmet > 0 then
        print("GCC source patch postconditions FAILED for this source tree:")
        for _, entry in ipairs(unmet) do
            print("  missing: " .. entry)
        end
        print("Upstream drift likely removed a patch anchor, so a required local fix no longer applies.")
        print("Check whether upstream already merged each fix; update or retire the patch in")
        print("build_support/languages/cpp/modules/gccpatches.lua, then bump the affected profile's entry in PROFILE_PATCH_STAMP.")
        errors.fail("GCC source patches did not fully apply: %d postcondition(s) unmet", #unmet)
    end
    base.writefile_bytes(path.join(src, source_patch_marker_name(target_os)), "ok\n")
end
