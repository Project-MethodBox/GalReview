-- Emscripten target provider: a thin forwarding layer over gccwasm, which
-- stays the single owner of the experimental GCC WebAssembly machinery
-- (WABT assembler, LLVM binary tools, emcc final link, smoke tests). This
-- module only adapts gccwasm to the target-provider hooks dispatched by
-- gcctargets/gccbuild/gccstatus; do not reimplement or restructure gccwasm
-- internals here.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("gccwasm", {rootdir = path.join(os.scriptdir(), "..")})
import("gccemsdk", {rootdir = path.join(os.scriptdir(), "..")})

function preflight(target_os)
    return gccwasm.preflight(target_os)
end

-- Read-only matrix probe: unlike preflight, this never runs the managed
-- Emscripten toolset ensure step; it reports the current state only.
function preflight_warnings(target_os)
    return gccwasm.preflight_warnings(target_os)
end

-- Read-only matrix probe: reports whether the recorded backend smoke is
-- current; never rebuilds or refreshes anything.
function smoke_state(target_os)
    return tostring(gccwasm.backend_smoke_current(target_os))
end

function sysroot(target_os)
    return gccwasm.emscripten_sysroot()
end

-- emscripten needs both driver entry points: GCC builds C runtime pieces
-- with the C driver during libgcc/libstdc++ bring-up.
function compiler_exists(target_os)
    local triplet = settings.managed_target(target_os)
    local bindir = path.join(settings.gcc_prefix(target_os), "bin")
    local c_compiler = os.isfile(path.join(bindir, base.exe(triplet .. "-gcc"))) or
        os.isfile(path.join(bindir, base.exe("gcc")))
    local cxx_compiler = os.isfile(path.join(bindir, base.exe(triplet .. "-g++"))) or
        os.isfile(path.join(bindir, base.exe("g++")))
    return c_compiler and cxx_compiler
end

function installed_extra(target_os)
    return gccwasm.tools_ready(target_os) and gccwasm.backend_smoke_current(target_os)
end

-- The resolved emcc version joins the capability tag in both the install
-- stamp and the .xmake-configure signature: hosted libstdc++ is configured
-- against the emcc sysroot, so swapping the emscripten release (even at an
-- unchanged path) must reconfigure and rebuild the toolchain.
function stamp_extra(target_os)
    return "wasm_capability=" .. gccwasm.capability_name() .. "\n"
        .. "emscripten_version=" .. gccwasm.emcc_version() .. "\n"
end

function signature_extra(target_os)
    return "wasm_capability=" .. gccwasm.capability_name() .. "\n"
        .. "emscripten_version=" .. gccwasm.emcc_version() .. "\n"
end

function needs_binutils(target_os)
    return false
end

-- Replaces the binutils bring-up: the WABT assembler and wasm-ld linker are
-- the emscripten target's toolchain backends.
function prepare_backend_tools(target_os)
    errors.log("preparing experimental GCC WebAssembly assembler and linker")
    gccwasm.prepare_target_tools(target_os)
end

function configure_args(target_os, args)
    -- prepare_target_tools is idempotent; calling it here keeps the
    -- --with-as/--with-ld arguments valid without assuming any dispatcher
    -- ordering between stage hooks and configure_args.
    local assembler, linker = gccwasm.prepare_target_tools(target_os)
    table.insert(args, "--with-as=" .. base.shpath(assembler))
    table.insert(args, "--with-ld=" .. base.shpath(linker))
    table.insert(args, "--enable-hosted-libstdcxx")
    table.insert(args, "--with-native-system-header-dir=/include")
    table.insert(args, "--with-libstdcxx-lock-policy=atomic")
    table.insert(args, "--disable-libstdcxx-backtrace")
    table.insert(args, "--disable-fixincludes")
    table.insert(args, "--disable-werror")
    local sysroot_dir = gccwasm.emscripten_sysroot()
    if sysroot_dir and os.isdir(sysroot_dir) then
        table.insert(args, "--with-sysroot=" .. base.shpath(sysroot_dir))
        table.insert(args, "--with-build-sysroot=" .. base.shpath(sysroot_dir))
        table.insert(args, "--disable-shared")
        table.insert(args, "--enable-static")
        table.insert(args, "CFLAGS_FOR_TARGET=-pthread")
        table.insert(args, "CXXFLAGS_FOR_TARGET=-pthread -fno-exceptions -fno-rtti")
        table.insert(args, "LIBCFLAGS_FOR_TARGET=-pthread")
        table.insert(args, "--enable-threads=posix")
    else
        table.insert(args, "--without-headers")
        table.insert(args, "--disable-shared")
        table.insert(args, "--disable-threads")
    end
    return args
end

function target_tools(target_os)
    return {ar = "ar", ranlib = "ranlib"}
end

function build_plan(target_os, context)
    return {
        {
            log = "building experimental GCC WebAssembly compiler, target libgcc, and hosted libstdc++",
            targets = {
                "all-gcc",
                "install-gcc",
                "all-target-libgcc",
                "install-target-libgcc",
                "configure-target-libstdc++-v3",
                "all-target-libstdc++-v3",
                "install-target-libstdc++-v3"
            },
            patch = true
        }
    }
end

function smoke(target_os)
    errors.log("running experimental GCC WebAssembly C/C++ runtime smoke tests")
    gccwasm.run_backend_smoke(target_os)
    gccwasm.run_emscripten_link_smoke(target_os)
end

-- finalize_existing_toolchain_install hook: refresh a stale backend smoke
-- before an already-installed toolchain is reused.
function ensure_smoke_current(target_os)
    if compiler_exists(target_os) and not gccwasm.backend_smoke_current(target_os) then
        gccwasm.prepare_target_tools(target_os)
        gccwasm.run_backend_smoke(target_os)
        gccwasm.run_emscripten_link_smoke(target_os)
    end
end

function status_lines(target_os)
    local binary_tools = gccwasm.host_binary_tools()
    print("wasm capability: " .. gccwasm.capability_name())
    print("wabt source:     " .. layout.wabt_source_dir())
    print("wabt revision:   " .. gccwasm.wabt_source_revision())
    print("wat2wasm:        " .. tostring(gccwasm.wabt_path(target_os)))
    print("wasm-ld:         " .. tostring(binary_tools.ld or ""))
    print("wasm ar:         " .. tostring(binary_tools.ar or ""))
    print("wasm nm:         " .. tostring(binary_tools.nm or ""))
    print("wasm objcopy:    " .. tostring(binary_tools.objcopy or ""))
    print("wasm ranlib:     " .. tostring(binary_tools.ranlib or ""))
    print("wasm strip:      " .. tostring(binary_tools.strip or ""))
    print("node:            " .. tostring(gccwasm.node_path() or ""))
    print("node version:    " .. (gccwasm.node_version() ~= "" and gccwasm.node_version() or "unknown"))
    print("emcc link-only:  " .. tostring(gccwasm.emcc_path() or "not configured"))
    print("emcc origin:     " .. tostring(gccwasm.emcc_origin() or "not found"))
    print("emcc version:    " .. (gccwasm.emcc_version() ~= "" and gccwasm.emcc_version() or "unknown"))
    gccemsdk.status_lines(target_os)
    print("backend smoke:   " .. tostring(gccwasm.backend_smoke_current(target_os)))
end

function on_fetch(target_os)
    gccwasm.sync_wabt_source(false)
    gccemsdk.prefetch()
end

function on_bundle(target_os)
    gccwasm.create_wabt_source_bundle()
end

function on_rebuild_reset(target_os)
    gccwasm.reset_build_cache(target_os)
end

-- The `xmake toolchains smoke` command hooks; their presence is also the
-- dispatcher's capability gate for that command.
function smoke_refresh(target_os)
    gccwasm.prepare_target_tools(target_os)
    gccwasm.run_backend_smoke(target_os)
end

function smoke_link(target_os)
    gccwasm.run_emscripten_link_smoke(target_os)
end
