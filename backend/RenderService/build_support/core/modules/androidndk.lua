-- Single source of truth for Android SDK/NDK discovery, shared by the
-- toolchain family (languages/cpp/modules/targets/android.lua) and the APK
-- packaging family (android/modules/sdk.lua). The two families used to carry
-- diverging resolution chains (the toolchain side knew nothing about the SDK
-- ndk/ folder or android_ndk_version; the packaging side failed loudly where
-- the toolchain side fell through to nil), so the same machine could resolve
-- different NDKs per command family. Everything here is non-raising:
-- resolve() reports misconfiguration as data in `problems` so read-only
-- probes (status/matrix/preflight warnings) can consume it, while
-- root_or_fail() preserves the packaging family's loud-failure semantics.
--
-- NDK root resolution order, uniform for both families:
--   option android_ndk (settings.value_or also accepts an ANDROID_NDK
--   environment variable) > ANDROID_NDK_HOME > ANDROID_NDK_ROOT > NDK_HOME >
--   SDK ndk/<android_ndk_version match> > newest SDK ndk/ folder.

import("base")
import("errors")
import("settings")

-- ---------------------------------------------------------------------------
-- generic helpers (also consumed by android/modules/sdk.lua for the SDK
-- components that stay over there: build-tools, platforms, JDK)
-- ---------------------------------------------------------------------------

function first_dir(candidates)
    for _, candidate in ipairs(candidates) do
        if candidate and candidate ~= "" and os.isdir(candidate) then
            return candidate
        end
    end
end

-- "27.0.12077973" -> {27, 0, 12077973}; robust against partial values
local function version_parts(text)
    local parts = {}
    for part in tostring(text or ""):gmatch("%d+") do
        table.insert(parts, tonumber(part))
    end
    return parts
end

function version_less(a, b)
    local pa = version_parts(a)
    local pb = version_parts(b)
    for index = 1, math.max(#pa, #pb) do
        local va = pa[index] or 0
        local vb = pb[index] or 0
        if va ~= vb then
            return va < vb
        end
    end
    return false
end

function newest_subdir(root)
    if not root or not os.isdir(root) then
        return nil
    end
    local best
    for _, dir in ipairs(os.dirs(path.join(root, "*"))) do
        local name = path.filename(dir)
        if not best or version_less(best, name) then
            best = name
        end
    end
    return best and path.join(root, best) or nil
end

-- ---------------------------------------------------------------------------
-- SDK root
-- ---------------------------------------------------------------------------

-- Returns root (or nil), problem (or nil). A configured android_sdk pointing
-- nowhere is a problem, not a raise; the packaging family's forwarder turns
-- it back into the historical loud failure.
function sdk_root()
    local configured = settings.value_or("android_sdk", "")
    if configured ~= "" then
        if not os.isdir(configured) then
            return nil, {format = "android_sdk points to a path that is not a directory: %s", args = {configured}}
        end
        return configured, nil
    end
    for _, env in ipairs({"ANDROID_HOME", "ANDROID_SDK_ROOT"}) do
        local value = os.getenv(env)
        if value and value ~= "" and os.isdir(value) then
            return value, nil
        end
    end
    local host = base.host_os()
    local home = os.getenv("HOME") or ""
    if host == "windows" then
        local localappdata = os.getenv("LOCALAPPDATA") or ""
        return first_dir({path.join(localappdata, "Android", "Sdk")}), nil
    elseif host == "macosx" then
        return first_dir({path.join(home, "Library", "Android", "sdk")}), nil
    end
    return first_dir({path.join(home, "Android", "Sdk"), path.join(home, "Android", "sdk")}), nil
end

-- ---------------------------------------------------------------------------
-- NDK inventory
-- ---------------------------------------------------------------------------

function installed_ndk_versions()
    local versions = {}
    local root = sdk_root()
    if root then
        for _, dir in ipairs(os.dirs(path.join(root, "ndk", "*"))) do
            -- a valid NDK install carries source.properties with its revision
            if os.isfile(path.join(dir, "source.properties")) then
                table.insert(versions, path.filename(dir))
            end
        end
    end
    table.sort(versions, version_less)
    return versions
end

function ndk_version_of(ndk_dir)
    local properties = path.join(ndk_dir, "source.properties")
    if os.isfile(properties) then
        local content = io.readfile(properties) or ""
        return content:match("Pkg%.Revision%s*=%s*([%d%.]+)")
    end
end

-- ---------------------------------------------------------------------------
-- NDK root resolution
-- ---------------------------------------------------------------------------

-- Cached: flag/library composition re-resolves per makefile line during the
-- Android GCC patch passes, and neither options nor the environment can
-- change mid-process. `xmake android ndk install` never resolves before it
-- installs, so the cache cannot go stale within one command.
local _resolved

-- The single resolver. Returns {root, version, source, problems}:
--   root     absolute NDK root, or nil
--   version  Pkg.Revision from source.properties (folder name as fallback)
--   source   "option" | "env:<NAME>" | "sdk:version" | "sdk:newest" | nil
--   problems list of {format = ..., args = {...}} misconfiguration reports
-- Explicit path wins over version selection, version selection wins over
-- "newest installed". Never invents a path and never raises.
function resolve()
    if _resolved then
        return _resolved
    end
    local problems = {}
    local function resolved(root, version, source)
        _resolved = {root = root, version = version, source = source, problems = problems}
        return _resolved
    end
    local configured = tostring(settings.value_or("android_ndk", ""))
    if configured ~= "" then
        if not os.isdir(configured) then
            table.insert(problems, {format = "android_ndk points to a path that is not a directory: %s", args = {configured}})
            return resolved(nil, nil, "option")
        end
        local root = path.absolute(configured)
        return resolved(root, ndk_version_of(root), "option")
    end
    for _, env in ipairs({"ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "NDK_HOME"}) do
        local value = os.getenv(env)
        if value and value ~= "" then
            if not os.isdir(value) then
                table.insert(problems, {format = "android_ndk points to a path that is not a directory: %s", args = {value}})
                return resolved(nil, nil, "env:" .. env)
            end
            local root = path.absolute(value)
            return resolved(root, ndk_version_of(root), "env:" .. env)
        end
    end
    local sdk, sdk_problem = sdk_root()
    if sdk_problem then
        table.insert(problems, sdk_problem)
        return resolved(nil, nil, nil)
    end
    if sdk then
        local wanted = tostring(settings.value_or("android_ndk_version", ""))
        if wanted ~= "" then
            -- accept both exact folder names and loose prefixes ("27" / "27.0")
            local candidates = installed_ndk_versions()
            for index = #candidates, 1, -1 do
                local name = candidates[index]
                if name == wanted or name:sub(1, #wanted + 1) == wanted .. "." or name:sub(1, #wanted) == wanted then
                    local root = path.join(sdk, "ndk", name)
                    return resolved(root, ndk_version_of(root) or name, "sdk:version")
                end
            end
            table.insert(problems, {
                format = "android_ndk_version %s is not installed; installed: %s\nRun `xmake android ndk install %s` or `xmake android ndk list`",
                args = {wanted, table.concat(candidates, ", "), wanted}})
            return resolved(nil, nil, "sdk:version")
        end
        local newest = newest_subdir(path.join(sdk, "ndk"))
        if newest then
            return resolved(newest, ndk_version_of(newest) or path.filename(newest), "sdk:newest")
        end
    end
    return resolved(nil, nil, nil)
end

function root()
    return resolve().root
end

function version()
    return resolve().version
end

-- Loud-failure entry (the packaging family's historical semantics): a
-- recorded problem fails with its registered message; an NDK that is simply
-- absent still returns nil so status-style callers can report "(not found)".
function root_or_fail()
    local resolved = resolve()
    if #resolved.problems > 0 then
        local problem = resolved.problems[1]
        errors.fail(problem.format, table.unpack(problem.args))
    end
    return resolved.root
end

-- English rendering for warning aggregation (preflight/matrix); the loud
-- path in root_or_fail keeps the localizable format-string form.
function problem_text(problem)
    return string.format(problem.format, table.unpack(problem.args))
end

-- ---------------------------------------------------------------------------
-- NDK layout knowledge
-- ---------------------------------------------------------------------------

function host_tag()
    if base.host_os() == "windows" then
        return "windows-x86_64"
    elseif base.host_os() == "linux" then
        return "linux-x86_64"
    elseif base.host_os() == "macosx" then
        -- the NDK ships a single fat darwin prebuilt folder
        return "darwin-x86_64"
    end
end

function sysroot()
    local ndk = root()
    if not ndk then
        return nil
    end
    local tag = host_tag()
    if tag then
        local dir = path.join(ndk, "toolchains", "llvm", "prebuilt", tag, "sysroot")
        if os.isdir(dir) then
            return dir
        end
    end
    for _, candidate in ipairs(os.dirs(path.join(ndk, "toolchains", "llvm", "prebuilt", "*"))) do
        local dir = path.join(candidate, "sysroot")
        if os.isdir(dir) then
            return dir
        end
    end
end

function llvm_bin_dir()
    local ndk = root()
    if not ndk then
        return nil
    end
    local tag = host_tag()
    if tag then
        local bindir = path.join(ndk, "toolchains", "llvm", "prebuilt", tag, "bin")
        if os.isdir(bindir) then
            return bindir
        end
    end
    for _, bindir in ipairs(os.dirs(path.join(ndk, "toolchains", "llvm", "prebuilt", "*", "bin"))) do
        if os.isdir(bindir) then
            return bindir
        end
    end
end
