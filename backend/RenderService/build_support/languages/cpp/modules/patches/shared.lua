-- Shared helpers for the profile-split GCC source patch modules: the strict
-- anchor-pinned replace/write primitives, the drift warning, and the
-- build-directory discovery used by cross-tree invalidation. Every stateful
-- helper receives the patch context table built by
-- gccpatches.patch_gcc_source (xmake import() exposes only functions to
-- importers, so per-run state travels through the explicit ctx argument
-- instead of module globals).

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("hosttools", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})

function isolated_source_profile(ctx)
    return ctx.target_os and settings.gcc_source_profile(ctx.target_os).name ~= "mainline"
end

-- True for a cache path under a build tree that an ISOLATED source profile
-- owns: those trees are configured against their own source fork
-- (emscripten/* -> gcc-wasm-experimental, macosx|ios/arm64 ->
-- gcc-darwin-arm64) and get their own patch run, so a mainline-tree patch
-- pass must leave them alone. Touching them is not merely wasted work: it
-- deletes objects and generated files a correct, up-to-date foreign build
-- tree still needs, forcing a needless recompile on its next build.
local function owned_by_isolated_profile(file)
    local relative = path.relative(file, layout.toolchains_cache_root()):gsub("\\", "/")
    local platform, arch = relative:match("^[^/]+/([^/]+)/([^/]+)/")
    return platform == "emscripten"
        or ((platform == "macosx" or platform == "ios") and arch == "arm64")
end

local function mainline_dependent_paths(pattern)
    local kept = {}
    for _, entry in ipairs(pattern) do
        if not owned_by_isolated_profile(entry) then
            table.insert(kept, entry)
        end
    end
    return kept
end

function dependent_gcc_compiler_build_dirs(ctx)
    if isolated_source_profile(ctx) then
        local gccdir = path.join(settings.gcc_build_dir(ctx.target_os), "gcc")
        return os.isdir(gccdir) and {gccdir} or {}
    end
    return mainline_dependent_paths(
        os.dirs(path.join(layout.toolchains_cache_root(), "*", "*", "*", "build", "gcc", "gcc")))
end

-- The isolated branch inspects only the build tree of the requested profile.
-- The non-isolated (mainline) branch skips the build directories owned by
-- isolated source profiles: those builds materialize cp-demangle.c from their
-- own source fork, so comparing their copies against the mainline libiberty
-- file would flag a correct copy as stale, delete it, and force a needless
-- recompile of this unusually expensive translation unit on every mainline
-- patch run.
function dependent_stale_demangle_files(ctx)
    if isolated_source_profile(ctx) then
        return os.files(path.join(settings.gcc_build_dir(ctx.target_os), "*", "libstdc++-v3", "**", "cp-demangle.c"))
    end
    return mainline_dependent_paths(os.files(path.join(layout.toolchains_cache_root(),
        "*", "*", "*", "build", "gcc", "*", "libstdc++-v3", "**", "cp-demangle.c")))
end

-- Soft counterpart of strict_replace's hard failure, for patches that edit a
-- region in place and can only report afterwards whether the edit took. Used
-- by the mainline, darwin and ios families; a reference sweep that only looks
-- at the wasm profile will wrongly read it as unreferenced.
function warn_patch_drift(text, marker, what, consequence)
    if not text:find(marker, 1, true) then
        print("WARNING: GCC source patch anchor not found (upstream drift): " .. what)
        print("         The local fix is NOT applied to this source tree. " .. consequence)
        print("         Check whether upstream already fixed the issue; then update or retire the patch in build_support.")
    end
end

function strict_replace(ctx, file, original, replacement, label)
    if not os.isfile(file) then
        errors.fail("cannot apply %s: source file is missing: %s", label, file)
    end
    local content = io.readfile(file)
    if content:find(replacement, 1, true) then
        return
    end
    local begin_pos = content:find(original, 1, true)
    if not begin_pos then
        errors.fail("cannot apply %s: the pinned upstream anchor drifted in %s", label, file)
    end
    if content:find(original, begin_pos + #original, true) then
        errors.fail("cannot apply %s: the upstream anchor is ambiguous in %s", label, file)
    end
    print("patching " .. label .. ": " .. path.relative(file, ctx.src))
    base.writefile_bytes(file, base.replace_plain(content, original, replacement))
end

function remove_exact_patch(ctx, file, patch, label)
    if not os.isfile(file) then
        errors.fail("cannot migrate %s: source file is missing: %s", label, file)
    end
    local content = io.readfile(file)
    local begin_pos = content:find(patch, 1, true)
    if not begin_pos then
        return
    end
    if content:find(patch, begin_pos + #patch, true) then
        errors.fail("cannot migrate %s: the project-owned patch is ambiguous in %s", label, file)
    end
    print("migrating " .. label .. ": " .. path.relative(file, ctx.src))
    base.writefile_bytes(file, base.replace_plain(content, patch, ""))
end

function strict_replace_migrated(ctx, file, original, previous, replacement, label)
    local content = io.readfile(file)
    if content:find(replacement, 1, true) then
        return
    end
    if previous and content:find(previous, 1, true) then
        strict_replace(ctx, file, previous, replacement, label .. " migration")
        return
    end
    strict_replace(ctx, file, original, replacement, label)
end

function strict_write_new(ctx, file, content, label)
    if os.isfile(file) then
        if io.readfile(file) == content then
            return
        end
        errors.fail("cannot apply %s: an upstream file already exists with different content: %s", label, file)
    end
    print("writing " .. label .. ": " .. path.relative(file, ctx.src))
    base.writefile_bytes(file, content)
end

function strict_write_owned(ctx, file, content, ownership_marker, label)
    if not os.isfile(file) then
        print("writing " .. label .. ": " .. path.relative(file, ctx.src))
        base.writefile_bytes(file, content)
        return
    end
    local previous = io.readfile(file)
    if previous == content then
        return
    end
    if not previous:find(ownership_marker, 1, true)
        or not content:find(ownership_marker, 1, true) then
        errors.fail("cannot update %s: an unowned file exists at %s", label, file)
    end
    print("updating " .. label .. ": " .. path.relative(file, ctx.src))
    base.writefile_bytes(file, content)
end
