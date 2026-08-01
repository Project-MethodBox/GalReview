-- Configuration-derived values: option lookup with its fallback chain,
-- target platform/triplet/arch resolution, toolchain build flags and the
-- build-config signature, plus every cache/install path that depends on the
-- configured target (configuration-independent paths live in layout.lua).

import("core.project.config")
import("base")
import("errors")
import("layout")
local defaults = import("defaults").values()

function config_file_value(name)
    local host = os.host()
    if host == "macos" or host == "macosx" then
        host = "macosx"
    end
    -- xmake's own config cache directory is keyed by os.arch() verbatim (see
    -- core.project.config: ".xmake/<host>/<arch>", e.g. "windows/x64" or
    -- "macosx/x86_64") -- no GNU/short-name remap needed or wanted here.
    local conf = path.join(os.projectdir(), ".xmake", host, os.arch(), "xmake.conf")
    if not os.isfile(conf) then
        return nil
    end
    local content = io.readfile(conf) or ""
    local escaped = base.escape_pattern(name)
    local value = content:match("[\r\n]%s*" .. escaped .. "%s*=%s*%[%[(.-)%]%]")
    if value ~= nil then
        return value
    end
    value = content:match("[\r\n]%s*" .. escaped .. "%s*=%s*\"(.-)\"")
    if value ~= nil then
        return value
    end
    value = content:match("[\r\n]%s*" .. escaped .. "%s*=%s*(true)")
    if value ~= nil then
        return true
    end
    value = content:match("[\r\n]%s*" .. escaped .. "%s*=%s*(false)")
    if value ~= nil then
        return false
    end
    return nil
end

function value_or(name, fallback)
    local value
    local ok, configured = errors.trycall(function ()
        return config.get(name)
    end)
    if ok then
        value = configured
    end
    if value == nil or value == "" then
        value = config_file_value(name)
    end
    if value == nil or value == "" then
        value = os.getenv(name:upper())
    end
    if value == nil or value == "" then
        return fallback
    end
    return value
end

-- ---------------------------------------------------------------------------
-- configuration pin sentinel: xmake treats unspecified `xmake f` options as
-- DEFAULTS (not stored values), and description-file changes trigger
-- implicit reconfigures with those defaults -- both silently flip
-- plat/arch/mode. `xmake toolchains pin` records the user's intended
-- configuration; the sentinel warns loudly whenever the active one differs.
-- No pin file means no constraint (CI never pins).
-- ---------------------------------------------------------------------------

local function active_config_triple()
    local plat = tostring(value_or("plat", "") or "")
    if plat == "" then
        plat = config_file_value("plat") or ""
    end
    local arch = tostring(configured_arch() or "")
    local mode = tostring(value_or("mode", "") or "")
    if mode == "" then
        mode = config_file_value("mode") or ""
    end
    return plat, arch, mode
end

function write_config_pin()
    import("layout")
    local plat, arch, mode = active_config_triple()
    if plat == "" or arch == "" then
        errors.fail("cannot pin: no stored configuration found; run `xmake f -p <plat> -a <arch> -m <mode>` first")
    end
    local pin = plat .. " " .. arch .. " " .. mode
    os.mkdir(path.directory(layout.config_pin_file()))
    io.writefile(layout.config_pin_file(), pin)
    return plat, arch, mode
end

function clear_config_pin()
    import("layout")
    local file = layout.config_pin_file()
    if os.isfile(file) then
        os.rm(file)
        return true
    end
    return false
end

function read_config_pin()
    import("layout")
    local file = layout.config_pin_file()
    if not os.isfile(file) then
        return nil
    end
    local content = base.trim(io.readfile(file) or "")
    local plat, arch, mode = content:match("^(%S+)%s+(%S+)%s*(%S*)$")
    if not plat then
        return nil
    end
    return {plat = plat, arch = arch, mode = mode}
end

local pin_warned

function warn_config_pin_drift()
    if pin_warned then
        return
    end
    pin_warned = true
    local pin = read_config_pin()
    if not pin then
        return
    end
    local plat, arch, mode = active_config_triple()
    if plat ~= pin.plat or arch ~= pin.arch or (pin.mode ~= "" and mode ~= pin.mode) then
        errors.warn(
            "active configuration %s/%s/%s differs from the pinned %s/%s/%s -- a bare `xmake f` or an implicit reconfigure reset it; restore with `xmake f -p %s -a %s -m %s -y` (or repin via `xmake toolchains pin`)",
            plat, arch, mode, pin.plat, pin.arch, pin.mode, pin.plat, pin.arch, pin.mode)
    end
end

function config_bool(name, default)
    local value = tostring(value_or(name, "")):lower()
    if value == "" or value == "auto" then
        return default
    end
    return value == "1" or value == "true" or value == "yes" or value == "on"
end

function detect_host_cpu_count()
    local env_count = tonumber(os.getenv("NUMBER_OF_PROCESSORS") or "")
    if env_count and env_count > 0 then
        return math.floor(env_count)
    end
    local candidates = {
        {"nproc", {}},
        {"sysctl", {"-n", "hw.logicalcpu"}}
    }
    for _, candidate in ipairs(candidates) do
        local ok, out = errors.trycall(function ()
            return os.iorunv(candidate[1], candidate[2], {try = true})
        end)
        if not ok or type(out) ~= "string" then
            out = nil
        end
        local count = tonumber(base.trim(out)) or nil
        if count and count > 0 then
            return math.floor(count)
        end
    end
    return os.default_njob and os.default_njob() or 8
end

local default_jobs_cache

function default_jobs()
    if not default_jobs_cache then
        default_jobs_cache = tostring(detect_host_cpu_count())
    end
    return default_jobs_cache
end

function configured_target_os()
    -- module equivalent of the description-scope is_plat() chain: read the
    -- configured plat directly; unset plat falls through to the host
    local plat = tostring(value_or("plat", "") or "")
    if plat == "android" then
        return "android"
    elseif plat == "mingw" or plat == "windows" then
        return "windows"
    elseif plat == "linux" then
        return "linux"
    elseif plat == "macosx" or plat == "macos" then
        return "macosx"
    elseif plat == "iphoneos" or plat == "ios" then
        return "ios"
    elseif plat == "wasm" or plat == "emscripten" then
        return "emscripten"
    end
    return base.host_os()
end

function configured_arch()
    local arch
    local ok, configured = errors.trycall(function ()
        return config.get("arch")
    end)
    if ok then
        arch = configured
    end
    if arch == nil or arch == "" or arch == "auto" then
        -- xmake's config cache directory is always host-keyed (never
        -- target-keyed) and uses os.arch() verbatim, e.g. ".xmake/windows/x64"
        -- or ".xmake/macosx/x86_64" -- matches config_file_value.
        local conf = path.join(os.projectdir(), ".xmake", base.host_os(), os.arch(), "xmake.conf")
        if os.isfile(conf) then
            arch = (io.readfile(conf) or ""):match("arch%s*=%s*\"([^\"]+)\"")
        end
    end
    if arch == nil or arch == "" or arch == "auto" then
        return os.arch()
    end
    return arch
end

function linux_libc_kind()
    local libc = value_or("linux_libc", "auto")
    if libc == "auto" then
        return base.host_os() == "linux" and "gnu" or "musl"
    end
    if libc ~= "gnu" and libc ~= "musl" then
        errors.warn("linux_libc must be auto, gnu, or musl; current value is '%s'.", libc)
        errors.fail("unsupported linux_libc value: %s; expected auto, gnu, or musl", libc)
    end
    return libc
end

function darwin_triplet_suffix()
    -- Pure computation over macosx_deployment_target -- must NOT gate on the
    -- HOST os, since default_triplet() only ever consumes this for the
    -- TARGET being macosx, which is exactly as meaningful when cross-building
    -- macOS from Windows/Linux as it is when building natively on macOS.
    --
    -- Config-only resolution (no environment step): this suffix keys the
    -- managed triplet and with it the install layout, prefixes, and
    -- configure signatures, so a stray MACOSX_DEPLOYMENT_TARGET in the
    -- shell must not drift the toolchain identity between invocations.
    -- The environment fallback stays honored where it is identity-safe:
    -- the deployment FLAGS (project builds and toolchain configure args)
    -- resolve through value_or.
    local version
    local ok, configured = errors.trycall(function ()
        return config.get("macosx_deployment_target")
    end)
    if ok then
        version = configured
    end
    if version == nil or version == "" then
        version = config_file_value("macosx_deployment_target")
    end
    if version == nil or version == "" then
        version = "11.0"
    end
    version = tostring(version)
    local major, minor = version:match("^(%d+)%.?(%d*)")
    major = tonumber(major or "")
    minor = tonumber(minor or "0") or 0
    if not major then
        return ""
    end
    local darwin_major
    if major == 10 then
        darwin_major = minor + 4
    elseif major >= 26 then
        darwin_major = major - 1
    else
        darwin_major = major + 9
    end
    return tostring(darwin_major)
end

function default_triplet(target_os, arch)
    arch = base.canonical_arch(arch or configured_arch(), target_os)
    if target_os == "windows" then
        return arch .. "-w64-mingw32"
    elseif target_os == "linux" then
        return arch .. "-linux-" .. linux_libc_kind()
    elseif target_os == "android" then
        local configured = value_or("arch", "")
        if arch == "x86_64" and (configured == nil or configured == "" or configured == "auto") then
            arch = "aarch64"
        end
        -- 32-bit ARM Android is arm-linux-androideabi, NOT armv7a-linux-android:
        -- the NDK names its sysroot include/lib dirs and GCC's config.gcc case
        -- by that exact eabi string, so the naive arch..-linux-android would
        -- resolve no dirs and have no GCC target case.
        if arch == "armv7a" or arch == "armv7" or arch == "arm" then
            return "arm-linux-androideabi"
        end
        return arch .. "-linux-android"
    elseif target_os == "macosx" then
        -- aarch64-only by policy: darwin-arm64 is the single validated
        -- Darwin source profile, and deriving this triplet from the
        -- configured project arch let a leftover host arch (x64 checkouts,
        -- reused matrix trees) silently select the mainline profile, which
        -- cannot build Darwin at all (bit the C3 chain live, 2026-07-17,
        -- with an EXPLICIT residual -a x86_64 -- so an auto-only guard
        -- would not have caught it). x86_64-apple-darwin was never
        -- validated here; anyone who truly wants it can say so explicitly
        -- with --toolchains_target=, which outranks this default and still
        -- trips the preflight profile warning.
        return "aarch64-apple-darwin" .. darwin_triplet_suffix()
    elseif target_os == "ios" then
        -- unversioned on purpose: the iOS minimum comes from
        -- ios_deployment_target/the patched config.gcc default, not from a
        -- darwin-style version suffix in the triplet. aarch64-only for the
        -- same reason as macosx above (no other iOS device arch exists;
        -- simulator triplets are phase E2).
        return "aarch64-apple-ios"
    elseif target_os == "emscripten" then
        return "wasm32-unknown-emscripten"
    end
    return arch .. "-" .. target_os
end

-- The HOST triplet must reflect the host's own libc, never the configured
-- target libc: with `--linux_libc=musl` on a glibc host, routing through
-- default_triplet() made host_triplet() equal the musl TARGET triplet, so
-- is_cross_target() collapsed to false, configure received
-- --build=<target>, and libstdc++'s configure tried to RUN musl test
-- binaries on the glibc host ("cannot run C compiled programs"; found by
-- the first Linux-host musl cross build, 2026-07-17).
local host_linux_libc_cache

local function host_linux_libc()
    if host_linux_libc_cache then
        return host_linux_libc_cache
    end
    local kind = "gnu"
    if #os.files("/lib/ld-musl-*.so.1") > 0 or #os.files("/usr/lib/ld-musl-*.so.1") > 0 then
        kind = "musl"
    end
    host_linux_libc_cache = kind
    return kind
end

function host_triplet()
    local host = base.host_os()
    if host == "linux" then
        return base.canonical_arch(os.arch(), host) .. "-linux-" .. host_linux_libc()
    end
    if host == "macosx" then
        -- The host triplet must reflect the host's REAL arch. default_triplet's
        -- macosx branch is aarch64-only by target policy and ignores the arch
        -- arg, so on an Intel Mac it would return aarch64-apple-darwin == the
        -- target triplet, collapsing is_cross_target() to false and mis-driving
        -- an arm64 cross build as native (build=host=target) -- which cannot
        -- produce a host-runnable compiler. Same class of bug as the Linux-libc
        -- host special-case above.
        return base.canonical_arch(os.arch(), host) .. "-apple-darwin" .. darwin_triplet_suffix()
    end
    return default_triplet(host, os.arch())
end

function managed_target(target_os)
    return value_or("toolchains_target", default_triplet(target_os or configured_target_os()))
end

function target_arch(target_os)
    local triplet = managed_target(target_os)
    local arch = tostring(triplet or ""):match("^([^-]+)") or configured_arch()
    return base.canonical_arch(arch, target_os)
end

function target_arch_folder(target_os)
    return base.arch_folder_name(target_arch(target_os))
end

function uses_darwin_arm64_gcc(target_os)
    target_os = target_os or configured_target_os()
    -- iOS shares the darwin-arm64 source profile (and its shared source
    -- tree/cache_name): the ios support is carried as additive patches on
    -- the same pinned iains tree, so both targets key one source cache.
    return (target_os == "macosx" or target_os == "ios") and target_arch(target_os) == "aarch64"
end

function gcc_source_profile(target_os)
    target_os = target_os or configured_target_os()
    if target_os == "emscripten" then
        return {
            name = "wasm-experimental",
            cache_name = "gcc-wasm-experimental",
            url = value_or("wasm_gcc_git_url", defaults.wasm_gcc_git_url),
            ref = value_or("wasm_gcc_ref", defaults.wasm_gcc_ref)
        }
    end
    if uses_darwin_arm64_gcc(target_os) then
        return {
            name = "darwin-arm64",
            cache_name = "gcc-darwin-arm64",
            url = value_or("darwin_arm64_gcc_git_url", defaults.darwin_arm64_gcc_git_url),
            ref = value_or("darwin_arm64_gcc_ref", defaults.darwin_arm64_gcc_ref),
            -- rebased upstream line the pinned ref was taken from; `update`
            -- reports its drift so pin bumps stay deliberate
            tracking_branch = defaults.darwin_arm64_gcc_tracking_branch
        }
    end
    return {
        name = "mainline",
        cache_name = "gcc-mainline",
        url = value_or("gcc_git_url", defaults.gcc_git_url),
        ref = value_or("gcc_ref", defaults.ref)
    }
end

function gcc_source_dir(target_os)
    return layout.gcc_source_dir(gcc_source_profile(target_os).cache_name)
end

function host_arch_folder()
    return base.arch_folder_name(base.canonical_arch(os.arch(), base.host_os()))
end

function is_cross_target(target_os)
    return managed_target(target_os) ~= host_triplet()
end

function macosx_target_supported(target_os)
    return (target_os ~= "macosx" and target_os ~= "ios")
        or target_arch(target_os) ~= "aarch64"
        or gcc_source_profile(target_os).name == "darwin-arm64"
end

-- Shared by the toolchains.auto rule and gcc.features rule -- both need the
-- same "which project GCC toolchain applies to this target platform" answer.
function default_project_gcc_toolchain_for_current_platform()
    local enabled = tostring(value_or("toolchains_auto", "true")):lower()
    if enabled == "false" or enabled == "0" or enabled == "off" or enabled == "no" then
        return ""
    end
    local target_os = configured_target_os()
    if target_os == "windows" then
        return "mingw"
    elseif target_os == "linux" or target_os == "android" or target_os == "macosx"
        or target_os == "ios" or target_os == "emscripten" then
        return "gcc"
    end
    return ""
end

-- Configuration-dependent cache/install paths -------------------------------

function build_cache_dir(target_os)
    return path.join(layout.toolchains_cache_dir(base.host_os()), layout.ensure_toolchain_platform(target_os), target_arch_folder(target_os), "build")
end

function state_cache_dir(target_os)
    return path.join(layout.toolchains_cache_dir(base.host_os()), layout.ensure_toolchain_platform(target_os), target_arch_folder(target_os), "state")
end

function gcc_build_dir(target_os)
    return path.join(build_cache_dir(target_os), "gcc")
end

function binutils_build_dir(target_os)
    return path.join(build_cache_dir(target_os), "binutils")
end

function mingw_w64_build_dir(target_os, component)
    return path.join(build_cache_dir(target_os), "mingw-w64-" .. component)
end

function musl_build_dir(target_os)
    return path.join(build_cache_dir(target_os), "musl")
end

function wabt_build_dir(target_os)
    return path.join(build_cache_dir(target_os), "wabt")
end

function glibc_build_dir(target_os)
    return path.join(build_cache_dir(target_os), "glibc")
end

function gcc_stage1_build_dir(target_os)
    return path.join(build_cache_dir(target_os), "gcc-stage1")
end

function linux_headers_build_dir(target_os)
    return path.join(build_cache_dir(target_os), "linux-headers")
end

function gcc_prefix(target_os)
    return path.join(layout.toolchains_home(), layout.ensure_toolchain_platform(base.host_os()), layout.ensure_toolchain_platform(target_os), target_arch_folder(target_os))
end

function gcc_sysroot(target_os)
    return path.join(gcc_prefix(target_os), managed_target(target_os))
end

function stamp_file(target_os)
    return path.join(state_cache_dir(target_os), "installed.stamp")
end

-- Toolchain build type/flags --------------------------------------------------

function build_type()
    local kind = tostring(value_or("toolchains_build_type", "release")):lower()
    if kind == "" or kind == "rel" then
        return "release"
    end
    return kind
end

function build_optimize()
    local configured = tostring(value_or("toolchains_build_optimize", ""))
    if configured ~= "" then
        return configured:gsub("^-O", "")
    end
    local kind = build_type()
    if kind == "debug" then
        return "0"
    elseif kind == "minsizerel" or kind == "size" then
        return "s"
    end
    return "2"
end

function build_debug_enabled()
    local kind = build_type()
    return config_bool("toolchains_build_debug", kind == "debug" or kind == "relwithdebinfo")
end

function strip_enabled()
    local kind = build_type()
    return config_bool("toolchains_strip", kind == "release" or kind == "minsizerel" or kind == "size")
end

function default_optimization_flags()
    local flags = {}
    local optimize = build_optimize()
    if optimize ~= "" and optimize ~= "none" and optimize ~= "false" and optimize ~= "off" then
        table.insert(flags, "-O" .. optimize)
    end
    if build_debug_enabled() then
        table.insert(flags, "-g")
    else
        table.insert(flags, "-g0")
    end
    return table.concat(flags, " ")
end

function build_cflags()
    return base.append_flags_once(default_optimization_flags(), value_or("toolchains_build_cflags", ""))
end

function build_cxxflags()
    return base.append_flags_once(default_optimization_flags(), value_or("toolchains_build_cxxflags", ""))
end

function build_ldflags()
    return value_or("toolchains_build_ldflags", "")
end

function target_cflags(target_os)
    local flags = base.append_flags_once(default_optimization_flags(), value_or("toolchains_target_cflags", ""))
    if target_os == "android" then
        flags = base.append_flags_once(flags, "-fPIC")
    end
    return flags
end

function target_cxxflags(target_os)
    local flags = base.append_flags_once(default_optimization_flags(), value_or("toolchains_target_cxxflags", ""))
    if target_os == "android" then
        flags = base.append_flags_once(flags, "-fPIC")
    end
    return flags
end

function validate_config(target_os)
    target_os = layout.ensure_toolchain_platform(target_os or configured_target_os())
    local jobs_text = tostring(value_or("toolchains_jobs", default_jobs()))
    local jobs = tonumber(jobs_text)
    if not jobs or jobs < 1 then
        errors.warn("toolchains_jobs must be a positive integer; current value is '%s'.", jobs_text)
        errors.fail("invalid toolchains_jobs value '%s'; expected a positive integer", jobs_text)
    end

    local kind = build_type()
    local allowed_build_types = {
        release = true,
        debug = true,
        relwithdebinfo = true,
        minsizerel = true,
        size = true
    }
    if not allowed_build_types[kind] then
        errors.warn("toolchains_build_type is not recognized: %s.", kind)
        errors.fail("invalid toolchains_build_type '%s'; expected release, debug, relwithdebinfo, minsizerel, or size", kind)
    end

    local optimize = build_optimize()
    if optimize:find("%s") then
        errors.warn("toolchains_build_optimize must be one GCC optimization suffix, not a flag list: %s.", optimize)
        errors.fail("invalid toolchains_build_optimize '%s'; use a single GCC -O suffix such as 0, 1, 2, 3, g, s, or fast", optimize)
    end

    local debug_value = tostring(value_or("toolchains_build_debug", "auto")):lower()
    if debug_value ~= "" and debug_value ~= "auto" and debug_value ~= "true" and debug_value ~= "false"
        and debug_value ~= "1" and debug_value ~= "0" and debug_value ~= "yes" and debug_value ~= "no"
        and debug_value ~= "on" and debug_value ~= "off" then
        errors.warn("toolchains_build_debug must be auto/true/false; current value is '%s'.", debug_value)
        errors.fail("invalid toolchains_build_debug '%s'; expected auto, true, or false", debug_value)
    end

    local strip_value = tostring(value_or("toolchains_strip", "auto")):lower()
    if strip_value ~= "" and strip_value ~= "auto" and strip_value ~= "true" and strip_value ~= "false"
        and strip_value ~= "1" and strip_value ~= "0" and strip_value ~= "yes" and strip_value ~= "no"
        and strip_value ~= "on" and strip_value ~= "off" then
        errors.warn("toolchains_strip must be auto/true/false; current value is '%s'.", strip_value)
        errors.fail("invalid toolchains_strip '%s'; expected auto, true, or false", strip_value)
    end

    if target_os == "linux" then
        local libc = tostring(value_or("linux_libc", "auto")):lower()
        if libc ~= "auto" and libc ~= "gnu" and libc ~= "musl" then
            errors.warn("linux_libc must be auto, gnu, or musl; current value is '%s'.", libc)
            errors.fail("invalid linux_libc '%s'; expected auto, gnu, or musl", libc)
        end
        -- format check only; membership in the supported managed set is a
        -- gccglibc/preflight concern (the value is consumed only in managed
        -- gnu mode)
        local glibc_version = tostring(value_or("linux_glibc_version", "auto"))
        if glibc_version ~= "" and glibc_version ~= "auto" and not glibc_version:match("^%d+%.%d+$") then
            errors.warn("linux_glibc_version must be auto or a glibc version such as 2.43; current value is '%s'.", glibc_version)
            errors.fail("invalid linux_glibc_version '%s'; expected auto or a glibc version such as 2.43", glibc_version)
        end
    elseif target_os == "android" then
        local api = tostring(value_or("android_api", "26")):gsub("^android%-", "")
        if not tonumber(api) then
            errors.warn("android_api must be numeric; current value is '%s'.", tostring(value_or("android_api", "26")))
            errors.fail("invalid android_api '%s'; expected a numeric Android API level", tostring(value_or("android_api", "26")))
        end
    elseif target_os == "macosx" then
        local deployment = tostring(value_or("macosx_deployment_target", "11.0"))
        if not deployment:match("^%d+%.%d+") then
            errors.warn("macosx_deployment_target should look like 11.0; current value is '%s'.", deployment)
            errors.fail("invalid macosx_deployment_target '%s'; expected a version such as 11.0", deployment)
        end
    elseif target_os == "ios" then
        local deployment = tostring(value_or("ios_deployment_target", defaults.ios_deployment_target))
        if not deployment:match("^%d+%.%d+") then
            errors.warn("ios_deployment_target should look like %s; current value is '%s'.", defaults.ios_deployment_target, deployment)
            errors.fail("invalid ios_deployment_target '%s'; expected a version such as %s", deployment, defaults.ios_deployment_target)
        end
    end
end

function append_env_flags(envs, key, flags)
    flags = base.trim(flags or "")
    if flags ~= "" then
        envs[key] = base.append_flags_once(envs[key], flags)
    end
end

function apply_build_envs(envs, target_os)
    local cflags = build_cflags()
    local cxxflags = build_cxxflags()
    local ldflags = build_ldflags()
    append_env_flags(envs, "CFLAGS", cflags)
    append_env_flags(envs, "CXXFLAGS", cxxflags)
    append_env_flags(envs, "CFLAGS_FOR_BUILD", cflags)
    append_env_flags(envs, "CXXFLAGS_FOR_BUILD", cxxflags)
    append_env_flags(envs, "BOOT_CFLAGS", cflags)
    append_env_flags(envs, "STAGE1_CFLAGS", cflags)
    append_env_flags(envs, "LDFLAGS", ldflags)
    if target_os then
        append_env_flags(envs, "CFLAGS_FOR_TARGET", target_cflags(target_os))
        append_env_flags(envs, "CXXFLAGS_FOR_TARGET", target_cxxflags(target_os))
        append_env_flags(envs, "LIBCFLAGS_FOR_TARGET", target_cflags(target_os))
        append_env_flags(envs, "LIBCXXFLAGS_FOR_TARGET", target_cxxflags(target_os))
    end
    return envs
end

function build_config_signature(target_os)
    local entries = {
        "toolchains_script_schema=windows-static-runtime-v1",
        "toolchains_build_type=" .. build_type(),
        "toolchains_build_optimize=" .. build_optimize(),
        "toolchains_build_debug=" .. tostring(build_debug_enabled()),
        "toolchains_build_cflags=" .. build_cflags(),
        "toolchains_build_cxxflags=" .. build_cxxflags(),
        "toolchains_build_ldflags=" .. build_ldflags(),
        "toolchains_target_cflags=" .. (target_os and target_cflags(target_os) or ""),
        "toolchains_target_cxxflags=" .. (target_os and target_cxxflags(target_os) or ""),
        "toolchains_strip=" .. tostring(strip_enabled())
    }
    if target_os and gcc_source_profile(target_os).name ~= "mainline" then
        local source = gcc_source_profile(target_os)
        table.insert(entries, "gcc_source_profile=" .. source.name)
        table.insert(entries, "gcc_source_url=" .. source.url)
        table.insert(entries, "gcc_source_ref=" .. source.ref)
        if source.name == "darwin-arm64" then
            -- the shared darwin-arm64 tree carries an extra additive ios
            -- patch layer for the ios target; keying it into the signature
            -- only for ios keeps macosx installs byte-identical
            if target_os == "ios" then
                table.insert(entries, "gcc_patch_schema=darwin-arm64-ios-v1")
            else
                table.insert(entries, "gcc_patch_schema=darwin-arm64-v1")
            end
        elseif source.name == "wasm-experimental" then
            table.insert(entries, "gcc_patch_schema=wasm-freestanding-cxx-int128-libgcc-libstdcxx-v2")
            table.insert(entries, "wasm_wabt_url=" .. value_or("wasm_wabt_git_url", defaults.wasm_wabt_git_url))
            table.insert(entries, "wasm_wabt_ref=" .. value_or("wasm_wabt_ref", defaults.wasm_wabt_ref))
            table.insert(entries, "wasm_ld=" .. value_or("wasm_ld", os.getenv("WASM_LD") or ""))
        end
    end
    return table.concat(entries, "\n") .. "\n"
end
