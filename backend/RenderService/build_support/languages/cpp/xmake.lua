includes(path.join(os.scriptdir(), "toolchains", "core.lua"))

-- Every callback below imports the modules it needs directly (script
-- scope owns import); these directory constants are the only shared
-- chunk state, captured lexically by the callbacks (os.scriptdir() is
-- only valid at description load).
local CORE_MODULES_DIR = path.join(os.scriptdir(), "..", "..", "core", "modules")
local CPP_MODULES_DIR = path.join(os.scriptdir(), "modules")
local OPTIONS_FILE = path.join(os.scriptdir(), "options.lua")

includes(path.join(os.scriptdir(), "toolchains", "gcc_features.lua"))

includes(path.join(os.scriptdir(), "toolchains", "gcc_features_help.lua"))
includes(path.join(os.scriptdir(), "toolchains", "gcc_feature_rules.lua"))

-- Callback-reachable capture of the gcc_features_help.lua error binder (the
-- help printer is description-scope code that can neither import nor raise
-- on its own; the toolchains task shell injects the errors module through
-- this binder before help can fail).
local bind_gcc_features_help_errors = managed_toolchains_bind_gcc_features_help_errors

-- Shared admission gate for toolchains.auto and gcc.platform (a chunk-local
-- upvalue on purpose: callbacks can reach it, while cross-chunk globals do
-- not survive the cold-configure sandbox -- see gcc_feature_rules.lua).
-- Returns nil when managed GCC must keep its hands off the target (auto
-- switch off, foreign plat, explicit non-GCC toolchain), else the resolved
-- { target_os, declared }. Identity comes from gccfeatures.toolchain_of --
-- the ONE resolution implementation, shared with gcc.features, so the rules
-- cannot drift apart. It is deliberately order-free: every rule calls this
-- gate itself instead of reading another rule's leftovers, because rule
-- dependencies execute depended-upon FIRST (probe-verified 2026-08-02), so
-- gcc.platform runs before toolchains.auto and could never see its data.
-- import is script-scope only, while this chunk-local body resolves globals
-- through the description chunk's _ENV (get_config/is_plat exist there,
-- import does not -- the gcc_feature_rules.lua sandbox note). Every callback
-- assigns the script-scope import here before calling the gate.
local script_import

local function managed_gcc_context(target)
    local settings = script_import("settings", {rootdir = CORE_MODULES_DIR})
    local enabled = tostring(settings.value_or("toolchains_auto", "true")):lower()
    if enabled == "false" or enabled == "0" or enabled == "off" or enabled == "no" then
        return nil
    end
    local target_os = settings.configured_target_os()
    if target_os ~= "windows" and target_os ~= "linux" and target_os ~= "android"
        and target_os ~= "macosx" and target_os ~= "ios" and target_os ~= "emscripten" then
        return nil
    end
    local gccfeatures = script_import("gccfeatures", {rootdir = CPP_MODULES_DIR})
    local declared = gccfeatures.toolchain_of(target, {
        global_toolchain = get_config("toolchain"),
        mingw_plat = is_plat("mingw"),
        default_toolchain = settings.default_project_gcc_toolchain_for_current_platform()
    })
    if not gccfeatures.is_gcc_toolchain(declared) then
        return nil
    end
    return {target_os = target_os, declared = declared}
end

toolchain("project_gcc")
    set_kind("standalone")
    set_description("Project-local GCC toolchain")
    set_runtimes("stdc++_static", "stdc++_shared")

    on_check(function (toolchain)
        return true
    end)

    on_load(function (toolchain)
        local settings = import("settings", {rootdir = CORE_MODULES_DIR})
        local target_os = settings.configured_target_os()
        if target_os ~= "windows" and target_os ~= "linux" and target_os ~= "android"
            and target_os ~= "macosx" and target_os ~= "ios" and target_os ~= "emscripten" then
            return
        end

        local hostboot = import("hostboot", {rootdir = CPP_MODULES_DIR})
        local gccstatus = import("gccstatus", {rootdir = CPP_MODULES_DIR})
        local triplet = settings.managed_target(target_os)
        local bindir = path.join(settings.gcc_prefix(target_os), "bin")
        local function tool(name)
            return hostboot.managed_tool(bindir, triplet, name)
        end

        toolchain:add("runenvs", "PATH", bindir)

        toolchain:add("toolset", "cc", tool("gcc"))
        toolchain:add("toolset", "cxx", tool("g++"), tool("gcc"))
        toolchain:add("toolset", "cpp", tool("gcc") .. " -E")
        toolchain:add("toolset", "as", tool("gcc"))
        toolchain:add("toolset", "ld", tool("g++"), tool("gcc"))
        toolchain:add("toolset", "sh", tool("g++"), tool("gcc"))
        toolchain:add("toolset", "ar", tool(gccstatus.project_gcc_ar_tool_name(target_os)))
        toolchain:add("toolset", "ranlib", tool(gccstatus.project_gcc_ranlib_tool_name(target_os)))
        toolchain:add("toolset", "strip", tool("strip"))
        toolchain:add("toolset", "objcopy", tool("objcopy"))
        toolchain:add("toolset", "mm", tool("gcc"))
        toolchain:add("toolset", "mxx", tool("g++"), tool("gcc"))
        if target_os == "windows" then
            toolchain:add("toolset", "mrc", tool("windres"))
            toolchain:add("toolset", "dlltool", tool("dlltool"))
        end

        local arch = toolchain:arch()
        if arch == "x86_64" or arch == "x64" then
            toolchain:add("cxflags", "-m64")
            toolchain:add("asflags", "-m64")
            toolchain:add("ldflags", "-m64")
            toolchain:add("shflags", "-m64")
        elseif arch == "i386" or arch == "x86" then
            toolchain:add("cxflags", "-m32")
            toolchain:add("asflags", "-m32")
            toolchain:add("ldflags", "-m32")
            toolchain:add("shflags", "-m32")
        end

        -- Android project compilation needs the NDK adjustments the compiler
        -- cannot default on its own: the per-triplet arch include dir (bionic
        -- keeps asm/ there, not under usr/include), the GCC/NDK compat
        -- header, the API level macros, and the API-versioned bionic library
        -- directories. The toolchain BUILD gets the same set through
        -- android_target_driver_flags; this is the project-build twin.
        if target_os == "android" then
            local base = import("base", {rootdir = CORE_MODULES_DIR})
            local gcctargets = import("gcctargets", {rootdir = CPP_MODULES_DIR})
            local api = gcctargets.android_api_level()
            local arch_include = gcctargets.android_arch_include_dir(target_os)
            if arch_include then
                toolchain:add("cxflags", "-idirafter" .. base.shpath(arch_include))
            end
            local sysroot_include = gcctargets.android_sysroot_include_dir(target_os)
            if sysroot_include then
                toolchain:add("cxflags", "-idirafter" .. base.shpath(sysroot_include))
            end
            -- -imacros, not -include: module interface units must START with
            -- their module declaration, and -include prepends tokens that
            -- break the preamble ("export may only occur after a module
            -- interface declaration" on bits/std.cc). -imacros keeps the
            -- compat macro definitions but contributes no tokens.
            toolchain:add("cxflags", "-imacros", base.shpath(gcctargets.ensure_android_gcc_compat_header()))
            toolchain:add("cxflags", "-D__ANDROID_API__=" .. api)
            toolchain:add("cxflags", "-D__ANDROID_MIN_SDK_VERSION__=" .. api)
            -- The NDK -L directories below are needed for the bionic crt
            -- objects and libraries, but they also contain the NDK's legacy
            -- libstdc++.so stub (a handful of loader symbols, not a C++
            -- runtime): if they outrank the compiler's own target libraries
            -- in the link search order, -lstdc++ binds to the stub and every
            -- real libstdc++ symbol comes out undefined (seen live
            -- 2026-07-18 on the Linux box). List the managed GCC's own
            -- target library directories first so its libstdc++ wins.
            local gcc_target_root = path.join(settings.gcc_prefix(target_os), settings.managed_target(target_os))
            for _, leaf in ipairs({"lib64", "lib"}) do
                local dir = path.join(gcc_target_root, leaf)
                if os.isdir(dir) then
                    toolchain:add("ldflags", "-L" .. base.shpath(dir))
                    toolchain:add("shflags", "-L" .. base.shpath(dir))
                end
            end
            local api_lib = gcctargets.android_api_library_dir(target_os)
            if api_lib then
                toolchain:add("ldflags", "-B" .. base.shpath(api_lib) .. "/", "-L" .. base.shpath(api_lib))
                toolchain:add("shflags", "-B" .. base.shpath(api_lib) .. "/", "-L" .. base.shpath(api_lib))
            end
            local libroot = gcctargets.android_library_root(target_os)
            if libroot then
                toolchain:add("ldflags", "-L" .. base.shpath(libroot))
                toolchain:add("shflags", "-L" .. base.shpath(libroot))
            end
            toolchain:add("ldflags", "-static-libgcc")
            toolchain:add("shflags", "-static-libgcc")
            -- bionic keeps the dlopen family in libdl.so and the GCC android
            -- driver does not add it on its own; the engine's
            -- dynamic_link_library_loader needs it on every link.
            toolchain:add("syslinks", "dl")
        end

        -- Darwin deployment minimums: the xmake config options
        -- (--macosx_deployment_target / --ios_deployment_target) are the
        -- authoritative source for project builds. The Darwin driver's own
        -- precedence is command line > MACOSX_DEPLOYMENT_TARGET environment
        -- > compiled-in default, so injecting the configured value as an
        -- explicit flag both applies the option and shields project builds
        -- from ambient environment leakage (a Mac shell's stray
        -- MACOSX_DEPLOYMENT_TARGET can no longer override the config).
        -- For iOS the patched driver has no -miphoneos-version-min option:
        -- its single Darwin version knob is -mmacosx-version-min, which the
        -- darwin-ios.h specs re-brand as the iOS minimum end to end
        -- (LC_BUILD_VERSION minos via "-platform_version ios", assembler
        -- via "-miphoneos-version-min").
        if target_os == "macosx" or target_os == "ios" then
            local defaults = import("defaults", {rootdir = CORE_MODULES_DIR}).values()
            local settings = import("settings", {rootdir = CORE_MODULES_DIR})
            local deployment
            if target_os == "ios" then
                deployment = tostring(settings.value_or("ios_deployment_target", defaults.ios_deployment_target))
            else
                deployment = tostring(settings.value_or("macosx_deployment_target", "11.0"))
            end
            for _, kind in ipairs({"cxflags", "asflags", "ldflags", "shflags"}) do
                toolchain:add(kind, "-mmacosx-version-min=" .. deployment)
            end
        end
    end)

-- Platform-ABI and gap-fix flag injection for managed-GCC targets: this rule
-- owns "how objects are compiled and linked ON this platform" (runtimes,
-- PIC, the emscripten target shape, --embed-dir), as opposed to "WHICH
-- toolchain compiles them and is it present" (toolchains.auto) and "which
-- NAMED features are switched on" (gcc.features). Attached automatically as
-- a dependency of toolchains.auto -- projects keep writing the classic trio
-- (or just gcc.managed) and never list this rule by hand.
rule("gcc.platform")
    on_load(function (target)
        script_import = import
        local context = managed_gcc_context(target)
        if not context then
            return
        end
        local settings = import("settings", {rootdir = CORE_MODULES_DIR})
        local target_os = context.target_os
        -- Every managed target is GCC/libstdc++, so declare the C++ runtime
        -- explicitly (matching project_gcc's set_runtimes default). Without it,
        -- xmake's get_cpplibrary_name falls back to a hard-coded plat allowlist
        -- that omits this project's "ios" plat name -- it only recognizes
        -- "iphoneos"/"appletvos"/... -- so it returns nil, and the std-module
        -- provisioning (support.get_stdmodules) bails on `if not cpplib`, adding
        -- no std module at all. Every `import std;` unit on iOS then fails the
        -- scanner with a non-deterministic "missing std dependency for module
        -- <X>". Setting the runtime makes the detection runtime-based and thus
        -- correct on every plat (wasm/emscripten already relied on this below).
        target:set("runtimes", "stdc++_static")
        -- Android engine archives exist to be linked into the APK's shared
        -- library, so every member object must be position-independent -- and
        -- the managed GCC, unlike NDK clang, does not default to PIC. This is
        -- platform ABI, not project policy, so it is injected here instead of
        -- being repeated as an is_os("android") stanza in every project file.
        -- cxflags covers C units too; shared targets get -fPIC from xmake.
        if target_os == "android" and target:is_static() then
            target:add("cxflags", "-fPIC")
        end
        -- Android executables must be PIE for the same reason: the platform
        -- loader has rejected non-PIE executables since API 21, and the
        -- managed GCC defaults to no-pie (verified ET_EXEC on the 2026-08-03
        -- CI binary). The engine archives feeding the link are already
        -- -fPIC, so only the binary's own units and the link driver flag are
        -- missing. Shared targets get PIC/-shared from xmake itself.
        if target_os == "android" and target:is_binary() then
            target:add("cxflags", "-fPIE")
            target:add("ldflags", "-pie")
        end
        if target_os == "emscripten" then
            -- GCC remains the only C/C++ compiler. The pthread option selects
            -- the Emscripten ABI macros and the POSIX gthread implementation;
            -- emcc (wired by toolchains.auto) is only the final linker driver.
            target:add("cxflags", "-pthread", {force = true})

            -- 64-bit linear memory. Both sides of the toolchain have to agree:
            -- -mwasm64 makes GCC emit 64-bit pointers and select the wasm64
            -- multilib of libgcc/libstdc++, and -sMEMORY64 makes emcc link
            -- against its own wasm64 sysroot and pass the matching emulation
            -- to wasm-ld. Neither implies the other -- mixing widths fails at
            -- link time -- so both come from the single settings predicate.
            if settings.wasm_memory64(target_os) then
                target:add("cxflags", "-mwasm64", {force = true})
            end

            -- Debug information on this target is name-section function names,
            -- not DWARF (probe evidence, 2026-07): the GCC 17 wasm backend
            -- emits no debug output at all (-g is a warned byte-level no-op,
            -- -gdwarf-N is a hard error), emcc -g only embeds DWARF from the
            -- clang-built Emscripten runtime objects (zero coverage of GCC
            -- code) while crippling wasm-opt into "limited binaryen
            -- optimizations" (~12x wasm bloat at -O3), -gsource-map is derived
            -- from that same DWARF so it maps no GCC code either, and the WABT
            -- fork --debug-names path emits objects wasm-ld rejects.
            -- symbols=none therefore stops xmake mapping symbols=debug to -g
            -- on both the compile side (kills the per-TU "target system does
            -- not support debug output" warning pair without relying on the
            -- feature-layer -g0 winning a flag-order race) and the emcc link
            -- side; the link keeps -g2 below as the function-name baseline.
            target:set("symbols", "none")

            if target:is_binary() or target:is_shared() then
                -- xmake's generic C++ symbol-extraction rule uses the ELF
                -- --only-keep-debug/--add-gnu-debuglink objcopy workflow.
                -- LLVM deliberately does not implement that workflow for
                -- WebAssembly, so skip the requested post-link strip. -g2
                -- preserves the wasm name section (GCC-side function names,
                -- demangled by wasm-ld, including internal statics) and,
                -- unlike -g, leaves the full wasm-opt pipeline enabled in
                -- release (-O3 -g2 verified: full --post-emscripten pass,
                -- no limited-postlink).
                target:set("strip", "none")
                target:add("ldflags", "-nostdlibxx", "-pthread", "-sPTHREAD_POOL_SIZE=4", "-g2", {force = true})
                target:add("shflags", "-nostdlibxx", "-pthread", "-sPTHREAD_POOL_SIZE=4", "-g2", {force = true})
                target:add("syslinks", "stdc++exp", "gcc")
                if settings.wasm_memory64(target_os) then
                    target:add("ldflags", "-sMEMORY64=1", {force = true})
                    target:add("shflags", "-sMEMORY64=1", {force = true})
                end
            end
            if target:is_binary() then
                target:set("extension", ".js")
                target:add("ldflags", "-sPROXY_TO_PTHREAD=1", "-sIGNORE_MISSING_MAIN=0", {force = true})
                -- Owner-configurable runtime-exit semantics (2026-07-17):
                -- default ON makes executables exit when main returns like a
                -- console program (without it, node runs hang alive after
                -- main; the smoke links always pass it). Long-lived browser
                -- targets can configure --wasm_exit_runtime=false.
                if settings.config_bool("wasm_exit_runtime", true) then
                    target:add("ldflags", "-sEXIT_RUNTIME=1", {force = true})
                end
                if tostring(settings.value_or("mode", "")) == "debug" then
                    -- pinned against emcc default drift: ASSERTIONS currently
                    -- defaults on only because debug links at -O0 (main-module
                    -- setting; side modules have no runtime glue to assert in)
                    target:add("ldflags", "-sASSERTIONS=1", {force = true})
                end
            elseif target:is_shared() then
                target:set("extension", ".wasm")
                target:add("shflags", "-sSIDE_MODULE=1", {force = true})
            end
        end

        -- add_embeddirs -> --embed-dir: xmake maps target.embeddirs to gcc's
        -- nf_embeddir only for a fully-registered toolchain tool, NOT for the
        -- bare-path toolset toolchains.auto installs (verified 2026-07-23:
        -- --embed-dir is silently dropped for both this rule and a plain
        -- set_toolset("cxx", <path>), while -D/-I still come through, so C++26
        -- `#embed <name>` fails with "no include path in which to search for
        -- <name>"). Inject it explicitly, absolute so it resolves from any
        -- compile cwd, mirroring xmake's own --embed-dir=<dir> (tools/gcc.lua
        -- nf_embeddir).
        for _, embeddir in ipairs(table.wrap(target:get("embeddirs"))) do
            target:add("cxflags", "--embed-dir=" .. path.absolute(embeddir, target:scriptdir()), {force = true})
        end
    end)

    on_config(function (target)
        -- The wasm link ingredients resolve version-globbed paths inside the
        -- installed toolchain, so they join at config time -- strictly after
        -- toolchains.auto's on_load bootstrap has provisioned GCC on a fresh
        -- machine (all on_load hooks run before any on_config).
        script_import = import
        local context = managed_gcc_context(target)
        if not context then
            return
        end
        if context.target_os == "emscripten" and (target:is_binary() or target:is_shared()) then
            local gccwasm = import("gccwasm", {rootdir = CPP_MODULES_DIR})
            -- emcc classifies stdc++ as a driver-owned runtime and drops the
            -- ordinary syslink entry under -nostdlibxx. A full archive path
            -- keeps the project-built GCC libstdc++ in the user-link group,
            -- after dependency archives and before the final GCC runtime.
            target:add("links", gccwasm.installed_libstdcxx_path(context.target_os))
            target:add("linkdirs",
                path.directory(gccwasm.installed_libstdcxx_path(context.target_os)),
                path.directory(gccwasm.installed_libstdcxx_exp_path(context.target_os)),
                path.directory(gccwasm.installed_libgcc_path(context.target_os)))
        end
    end)

rule("toolchains.auto")
    add_deps("gcc.platform")
    on_load(function (target)
        script_import = import
        local settings = import("settings", {rootdir = CORE_MODULES_DIR})

        -- constant-drift and config-pin sentinels: both warn once per
        -- process, cost one file read each, and exist because the failure
        -- modes they catch are silent (options.lua literals diverging from
        -- core/modules/defaults.lua; a bare `xmake f`/implicit reconfigure
        -- resetting plat/arch/mode to defaults behind the user's back)
        import("catalog", {rootdir = CORE_MODULES_DIR})
        import("defaults", {rootdir = CORE_MODULES_DIR}).check_options_file(OPTIONS_FILE)
        settings.warn_config_pin_drift()
        settings.warn_source_pin_drift()

        -- Refuse the poisoned `-P` combination before it can write anything.
        -- xmake resolves config.directory() (and a relative builddir) against
        -- the CURRENT directory whenever that directory carries a .xmake
        -- marker (the issue-#820 "independent working directory" rule), so
        -- `xmake build -P ./WhiteHopeEngine.Test` from the checkout root runs
        -- the subproject against the ROOT's config store: one shared
        -- localcache and one stored builddir serve two different projectdirs,
        -- and per-source keys flip between them -- the `__\...` object trees
        -- and `..\`-relative compiles that rot later root builds. The store
        -- is resolved before any project script runs, so it cannot be
        -- re-keyed from here; stop loudly with the working alternatives
        -- instead. An explicit XMAKE_CONFIGDIR (how `xmake lane` isolates its
        -- children) is a deliberate override and passes.
        local config = import("core.project.config")
        local function canonical_dir(value)
            value = path.translate(path.absolute(value))
            return os.host() == "windows" and value:lower() or value
        end
        -- Only build-state-mutating tasks are guarded. Generator/query tasks
        -- (`xmake project -k compile_commands` from the IDE plugins, `xmake
        -- show`) legitimately load subprojects with `-P` from an alien cwd
        -- and write no build trees -- and, observed live 2026-08-08, an
        -- on_load raise inside the project-generator context wedges that
        -- process at zero CPU instead of exiting, leaving the IDE with a
        -- dead generator.
        local option = import("core.base.option")
        local guarded_tasks = {build = true, config = true, rebuild = true,
            run = true, install = true, uninstall = true, clean = true,
            package = true, test = true}
        local taskname = option.taskname and option.taskname() or ""
        local configdir_owner = path.directory(path.directory(path.directory(path.translate(path.absolute(config.directory())))))
        if guarded_tasks[taskname]
            and os.getenv("XMAKE_CONFIGDIR") == nil
            and canonical_dir(os.projectdir()) ~= canonical_dir(configdir_owner) then
            -- Refuse with a plain print and a hard exit, NOT a raise: an
            -- errors.fail from on_load wedges some task contexts at zero CPU
            -- forever (observed live 2026-08-08 on IDE-spawned `xmake f -P
            -- <subproject>` runs, which then sat holding the store lock). A
            -- policy refusal needs no backtrace, and os.exit() cannot get
            -- lost in the scheduler's error propagation.
            print(string.format(
                "error: this run mixes the project at %s with the config store owned by %s"
                .. " (the current directory's .xmake captured config.directory()), which corrupts"
                .. " the shared build trees; run the subproject from its own directory WITH an"
                .. " explicit `-P .` (a bare run there walks back up to the outermost xmake.lua),"
                .. " e.g. `cd WhiteHopeEngine.Test` then `xmake build -P . -y <target>`, or give"
                .. " the child an explicit XMAKE_CONFIGDIR the way `xmake lane` does",
                os.projectdir(), configdir_owner))
            os.exit(1)
        end

        -- Anchor a relative builddir to this project's own root: the same
        -- issue-#820 rule would otherwise re-anchor it to whichever cwd the
        -- command happens to run from. An absolute value (e.g. a lane's
        -- pinned `-o`) passes through untouched; force covers the readonly
        -- mark a command-line `-o` carries.
        local builddir = config.get("builddir") or "build"
        if not path.is_absolute(builddir) then
            config.set("builddir", path.absolute(builddir, os.projectdir()), {force = true})
        end

        local context = managed_gcc_context(target)
        if not context then
            return
        end
        local target_os = context.target_os
        -- Kept as a fast-path marker for this rule's own later hooks and for
        -- gccfeatures.toolchain_of's first-priority read; the authoritative
        -- resolution is managed_gcc_context (shared with gcc.platform and
        -- gcc.features), never this data by itself.
        target:data_set("toolchains.auto.declared", context.declared)

        -- Apple MANAGED-GCC project builds must agree with the managed
        -- toolchain arch. This check deliberately sits AFTER the external-
        -- toolchain bypass above: `--toolchain=<other>` is documented to skip
        -- the managed GCC wiring entirely, so e.g. a macosx x86_64 build on
        -- an explicit non-GCC toolchain must not be stopped by a gate about
        -- a toolchain it never uses (external review, 2026-07-18).
        -- the managed triplet is clamped to aarch64 (the only validated
        -- Darwin profile), but a residual `-a x64` in the project config
        -- would still drive per-arch flags (-m64) and per-arch build
        -- directories against the arm64 compiler. Toolchain-only commands
        -- keep working off the clamped triplet; the project build stops
        -- loudly with the full reconfigure line instead.
        if target_os == "macosx" or target_os == "ios" then
            local base = import("base", {rootdir = CORE_MODULES_DIR})
            local errors = import("errors", {rootdir = CORE_MODULES_DIR})
            local configured = base.canonical_arch(settings.configured_arch(), target_os)
            local managed = settings.target_arch(target_os)
            if configured ~= managed then
                errors.fail("Apple project builds need the configured arch to match the managed toolchain arch %s, but the configuration says %s; rerun the full configure: xmake f -p %s -a arm64 -m <mode>",
                    managed, configured, target_os == "ios" and "iphoneos" or "macosx")
            end
        end


        local hostboot = import("hostboot", {rootdir = CPP_MODULES_DIR})
        local gccstatus = import("gccstatus", {rootdir = CPP_MODULES_DIR})
        local gccbuild = import("gccbuild", {rootdir = CPP_MODULES_DIR})
        local triplet = settings.managed_target(target_os)
        local bindir = path.join(settings.gcc_prefix(target_os), "bin")
        target:set("toolchains", "project_gcc")
        -- Target-shape flags (runtimes/PIC/emscripten ABI/--embed-dir) live in
        -- gcc.platform, attached via add_deps above; this rule only wires
        -- WHICH tools compile and link.
        target:set("toolset.cc", hostboot.managed_tool(bindir, triplet, "gcc"))
        target:set("toolset.cxx", hostboot.managed_tool(bindir, triplet, "g++"))
        target:set("toolset.cpp", hostboot.managed_tool(bindir, triplet, "gcc") .. " -E")
        target:set("toolset.as", hostboot.managed_tool(bindir, triplet, "gcc"))
        target:set("toolset.ld", hostboot.managed_tool(bindir, triplet, "g++"))
        target:set("toolset.sh", hostboot.managed_tool(bindir, triplet, "g++"))
        if target_os == "emscripten" and (target:is_binary() or target:is_shared()) then
            local gccwasm = import("gccwasm", {rootdir = CPP_MODULES_DIR})
            local emcc = gccwasm.emcc_path()
            if not emcc then
                -- same bring-up phase as the GCC bootstrap below: install the
                -- pinned managed Emscripten toolset before giving up (its own
                -- install lock serializes concurrent processes)
                local errors = import("errors", {rootdir = CORE_MODULES_DIR})
                local gccemsdk = import("gccemsdk", {rootdir = CPP_MODULES_DIR})
                local ensured, failure = errors.trycall(function ()
                    return gccemsdk.ensure_installed()
                end)
                if not ensured then
                    errors.warn("managed Emscripten toolset install failed; falling back to emcc/node/wasm-ld from explicit configuration, PATH, or EMSDK: %s", tostring(failure))
                end
                emcc = gccwasm.emcc_path()
            end
            if not emcc then
                os.raise("emcc is required as the final GCC/Emscripten linker; the managed Emscripten toolset could not be installed and no emcc was found -- fix the reported install failure or configure --emscripten_emcc=<path>")
            end
            target:set("toolset.ld", emcc)
            target:set("toolset.sh", emcc)
        end
        target:set("toolset.ar", hostboot.managed_tool(bindir, triplet, gccstatus.project_gcc_ar_tool_name(target_os)))
        target:set("toolset.ranlib", hostboot.managed_tool(bindir, triplet, gccstatus.project_gcc_ranlib_tool_name(target_os)))
        target:set("toolset.strip", hostboot.managed_tool(bindir, triplet, "strip"))
        target:set("toolset.objcopy", hostboot.managed_tool(bindir, triplet, "objcopy"))
        if target_os == "windows" then
            target:set("toolset.mrc", hostboot.managed_tool(bindir, triplet, "windres"))
            target:set("toolset.dlltool", hostboot.managed_tool(bindir, triplet, "dlltool"))
        end

        -- The built-in c++.build.modules rule probes the compiler for module
        -- support during config and may run before this rule's on_config
        -- bootstrap; on a fresh machine the managed g++ does not exist yet and
        -- the probe fails with "compiler(gcc): does not support c++ module!".
        -- Ensure the toolchain exists already at load time (before any
        -- on_config); on provisioned machines this is a pure check.
        if not gccbuild.toolchain_installed(target_os) and not gccbuild.build_in_progress(target_os) then
            -- build_gcc_for now takes the per-prefix cross-process install lock
            -- itself and re-checks under it (skip_if_installed), so the former
            -- outer bootstrap.lock here is gone: nesting the same lock in one
            -- process would self-deadlock, and a second lock name would not
            -- serialize against the explicit `xmake toolchains` commands.
            -- build_in_progress covers the one case where this load IS the
            -- nesting: a toolchain build whose smoke loads the project to ask
            -- whether it uses Rust. That toolchain's stamp is written only
            -- after the smoke, so the check above is guaranteed false there --
            -- without the second condition every such load asks to bootstrap
            -- the toolchain that is being built around it.
            print("bootstrapping missing project-local GCC for " .. target_os)
            gccbuild.build_gcc_for(target_os, {skip_if_installed = true})
            if not gccbuild.toolchain_installed(target_os) then
                os.raise("automatic project-local GCC bootstrap failed; run `xmake toolchains install " .. target_os .. "` for details")
            end
        end
        hostboot.ensure_windows_host_binutils_aliases(target_os)
        hostboot.ensure_linux_host_binutils_aliases(target_os)
    end)

    on_config(function (target)
        script_import = import
        local context = managed_gcc_context(target)
        if not context then
            return
        end
        local target_os = context.target_os
        local hostboot = import("hostboot", {rootdir = CPP_MODULES_DIR})
        local gccbuild = import("gccbuild", {rootdir = CPP_MODULES_DIR})
        if not gccbuild.toolchain_installed(target_os) and not gccbuild.build_in_progress(target_os) then
            -- build_gcc_for takes the per-prefix install lock itself now (see
            -- the on_load twin, which also explains build_in_progress).
            print("bootstrapping missing project-local GCC for " .. target_os)
            gccbuild.build_gcc_for(target_os, {skip_if_installed = true})
            if not gccbuild.toolchain_installed(target_os) then
                os.raise("automatic project-local GCC bootstrap failed; run `xmake toolchains install " .. target_os .. "` for details")
            end
        end
        hostboot.ensure_windows_host_binutils_aliases(target_os)
        hostboot.ensure_linux_host_binutils_aliases(target_os)
    end)

    before_build(function (target)
        -- managed_gcc_context resolves identity through gccfeatures
        -- .toolchain_of, which already folds in everything the former ad-hoc
        -- three-way probe here re-derived (declared data, toolset.cxx smell,
        -- explicit gcc/mingw entries) -- one implementation, not four.
        script_import = import
        local context = managed_gcc_context(target)
        if not context then
            return
        end
        local target_os = context.target_os
        local errors = import("errors", {rootdir = CORE_MODULES_DIR})
        local hostboot = import("hostboot", {rootdir = CPP_MODULES_DIR})
        local gccbuild = import("gccbuild", {rootdir = CPP_MODULES_DIR})
        if not gccbuild.toolchain_installed(target_os) then
            -- Wait out any concurrent install by taking the SAME per-prefix lock
            -- build_gcc_for holds, then verify. Sharing that lock file (not a
            -- separate bootstrap.lock) is what makes this actually block on an
            -- in-flight build in another process instead of racing past it.
            local lockfile = gccbuild.install_lock_file(target_os)
            os.mkdir(path.directory(lockfile))
            local lock = io.openlock(lockfile)
            lock:lock()
            local missing = not gccbuild.toolchain_installed(target_os)
            lock:unlock()
            if missing then
                os.raise("project-local GCC toolchain is not available for " .. target_os .. "; run `xmake toolchains install " .. target_os .. "` for details")
            end
        end
        hostboot.ensure_windows_host_binutils_aliases(target_os)
        hostboot.ensure_linux_host_binutils_aliases(target_os)
        -- Smoke freshness: installed_extra deliberately no longer folds a
        -- stale smoke stamp into "toolchain not installed" (that re-entered
        -- the FULL rebuild pipeline), so refresh it here instead. Project
        -- loading is complete at before_build, so the finalize path may
        -- consult project truth (ensure_smoke_current reads
        -- project_enables_rust); no-op for providers without the hook,
        -- ~60ms verdict when the recorded smoke is fresh.
        gccbuild.finalize_existing_toolchain_install(target_os)
        local function clear_memcache(owner)
            local getter = owner and owner.memcache
            if type(getter) == "function" then
                local ok, cache = errors.trycall(function ()
                    return getter(owner)
                end)
                if ok and cache and cache.clear then
                    cache:clear()
                end
            end
        end
        for _, toolchain_inst in ipairs(target:toolchains()) do
            clear_memcache(toolchain_inst)
        end
        clear_memcache(target)
    end)

rule("gcc.modules")
    on_config(function (target)
        if not target:policy("build.c++.modules") then
            return
        end

        -- The validation passes live in the gccmodulecheck module (script
        -- scope); this shell owns everything that touches target state.
        local gccmodulecheck = import("gccmodulecheck", {rootdir = CPP_MODULES_DIR})
        local gccmodulecache = import("gccmodulecache", {rootdir = CPP_MODULES_DIR})
        gccmodulecache.prepare(target)

        -- Read every .cpp sourcefile once and share the content between the
        -- interface-unit classification pass below and the module-organization
        -- validation in gccmodulecheck -- both previously re-read the same
        -- ~330-file module tree independently on every configure.
        local file_contents = {}
        for _, sourcefile in ipairs(target:sourcefiles()) do
            if sourcefile:endswith(".cpp") then
                file_contents[sourcefile] = io.readfile(path.absolute(sourcefile, os.projectdir()))
            end
        end

        -- xmake propagates every add_files(..., {public = true}) source file to
        -- dependent targets, and units without an exported module name fall into
        -- the "regular translation unit ... always inserted" branch of the module
        -- scanner (xmake rules/c++/modules/scanner.lua, _get_targetdeps_modules),
        -- so consumers would parasitically compile our implementation units and
        -- fail to resolve their implicit interface import. Demote everything that
        -- is not an importable unit back to private before the scanner reads
        -- the fileconfig; module partition implementation units (module M:P;)
        -- stay public because dependents import their BMIs like interfaces.
        -- Misclassification stays loud: a demoted importable unit breaks
        -- consumer imports at build time instead of corrupting anything
        -- (and an unreadable file keeps its public flag for the same reason).
        for _, sourcefile in ipairs(target:sourcefiles()) do
            if sourcefile:endswith(".cpp") then
                local fileconfig = target:fileconfig(sourcefile)
                if fileconfig and fileconfig.public then
                    local content = file_contents[sourcefile]
                    if content and not gccmodulecheck.is_importable_unit(content) then
                        local demoted = table.clone(fileconfig)
                        demoted.public = false
                        target:fileconfig_set(sourcefile, demoted)
                    end
                end
            end
        end

        -- GCC module streaming currently loses the weak/COMDAT linkage of some
        -- libstdc++ inline-function-local statics reachable through CMIs; consumer
        -- TUs then instantiate an equivalent strong copy and linking fails with
        -- "multiple definition" (upstream defect; the copies are equivalent, so
        -- keeping either is safe). Tolerate duplicates on linkable targets until
        -- the toolchain fix lands. ld64 does not understand this switch, so the
        -- macOS side keeps default behaviour until that platform is validated.
        -- Retest ritual: after each gcc_ref bump, drop this block and relink
        -- WhiteHopeEngine.Test; the witness symbol is
        -- std::__format::__write_escaped_unicode_part<...>::__replace_rep
        -- (include/c++/<ver>/format). Last retested 2026-07-18 on GCC 17.0.0
        -- 20260717: still fails, flag still required.
        if (target:is_binary() or target:is_shared()) and not target:is_plat("macosx") and not target:is_plat("iphoneos") and not target:is_plat("ios") then
            target:add("ldflags", "-Wl,--allow-multiple-definition")
        end

        -- darwin (macOS + iOS) has no system GNU libstdc++: the platform C++
        -- runtime is libc++, so a dynamically-linked GCC libstdc++ is never a
        -- system library -- it would have to be bundled and found via @rpath.
        -- Link it statically on every darwin target for self-contained binaries
        -- and a uniform linkage model. iOS already ships libstdc++ static-only
        -- (no dylib is built), so this only changes macOS, aligning it with iOS.
        -- It also sidesteps a GCC -Os codegen quirk: a direct (adrp) reference to
        -- an interposable libstdc++ symbol cannot resolve across a dylib boundary,
        -- so -Os macOS links otherwise fail on e.g. std exception destructors
        -- pulled from the dylib; a static libstdc++ places them in the image.
        if (target:is_binary() or target:is_shared())
            and (target:is_plat("macosx") or target:is_plat("iphoneos") or target:is_plat("ios")) then
            target:add("ldflags", "-static-libstdc++")
        end

        -- Branch layering source (spec item 11): if the project declared an
        -- explicit order via set_values("cxxmodule.branch_layers", "1:ExceptionEngine",
        -- ...) the check enforces direction against it; otherwise it derives the
        -- layering from this module graph and only guards against branch cycles.
        -- Either way build_support hardcodes no branch names.
        -- How module units group into layer-nodes: layers.lua auto-detects this
        -- (single module with partitions -> by partition prefix, otherwise by
        -- named module), so nothing is declared for the common cases. A project
        -- whose shape defeats the heuristic may override via
        -- set_values("cxxmodule.layer_grouping", "module"|"partition-prefix").
        local grouping = table.wrap(target:values("cxxmodule.layer_grouping"))[1]

        local manual_layers = table.wrap(target:values("cxxmodule.branch_layers"))
        local check_opts = {grouping = grouping}
        if #manual_layers > 0 then
            local layers = import("layers", {rootdir = CORE_MODULES_DIR})
            local errors = import("errors", {rootdir = CORE_MODULES_DIR})
            local manual = layers.from_manual(manual_layers)
            -- Cross-check the declaration against the real module graph (the
            -- ground truth for which branches exist), both directions:
            --   * a DECLARED branch with no matching module is almost always a
            --     typo (e.g. "4:OSCallEngien") that silently unranks the real
            --     branch and unguards it;
            --   * an OMITTED real branch is left unranked, so "complete
            --     direction enforcement" would silently miss it.
            -- Both are warnings, so a project may still adopt manual mode
            -- gradually, but neither gap is silent anymore.
            local declared = {}
            for _, name in ipairs(manual.known_names()) do
                declared[name] = true
            end
            local real = {}
            for _, name in ipairs(layers.from_module_graph(file_contents, {grouping = grouping}).known_names()) do
                real[name] = true
            end
            local phantom, missing = {}, {}
            for name in pairs(declared) do
                if not real[name] then
                    table.insert(phantom, name)
                end
            end
            for name in pairs(real) do
                if not declared[name] then
                    table.insert(missing, name)
                end
            end
            table.sort(phantom)
            table.sort(missing)
            if #phantom > 0 then
                errors.warn("cxxmodule.branch_layers declares branch(es) with no matching module in the tree (typo? unranks the real branch): %s", table.concat(phantom, ", "))
            end
            if #missing > 0 then
                errors.warn("cxxmodule.branch_layers omits real branch(es), leaving them unranked and direction-unguarded: %s", table.concat(missing, ", "))
            end
            check_opts.level_of = manual.level_of
        end
        gccmodulecheck.run(file_contents, check_opts)
        gccmodulecheck.warn_foreign_plat_cache(target)
    end)

    -- The builtin module scanner creates/updates cxxmodules during the
    -- prepare stage. Normalize those freshly generated output paths before
    -- the builder turns them into compiler mapper arguments.
    after_prepare(function (target)
        if not target:policy("build.c++.modules") then
            return
        end

        local gccmodulecache = import("gccmodulecache", {rootdir = CPP_MODULES_DIR})
        gccmodulecache.prepare(target)
    end)

-- One-line opt-in for the whole managed-GCC stack: toolchain selection and
-- bootstrap (toolchains.auto, which itself depends on gcc.platform for the
-- platform-ABI flags), named feature injection (gcc.features) and C++20
-- module automation (gcc.modules). Rule dependencies execute depended-upon
-- first, so the effective order is platform -> auto -> features -> modules.
-- The classic explicit trio add_rules("toolchains.auto", "gcc.features",
-- "gcc.modules") keeps working unchanged -- this is the same set expressed
-- as one dependency-ordered name.
rule("gcc.managed")
    add_deps("toolchains.auto", "gcc.features", "gcc.modules")

includes(path.join(os.scriptdir(), "toolchains", "commands_help.lua"))

-- Callback-reachable captures of the commands_help.lua globals (see the
-- cold-configure sandbox note: callback bodies resolve upvalues reliably,
-- cross-chunk plain globals less so).
local print_toolchains_help = print_toolchains_help
local print_toolchains_config_help = print_toolchains_config_help
local bind_help_errors = managed_toolchains_bind_help_errors
local bind_help_i18n = managed_toolchains_bind_help_i18n
local bind_gcc_features_help_i18n = managed_toolchains_bind_gcc_features_help_i18n

task("toolchains")
    set_category("plugin")
    on_run(function ()
        -- plugin tasks do not auto-load the project configuration, so
        -- settings resolution (plat/arch/mode) would silently fall back to
        -- host-native defaults -- harmless when native happens to equal the
        -- configured arch (Apple Silicon hosts, since the macosx/ios default
        -- triplet now clamps to aarch64), but on an Intel Mac host the
        -- native x86_64 default would silently diverge from that clamped
        -- aarch64 configuration (phantom x86_64 installs).
        import("core.project.config").load()
        import("catalog", {rootdir = CORE_MODULES_DIR})
        local option = import("core.base.option")
        local errors = import("errors", {rootdir = CORE_MODULES_DIR})
        -- The source-pin sentinel belongs here as much as in the build rule:
        -- these commands are exactly where a frozen pin does its damage,
        -- syncing and stamping the previous baseline while reporting success.
        import("settings", {rootdir = CORE_MODULES_DIR}).warn_source_pin_drift()
        bind_help_errors(errors)
        bind_gcc_features_help_errors(errors)
        local i18n = import("i18n", {rootdir = CORE_MODULES_DIR})
        bind_help_i18n(i18n)
        bind_gcc_features_help_i18n(i18n)
        i18n.register({
            ["run `xmake toolchains status <windows|linux|android|macosx|ios|emscripten>` to inspect the toolchain state"] =
                "运行 `xmake toolchains status <windows|linux|android|macosx|ios|emscripten>` 检查工具链状态",
            ["run `xmake toolchains help` for command usage"] =
                "运行 `xmake toolchains help` 查看命令用法"
        })
        errors.friendly_guard("xmake toolchains " .. (option.get("action") or "status"), {
            "run `xmake toolchains status <windows|linux|android|macosx|ios|emscripten>` to inspect the toolchain state",
            "run `xmake toolchains help` for command usage"
        }, function ()
            -- the help/options printers are description-scope globals from
            -- commands_help.lua that script-scope modules cannot see, so
            -- those two actions are answered here in the shell; everything
            -- else delegates to the gccstatus module.
            local action = option.get("action")
            local subject = option.get("subject")
            local normalized = (action and action ~= "") and action or "status"
            if normalized == "help" or normalized == "--help" or normalized == "-h" then
                print_toolchains_help((subject and subject ~= "") and subject or nil)
                return
            elseif normalized == "options" or normalized == "config" then
                print_toolchains_config_help()
                return
            end
            import("gccstatus", {rootdir = CPP_MODULES_DIR}).run_toolchains_command(action, subject)
        end)
    end)
    set_menu {
        usage = "xmake toolchains [help|options|status|matrix|fetch|install|update|bundle|build|smoke] [command|windows|linux|android|macosx|ios|emscripten|host]",
        description = "Manage project-local GCC toolchains",
        options = {
            {nil, "action", "v", "status", "help, options, status, matrix, fetch, install, update, bundle, build, rebuild, or smoke"},
            {nil, "subject", "v", "", "command name or target OS folder: windows, linux, android, macosx, ios, emscripten, host"}
        }
    }

-- Entry chain note: the android and rust providers are included by the real
-- entry, build_support/xmake.lua (phase 3 directory split).
