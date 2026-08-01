-- Owner-root detection and every configuration-independent cache/install
-- path. Configuration-DEPENDENT paths (anything involving the target triplet
-- or target arch, e.g. gcc_prefix/stamp_file) live in settings.lua instead,
-- because they need value_or()/config lookups this module must not depend on.
--
-- Owner-root here is self-bootstrapped from the module's own location
-- (build_support/core/modules -> walk up to build_support -> its parent).
-- options.lua keeps a small independent description-scope copy of the same
-- walk because option() defaults are evaluated before any module can load;
-- that copy is the documented single exception, see options.lua.

import("base")
import("errors")

-- os.scriptdir() is only trustworthy at module load time (phase-0 spike);
-- capture it now.
local moduledir = os.scriptdir()

local function detect_owner_root()
    local current = path.absolute(moduledir)
    while current and current ~= "" do
        if path.filename(current) == "build_support" then
            return path.directory(current)
        end
        local parent = path.directory(current)
        if not parent or parent == current then
            break
        end
        current = parent
    end
    -- build_support was renamed/relocated in a way the walk cannot see;
    -- fall back to the project root rather than guessing further.
    return os.projectdir()
end

local owner_root_cache

function owner_root()
    if not owner_root_cache or owner_root_cache == "" then
        owner_root_cache = detect_owner_root()
    end
    return owner_root_cache
end

function toolchains_home()
    return path.join(owner_root(), ".toolchains")
end

local supported_toolchain_platforms = {
    windows = true,
    linux = true,
    android = true,
    macosx = true,
    ios = true,
    emscripten = true
}

function ensure_toolchain_platform(platform)
    if not supported_toolchain_platforms[platform] then
        errors.fail("unsupported toolchain platform folder: %s; supported folders are windows, linux, android, macosx, ios, emscripten", tostring(platform))
    end
    return platform
end

function toolchains_cache_root()
    return path.join(toolchains_home(), ".cache")
end

-- Host-keyed record of the configuration the user explicitly pinned via
-- `xmake toolchains pin`; the drift sentinel compares the active config
-- against it (see settings.warn_config_pin_drift).
function config_pin_file()
    return path.join(toolchains_home(), base.host_os() .. "-config.pin")
end

function toolchains_cache_dir(platform)
    return path.join(toolchains_cache_root(), ensure_toolchain_platform(platform))
end

function source_cache_dir()
    return path.join(toolchains_cache_dir(base.host_os()), "src")
end

function shared_source_cache_dir()
    return path.join(toolchains_cache_root(), "src")
end

function download_cache_dir()
    return path.join(toolchains_cache_dir(base.host_os()), "downloads")
end

function extract_cache_dir(name)
    return path.join(toolchains_cache_dir(base.host_os()), "extract", name)
end

function tools_cache_dir()
    return path.join(toolchains_cache_dir(base.host_os()), "tools")
end

function gcc_source_dir(cache_name)
    return path.join(shared_source_cache_dir(), cache_name or "gcc-mainline")
end

function wabt_source_dir()
    return path.join(shared_source_cache_dir(), "wabt-gcc-wasm")
end

-- Offline source-bundle store, shared across targets like the source cache
-- (bundles are keyed by cache name + revision, not by host or platform).
function bundles_cache_dir()
    return path.join(toolchains_cache_root(), "bundles")
end

function binutils_source_dir()
    return path.join(source_cache_dir(), "binutils")
end

function mingw_w64_source_dir()
    return path.join(source_cache_dir(), "mingw-w64")
end

function musl_source_dir()
    return path.join(source_cache_dir(), "musl")
end

local stale_counter = 0

function unique_cache_path(basepath, tag)
    stale_counter = stale_counter + 1
    local leaf = path.filename(basepath) or "path"
    leaf = leaf:gsub("[^%w%._%-]+", "_")
    local pid = (os.getpid and os.getpid()) or "process"
    return path.join(toolchains_cache_root(), tag or "tmp", tostring(os.time()) .. "-" .. tostring(pid) .. "-" .. tostring(stale_counter) .. "-" .. leaf)
end

local function ps_quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

function windows_remove_path(value)
    if not base.is_windows_host() then
        return false
    end
    -- deferred sibling import: hosttools depends on this module at its top
    -- level (smoke-test scratch dirs), so the reverse edge must stay inside
    -- the function body to avoid an import cycle
    local hosttools = import("hosttools", {rootdir = moduledir})
    local ps = hosttools.find_tool_path("pwsh") or hosttools.find_tool_path("powershell")
    if not ps then
        return false
    end
    local script = table.concat({
        "$ErrorActionPreference='Stop'",
        "$p=" .. ps_quote(value),
        "if(Test-Path -LiteralPath $p){",
        "  $i=Get-Item -LiteralPath $p -Force",
        "  $isReparse=($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0",
        "  if($isReparse){",
        "    if($i.PSIsContainer){[System.IO.Directory]::Delete($p,$false)}else{[System.IO.File]::Delete($p)}",
        "  }else{",
        "    Remove-Item -LiteralPath $p -Recurse -Force",
        "  }",
        "}"
    }, "; ")
    local ok = errors.trycall(function ()
        os.vrunv(ps, {"-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script})
        return true
    end)
    return ok and not os.exists(value)
end

function remove_toolchains_path(value)
    local root = base.normalized_path(toolchains_home())
    local target = base.normalized_path(value)
    if target ~= root and target:sub(1, #root + 1) ~= root .. "/" then
        errors.fail("refusing to remove path outside toolchains home: %s", value)
    end
    -- os.exists stat-FOLLOWS symlinks, so a dangling link reads as absent
    -- and would silently survive removal; a later copy onto the surviving
    -- link then writes through it to the (absolute) target path on the
    -- build host (seen live 2026-07-18 with the musl loader symlink on
    -- glibc hosts without /usr/lib/libc.so). os.rm removes dangling links,
    -- so treat links as existing here.
    if os.exists(value) or os.islink(value) then
        if base.is_windows_host() then
            local removed = windows_remove_path(value)
            if removed or not os.exists(value) then
                return
            end
        end
        local ok, removed = errors.trycall(function ()
            os.rm(value)
            return not os.exists(value)
        end)
        if (ok and removed) or not os.exists(value) then
            return
        end
        local stale = unique_cache_path(value, "stale")
        local moved = errors.trycall(function ()
            os.mkdir(path.directory(stale))
            os.mv(value, stale)
            return true
        end)
        if moved or not os.exists(value) then
            if os.exists(stale) then
                local cleaned = errors.trycall(function ()
                    os.rm(stale)
                    return true
                end)
                if not cleaned and os.exists(stale) then
                    print("warning: moved stale cache path out of the way, but could not delete it yet: " .. stale)
                end
            end
            return
        end
        errors.fail("cannot remove or quarantine cache path: %s", value)
    end
end
