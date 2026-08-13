function managed_toolchains_trycall(script)
    if utils and utils.trycall then
        return utils.trycall(script)
    end
    if import then
        local imported_utils = import("core.base.utils")
        if imported_utils and imported_utils.trycall then
            return imported_utils.trycall(script)
        end
    end
    -- Last-resort fallback when neither utils.trycall nor
    -- import("core.base.utils").trycall is reachable: the try{}/catch{}
    -- sandbox DSL is only injected into rule/task callback scopes, not this
    -- top-level project-description scope (verified empirically -- "catch"
    -- is nil here), so it cannot be used in this file. Prefer a real pcall
    -- when the sandbox happens to expose one; otherwise degrade to the
    -- original unguarded call rather than risk breaking script loading.
    if type(pcall) == "function" then
        return pcall(script)
    end
    return true, script()
end

-- Stage logging lives in core/modules/errors.lua (errors.log); nothing in
-- this bootstrap file's own load-time execution needs it.

function managed_toolchains_normalized_owner_path(value)
    local text = path.absolute(value):gsub("\\", "/")
    if is_host("windows") then
        text = text:lower()
    end
    return text
end

function managed_toolchains_path_is_in_tree(child, parent)
    child = managed_toolchains_normalized_owner_path(child)
    parent = managed_toolchains_normalized_owner_path(parent)
    return child == parent or child:sub(1, #parent + 1) == parent .. "/"
end

function managed_toolchains_owner_from_support_script(scriptdir)
    local current = path.absolute(scriptdir)
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
end

function managed_toolchains_detect_owner_root()
    local owner_root = managed_toolchains_owner_from_support_script(os.scriptdir())
    if owner_root then
        return owner_root
    end
    local support_root = path.absolute(path.directory(os.scriptdir()))
    local project_root = path.absolute(os.projectdir())
    if managed_toolchains_path_is_in_tree(project_root, support_root) then
        return support_root
    end
    return project_root
end

MANAGED_TOOLCHAINS_OWNER_ROOT = MANAGED_TOOLCHAINS_OWNER_ROOT or managed_toolchains_detect_owner_root()

-- Upstream source identity -- which repository and which revision each managed
-- GCC line is built from -- lives ONLY in core/modules/defaults.lua. The
-- matching options below exist to OVERRIDE it, so their default is empty and
-- settings.value_or() falls through to the module value.
--
-- Why no literal is mirrored here: xmake freezes an option's value into the
-- config store the moment a configuration is written, and every store keeps
-- its own copy -- the root, each lane under build/<plat>, and the test
-- subproject. A mirrored default is therefore frozen at write time, so
-- bumping defaults.lua reached none of the existing stores and every bump
-- turned into a restate-it-in-N-places ritual, with a missed store silently
-- building different sources than its siblings (found the hard way: three
-- lane stores were still carrying a retired WebAssembly repository URL and
-- the pin from two syncs earlier). An empty default freezes as empty, so the
-- module value is consulted on every read and one edit reaches every store.
-- An explicit `--gcc_ref=<rev>` still overrides, still only in the store it
-- is written to -- now the ONLY way a store can differ, which is exactly what
-- settings.warn_source_pin_drift() reports.
--
-- mirrored from core/modules/defaults.lua (ios_deployment_target); the ios
-- GCC patch family reads the module value, so this literal must stay equal
-- to it (check_options_file verifies at configure time)
default_ios_deployment_target = "15.0"
default_binutils_snapshot_url = "https://ftp.gnu.org/gnu/binutils/binutils-2.45.tar.xz"
default_mingw_w64_snapshot_url = "https://downloads.sourceforge.net/project/mingw-w64/mingw-w64/mingw-w64-release/mingw-w64-v14.0.0.tar.bz2"
default_musl_snapshot_url = "https://musl.libc.org/releases/musl-1.2.5.tar.gz"
default_m4_url = "https://ftp.gnu.org/gnu/m4/m4-1.4.19.tar.xz"
default_flex_url = "https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz"

MANAGED_TOOLCHAINS_DEFAULTS = MANAGED_TOOLCHAINS_DEFAULTS or {
    winflexbison_url = "https://github.com/lexxmark/winflexbison/releases/download/v2.5.25/win_flex_bison-2.5.25.zip",
    winflexbison_package = "winflexbison",
    windows_bootstrap_url = "latest",
    -- pinned known-good release used when the GitHub "latest" API is
    -- unreachable or rate-limited (unauthenticated CI/shared IPs often are)
    windows_bootstrap_fallback_url_x64 = "https://github.com/skeeto/w64devkit/releases/download/v2.8.0/w64devkit-x64-2.8.0.7z.exe",
    windows_bootstrap_fallback_url_x86 = "https://github.com/skeeto/w64devkit/releases/download/v2.8.0/w64devkit-x86-2.8.0.7z.exe",
    gcc_prerequisites_base_url = "https://gcc.gnu.org/pub/gcc/infrastructure",
    mingw_msvcrt = "msvcrt"
}

function managed_toolchains_detect_host_cpu_count()
    local env_count = tonumber(os.getenv("NUMBER_OF_PROCESSORS") or "")
    if env_count and env_count > 0 then
        return math.floor(env_count)
    end
    if os.iorunv then
        local candidates = {
            {"nproc", {}},
            {"sysctl", {"-n", "hw.logicalcpu"}}
        }
        for _, candidate in ipairs(candidates) do
            local _, out = managed_toolchains_trycall(function ()
                return os.iorunv(candidate[1], candidate[2], {try = true})
            end)
            local count = tonumber((out or ""):gsub("^%s+", ""):gsub("%s+$", "")) or nil
            if count and count > 0 then
                return math.floor(count)
            end
        end
    end
    return os.default_njob and os.default_njob() or 8
end

default_jobs = tostring(managed_toolchains_detect_host_cpu_count())

option("toolchains_auto")
    set_default(os.getenv("TOOLCHAINS_AUTO") or "true")
    set_showmenu(true)
    set_description("Automatically bootstrap and use the project-local GCC toolchain during plain xmake builds")
option_end()

option("toolchains_target")
    set_default("")
    set_showmenu(true)
    set_description("Override target triplet")
option_end()

-- Source-identity overrides: empty default on purpose, see the note above the
-- ios_deployment_target literal. Empty means "use core/modules/defaults.lua".
option("gcc_git_url")
    set_default("")
    set_showmenu(true)
    set_description("Override the GCC git repository URL")
option_end()

option("gcc_ref")
    set_default("")
    set_showmenu(true)
    set_description("Override the GCC branch/tag/commit to sync")
option_end()

option("darwin_arm64_gcc_git_url")
    set_default("")
    set_showmenu(true)
    set_description("Override the Darwin Arm64 GCC git repository URL")
option_end()

option("darwin_arm64_gcc_ref")
    set_default("")
    set_showmenu(true)
    set_description("Override the Darwin Arm64 GCC branch/tag/commit to sync")
option_end()

option("wasm_gcc_git_url")
    set_default("")
    set_showmenu(true)
    set_description("Override the GCC WebAssembly backend git repository URL")
option_end()

option("wasm_gcc_ref")
    set_default("")
    set_showmenu(true)
    set_description("Override the pinned GCC WebAssembly backend commit")
option_end()

option("wasm_wabt_git_url")
    set_default("")
    set_showmenu(true)
    set_description("Override the WABT fork git repository URL required by the GCC WebAssembly backend")
option_end()

option("wasm_wabt_ref")
    set_default("")
    set_showmenu(true)
    set_description("Override the pinned WABT fork commit required by the GCC WebAssembly backend")
option_end()

option("wasm_ld")
    set_default(os.getenv("WASM_LD") or "")
    set_showmenu(true)
    set_description("wasm-ld executable used to link GCC-produced WebAssembly objects")
option_end()

option("wasm_node")
    set_default(os.getenv("NODE") or "")
    set_showmenu(true)
    set_description("Node.js executable used to run WebAssembly modules; overrides the managed Emscripten toolset Node")
option_end()

option("wasm_exit_runtime")
    set_default("auto")
    set_showmenu(true)
    set_description("Tear down the Emscripten runtime when main returns (auto/true = console-program exit semantics; false = keep the runtime alive for long-lived browser targets)")
option_end()

option("emscripten_emcc")
    set_default(os.getenv("EMCC") or "")
    set_showmenu(true)
    set_description("emcc executable override used only to link GCC-produced object files; the pinned managed Emscripten toolset is used when unset")
option_end()

option("gcc_features")
    set_default(os.getenv("GCC_FEATURES") or "")
    set_showmenu(true)
    set_description("Comma/space separated GCC features appended to the automatic gcc.features set")
option_end()

option("binutils_snapshot_url")
    set_default(default_binutils_snapshot_url)
    set_showmenu(true)
    set_description("GNU binutils source archive URL for cross targets")
option_end()

option("mingw_w64_snapshot_url")
    set_default(default_mingw_w64_snapshot_url)
    set_showmenu(true)
    set_description("MinGW-w64 runtime/header source archive URL for Windows targets")
option_end()

option("musl_snapshot_url")
    set_default(default_musl_snapshot_url)
    set_showmenu(true)
    set_description("musl libc source archive URL for project-local Linux cross sysroots")
option_end()

option("linux_libc")
    set_default(os.getenv("LINUX_LIBC") or "auto")
    set_showmenu(true)
    set_description("Linux target C library: auto, gnu, or musl. Cross Linux defaults to musl unless toolchains_target is set.")
option_end()

option("linux_sysroot")
    set_default(os.getenv("LINUX_SYSROOT") or "")
    set_showmenu(true)
    set_description("Existing Linux GNU/glibc sysroot for Linux cross targets; empty selects the project-managed glibc sysroot for gnu targets")
option_end()

-- Deliberately empty default (androidndk lesson): a non-empty env-derived
-- default freezes into the config cache at first configure and then
-- permanently masks later environment changes. The LINUX_GLIBC_VERSION
-- environment fallback lives at the consumer via settings.value_or
-- (languages/cpp/modules/gccglibc.lua resolve_version); empty means auto.
option("linux_glibc_version")
    set_default("")
    set_showmenu(true)
    set_description("Managed glibc version for GNU Linux cross targets: auto follows the Linux host glibc (closest supported); other hosts use the default supported version")
option_end()

option("glibc_snapshot_url")
    set_default("")
    set_showmenu(true)
    set_description("glibc source archive URL override for the project-managed glibc sysroot; empty uses the pinned URL for the resolved version")
option_end()

option("mingw_msvcrt")
    set_default(os.getenv("MINGW_DEFAULT_MSVCRT") or MANAGED_TOOLCHAINS_DEFAULTS.mingw_msvcrt)
    set_showmenu(true)
    set_description("MinGW-w64 default C runtime name, for example msvcrt or ucrt")
option_end()

-- Deliberately empty default: a non-empty env-derived default freezes into
-- the config cache at first configure and then permanently masks later
-- environment changes. The environment fallback lives at the consumer
-- (core/modules/androidndk.lua resolve():
-- option > ANDROID_NDK_HOME/ANDROID_NDK_ROOT/NDK_HOME > SDK ndk/ selection).
option("android_ndk")
    set_default("")
    set_showmenu(true)
    set_description("Android NDK root used as the Android target sysroot; empty resolves NDK env variables, then SDK-installed NDKs")
option_end()

option("android_api")
    set_default(os.getenv("ANDROID_API") or os.getenv("ANDROID_PLATFORM") or "26")
    set_showmenu(true)
    set_description("Android API level used when building the managed Android GCC target libraries; full libstdc++ requires at least 26")
option_end()

-- Deliberately empty default (androidndk lesson, same as apple_sdk): the
-- MACOSX_DEPLOYMENT_TARGET environment fallback lives at the consumers via
-- settings.value_or (falling back to 11.0), so later environment changes
-- are never masked by a value frozen into the config cache at f-time. The
-- configured option always outranks the environment.
option("macosx_deployment_target")
    set_default("")
    set_showmenu(true)
    set_description("macOS deployment target for Darwin GCC target runtimes and project builds; empty falls back to MACOSX_DEPLOYMENT_TARGET, then 11.0")
option_end()

-- Deliberately empty default (androidndk lesson): the APPLE_SDK environment
-- fallback lives at the consumer via settings.value_or, so later environment
-- changes are never masked by a frozen config cache value. The SDK itself is
-- user-provided: Apple's license terms do not allow this manager to download
-- macOS SDKs, so copy one from your own Mac/Xcode installation.
option("apple_sdk")
    set_default("")
    set_showmenu(true)
    set_description("User-provided macOS SDK root used for Darwin cross targets on non-macOS hosts; empty uses xcrun on macOS hosts")
option_end()

option("ios_deployment_target")
    set_default(default_ios_deployment_target)
    set_showmenu(true)
    set_description("iOS minimum deployment target used when building iOS GCC target runtimes")
option_end()

-- Deliberately empty default (androidndk lesson, same as apple_sdk): the
-- IOS_SDK environment fallback and the xcrun --sdk iphoneos probing (with
-- the DEVELOPER_DIR fallback) live at the consumer, targets/ios.lua.
option("ios_sdk")
    set_default("")
    set_showmenu(true)
    set_description("iOS SDK (iPhoneOS.sdk) root used for iOS targets; empty resolves through xcrun --sdk iphoneos on macOS hosts")
option_end()

option("toolchains_jobs")
    set_default(os.getenv("TOOLCHAINS_JOBS") or default_jobs)
    set_showmenu(true)
    set_description("Parallel jobs for GCC builds")
option_end()

option("toolchains_build_type")
    set_default(os.getenv("TOOLCHAINS_BUILD_TYPE") or "release")
    set_showmenu(true)
    set_description("Build type for project-local compiler binaries: release, debug, relwithdebinfo, or minsizerel")
option_end()

option("toolchains_build_optimize")
    set_default(os.getenv("TOOLCHAINS_BUILD_OPTIMIZE") or "")
    set_showmenu(true)
    set_description("Optimization level used when building compiler binaries, for example 0, 1, 2, 3, s, or z")
option_end()

option("toolchains_build_debug")
    set_default(os.getenv("TOOLCHAINS_BUILD_DEBUG") or "")
    set_showmenu(true)
    set_description("Whether compiler binaries keep debug info: auto, true, or false")
option_end()

option("toolchains_build_cflags")
    set_default(os.getenv("TOOLCHAINS_BUILD_CFLAGS") or "")
    set_showmenu(true)
    set_description("Extra CFLAGS used when building compiler binaries and helper tools")
option_end()

option("toolchains_build_cxxflags")
    set_default(os.getenv("TOOLCHAINS_BUILD_CXXFLAGS") or "")
    set_showmenu(true)
    set_description("Extra CXXFLAGS used when building compiler binaries and helper tools")
option_end()

option("toolchains_build_ldflags")
    set_default(os.getenv("TOOLCHAINS_BUILD_LDFLAGS") or "")
    set_showmenu(true)
    set_description("Extra LDFLAGS used when building compiler binaries and helper tools")
option_end()

option("toolchains_target_cflags")
    set_default(os.getenv("TOOLCHAINS_TARGET_CFLAGS") or "")
    set_showmenu(true)
    set_description("Extra target CFLAGS used when building GCC target runtime libraries")
option_end()

option("toolchains_target_cxxflags")
    set_default(os.getenv("TOOLCHAINS_TARGET_CXXFLAGS") or "")
    set_showmenu(true)
    set_description("Extra target CXXFLAGS used when building GCC target runtime libraries")
option_end()

option("toolchains_strip")
    set_default(os.getenv("TOOLCHAINS_STRIP") or "auto")
    set_showmenu(true)
    set_description("Strip installed compiler binaries after release builds: auto, true, or false")
option_end()

option("toolchains_make")
    set_default(os.getenv("MAKE") or "make")
    set_showmenu(true)
    set_description("GNU make compatible command")
option_end()

option("toolchains_auto_install_tools")
    set_default(os.getenv("TOOLCHAINS_AUTO_INSTALL_TOOLS") or "true")
    set_showmenu(true)
    set_description("Automatically install missing user-level bootstrap helper tools when a supported package manager is available")
option_end()

option("toolchains_package_manager")
    set_default(os.getenv("TOOLCHAINS_PACKAGE_MANAGER") or "auto")
    set_showmenu(true)
    set_description("Package manager for missing helper tools: auto, scoop, or none")
option_end()

option("toolchains_bootstrap")
    set_default(os.getenv("TOOLCHAINS_BOOTSTRAP") or "auto")
    set_showmenu(true)
    set_description("Windows host bootstrap provider: auto (provision only when host tools are missing), portable/force (always download and prepend a project-private bootstrap), path (use toolchains_bootstrap_path), or none")
option_end()

option("toolchains_bootstrap_url")
    set_default(os.getenv("TOOLCHAINS_BOOTSTRAP_URL") or MANAGED_TOOLCHAINS_DEFAULTS.windows_bootstrap_url)
    set_showmenu(true)
    set_description("Portable Windows MinGW bootstrap archive URL, or latest for the newest w64devkit release")
option_end()

option("toolchains_bootstrap_path")
    set_default(os.getenv("TOOLCHAINS_BOOTSTRAP_PATH") or "")
    set_showmenu(true)
    set_description("Existing portable Windows MinGW bootstrap root or bin directory")
option_end()

add_options(
    "toolchains_auto",
    "toolchains_target",
    "gcc_git_url",
    "gcc_ref",
    "darwin_arm64_gcc_git_url",
    "darwin_arm64_gcc_ref",
    "wasm_gcc_git_url",
    "wasm_gcc_ref",
    "wasm_wabt_git_url",
    "wasm_wabt_ref",
    "wasm_ld",
    "wasm_node",
    "wasm_exit_runtime",
    "emscripten_emcc",
    "gcc_features",
    "binutils_snapshot_url",
    "mingw_w64_snapshot_url",
    "musl_snapshot_url",
    "linux_libc",
    "linux_sysroot",
    "linux_glibc_version",
    "glibc_snapshot_url",
    "mingw_msvcrt",
    "android_ndk",
    "android_api",
    "macosx_deployment_target",
    "apple_sdk",
    "ios_deployment_target",
    "ios_sdk",
    "toolchains_jobs",
    "toolchains_build_type",
    "toolchains_build_optimize",
    "toolchains_build_debug",
    "toolchains_build_cflags",
    "toolchains_build_cxxflags",
    "toolchains_build_ldflags",
    "toolchains_target_cflags",
    "toolchains_target_cxxflags",
    "toolchains_strip",
    "toolchains_make",
    "toolchains_auto_install_tools",
    "toolchains_package_manager",
    "toolchains_bootstrap",
    "toolchains_bootstrap_url",
    "toolchains_bootstrap_path"
)
