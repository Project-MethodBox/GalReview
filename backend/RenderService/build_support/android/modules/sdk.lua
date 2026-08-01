-- Android SDK/NDK/JDK discovery and version management for the APK pipeline.
-- Everything resolves lazily and reports precisely what is missing; nothing
-- here silently falls back to a nonexistent path (see the gcc-ndk-compat.h
-- incident: composed paths must exist or fail loudly at the point of use).
--
-- Resolution priority, uniform for every component:
--   explicit option/config value > conventional environment variables >
--   conventional install locations > absent (nil + guidance).
--
-- SDK/NDK discovery itself lives in core/modules/androidndk.lua (one
-- resolver shared with the toolchain family in
-- languages/cpp/modules/targets/android.lua); the forwarders below only add
-- back this family's loud-failure semantics. JDK, build-tools, platforms,
-- and installer knowledge stays owned here.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("download", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("androidndk", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})

local moduledir = os.scriptdir()

-- ---------------------------------------------------------------------------
-- generic helpers (shared implementations live in androidndk)
-- ---------------------------------------------------------------------------

local function first_dir(candidates)
    return androidndk.first_dir(candidates)
end

local function newest_subdir(root)
    return androidndk.newest_subdir(root)
end

-- ---------------------------------------------------------------------------
-- SDK root
-- ---------------------------------------------------------------------------

function sdk_root()
    local root, problem = androidndk.sdk_root()
    if problem then
        errors.fail(problem.format, table.unpack(problem.args))
    end
    return root
end

local function sdk_root_or_fail()
    local root = sdk_root()
    if not root then
        errors.fail("cannot locate an Android SDK; set --android_sdk=<path> or export ANDROID_HOME")
    end
    return root
end

-- ---------------------------------------------------------------------------
-- NDK: list / resolve / install
-- ---------------------------------------------------------------------------

function installed_ndk_versions()
    return androidndk.installed_ndk_versions()
end

function ndk_version_of(ndk_dir)
    return androidndk.ndk_version_of(ndk_dir)
end

-- Explicit path wins over version selection, version selection wins over
-- "newest installed". Never invents a path; misconfiguration fails loudly.
function ndk_root()
    return androidndk.root_or_fail()
end

function ndk_host_tag()
    return androidndk.host_tag()
end

function ndk_llvm_bin_dir()
    if not ndk_root() then
        return nil
    end
    return androidndk.llvm_bin_dir()
end

function ndk_tool(name)
    local bin = ndk_llvm_bin_dir()
    if bin then
        local tool = path.join(bin, base.exe(name))
        if os.isfile(tool) then
            return tool
        end
    end
end

-- sdkmanager first (respects SDK licensing state), official archive second.
-- Official archives are keyed by release name (r27c), not by the numeric
-- folder version, so the fallback only accepts that form.
function ndk_install(version)
    if not version or version == "" then
        errors.fail("usage: xmake android ndk install <version>; e.g. 27.0.12077973 (sdkmanager) or r27c (official archive)")
    end
    local sdk = sdk_root_or_fail()
    if not version:match("^r%d+") then
        local manager = sdkmanager_command()
        if manager then
            errors.log("installing NDK " .. version .. " through sdkmanager")
            local args = table.join(manager.args, {"--install", "ndk;" .. version})
            local ok = errors.trycall(function ()
                os.execv(manager.program, args)
            end)
            if ok and os.isdir(path.join(sdk, "ndk", version)) then
                return path.join(sdk, "ndk", version)
            end
            errors.warn("sdkmanager could not install ndk;%s; falling back to the official archive needs a release name like r27c", version)
        end
        errors.fail("cannot install NDK %s: sdkmanager unavailable or failed; retry with a release name (e.g. r27c) to pull the official archive", version)
    end
    local host = base.host_os()
    local platform_name = host == "windows" and "windows" or (host == "macosx" and "darwin" or "linux")
    local url = string.format("https://dl.google.com/android/repository/android-ndk-%s-%s.zip", version, platform_name)
    local staging = path.join(layout.toolchains_cache_root(), "android", "ndk-" .. version)
    local archive = path.join(layout.download_cache_dir(), string.format("android-ndk-%s-%s.zip", version, platform_name))
    download.download_and_extract_archive(url, archive, staging)
    -- the archive expands to a single android-ndk-<version> folder
    local extracted = os.dirs(path.join(staging, "android-ndk-*"))[1]
    if not extracted then
        errors.fail("downloaded NDK archive did not contain an android-ndk-* folder: %s", staging)
    end
    local folder_version = ndk_version_of(extracted) or version
    local destination = path.join(sdk, "ndk", folder_version)
    if not os.isdir(destination) then
        os.mkdir(path.directory(destination))
        os.mv(extracted, destination)
    end
    return destination
end

-- ---------------------------------------------------------------------------
-- build-tools / platforms / platform-tools
-- ---------------------------------------------------------------------------

function build_tools_dir()
    local sdk = sdk_root()
    if not sdk then
        return nil
    end
    local wanted = tostring(settings.value_or("android_build_tools", ""))
    if wanted ~= "" then
        local dir = path.join(sdk, "build-tools", wanted)
        if not os.isdir(dir) then
            errors.fail("android_build_tools %s is not installed; installed: %s", wanted,
                table.concat(table.imap(os.dirs(path.join(sdk, "build-tools", "*")), function (_, d) return path.filename(d) end), ", "))
        end
        return dir
    end
    return newest_subdir(path.join(sdk, "build-tools"))
end

function build_tool(name)
    local dir = build_tools_dir()
    if not dir then
        return nil
    end
    local tool = path.join(dir, base.exe(name))
    if os.isfile(tool) then
        return tool
    end
end

-- apksigner ships as a launcher script; invoking its jar through the JDK
-- avoids .bat interpreter indirection on Windows entirely.
function apksigner_jar()
    local dir = build_tools_dir()
    if not dir then
        return nil
    end
    local jar = path.join(dir, "lib", "apksigner.jar")
    if os.isfile(jar) then
        return jar
    end
end

function platform_jar(api)
    local sdk = sdk_root()
    if not sdk then
        return nil
    end
    local exact = path.join(sdk, "platforms", "android-" .. tostring(api), "android.jar")
    if os.isfile(exact) then
        return exact
    end
    local newest = newest_subdir(path.join(sdk, "platforms"))
    if newest then
        local jar = path.join(newest, "android.jar")
        if os.isfile(jar) then
            errors.warn("platforms/android-%s is not installed; linking against %s instead", tostring(api), path.filename(newest))
            return jar
        end
    end
end

function adb()
    local sdk = sdk_root()
    if sdk then
        local tool = path.join(sdk, "platform-tools", base.exe("adb"))
        if os.isfile(tool) then
            return tool
        end
    end
end

function emulator()
    local sdk = sdk_root()
    if sdk then
        local tool = path.join(sdk, "emulator", base.exe("emulator"))
        if os.isfile(tool) then
            return tool
        end
    end
end

function sdkmanager_command()
    local sdk = sdk_root()
    if not sdk then
        return nil
    end
    local java_program = java()
    local cmdline_root = first_dir({path.join(sdk, "cmdline-tools", "latest")})
    if not (java_program and cmdline_root) then
        return nil
    end
    local jars = os.files(path.join(cmdline_root, "lib", "*.jar"))
    if #jars == 0 then
        return nil
    end
    return {
        program = java_program,
        args = {
            "-classpath", table.concat(jars, base.pathsep()),
            "com.android.sdklib.tool.sdkmanager.SdkManagerCli",
            "--sdk_root=" .. sdk
        }
    }
end

-- ---------------------------------------------------------------------------
-- JDK (keytool / apksigner host)
-- ---------------------------------------------------------------------------

function jdk_home()
    local java_home = os.getenv("JAVA_HOME")
    if java_home and java_home ~= "" and os.isdir(java_home) then
        return java_home
    end
    local host = base.host_os()
    if host == "windows" then
        local programs = os.getenv("ProgramFiles") or "C:\\Program Files"
        local openjdk = newest_subdir(path.join(programs, "Android", "openjdk"))
        return first_dir({
            openjdk,
            path.join(programs, "Android", "Android Studio", "jbr")
        })
    elseif host == "macosx" then
        return first_dir({"/Applications/Android Studio.app/Contents/jbr/Contents/Home"})
    end
    return first_dir({"/usr/lib/jvm/default-java", newest_subdir("/usr/lib/jvm")})
end

local function jdk_tool(name)
    local home = jdk_home()
    if home then
        local tool = path.join(home, "bin", base.exe(name))
        if os.isfile(tool) then
            return tool
        end
    end
end

function java()
    return jdk_tool("java")
end

function keytool()
    return jdk_tool("keytool")
end

-- ---------------------------------------------------------------------------
-- status report
-- ---------------------------------------------------------------------------

function status()
    local api = tostring(settings.value_or("android_api", "26"))
    local ndk = ndk_root()
    local report = {
        {"sdk root", sdk_root()},
        {"ndk root", ndk},
        {"ndk version", ndk and ndk_version_of(ndk) or nil},
        {"ndk installed", table.concat(installed_ndk_versions(), ", ")},
        {"ndk llvm bin", ndk_llvm_bin_dir()},
        {"build-tools", build_tools_dir()},
        {"apksigner jar", apksigner_jar()},
        {"android api", api},
        {"platform jar", platform_jar(api)},
        {"adb", adb()},
        {"emulator", emulator()},
        {"jdk home", jdk_home()},
        {"keytool", keytool()}
    }
    for _, entry in ipairs(report) do
        print(string.format("%-14s %s", entry[1] .. ":", entry[2] or "(not found)"))
    end
end
