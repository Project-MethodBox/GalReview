-- Description-scope code sees neither import nor raise/error at load or run
-- time (verified empirically), so failing needs the errors module injected
-- from script scope: the toolchains task shell calls the binder below before
-- any help printer can run.
local errors

function managed_toolchains_bind_help_errors(errors_module)
    errors = errors_module
end

local i18n

function managed_toolchains_bind_help_i18n(i18n_module)
    i18n = i18n_module
end

-- Help text rides the same gettext-shaped channel as diagnostics: the
-- English line is the catalog key, registered lines render in the detected
-- system language, everything else passes through verbatim. Usage lines
-- are command SYNTAX and deliberately stay untranslated.
local function tr(text, ...)
    if i18n then
        return i18n.tr(text, ...)
    end
    return text
end

local print_managed_gcc_features_help = print_managed_gcc_features_help

local toolchains_subject_help = {
    "windows   manage the Windows target compiler for the current host",
    "linux     manage the Linux target compiler for the current host",
    "android   manage the Android target compiler for the current host",
    "macosx    manage the macOS target compiler for the current host",
    "ios       manage the iOS target compiler for the current host",
    "emscripten manage the experimental GCC WebAssembly C/C++ toolchain",
    "host      alias for the current host target"
}

local toolchains_config_help = {
    {"--toolchains_auto=<true|false>", "Enable or disable automatic bootstrap/use of the project-local GCC toolchain during plain xmake builds."},
    {"--toolchains_target=<triplet>", "Override the inferred GNU target triplet."},
    {"--gcc_features=<list>", "Comma/space separated feature names appended globally through gcc.features."},
    -- The eight source-identity options below override the project defaults
    -- for THIS configuration only; each config store keeps its own copy. Pass
    -- an empty value (`--gcc_ref=`) to drop the override and follow the
    -- project default again.
    {"--gcc_git_url=<url>", "Override the GCC git repository URL."},
    {"--gcc_ref=<ref>", "Override the GCC branch, tag, or commit the manager syncs."},
    {"--darwin_arm64_gcc_git_url=<url>", "Override the Darwin Arm64 GCC git repository URL."},
    {"--darwin_arm64_gcc_ref=<ref>", "Override the Darwin Arm64 GCC branch, tag, or commit the manager syncs."},
    {"--wasm_gcc_git_url=<url>", "Override the GCC WebAssembly backend repository URL."},
    {"--wasm_gcc_ref=<commit>", "Override the pinned GCC WebAssembly backend commit."},
    {"--wasm_wabt_git_url=<url>", "Override the annotated-WAT WABT fork repository required by the GCC backend."},
    {"--wasm_wabt_ref=<commit>", "Override the pinned WABT fork commit."},
    {"--wasm_ld=<path>", "wasm-ld override for WebAssembly linking; the managed Emscripten toolset LLVM is used when unset."},
    {"--wasm_node=<path>", "Node.js override for running WebAssembly modules; the managed Emscripten toolset Node is used when unset."},
    {"--wasm_exit_runtime=<auto|true|false>", "Tear down the Emscripten runtime when main returns (default on; set false for long-lived browser targets)."},
    {"--emscripten_emcc=<path>", "emcc override used only to link GCC-produced objects; the pinned managed Emscripten toolset is used when unset."},
    {"--binutils_snapshot_url=<url>", "GNU binutils archive URL for cross targets."},
    {"--mingw_w64_snapshot_url=<url>", "MinGW-w64 runtime and header archive URL for Windows targets."},
    {"--musl_snapshot_url=<url>", "musl libc archive URL for Linux musl cross sysroots."},
    {"--linux_libc=<auto|gnu|musl>", "Linux target C library selection; gnu cross targets without linux_sysroot use the project-managed glibc sysroot (built on Linux hosts)."},
    {"--linux_sysroot=<path>", "Existing GNU/Linux sysroot path when linux_libc is gnu; empty selects the project-managed glibc sysroot."},
    {"--linux_glibc_version=<auto|X.Y>", "Managed glibc version for gnu Linux cross targets; auto follows the Linux host glibc (closest supported) and uses the default supported version on other hosts."},
    {"--glibc_snapshot_url=<url>", "glibc source archive URL override for the project-managed glibc sysroot."},
    {"--mingw_msvcrt=<name>", "MinGW-w64 default C runtime name, for example msvcrt or ucrt."},
    {"--android_ndk=<path>", "Android NDK root used as the Android target sysroot. Resolution order: option, then ANDROID_NDK_HOME/ANDROID_NDK_ROOT/NDK_HOME, then SDK ndk/<android_ndk_version>, then the newest SDK ndk; the toolchains and android command families share one resolver."},
    {"--android_api=<level>", "Android API level used for Android target libraries."},
    {"--macosx_deployment_target=<version>", "macOS deployment minimum for Darwin GCC target runtimes AND project builds (injected as an explicit driver flag, so the configured value outranks any ambient MACOSX_DEPLOYMENT_TARGET; empty falls back to that environment variable, then 11.0)."},
    {"--apple_sdk=<path>", "User-provided macOS SDK root for Darwin cross targets on non-macOS hosts (copy one from your own Mac/Xcode; Apple's license forbids downloading it here); empty uses xcrun on macOS hosts. APPLE_SDK env is the fallback."},
    {"--ios_deployment_target=<version>", "iOS deployment minimum for iOS GCC target runtimes and project builds (default 15.0; the toolchain's compiled-in default is baked at patch time, and a differing configured value reaches project builds as an explicit driver flag)."},
    {"--ios_sdk=<path>", "iOS SDK (iPhoneOS.sdk) root for iOS targets; empty resolves through xcrun --sdk iphoneos on macOS hosts. IOS_SDK env is the fallback."},
    {"--toolchains_jobs=<count>", "Parallel job count used by GCC and runtime builds."},
    {"--toolchains_build_type=<release|debug|relwithdebinfo|minsizerel>", "Build type used for compiler binaries; release is the default."},
    {"--toolchains_build_optimize=<0|1|2|3|s|z>", "Optimization level used for compiler binaries; empty follows toolchains_build_type."},
    {"--toolchains_build_debug=<auto|true|false>", "Keep debug information in compiler binaries; auto is false for release/minsizerel."},
    {"--toolchains_build_cflags=<flags>", "Extra CFLAGS used when building compiler binaries and helper tools."},
    {"--toolchains_build_cxxflags=<flags>", "Extra CXXFLAGS used when building compiler binaries and helper tools."},
    {"--toolchains_build_ldflags=<flags>", "Extra LDFLAGS used when building compiler binaries and helper tools."},
    {"--toolchains_target_cflags=<flags>", "Extra target CFLAGS used when building GCC target runtime libraries."},
    {"--toolchains_target_cxxflags=<flags>", "Extra target CXXFLAGS used when building GCC target runtime libraries."},
    {"--toolchains_strip=<auto|true|false>", "Strip installed compiler binaries and target runtime debug data after release builds; auto follows toolchains_build_type."},
    {"--toolchains_make=<command>", "GNU make compatible command."},
    {"--toolchains_auto_install_tools=<true|false>", "Allow xmake to install missing user-level helper tools when supported."},
    {"--toolchains_package_manager=<auto|scoop|none>", "Package manager used for missing helper tools; auto only uses Scoop on Windows."},
    {"--toolchains_bootstrap=<auto|portable|path|none>", "Windows host bootstrap provider used when no complete MinGW sysroot/tools are found."},
    {"--toolchains_bootstrap_url=<latest|url>", "Portable Windows MinGW bootstrap archive. latest resolves the newest w64devkit release."},
    {"--toolchains_bootstrap_path=<path>", "Existing portable Windows MinGW root or bin directory used when toolchains_bootstrap=path or as an auto candidate."}
}

local toolchains_command_help = {
    {
        name = "help",
        usage = "xmake toolchains help [command|options]",
        summary = "Show toolchain manager help.",
        details = {
            "Without a command, prints the command list.",
            "With a command, prints command-specific usage and behavior.",
            "Use `xmake toolchains help options` to list xmake configuration options that start with --.",
            "Use `xmake toolchains help features` to list the managed GCC feature switches and groups.",
            "`xmake toolchains --help` and `xmake toolchains -h` are accepted as help aliases when passed through by xmake."
        }
    },
    {
        name = "status",
        usage = "xmake toolchains status [windows|linux|android|macosx|ios|emscripten|host]",
        summary = "Print paths, target triplet, installation state, source URL, and proxy state.",
        details = {
            "This command is read-only.",
            "If no subject is provided, it uses xmake's configured platform."
        }
    },
    {
        name = "matrix",
        usage = "xmake toolchains matrix [windows|linux|android|macosx|ios|emscripten|rust|host]",
        summary = "Print a one-line-per-target overview of every managed toolchain on this host.",
        details = {
            "This command is read-only: its probes never download, configure, or build anything.",
            "Without a subject it prints every target OS row plus a rust summary row; with one it prints that row only.",
            "Columns: triplet/arch (as configured), source profile and pinned ref, source synced, toolchain installed, smoke state (emscripten backend smoke and macosx cross Mach-O smoke; other targets use the engine test suites), verified (static registry of real-machine build+smoke evidence for this host), and the first missing prerequisite from the preflight probe.",
            "Values come from the same probes `xmake toolchains status <subject>` uses, so the two commands cannot disagree.",
            "The Windows row queries the host compiler for its sysroot once; read-only but second-scale."
        }
    },
    {
        name = "fetch",
        aliases = {"sync"},
        usage = "xmake toolchains fetch [windows|linux|android|macosx|ios|emscripten|host]",
        summary = "Clone, fetch, or reuse the GCC source profile selected for the subject target.",
        details = {
            "This prepares GCC source files, GCC prerequisites, and generator tools, and applies the registered source patches (verified by hard postconditions before the patch stamp is written).",
            "Pinned revisions restore from a matching offline bundle under .toolchains/.cache/bundles before any remote is tried (see `xmake toolchains bundle`).",
            "macosx and ios share one pinned Darwin arm64 source tree; fetching either subject also carries the additive iOS patch layer.",
            "For emscripten it also downloads and digest-checks the pinned managed Emscripten toolset archives (emcc/LLVM, Node.js, Windows python).",
            "It does not build or install a compiler."
        }
    },
    {
        name = "install",
        aliases = {"bootstrap"},
        usage = "xmake toolchains install [windows|linux|android|macosx|ios|emscripten|host]",
        summary = "Ensure the project-local GCC toolchain is installed for the selected target.",
        details = {
            "The compiler is installed under the project-local .toolchains directory.",
            "If the selected toolchain is already installed, this command reuses it.",
            "Use `xmake toolchains build` for an explicit rebuild.",
            "Installed toolchains use .toolchains/<host>/<target>/<arch>.",
            "GCC source uses a target-selected shared cache under .toolchains/.cache/src.",
            "Host-local downloads, build, tools, and state files use .toolchains/.cache/<host>.",
            "Plain xmake builds call this automatically when toolchains_auto is enabled and the selected toolchain is missing."
        }
    },
    {
        name = "checksums",
        usage = "xmake toolchains checksums",
        summary = "List pinned-digest coverage and this host's trust-on-first-use records.",
        details = {
            "Read-only: prints how many archives carry pinned digests plus every TOFU record this host has accumulated.",
            "TOFU records live in the host-local cache and die with it (a cold CI host re-trusts from zero), so digests worth keeping should graduate into the pinned registry.",
            "Each record is printed as a paste-ready core/modules/checksums.lua entry; re-establish the digest first-hand (upstream signature, official manifest, or multi-source cross-check) before pinning it."
        }
    },
    {
        name = "pin",
        usage = "xmake toolchains pin [clear]",
        summary = "Pin the current plat/arch/mode; any later drift warns on every configure.",
        details = {
            "xmake treats unspecified `xmake f` options as defaults, and description-file",
            "changes trigger implicit reconfigures with those defaults -- both can silently",
            "reset plat/arch/mode. Pinning records the intended configuration under",
            ".toolchains/<host>-config.pin; `xmake toolchains pin clear` removes it.",
            "Without a pin the sentinel stays silent (CI is unaffected)."
        }
    },
    {
        name = "update",
        usage = "xmake toolchains update [windows|linux|android|macosx|ios|emscripten|host]",
        summary = "Refresh the selected GCC source profile and rebuild an already installed selected toolchain.",
        details = {
            "GCC source updates use git fetch --depth=1 for the selected ref.",
            "If shallow fetch is not usable, the manager falls back to a full git fetch.",
            "Existing source prerequisites and build directories are kept so GCC can reuse build cache where possible.",
            "If the fetched GCC commit is unchanged, no compiler rebuild is started.",
            "If the selected compiler is not installed yet, this updates source only.",
            "Use install after update when bootstrapping a new target."
        }
    },
    {
        name = "bundle",
        usage = "xmake toolchains bundle [windows|linux|android|macosx|ios|emscripten|host]",
        summary = "Create an offline git bundle of the synced GCC source profile.",
        details = {
            "The bundle lands under .toolchains/.cache/bundles, keyed by source cache name and revision.",
            "A fresh sync of the same pinned revision restores from the bundle before trying any remote.",
            "This is the durable escape when a rebased upstream branch no longer carries the pinned revision.",
            "For emscripten this also bundles the pinned WABT fork sources.",
            "Copy bundle files into another machine's .toolchains/.cache/bundles to seed it offline."
        }
    },
    {
        name = "build",
        usage = "xmake toolchains build [windows|linux|android|macosx|ios|emscripten|host]",
        summary = "Compatibility alias for installing a project-local toolchain.",
        details = {
            "Build outputs are still produced by plain xmake.",
            "This command only builds the compiler toolchain."
        }
    },
    {
        name = "smoke",
        aliases = {"verify"},
        usage = "xmake toolchains smoke [macosx|emscripten]",
        summary = "Compile, link, and statically assert the target-specific toolchain capability probes.",
        details = {
            "The source object is always produced by GCC; Clang is never used as the target source compiler.",
            "emscripten: the mandatory path validates C/C++26, Basic C ABI, __int128/libgcc, freestanding libstdc++, the pinned WABT fork, wasm-ld, and Node.js.",
            "emscripten: if emcc is configured, it receives only the GCC-produced object for an additional link-only compatibility probe.",
            "macosx (cross builds only): compiles C and C++ probes, links an executable and a dylib, and statically asserts Mach-O file types plus expected symbols via readobj/otool; run the artifacts on a real mac to extend the evidence.",
            "macosx (native macOS hosts): the engine test suites are the smoke; this command has nothing extra to add there.",
            "This does not claim a target libc, hosted libstdc++, exceptions, the complete Emscripten ABI, or full Engine support."
        }
    },
    {
        name = "rebuild",
        aliases = {"repatch"},
        usage = "xmake toolchains rebuild [windows|linux|android|macosx|ios|emscripten|host]",
        summary = "Discard the cached GCC build directory and recompile the toolchain from source.",
        details = {
            "Unlike update, this ignores the git revision check and always recompiles.",
            "Use it after changing the registered GCC source patches (gccpatches.patch_gcc_source),",
            "or when the cached build directory references a bootstrap toolchain that no longer exists.",
            "The GCC source is re-synced and re-patched, the build directory is reset, and GCC is rebuilt from scratch.",
            "A full GCC recompile is expensive; expect a long run."
        }
    }
}

local function toolchains_command_index()
    local index = {}
    for _, info in ipairs(toolchains_command_help) do
        index[info.name] = info
        for _, alias in ipairs(info.aliases or {}) do
            index[alias] = info
        end
    end
    return index
end

function print_toolchains_config_help()
    print("usage: xmake f [--option=value] ...")
    print("")
    print(tr("These are xmake configuration options, not `xmake toolchains` positional arguments."))
    print(tr("Set them with `xmake f --name=value`, then run `xmake toolchains ...` or plain `xmake`."))
    print("")
    print(tr("options:"))
    for _, info in ipairs(toolchains_config_help) do
        print(string.format("  %-36s %s", info[1], tr(info[2])))
    end
    print("")
    print(tr("common xmake options:"))
    print("  --toolchain=gcc|mingw                " .. tr("Allow toolchains.auto to install project-local GCC toolsets."))
    print("  --toolchain=<other>                  " .. tr("Bypass GCC auto toolset setup and gcc.features."))
    print("  -p, --plat=<plat>                    " .. tr("Select xmake platform, for example mingw, linux, or android."))
    print("  -a, --arch=<arch>                    " .. tr("Select target architecture when needed."))
end

function print_toolchains_help(command)
    local index = toolchains_command_index()
    if command and command ~= "" and command ~= "all" then
        if command == "options" or command == "config" then
            print_toolchains_config_help()
            return
        end
        if command == "features" or command == "gcc_features" then
            print_managed_gcc_features_help()
            return
        end
        local info = index[command]
        if not info then
            errors.fail("unknown toolchains command for help: %s", command)
        end
        print("usage: " .. info.usage)
        print("")
        print(tr(info.summary))
        if info.aliases and #info.aliases > 0 then
            print(tr("aliases: %s", table.concat(info.aliases, ", ")))
        end
        if info.details and #info.details > 0 then
            print("")
            for _, detail in ipairs(info.details) do
                print("  - " .. tr(detail))
            end
        end
        print("")
        print(tr("subjects:"))
        for _, subject in ipairs(toolchains_subject_help) do
            print("  " .. tr(subject))
        end
        print("")
        print(tr("configuration:"))
        print("  " .. tr("Run `xmake toolchains help options` for --option=value settings."))
        return
    end

    print("usage: xmake toolchains <command> [subject]")
    print("")
    print(tr("Manage the project-local GCC toolchains (mainline, Darwin arm64, and experimental wasm source profiles)."))
    print("")
    print(tr("commands:"))
    for _, info in ipairs(toolchains_command_help) do
        local alias_text = ""
        if info.aliases and #info.aliases > 0 then
            alias_text = " " .. tr("(aliases: %s)", table.concat(info.aliases, ", "))
        end
        print(string.format("  %-8s %s%s", info.name, tr(info.summary), alias_text))
    end
    print("")
    print(tr("subjects:"))
    for _, subject in ipairs(toolchains_subject_help) do
        print("  " .. tr(subject))
    end
    print("")
    print(tr("configuration:"))
    print("  " .. tr("Set manager options with `xmake f --name=value`."))
    print("  " .. tr("Run `xmake toolchains help options` for the full --option list."))
    print("  " .. tr("Compiler-build defaults are release, optimized, debug-info off, and strip on."))
    print("  " .. tr("Tune them with --toolchains_build_type/optimize/debug/cflags/cxxflags/ldflags and --toolchains_strip."))
    print("  " .. tr("On Windows, missing host MinGW tools are bootstrapped from latest w64devkit unless toolchains_bootstrap says otherwise."))
    print("  " .. tr(".toolchains uses .cache plus host folders such as windows/linux/android/macosx."))
    print("  " .. tr("Installed compilers live in .toolchains/<host>/<target>/<arch>."))
    print("  " .. tr("Plain `xmake` bootstraps the selected project-local GCC toolchain when toolchains_auto is enabled."))
    print("")
    print(tr("xmake.lua helpers:"))
    print("  " .. tr("toolchains.auto points target toolsets to .toolchains/<host>/<target>/<arch>/bin."))
    print("  " .. tr("gcc/mingw toolchains automatically get gcc.features=all."))
    print("  " .. tr("add_gcc_features(...) and set_gcc_features(...) append/replace per-target GCC feature settings."))
    print("  " .. tr("xmake f --gcc_features=... appends project-wide GCC feature settings."))
    print("")
    print_managed_gcc_features_help()
    print("")
    print(tr("Use `xmake toolchains help <command>` for command-specific help."))
end
