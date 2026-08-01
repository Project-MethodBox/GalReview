-- Shared installed-toolchain probing and configure bookkeeping
-- (C++-specific): compiler/runtime presence checks against the install
-- tree, the configure-signature composition shared by every component
-- configure, and the guarded build-directory reset. This is the lowest
-- shared layer of the target-provider split: gccbuild and every provider
-- under targets/ import it, so it must never import gccbuild, gcctargets,
-- gccstatus, gccwasm, or any target provider.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("gccsources")

-- Generic compiler probe. Providers may override this per target OS through
-- their compiler_exists hook (see gccbuild.compiler_exists for the dispatch);
-- this body is the default used when no override exists.
function compiler_exists(target_os)
    local triplet = settings.managed_target(target_os)
    local bindir = path.join(settings.gcc_prefix(target_os), "bin")
    if os.isfile(path.join(bindir, base.exe(triplet .. "-g++"))) then
        return true
    end
    -- The unprefixed fallback only proves a NATIVE install: for a cross
    -- target, a bare g++ in the (libc-flavor-shared) prefix is another
    -- flavor's native compiler, not ours -- a leftover native-gnu install
    -- once convinced the musl headers stage its cross compiler existed and
    -- routed it into a doomed configure (seen live 2026-07-17).
    return not settings.is_cross_target(target_os)
        and os.isfile(path.join(bindir, base.exe("g++")))
end

function target_libgcc_file(target_os)
    local prefix = settings.gcc_prefix(target_os)
    local triplet = settings.managed_target(target_os)
    local patterns = {
        path.join(prefix, "lib", "gcc", triplet, "*", "libgcc.a"),
        path.join(prefix, triplet, "lib", "libgcc.a"),
        path.join(settings.gcc_build_dir(target_os), triplet, "libgcc", "libgcc.a")
    }
    for _, pattern in ipairs(patterns) do
        local files = os.files(pattern)
        if #files > 0 then
            return files[1]
        end
    end
end

function target_static_libgcc_available(target_os)
    return target_libgcc_file(target_os) ~= nil
end

function installed_cxx_header(prefix, name)
    for _, version_dir in ipairs(os.dirs(path.join(prefix, "include", "c++", "*"))) do
        if os.isfile(path.join(version_dir, name)) then
            return true
        end
    end
    return #os.files(path.join(prefix, "**", "include", "c++", "*", name)) > 0
end

function installed_library(prefix, target_os, names)
    for _, libdir in ipairs({path.join(prefix, "lib"), path.join(prefix, settings.managed_target(target_os), "lib")}) do
        for _, name in ipairs(names) do
            if os.isfile(path.join(libdir, name)) then
                return true
            end
        end
    end
    for _, name in ipairs(names) do
        if #os.files(path.join(prefix, "**", name)) > 0 then
            return true
        end
    end
    return false
end

-- A failed std/std.compat module compile during the GCC build falls back to
-- an empty placeholder source (see gcc_patches.lua's
-- patch_libstdcxx_std_module_fallbacks) so the build itself doesn't abort;
-- the module still gets a real .gcm and consumers still successfully `import
-- std;`, but specific symbols never compiled into it (observed: "undefined
-- reference to std::basic_format_arg<...>::_M_handle_unrecognized() const").
-- toolchain_installed() previously only checked for the presence of
-- libstdc++.a/meta headers, so a toolchain cached from a run that hit this
-- fallback stays silently broken across every later run using the same
-- cache key (the fallback never gets re-detected because build_gcc_for,
-- where the detection lives, is skipped whenever the cached toolchain looks
-- "installed"). Mirrors libstdcxx_std_module_source_valid's conservative
-- check: a missing file is not proof of a problem, only a present-but-marker-less
-- one is.
function installed_std_module_valid(prefix)
    for _, entry in ipairs({
        {source = "std.cc", marker = "export module std;"},
        {source = "std.compat.cc", marker = "export module std.compat;"}
    }) do
        for _, version_dir in ipairs(os.dirs(path.join(prefix, "include", "c++", "*"))) do
            local file = path.join(version_dir, "bits", entry.source)
            if os.isfile(file) then
                local ok, content = errors.trycall(function ()
                    return io.readfile(file)
                end)
                if not ok or not content or not content:find(entry.marker, 1, true) then
                    return false
                end
            end
        end
    end
    return true
end

-- Default installed-runtime completeness check shared by every target OS
-- without an installed_extra provider override.
function installed_runtime_complete(target_os)
    local prefix = settings.gcc_prefix(target_os)
    local has_meta = installed_cxx_header(prefix, "meta")
    local has_libstdcxx = installed_library(prefix, target_os, {"libstdc++.a", "libstdc++.so", "libstdc++.dll.a"})
    return has_meta and has_libstdcxx and installed_std_module_valid(prefix)
end

function reset_build_dir(build)
    local root = base.normalized_path(layout.toolchains_cache_root())
    local target = base.normalized_path(build)
    if target:sub(1, #root + 1) ~= root .. "/" then
        errors.fail("refusing to remove unexpected GCC build directory: %s", build)
    end
    print("reconfiguring GCC build directory: " .. build)
    os.rm(build)
end

-- `extra` carries per-target signature lines supplied by the provider's
-- signature_extra hook (for example the emscripten wasm capability); it is
-- inserted exactly where the old inline target_os branch appended it.
function configure_signature(args, target_os, source_root, extra)
    local source_signature = ""
    if source_root then
        source_signature = "source_root=" .. base.normalized_path(source_root) .. "\n"
        if settings.uses_darwin_arm64_gcc(target_os) then
            source_signature = source_signature .. "source_revision=" ..
                gccsources.managed_toolchains_gcc_source_revision(source_root) .. "\n"
        end
    end
    if extra and extra ~= "" then
        source_signature = source_signature .. extra
    end
    return table.concat(args, "\n") .. "\n" .. source_signature .. settings.build_config_signature(target_os)
end

function remove_empty_archives(root)
    local count = 0
    for _, archive in ipairs(os.files(path.join(root, "**", "*.a"))) do
        if os.filesize and os.filesize(archive) == 0 then
            os.rm(archive)
            count = count + 1
        end
    end
    if count > 0 then
        print(string.format("removed %d empty archive file(s) left by an interrupted build", count))
    end
end
