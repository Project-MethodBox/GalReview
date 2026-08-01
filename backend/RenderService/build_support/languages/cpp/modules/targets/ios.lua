-- iOS target provider (phase E1: theoretical cross build). Apple host-tool
-- wrapper staging, *_FOR_TARGET build envs, the iOS configure argument set
-- (iPhoneOS SDK sysroot, static-only runtimes), and the iOS preflight. iOS
-- targets currently build only on macOS hosts with Xcode and the Apple
-- command-line tools (the shared Mach-O tool family for other hosts is
-- phase C2); no project binutils are built for this target. The compiler
-- side lives in the ios patch family on the shared darwin-arm64 source
-- tree (patches/ios.lua).

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
local defaults = import("defaults", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")}).values()
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("hosttools", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("run", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})

-- Default Xcode.app developer directory used for the xcrun retry when
-- xcode-select points at the plain Command Line Tools (which cannot see the
-- iPhoneOS SDK). The retry is command-scoped and never touches the system
-- xcode-select state.
local XCODE_DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"

local _sdk_cache

local function ios_minimum()
    return tostring(settings.value_or("ios_deployment_target", defaults.ios_deployment_target))
end

local function xcrun_iphoneos(query)
    local ok, value = errors.trycall(function ()
        return os.iorunv("xcrun", {"--sdk", "iphoneos", query})
    end)
    value = ok and base.trim(value or "") or ""
    if value ~= "" then
        return value
    end
    -- xmake merges the envs option over the inherited environment, so this
    -- only pins DEVELOPER_DIR for the retried command.
    ok, value = errors.trycall(function ()
        return os.iorunv("xcrun", {"--sdk", "iphoneos", query},
            {envs = {DEVELOPER_DIR = XCODE_DEVELOPER_DIR}})
    end)
    return ok and base.trim(value or "") or ""
end

-- SDK version from the SDK's own metadata (same shape as the macosx
-- provider's apple_sdk_version): works on any host and for any directory
-- name, unlike the iPhoneOS<ver>.sdk name pattern or an xcrun query that
-- answers for the DEFAULT SDK rather than the configured one.
local function sdk_settings_version(sdk)
    local json_file = path.join(sdk, "SDKSettings.json")
    if os.isfile(json_file) then
        local version = tostring(io.readfile(json_file) or ""):match("\"Version\"%s*:%s*\"([^\"]+)\"")
        if version then
            return version
        end
    end
    local plist_file = path.join(sdk, "SDKSettings.plist")
    if os.isfile(plist_file) then
        local version = tostring(io.readfile(plist_file) or ""):match("<key>Version</key>%s*<string>([^<]+)</string>")
        if version then
            return version
        end
    end
    return ""
end

-- Resolution order: --ios_sdk option (IOS_SDK environment falls back for
-- free through settings.value_or) -> xcrun --sdk iphoneos with the
-- DEVELOPER_DIR retry. Read-only and non-fatal on every host so status and
-- matrix probes stay safe; returns "" when no SDK is available.
local function resolve_ios_sdk()
    if _sdk_cache ~= nil then
        return _sdk_cache.path, _sdk_cache.version
    end
    local from_xcrun = false
    local sdk = tostring(settings.value_or("ios_sdk", "") or "")
    if sdk == "" and base.host_os() == "macosx" then
        sdk = xcrun_iphoneos("--show-sdk-path")
        from_xcrun = true
    end
    if sdk ~= "" and not os.isdir(sdk) then
        sdk = ""
    end
    local version = ""
    if sdk ~= "" then
        version = sdk_settings_version(sdk)
        if version == "" then
            version = sdk:match("iPhoneOS([%d%.]+)%.sdk$") or ""
        end
        -- xcrun answers for its default SDK, so this last resort is only
        -- honest when the path itself came from xcrun
        if version == "" and from_xcrun then
            version = xcrun_iphoneos("--show-sdk-version")
        end
    end
    _sdk_cache = {path = sdk, version = version}
    return sdk, version
end

function stage_tools(target_os)
    if target_os ~= "ios" then
        return
    end
    local triplet = settings.managed_target(target_os)
    local prefix = settings.gcc_prefix(target_os)
    local function install_wrapper(bindir, name)
        local real = hosttools.find_tool_path(name)
        if not real then
            return
        end
        os.mkdir(bindir)
        local target = path.join(bindir, triplet .. "-" .. name)
        if os.isfile(target) then
            return
        end
        io.writefile(target, "#!/bin/sh\nexec " .. base.shquote(real) .. " \"$@\"\n")
        os.vrunv(hosttools.preferred_host_tool("chmod"), {"+x", target}, {try = true})
    end
    for _, bindir in ipairs({path.join(prefix, "bin"), path.join(prefix, triplet, "bin")}) do
        for _, name in ipairs({"ar", "as", "ld", "nm", "ranlib", "strip", "lipo", "otool", "dsymutil"}) do
            install_wrapper(bindir, name)
        end
    end
end

function apply_envs(target_os, envs)
    if target_os ~= "ios" then
        return envs
    end
    local triplet = settings.managed_target(target_os)
    -- Deliberately neutralized rather than set: a MACOSX_DEPLOYMENT_TARGET
    -- inherited from a Mac shell would override the compiled-in iOS minimum
    -- inside the Darwin driver. xmake env tables merge over the inherited
    -- environment and cannot unset a variable, but darwin-driver.cc
    -- documents the empty string as "as if it was never set".
    envs.MACOSX_DEPLOYMENT_TARGET = ""
    envs.AR_FOR_TARGET = triplet .. "-ar"
    envs.AS_FOR_TARGET = triplet .. "-as"
    envs.LD_FOR_TARGET = triplet .. "-ld"
    envs.NM_FOR_TARGET = triplet .. "-nm"
    envs.RANLIB_FOR_TARGET = triplet .. "-ranlib"
    envs.STRIP_FOR_TARGET = triplet .. "-strip"
    envs.LIPO_FOR_TARGET = triplet .. "-lipo"
    envs.DSYMUTIL_FOR_TARGET = triplet .. "-dsymutil"
    return envs
end

-- Read-only preflight probe (matrix-consumable); preflight() below turns a
-- non-empty result into the loud stop.
function preflight_warnings(target_os)
    if target_os ~= "ios" then
        return {}, {}
    end
    local warnings = {}
    local actions = {
        errors.message("Build iOS targets from a macOS host with Xcode (the iPhoneOS SDK) installed."),
        errors.message("Check the SDK with: xcrun --sdk iphoneos --show-sdk-path (this manager retries with DEVELOPER_DIR=%s when xcode-select points at the Command Line Tools).", XCODE_DEVELOPER_DIR),
        errors.message("iOS shares the project Darwin Arm64 GCC source profile; inspect it with `xmake toolchains status ios`.")
    }

    if not settings.macosx_target_supported(target_os) then
        table.insert(warnings, errors.message("The selected GCC source profile does not support the iOS target: %s", settings.managed_target(target_os)))
    end
    -- macosx_target_supported passes non-aarch64 arches (real for macosx,
    -- where mainline x86_64-apple-darwin exists), but iOS device targets
    -- are aarch64-only: any other arch resolves to the mainline source
    -- profile, whose tree carries no iOS patches, and dies later in a raw
    -- GCC configure error far from the misconfiguration.
    if settings.target_arch(target_os) ~= "aarch64" then
        table.insert(warnings, errors.message("iOS device targets are aarch64-only (phase E1); the configured arch %s selects a GCC source profile without iOS support.", tostring(settings.target_arch(target_os))))
    end
    if tostring(settings.managed_target(target_os)):find("simulator", 1, true) then
        table.insert(warnings, errors.message("iOS simulator triplets are not supported yet (phase E2): %s", settings.managed_target(target_os)))
    end
    if base.host_os() ~= "macosx" then
        table.insert(warnings, errors.message("iOS target builds currently need a macOS host with Xcode and the Apple command-line tools; building from a %s host waits for the shared Mach-O tool family (phase C2).", base.host_os()))
    else
        local sdk = resolve_ios_sdk()
        if sdk == "" then
            table.insert(warnings, errors.message("Apple iPhoneOS SDK was not found (checked --ios_sdk/IOS_SDK and xcrun --sdk iphoneos, including the Xcode.app DEVELOPER_DIR retry)."))
        end
        for _, tool in ipairs({"as", "ld", "ar", "ranlib", "strip"}) do
            if not hosttools.find_tool_path(tool) then
                table.insert(warnings, errors.message("Required Apple command-line tool was not found in PATH: %s", tool))
            end
        end
    end

    return warnings, actions
end

function preflight(target_os)
    if target_os ~= "ios" then
        return
    end
    local warnings, actions = preflight_warnings(target_os)
    if #warnings > 0 then
        run.stop_with_guidance(target_os, errors.message("iOS target settings are incomplete"), warnings, actions)
    end
end

function needs_binutils(target_os)
    return false
end

function sysroot(target_os)
    local sdk = resolve_ios_sdk()
    if sdk ~= "" then
        return sdk
    end
end

function configure_args(target_os, args)
    -- Shared libgcc, static everything else -- GCC's own --enable-shared=PKGS
    -- idiom (libgcc/configure matches the package name explicitly).
    -- Both halves are forced by evidence (2026-07-17):
    --   * libgcc must be shared, because the Darwin libgcc machinery the ios
    --     patch family reuses (t-slibgcc-darwin's libemutls_w.a rule) only
    --     defines its _s-flavor object rules for shared builds; a plain
    --     --disable-shared died with "No rule to make target emutls_s.o".
    --   * libstdc++ must NOT be shared, because libtool switches on host_os
    --     and knows nothing about "ios": its generated script comes out with
    --     shrext_cmds=".so" and EMPTY library_names_spec/soname_spec (the
    --     macosx build gets the proper .dylib set), so a shared libstdc++
    --     here would be built by a libtool that cannot even name it.
    -- Static archives are also the honest shape for iOS app bundles.
    table.insert(args, "--enable-shared=libgcc")
    table.insert(args, "--enable-threads=posix")
    local sdk = resolve_ios_sdk()
    if sdk ~= "" then
        table.insert(args, "--with-sysroot=" .. base.shpath(sdk))
    end
    local apple_as = hosttools.find_tool_path("as")
    local apple_ld = hosttools.find_tool_path("ld")
    if apple_as then
        table.insert(args, "--with-as=" .. base.shpath(apple_as))
    end
    if apple_ld then
        table.insert(args, "--with-ld=" .. base.shpath(apple_ld))
    end
    return args
end

function target_tools(target_os)
    return {ar = "ar", ranlib = "ranlib", strip_globs = {}}
end

function build_plan(target_os, context)
    return {
        {
            log = "building iOS GCC compiler and target runtime",
            targets = {"all-gcc", "install-gcc", "configure-target-libgcc"}
        },
        {
            targets = {"all-target-libgcc", "install-target-libgcc"}
        },
        {
            targets = {"configure-target-libstdc++-v3", "all-target-libstdc++-v3", "install-target-libstdc++-v3"},
            patch = true
        }
    }
end

-- The SDK identity keys the configure signature and the install stamp:
-- swapping Xcode or upgrading the iPhoneOS SDK must trigger a
-- reconfigure/reinstall (iOS links everything against SDK .tbd stubs, so it
-- is more SDK-sensitive than the macosx subject, which does not key this).
-- The deployment key uses defaults.ios_deployment_target (the COMPILED-IN
-- minimum, baked from the default via patches/ios.lua), NOT the live option:
-- the option reaches project builds only as an -mmacosx-version-min driver
-- flag and does not change the toolchain output, so keying the toolchain
-- rebuild on it would force a multi-hour reconfigure that produces an
-- identical artifact. Only a change to the default itself must rebuild.
function signature_extra(target_os)
    local sdk, version = resolve_ios_sdk()
    return "ios_sdk=" .. sdk .. "\n"
        .. "ios_sdk_version=" .. version .. "\n"
        .. "ios_deployment_target=" .. tostring(defaults.ios_deployment_target) .. "\n"
end

function stamp_extra(target_os)
    return signature_extra(target_os)
end

-- SDK/deployment drift visibility for the OUTER install gate (same pattern
-- as the linux/android providers): stamp_extra above records the keys, but
-- the gate never rereads them on its own, so an SDK swap, an SDK version
-- bump, or a deployment-target change would otherwise print "already
-- installed" and silently reuse the old install. Stamps written before a
-- key existed are grandfathered until their next rebuild re-stamps them.
function installed_extra(target_os)
    local stamp = settings.stamp_file(target_os)
    if not os.isfile(stamp) then
        return true
    end
    local content = io.readfile(stamp) or ""
    local sdk, version = resolve_ios_sdk()
    local expected = {
        ios_sdk = sdk,
        ios_sdk_version = version,
        ios_deployment_target = tostring(defaults.ios_deployment_target)
    }
    for key, current in pairs(expected) do
        local recorded = content:match("[\r\n]" .. key .. "=([^\r\n]*)")
        if recorded ~= nil and recorded ~= tostring(current) then
            return false
        end
    end
    return true
end

function status_lines(target_os)
    local sdk, version = resolve_ios_sdk()
    print("iOS min:         " .. ios_minimum())
    print("iOS SDK:         " .. (sdk ~= "" and sdk or "not found"))
    print("iOS SDK version: " .. (version ~= "" and version or "unknown"))
end
