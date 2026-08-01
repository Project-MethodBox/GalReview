-- Target-provider dispatch (C++-specific). The per-target-OS knowledge that
-- used to live inline here and in gccbuild/gccstatus now lives in one
-- provider module per target OS under targets/ (windows, linux, android,
-- macosx, emscripten). This module resolves and caches providers, supplies
-- the dispatcher-level defaults for optional hooks, and keeps the historical
-- public entry points as thin forwards so existing callers (cpp/xmake.lua
-- rule/toolchain callbacks, gccbuild, gccstatus) stay unchanged.
--
-- Providers must never import gccbuild, gcctargets, or gccstatus (xmake's
-- import has no cycle protection); their shared low layer is gccinstall,
-- and gccwasm stays owned by targets/emscripten.lua.

-- os.scriptdir() is only trustworthy at module load time; capture the
-- provider directory now for the runtime dispatch below.
local TARGETS_DIR = path.join(os.scriptdir(), "targets")
local _providers = {}

-- Resolves the provider module for a target OS. Unknown target OS names get
-- an empty provider (every optional hook absent), which reproduces the old
-- behavior of the inline elseif chains silently falling through; hard
-- validation of platform names stays owned by layout.ensure_toolchain_platform.
function provider_of(target_os)
    local cached = _providers[target_os]
    if cached then
        return cached
    end
    local provider
    if os.isfile(path.join(TARGETS_DIR, tostring(target_os) .. ".lua")) then
        -- anonymous import: binding the module to a global named after the
        -- target OS ("windows", "linux", ...) would invite name collisions.
        provider = import(target_os, {rootdir = TARGETS_DIR, anonymous = true})
    else
        provider = {}
    end
    _providers[target_os] = provider
    return provider
end

function known_target_oses()
    local names = {}
    for _, file in ipairs(os.files(path.join(TARGETS_DIR, "*.lua"))) do
        table.insert(names, path.basename(file))
    end
    return names
end

-- Dispatcher-level defaults for optional provider hooks.

function target_tools(target_os)
    local provider = provider_of(target_os)
    local tools = provider.target_tools and provider.target_tools(target_os) or {}
    if not tools.ar then
        tools.ar = "gcc-ar"
    end
    if not tools.ranlib then
        tools.ranlib = "gcc-ranlib"
    end
    if not tools.strip_globs then
        tools.strip_globs = {path.join("**", "*.so"), path.join("**", "*.so.*")}
    end
    return tools
end

function signature_extra(target_os)
    local provider = provider_of(target_os)
    if provider.signature_extra then
        return provider.signature_extra(target_os)
    end
    return ""
end

function stamp_extra(target_os)
    local provider = provider_of(target_os)
    if provider.stamp_extra then
        return provider.stamp_extra(target_os)
    end
    return ""
end

function needs_binutils(target_os)
    local provider = provider_of(target_os)
    if provider.needs_binutils then
        return provider.needs_binutils(target_os)
    end
    return true
end

function target_sysroot(target_os)
    local provider = provider_of(target_os)
    if provider.sysroot then
        return provider.sysroot(target_os)
    end
end

-- Historical public entry points, forwarded to the owning provider. The
-- target-OS gates stay here so a forward never loads an unrelated provider.

function stage_macosx_target_tools(target_os)
    if target_os ~= "macosx" then
        return
    end
    return provider_of(target_os).stage_tools(target_os)
end

function android_api_level()
    return provider_of("android").android_api_level()
end

function android_arch_include_dir(target_os)
    return provider_of("android").android_arch_include_dir(target_os)
end

function android_sysroot_include_dir(target_os)
    return provider_of("android").android_sysroot_include_dir(target_os)
end

function ensure_android_gcc_compat_header()
    return provider_of("android").ensure_android_gcc_compat_header()
end

function android_api_library_dir(target_os)
    return provider_of("android").android_api_library_dir(target_os)
end

function android_library_root(target_os)
    return provider_of("android").android_library_root(target_os)
end

function managed_toolchains_preflight_target(target_os)
    local provider = provider_of(target_os)
    if provider.preflight then
        return provider.preflight(target_os)
    end
end

-- Executable provider contract. Hooks are the generic lifecycle surface the
-- dispatcher/gccbuild may call on any provider (required = every provider
-- must export it); family lists the provider-specific public helpers each
-- targets/<os>.lua may additionally export. The fixture suite
-- (tests/cases/gcctargets_cases.lua) asserts every shipped provider against
-- this table in both directions, so a typo'd optional hook -- which would
-- otherwise become a silently-never-called function -- and a forgotten
-- required hook both fail in the fixture battery instead of at install
-- time on some host. Extending a provider means extending this table.
function provider_contract()
    return {
        hooks = {
            preflight = {required = true,
                doc = "hard-stop misconfiguration gate (loud, via run.stop_with_guidance)"},
            preflight_warnings = {required = true,
                doc = "read-only (warnings, actions) lists shared by preflight, status, and matrix"},
            configure_args = {required = true,
                doc = "(target_os, args) -> args extended with profile-specific GCC configure arguments"},
            build_plan = {required = true,
                doc = "(target_os, context) -> ordered step list driving gccbuild: steps carry targets (\"\" = bare make) and/or before/after callbacks, plus log and patch"},
            sysroot = {doc = "(target_os) -> target sysroot path or nil"},
            target_tools = {doc = "(target_os) -> {ar, ranlib, strip_globs} tool names"},
            needs_binutils = {doc = "(target_os) -> whether GNU binutils must be built for this target"},
            signature_extra = {doc = "(target_os) -> extra configure-signature text; a change forces reconfigure"},
            stamp_extra = {doc = "(target_os) -> extra install-stamp text recorded at install time"},
            installed_extra = {doc = "(target_os) -> false when the recorded stamp no longer matches live settings (outer install gate)"},
            status_lines = {doc = "(target_os) prints provider-specific status lines"},
            finalize = {doc = "(target_os) post-install repair hook (fresh builds and cache restores)"},
            stage_tools = {doc = "(target_os) stages wrappers/shims into the managed prefix"},
            apply_envs = {doc = "(target_os, envs) -> envs adjusted for the toolchain build"},
            prepare_sysroot = {doc = "(target_os) materializes the target sysroot before configure"},
            prepare_runtime_inputs = {doc = "(target_os) prepares target runtime inputs before the build plan"},
            prepare_backend_tools = {doc = "(target_os) prepares backend assembler/linker tools"},
            patch_build_tree = {doc = "(target_os) patches the configured build tree between plan stages"},
            makefile_patch_context = {doc = "(...) Windows makefile patch closure table consumed by gccbuild"},
            compiler_exists = {doc = "(target_os) provider override for the installed-compiler probe"},
            repair_installed_tree = {doc = "(target_os) repairs an existing install in place"},
            smoke = {doc = "(target_os) post-build smoke closure"},
            smoke_refresh = {doc = "(target_os) smoke-command hook: rebuild smoke artifacts (presence gates the command)"},
            smoke_link = {doc = "(target_os) smoke-command hook: link/execute assertions"},
            smoke_state = {doc = "(target_os) -> read-only matrix smoke column value"},
            smoke_noop_reason = {doc = "(target_os) -> message when the smoke command is a documented no-op on this host"},
            ensure_smoke_current = {doc = "(target_os) asserts the recorded smoke matches the current capability tag"},
            on_fetch = {doc = "(target_os) extra fetch-time work (managed archives, companion sources)"},
            on_bundle = {doc = "(target_os) extra bundle-time work (companion source trees)"},
            on_rebuild_reset = {doc = "(target_os) extra state reset on rebuild"}
        },
        family = {
            windows = {"install_mingw_w64_crt", "install_mingw_w64_headers",
                "install_mingw_w64_winpthreads", "stage_binutils",
                "repair_windows_readelf_config_cache"},
            linux = {"ensure_musl_windows_configure_compat",
                "install_musl_headers_without_configure", "linux_configured_sysroot",
                "linux_glibc_managed", "linux_sysroot_has_headers",
                "linux_sysroot_has_libc", "linux_target_libc", "linux_target_uses_gnu",
                "linux_target_uses_musl", "musl_arch_from_triplet",
                "patch_musl_makefile_for_windows", "repair_musl_runtime_loader"},
            android = {"android_api_level", "android_api_library_dir",
                "android_arch_include_dir", "android_gcc_compat_header",
                "android_library_root", "android_ndk_bin_dir", "android_ndk_sysroot",
                "android_sysroot_include_dir", "android_target_compile_flags",
                "android_target_driver_flags", "android_target_library_flags",
                "ensure_android_gcc_compat_header",
                "patch_android_libstdcxx_bionic_ctype",
                "patch_android_ndk_headers_for_gcc"},
            macosx = {},
            ios = {},
            emscripten = {}
        }
    }
end
