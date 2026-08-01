-- Experimental GCC WebAssembly support. GCC 17 compiles every project C/C++
-- source and the WABT fork emits relocatable WebAssembly objects. Direct
-- wasm-ld links are retained only for compiler/backend ABI smoke tests.
-- Production targets use the Emscripten sysroot to build hosted libstdc++ with
-- POSIX gthreads, then pass GCC and Rust objects to emcc solely for final
-- linking, libc/pthread/allocator support, and JavaScript runtime generation.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
local defaults = import("defaults", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")}).values()
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("hosttools", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("envs", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("run", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("gccsources")
import("gccemsdk")
import("core.base.bytes")

local RUST_MODULES_DIR = path.join(os.scriptdir(), "..", "..", "rust", "modules")
local WASM_CAPABILITY = "gcc17-hosted-emscripten-pthread-tls-atomic-locks-wait-rust-atomic-concepts-contracts-coroutines-reflection-basic-abi-int128-backend-v43"
local WASM_SMOKE_CAPABILITY = "hosted-pthread-tls-atomic-lock-policy-shared-ptr-rust-int128-std-module-empty-abi-dwarf-canary-name-section-eh-trap-opt-size-v8"

-- Debug/GC assertion anchors for the hosted link smoke. The two data markers
-- and the marker/unused functions are planted into the smoke C++ source below
-- (write_emscripten_hosted_smoke_sources). The name-section anchor is the
-- demangle-invariant core of the C++ marker function name: wasm-ld writes
-- DEMANGLED names into the name section by default ("gcc_wasm_name_section_
-- marker(unsigned int)", probe-verified 2026-07-17), and this substring is
-- contained in both that form and the raw mangling
-- _Z28gcc_wasm_name_section_markerj, so a --demangle default flip cannot
-- break the assertion. A drift between these constants and the planted
-- source fails the smoke loudly instead of passing silently.
local WASM_SMOKE_NAME_SECTION_SYMBOL = "gcc_wasm_name_section_marker"
local WASM_SMOKE_USED_DATA_MARKER = "GCC-WASM-SMOKE-USED-DATA-MARKER"
local WASM_SMOKE_UNUSED_DATA_MARKER = "GCC-WASM-SMOKE-UNUSED-DATA-MARKER"

local function host_tool_candidates(name)
    local candidates = {}
    local executable = base.exe(name)
    local function add(candidate)
        if candidate and candidate ~= "" then
            table.insert(candidates, candidate)
        end
    end

    if base.is_windows_host() then
        for _, root in ipairs({
            os.getenv("ProgramW6432"),
            os.getenv("ProgramFiles"),
            os.getenv("ProgramFiles(x86)")
        }) do
            if root and root ~= "" then
                add(path.join(root, "LLVM", "bin", executable))
                add(path.join(root, "CMake", "bin", executable))
                add(path.join(root, "nodejs", executable))
            end
        end
        local localappdata = os.getenv("LOCALAPPDATA")
        if localappdata and localappdata ~= "" then
            add(path.join(localappdata, "Programs", "LLVM", "bin", executable))
        end
        local userprofile = os.getenv("USERPROFILE")
        if userprofile and userprofile ~= "" then
            add(path.join(userprofile, "scoop", "apps", "llvm", "current", "bin", executable))
        end
        local programfiles = os.getenv("ProgramW6432") or os.getenv("ProgramFiles")
        if programfiles and programfiles ~= "" then
            for _, candidate in ipairs(os.files(path.join(programfiles, "Microsoft Visual Studio", "*", "*",
                "VC", "Tools", "Llvm", "x64", "bin", executable))) do
                add(candidate)
            end
        end
    elseif base.host_os() == "macosx" then
        for _, prefix in ipairs({"/opt/homebrew", "/usr/local", "/opt/local"}) do
            add(path.join(prefix, "bin", name))
            for _, package in ipairs({"llvm", "lld", "cmake", "ninja", "node"}) do
                add(path.join(prefix, "opt", package, "bin", name))
            end
        end
    end
    if name == "wasm-ld" then
        for _, candidate in ipairs(os.files(path.join(layout.toolchains_cache_root(), "rust", "**",
            "gcc-ld", executable))) do
            add(candidate)
        end
    end
    return candidates
end

local function find_host_tool(name)
    local found = hosttools.find_tool_path(name)
    if found then
        return found
    end
    for _, candidate in ipairs(host_tool_candidates(name)) do
        if os.isfile(candidate) then
            return path.absolute(candidate)
        end
    end
end

-- Resolution order for emcc/node/wasm-ld (v43): explicit option/env, then
-- the managed Emscripten toolset (gccemsdk), then PATH, then a loudly warned
-- $EMSDK derivation. The explicit tier accepts a path or a tool name.
local function explicitly_configured_tool(option_name, environment_name)
    local configured = tostring(settings.value_or(option_name, os.getenv(environment_name) or "") or "")
    if configured == "" then
        return nil
    end
    if os.isfile(configured) then
        return path.absolute(configured)
    end
    return find_host_tool(configured)
end

local emsdk_env_warned = false

local function warn_emsdk_env_fallback(tool, candidate)
    if not emsdk_env_warned then
        emsdk_env_warned = true
        errors.warn("using %s from the external EMSDK environment (%s); the managed Emscripten toolset is missing, so toolchain identity depends on that external install", tool, candidate)
    end
end

function wasm_ld_path()
    local configured = explicitly_configured_tool("wasm_ld", "WASM_LD")
    if configured then
        return configured
    end
    local managed = gccemsdk.wasm_ld_path()
    if managed then
        return managed
    end
    local found = find_host_tool("wasm-ld")
    if found then
        return found
    end
    local emsdk = os.getenv("EMSDK")
    if emsdk and emsdk ~= "" then
        local candidate = path.join(emsdk, "upstream", "bin", base.exe("wasm-ld"))
        if os.isfile(candidate) then
            warn_emsdk_env_fallback("wasm-ld", candidate)
            return candidate
        end
    end
end

function node_path()
    local configured = explicitly_configured_tool("wasm_node", "NODE")
    if configured then
        return configured
    end
    local managed = gccemsdk.node_path()
    if managed then
        return managed
    end
    for _, name in ipairs({"node", "nodejs"}) do
        local found = find_host_tool(name)
        if found then
            return found
        end
    end
end

-- Returns the resolved emcc plus its origin (configured|managed|path|
-- emsdk-env); the origin is recorded in the smoke signature so any drift of
-- the tool source forces a revalidation.
function emcc_resolution()
    local configured = explicitly_configured_tool("emscripten_emcc", "EMCC")
    if configured then
        return configured, "configured"
    end
    local managed = gccemsdk.emcc_launcher_path()
    if managed then
        return managed, "managed"
    end
    local found = find_host_tool("emcc")
    if found then
        return found, "path"
    end
    local emsdk = os.getenv("EMSDK")
    if emsdk and emsdk ~= "" then
        for _, candidate in ipairs({
            path.join(emsdk, "upstream", "emscripten", base.exe("emcc")),
            path.join(emsdk, "upstream", "emscripten", "emcc.bat"),
            path.join(emsdk, "upstream", "emscripten", "emcc")
        }) do
            if os.isfile(candidate) then
                warn_emsdk_env_fallback("emcc", candidate)
                return candidate, "emsdk-env"
            end
        end
    end
end

function emcc_path()
    local resolved = emcc_resolution()
    return resolved
end

function emcc_origin()
    local _, origin = emcc_resolution()
    return origin
end

function emcc_version()
    local emcc, origin = emcc_resolution()
    if not emcc then
        return ""
    end
    if origin == "managed" then
        return gccemsdk.installed_emscripten_version() or ""
    end
    return gccemsdk.emscripten_version_of(emcc) or ""
end

function node_version()
    return gccemsdk.node_version_of(node_path()) or ""
end

function emscripten_sysroot()
    local emcc, origin = emcc_resolution()
    if not emcc then
        return
    end
    if origin == "managed" then
        local managed = gccemsdk.sysroot()
        if managed then
            return managed
        end
        -- the managed launcher lives outside the release tree; derive from
        -- the real emcc if the prebuilt sysroot check ever fails
        emcc = gccemsdk.emcc_path() or emcc
    end
    for _, candidate in ipairs({
        path.join(path.directory(emcc), "cache", "sysroot"),
        path.join(path.directory(path.directory(emcc)), "emscripten", "cache", "sysroot")
    }) do
        if os.isfile(path.join(candidate, "include", "pthread.h"))
            and os.isdir(path.join(candidate, "lib", "wasm32-emscripten")) then
            return candidate
        end
    end
end

function host_binary_tools()
    local linker = wasm_ld_path()
    local linker_dir = linker and path.directory(linker) or nil
    local function find_binary_tool(candidates)
        for _, name in ipairs(candidates) do
            if linker_dir then
                local sibling = path.join(linker_dir, base.exe(name))
                if os.isfile(sibling) then
                    return sibling
                end
            end
            local found = find_host_tool(name)
            if found then
                return found
            end
        end
    end
    return {
        ld = linker,
        ar = find_binary_tool({"llvm-ar", "ar"}),
        nm = find_binary_tool({"llvm-nm", "nm"}),
        objcopy = find_binary_tool({"llvm-objcopy"}),
        ranlib = find_binary_tool({"llvm-ranlib", "ranlib"}),
        strip = find_binary_tool({"llvm-strip"})
    }
end

function wabt_source_revision()
    local src = layout.wabt_source_dir()
    if not os.isdir(path.join(src, ".git")) then
        return ""
    end
    local git = gccsources.managed_toolchains_preferred_git()
    local ok, output = gccsources.managed_toolchains_run_git(git,
        {"-C", src, "rev-parse", "HEAD"}, {envs = envs.proxy_envs(), try = true})
    return ok and base.trim(output or "") or ""
end

function sync_wabt_source(force)
    local url = settings.value_or("wasm_wabt_git_url", defaults.wasm_wabt_git_url)
    local ref = settings.value_or("wasm_wabt_ref", defaults.wasm_wabt_ref)
    local pinned_commit = #ref == 40 and ref:match("^[0-9a-fA-F]+$") ~= nil
    local src = layout.wabt_source_dir()
    local stamp = path.join(src, ".xmake-source")
    local signature = "url=" .. url .. "\nref=" .. ref .. "\n"
    local git = gccsources.managed_toolchains_preferred_git()
    local function sync_submodules()
        gccsources.managed_toolchains_run_git(git,
            {"-C", src, "submodule", "sync", "--", "third_party/picosha2"},
            {envs = envs.proxy_envs()})
        gccsources.managed_toolchains_run_git(git,
            {"-C", src, "submodule", "update", "--init", "--depth=1", "--", "third_party/picosha2"},
            {envs = envs.proxy_envs()})
    end
    if not force and os.isfile(path.join(src, "CMakeLists.txt")) and os.isfile(stamp)
        and (io.readfile(stamp) or ""):sub(1, #signature) == signature
        and wabt_source_revision() == ref then
        sync_submodules()
        return src
    end

    if os.exists(src) then
        layout.remove_toolchains_path(src)
    end
    os.mkdir(src)
    gccsources.managed_toolchains_run_git(git, {"-C", src, "init"}, {envs = envs.proxy_envs()})
    gccsources.managed_toolchains_run_git(git, {"-C", src, "config", "--local", "core.autocrlf", "false"}, {envs = envs.proxy_envs()})
    gccsources.managed_toolchains_run_git(git, {"-C", src, "remote", "add", "origin", url}, {envs = envs.proxy_envs()})
    if not (pinned_commit and gccsources.managed_toolchains_restore_source_from_bundle(git, src, "wabt-gcc-wasm", ref, envs.proxy_envs())) then
        gccsources.managed_toolchains_fetch_gcc_ref(git, src, ref, envs.proxy_envs(), not pinned_commit)
    end
    gccsources.managed_toolchains_run_git(git, {"-C", src, "checkout", "--force", "FETCH_HEAD"}, {envs = envs.proxy_envs()})
    local revision = wabt_source_revision()
    if revision ~= ref then
        errors.fail("WABT checkout revision mismatch: expected %s, got %s", ref, revision)
    end
    sync_submodules()
    if not os.isfile(path.join(src, "CMakeLists.txt")) then
        errors.fail("WABT checkout did not contain CMakeLists.txt: %s", src)
    end
    io.writefile(stamp, signature .. "revision=" .. revision .. "\n")
    return src
end

-- Offline insurance for the pinned WABT fork, mirroring the GCC source
-- bundles (see gccsources.create_gcc_source_bundle). The picosha2 submodule
-- is not bundled: a fresh restore still syncs that tiny tree from its own
-- upstream.
function create_wabt_source_bundle()
    local src = sync_wabt_source(false)
    local git = gccsources.managed_toolchains_preferred_git()
    local revision = wabt_source_revision()
    if revision == "" then
        errors.fail("cannot determine the WABT source revision to bundle: %s", src)
    end
    local bundle = gccsources.managed_toolchains_source_bundle_file("wabt-gcc-wasm", revision)
    os.mkdir(path.directory(bundle))
    local tmp = layout.unique_cache_path(bundle, "bundles")
    os.mkdir(path.directory(tmp))
    gccsources.managed_toolchains_run_git(git, {"-C", src, "bundle", "create", tmp, "HEAD"}, {envs = envs.proxy_envs()})
    if os.isfile(bundle) then
        os.rm(bundle)
    end
    os.mv(tmp, bundle)
    print("created source bundle: " .. bundle)
    return bundle
end

local function wabt_executable_in_build(build)
    local direct = path.join(build, base.exe("wat2wasm"))
    if os.isfile(direct) then
        return direct
    end
    for _, candidate in ipairs(os.files(path.join(build, "**", base.exe("wat2wasm")))) do
        if os.isfile(candidate) then
            return candidate
        end
    end
end

function wabt_path(target_os)
    return path.join(settings.gcc_prefix(target_os), "bin", base.exe("wat2wasm"))
end

function build_wabt(target_os, force)
    target_os = target_os or "emscripten"
    local src = sync_wabt_source(false)
    local build = settings.wabt_build_dir(target_os)
    local prefix = settings.gcc_prefix(target_os)
    local cmake = find_host_tool("cmake")
    if not cmake then
        errors.fail("CMake is required to build the GCC WebAssembly WABT fork")
    end
    local args = {
        "-S", src,
        "-B", build,
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_TESTS=OFF",
        "-DBUILD_LIBWASM=OFF",
        "-DBUILD_TOOLS=ON",
        "-DWABT_INSTALL_RULES=OFF"
    }
    local ninja = find_host_tool("ninja")
    if ninja then
        table.insert(args, "-G")
        table.insert(args, "Ninja")
    end
    local signature = table.concat(args, "\n") .. "\nrevision=" .. wabt_source_revision() .. "\n"
    local sigfile = path.join(build, ".xmake-configure")
    if force or (os.isfile(path.join(build, "CMakeCache.txt"))
        and base.trim(io.readfile(sigfile) or "") ~= base.trim(signature)) then
        layout.remove_toolchains_path(build)
    end
    os.mkdir(build)
    if not os.isfile(path.join(build, "CMakeCache.txt")) then
        run.run_program("configure GCC WebAssembly WABT fork", cmake, args, {target_os = target_os})
        io.writefile(sigfile, signature)
    end
    run.run_program("build GCC WebAssembly wat2wasm", cmake,
        {"--build", build, "--target", "wat2wasm", "--parallel",
            tostring(settings.value_or("toolchains_jobs", settings.default_jobs()))},
        {target_os = target_os})
    local built = wabt_executable_in_build(build)
    if not built then
        errors.fail("WABT build completed without producing wat2wasm: %s", build)
    end
    local bindir = path.join(prefix, "bin")
    os.mkdir(bindir)
    local installed = wabt_path(target_os)
    os.cp(built, installed)
    os.cp(built, path.join(bindir, base.exe(settings.managed_target(target_os) .. "-as")))
    return installed
end

function prepare_target_tools(target_os)
    if target_os ~= "emscripten" then
        return
    end
    local assembler = build_wabt(target_os, false)
    local binary_tools = host_binary_tools()
    local triplet = settings.managed_target(target_os)
    for name, real in pairs(binary_tools) do
        if not real then
            errors.fail("a WebAssembly-compatible %s tool was not found; install LLVM tools", name)
        end
        for _, bindir in ipairs({
            path.join(settings.gcc_prefix(target_os), "bin"),
            path.join(settings.gcc_prefix(target_os), triplet, "bin")
        }) do
            os.mkdir(bindir)
            local launcher = path.join(bindir, base.exe(triplet .. "-" .. name))
            if base.is_windows_host() then
                os.cp(real, launcher)
            else
                io.writefile(launcher, "#!/bin/sh\nexec " .. base.shquote(real) .. " \"$@\"\n")
                run.run_program("making GCC WebAssembly " .. name .. " launcher executable",
                    "chmod", {"+x", launcher}, {target_os = target_os})
            end
        end
    end
    -- LLD selects its driver flavour from argv[0]. On Windows, copying
    -- wasm-ld.exe to <triplet>-ld.exe makes it silently select the ELF
    -- linker, which then rejects otherwise valid relocatable WebAssembly
    -- objects. Keep a wasm-ld-named entry for GCC's configure-time link
    -- probes; production targets still use emcc as their final linker.
    local linker = path.join(settings.gcc_prefix(target_os), "bin", base.exe("wasm-ld"))
    if base.is_windows_host() then
        os.cp(binary_tools.ld, linker)
    else
        io.writefile(linker, "#!/bin/sh\nexec " .. base.shquote(binary_tools.ld) .. " \"$@\"\n")
        run.run_program("making GCC WebAssembly linker launcher executable",
            "chmod", {"+x", linker}, {target_os = target_os})
    end
    return assembler, linker
end

-- Read-only preflight probe (matrix-consumable): reports the CURRENT tool
-- state without the managed-toolset ensure step below -- on a machine where
-- the managed Emscripten toolset is not installed yet, the warnings simply
-- say so; preflight() would install it before stopping on anything.
function preflight_warnings(target_os)
    if target_os ~= "emscripten" then
        return {}, {}
    end
    local warnings = {}
    local actions = {
        errors.message("Install CMake and a native C++ compiler to build the pinned WABT fork."),
        errors.message("The pinned Emscripten toolset (emcc, LLVM binary tools, Node.js) installs automatically under .toolchains; fix any reported download failure and rerun, or seed the pinned archives into .toolchains/.cache/<host>/downloads."),
        errors.message("Override single tools with --emscripten_emcc=<path>, --wasm_ld=<path>, or --wasm_node=<path> only when a non-managed install must be used."),
        errors.message("Run `xmake toolchains status emscripten` to inspect every detected path.")
    }
    for _, tool in ipairs({"git", "cmake"}) do
        if not find_host_tool(tool) then
            table.insert(warnings, errors.message("Required GCC WebAssembly build tool was not found in PATH: %s", tool))
        end
    end
    if not base.is_windows_host() and not find_host_tool("python3") and not find_host_tool("python") then
        table.insert(warnings, errors.message("python3 was not found in PATH; emcc needs a host python3 on this platform."))
    end
    local binary_tools = host_binary_tools()
    for _, name in ipairs({"ld", "ar", "nm", "objcopy", "ranlib", "strip"}) do
        if not binary_tools[name] then
            table.insert(warnings, errors.message("Required WebAssembly binary tool was not found: %s", name))
        end
    end
    if not node_path() then
        table.insert(warnings, errors.message("Node.js was not found: the managed Emscripten toolset is missing and neither --wasm_node nor PATH provides node."))
    end
    if not emcc_path() then
        table.insert(warnings, errors.message("emcc was not found: the managed Emscripten toolset is missing and neither --emscripten_emcc nor PATH provides emcc."))
    elseif not emscripten_sysroot() then
        table.insert(warnings, errors.message("the emcc sysroot is incomplete or missing pthread.h; initialize the Emscripten system cache."))
    end
    return warnings, actions
end

function preflight(target_os)
    if target_os ~= "emscripten" then
        return
    end
    -- the managed toolset is the primary emcc/node/wasm-ld source; a failed
    -- install degrades loudly to the explicit/PATH/EMSDK tiers below (the
    -- origin recorded in the smoke signature keeps any drift visible)
    local ensured, failure = errors.trycall(function ()
        return gccemsdk.ensure_installed()
    end)
    if not ensured then
        errors.warn("managed Emscripten toolset install failed; falling back to emcc/node/wasm-ld from explicit configuration, PATH, or EMSDK: %s", tostring(failure))
    end
    local warnings, actions = preflight_warnings(target_os)
    if #warnings > 0 then
        run.stop_with_guidance(target_os, errors.message("experimental GCC WebAssembly prerequisites are incomplete"), warnings, actions)
    end
end

local function compiler_path(target_os, language)
    local bindir = path.join(settings.gcc_prefix(target_os), "bin")
    local triplet = settings.managed_target(target_os)
    local driver = language == "c++" and "g++" or "gcc"
    for _, candidate in ipairs({
        path.join(bindir, base.exe(triplet .. "-" .. driver)),
        path.join(bindir, base.exe(driver))
    }) do
        if os.isfile(candidate) then
            return candidate
        end
    end
end

local function libgcc_path(target_os)
    local candidates = os.files(path.join(settings.gcc_prefix(target_os), "lib", "gcc",
        settings.managed_target(target_os), "*", "libgcc.a"))
    if #candidates ~= 1 then
        errors.fail("expected exactly one installed GCC WebAssembly libgcc archive, found %d", #candidates)
    end
    return candidates[1]
end

local function libstdcxx_path(target_os)
    local archive = path.join(settings.gcc_prefix(target_os),
        settings.managed_target(target_os), "lib", "libstdc++.a")
    if not os.isfile(archive) then
        errors.fail("installed GCC WebAssembly freestanding libstdc++ archive was not found: %s", archive)
    end
    return archive
end

local function libstdcxx_exp_path(target_os)
    local prefix = settings.gcc_prefix(target_os)
    local triplet = settings.managed_target(target_os)
    local candidates = {
        path.join(prefix, "lib", "libstdc++exp.a"),
        path.join(prefix, triplet, "lib", "libstdc++exp.a")
    }
    for _, candidate in ipairs(candidates) do
        if os.isfile(candidate) then
            return candidate
        end
    end
    local versioned = os.files(path.join(prefix, triplet, "lib", "gcc", triplet, "*", "libstdc++exp.a"))
    if #versioned == 1 then
        return versioned[1]
    end
    errors.fail("installed GCC WebAssembly experimental libstdc++ archive was not found under: %s", prefix)
end

function installed_libgcc_path(target_os)
    return libgcc_path(target_os or "emscripten")
end

function installed_libstdcxx_path(target_os)
    return libstdcxx_path(target_os or "emscripten")
end

function installed_libstdcxx_exp_path(target_os)
    return libstdcxx_exp_path(target_os or "emscripten")
end

local function installed_binary_tool_path(target_os, name)
    local prefix = settings.gcc_prefix(target_os)
    local triplet = settings.managed_target(target_os)
    for _, candidate in ipairs({
        path.join(prefix, "bin", base.exe(triplet .. "-" .. name)),
        path.join(prefix, "bin", base.exe(name)),
        path.join(prefix, triplet, "bin", base.exe(triplet .. "-" .. name)),
        path.join(prefix, triplet, "bin", base.exe(name))
    }) do
        if os.isfile(candidate) then
            return candidate
        end
    end
end

local function archive_tools_ready(target_os)
    return installed_binary_tool_path(target_os, "ar") ~= nil
        and installed_binary_tool_path(target_os, "ranlib") ~= nil
end

local function runtime_archives_ready(target_os)
    local libgcc_candidates = os.files(path.join(settings.gcc_prefix(target_os), "lib", "gcc",
        settings.managed_target(target_os), "*", "libgcc.a"))
    local libstdcxx = path.join(settings.gcc_prefix(target_os),
        settings.managed_target(target_os), "lib", "libstdc++.a")
    local libstdcxx_exp = os.files(path.join(settings.gcc_prefix(target_os), "**", "libstdc++exp.a"))
    return #libgcc_candidates == 1 and os.isfile(libstdcxx) and #libstdcxx_exp > 0
end

local function smoke_dir(target_os)
    return path.join(settings.state_cache_dir(target_os), "wasm-smoke")
end

local function smoke_signature(target_os)
    local source = settings.gcc_source_profile(target_os)
    return table.concat({
        "capability=" .. WASM_CAPABILITY,
        "smoke_capability=" .. WASM_SMOKE_CAPABILITY,
        "gcc_ref=" .. source.ref,
        "gcc_revision=" .. gccsources.managed_toolchains_gcc_source_revision(settings.gcc_source_dir(target_os)),
        "c_compiler=" .. tostring(compiler_path(target_os, "c") or ""),
        "cxx_compiler=" .. tostring(compiler_path(target_os, "c++") or ""),
        "archiver=" .. tostring(installed_binary_tool_path(target_os, "ar") or ""),
        "ranlib=" .. tostring(installed_binary_tool_path(target_os, "ranlib") or ""),
        "wabt_ref=" .. settings.value_or("wasm_wabt_ref", defaults.wasm_wabt_ref),
        "wabt_revision=" .. wabt_source_revision(),
        "wat2wasm=" .. wabt_path(target_os),
        "wasm_ld=" .. tostring(wasm_ld_path() or ""),
        "emcc=" .. tostring(emcc_path() or ""),
        "emcc_origin=" .. tostring(emcc_origin() or ""),
        "emcc_version=" .. emcc_version(),
        "emscripten_sysroot=" .. tostring(emscripten_sysroot() or ""),
        "node=" .. tostring(node_path() or ""),
        "node_version=" .. node_version(),
        "triplet=" .. settings.managed_target(target_os)
    }, "\n") .. "\n"
end

local function backend_only_smoke_current(target_os)
    if target_os ~= "emscripten" then
        return false
    end
    local stamp = path.join(smoke_dir(target_os), "backend.stamp")
    return runtime_archives_ready(target_os)
        and archive_tools_ready(target_os)
        and os.isfile(stamp)
        and io.readfile(stamp) == smoke_signature(target_os)
end

function backend_smoke_current(target_os)
    local emscripten_stamp = path.join(smoke_dir(target_os), "emscripten.stamp")
    return backend_only_smoke_current(target_os)
        and os.isfile(emscripten_stamp)
        and io.readfile(emscripten_stamp) == smoke_signature(target_os)
end

function tools_ready(target_os)
    return target_os == "emscripten"
        and os.isfile(wabt_path(target_os))
        and wasm_ld_path() ~= nil
        and emcc_path() ~= nil
        and emscripten_sysroot() ~= nil
        and node_path() ~= nil
        and archive_tools_ready(target_os)
        and runtime_archives_ready(target_os)
end

local function write_smoke_sources(target_os)
    local root = smoke_dir(target_os)
    os.mkdir(root)
    local source = path.join(root, "basic_c_scalar.c")
    io.writefile(source, table.concat({
        "#ifndef __EMSCRIPTEN__",
        "#error GCC WebAssembly target identity is not Emscripten",
        "#endif",
        "#ifdef __wasi__",
        "#error Emscripten target must not advertise the WASI ABI",
        "#endif",
        "#ifdef __CHAR_UNSIGNED__",
        "#error Basic C ABI requires signed plain char",
        "#endif",
        "",
        "_Static_assert(_Generic((__WCHAR_TYPE__)0, int: 1, default: 0), \"wchar_t ABI must use int\");",
        "",
        "__attribute__((visibility(\"default\")))",
        "int gcc_wasm_add(int left, int right)",
        "{",
        "\treturn left + right;",
        "}",
        "",
        "__attribute__((visibility(\"default\")))",
        "int gcc_wasm_plain_char_is_signed(void)",
        "{",
        "\treturn (char)-1 < 0;",
        "}",
        ""
    }, "\n"))
    local cxx_helper = path.join(root, "freestanding_cxx_helper.cpp")
    io.writefile(cxx_helper, table.concat({
        "template<typename value_type>",
        "constexpr value_type add(value_type left, value_type right)",
        "{",
        "\treturn left + right;",
        "}",
        "",
        "class accumulator",
        "{",
        "public:",
        "\tconstexpr explicit accumulator(int value)",
        "\t\t: stored_value(value)",
        "\t{",
        "\t}",
        "",
        "\tconstexpr int value() const",
        "\t{",
        "\t\treturn this->stored_value;",
        "\t}",
        "",
        "private:",
        "\tint stored_value;",
        "};",
        "",
        "extern \"C\" int gcc_wasm_cxx_helper(int value)",
        "{",
        "\taccumulator result(value);",
        "\treturn add(result.value(), 6);",
        "}",
        ""
    }, "\n"))
    local cxx_entry = path.join(root, "freestanding_cxx_entry.cpp")
    io.writefile(cxx_entry, table.concat({
        "extern \"C\" int gcc_wasm_cxx_helper(int value);",
        "",
        "struct indirect_result",
        "{",
        "\tint first;",
        "\tint second;",
        "\tint total;",
        "};",
        "",
        "struct empty_indirect_result",
        "{",
        "};",
        "",
        "__attribute__((noinline, used))",
        "empty_indirect_result make_empty_indirect_result()",
        "{",
        "\treturn {};",
        "}",
        "",
        "__attribute__((noinline))",
        "indirect_result make_indirect_result(int value)",
        "{",
        "\treturn {value, value + 1, value * 2 + 1};",
        "}",
        "",
        "class scoped_increment",
        "{",
        "public:",
        "\texplicit scoped_increment(int* value)",
        "\t\t: value(value)",
        "\t{",
        "\t}",
        "",
        "\t~scoped_increment()",
        "\t{",
        "\t\t++*this->value;",
        "\t}",
        "",
        "private:",
        "\tint* value;",
        "};",
        "",
        "extern \"C\" __attribute__((visibility(\"default\")))",
        "int gcc_wasm_cxx_frontend(void)",
        "{",
        "\tconst empty_indirect_result empty = make_empty_indirect_result();",
        "\t(void)empty;",
        "",
        "\tconst indirect_result indirect = make_indirect_result(13);",
        "\tif (indirect.first != 13 || indirect.second != 14 || indirect.total != 27)",
        "\t\treturn -1;",
        "",
        "\tint result = gcc_wasm_cxx_helper(35);",
        "\t{",
        "\t\tscoped_increment increment(&result);",
        "\t}",
        "\treturn result;",
        "}",
        ""
    }, "\n"))
    return root, source, cxx_helper, cxx_entry
end

local function write_module_initializer_smoke_sources(root)
    local files = {
        provider_source = path.join(root, "module_initializer_provider.cpp"),
        consumer_source = path.join(root, "module_initializer_consumer.cpp"),
        provider_mapper = path.join(root, "module_initializer_provider.mapper"),
        consumer_mapper = path.join(root, "module_initializer_consumer.mapper"),
        provider_bmi = path.join(root, "gcc_wasm_provider.gcm"),
        consumer_bmi = path.join(root, "gcc_wasm_consumer.gcm"),
        provider_object = path.join(root, "module_initializer_provider.o"),
        consumer_object = path.join(root, "module_initializer_consumer.o")
    }
    local mapper_root = base.shpath(root)
    local provider_bmi = path.filename(files.provider_bmi)
    local consumer_bmi = path.filename(files.consumer_bmi)
    io.writefile(files.provider_source, table.concat({
        "export module gcc_wasm.provider;",
        "",
        "int initialize_gcc_wasm_module_value()",
        "{",
        "\treturn 42;",
        "}",
        "",
        "export int gcc_wasm_module_value = initialize_gcc_wasm_module_value();",
        ""
    }, "\n"))
    io.writefile(files.consumer_source, table.concat({
        "export module gcc_wasm.consumer;",
        "import gcc_wasm.provider;",
        "",
        "export extern \"C\" __attribute__((visibility(\"default\")))",
        "int gcc_wasm_module_initializer_import()",
        "{",
        "\treturn gcc_wasm_module_value;",
        "}",
        ""
    }, "\n"))
    base.writefile_bytes(files.provider_mapper, table.concat({
        "$root " .. mapper_root,
        "gcc_wasm.provider " .. provider_bmi,
        ""
    }, "\n"))
    base.writefile_bytes(files.consumer_mapper, table.concat({
        "$root " .. mapper_root,
        "gcc_wasm.consumer " .. consumer_bmi,
        "gcc_wasm.provider " .. provider_bmi,
        ""
    }, "\n"))
    return files
end

local function write_basic_abi_source(root)
    local source = path.join(root, "basic_c_abi.c")
    io.writefile(source, table.concat({
        "#ifdef __cplusplus",
        "#define WHE_ABI_EXTERN extern \"C\"",
        "#else",
        "#define WHE_ABI_EXTERN",
        "#endif",
        "",
        "struct empty_value",
        "{",
        "};",
        "",
        "struct singleton_value",
        "{",
        "\tint value;",
        "};",
        "",
        "struct nested_singleton_value",
        "{",
        "\tstruct singleton_value value;",
        "};",
        "",
        "struct pair_value",
        "{",
        "\tint left;",
        "\tint right;",
        "};",
        "",
        "WHE_ABI_EXTERN __attribute__((visibility(\"default\"), noinline))",
        "struct empty_value gcc_wasm_abi_empty(struct empty_value value)",
        "{",
        "\treturn value;",
        "}",
        "",
        "WHE_ABI_EXTERN __attribute__((visibility(\"default\"), noinline))",
        "struct singleton_value gcc_wasm_abi_singleton(struct singleton_value value)",
        "{",
        "\tstruct singleton_value result = {value.value + 1};",
        "\treturn result;",
        "}",
        "",
        "WHE_ABI_EXTERN __attribute__((visibility(\"default\"), noinline))",
        "struct nested_singleton_value gcc_wasm_abi_nested_singleton(struct nested_singleton_value value)",
        "{",
        "\tstruct nested_singleton_value result = {{value.value.value + 1}};",
        "\treturn result;",
        "}",
        "",
        "WHE_ABI_EXTERN __attribute__((visibility(\"default\"), noinline))",
        "struct pair_value gcc_wasm_abi_pair(struct pair_value value)",
        "{",
        "\tstruct pair_value result = {value.left + 1, value.right + 2};",
        "\treturn result;",
        "}",
        "",
        "WHE_ABI_EXTERN __attribute__((visibility(\"default\"), noinline))",
        "int gcc_wasm_abi_varargs(int fixed, ...)",
        "{",
        "\t__builtin_va_list arguments;",
        "\t__builtin_va_start(arguments, fixed);",
        "\tint value = __builtin_va_arg(arguments, int);",
        "\t__builtin_va_end(arguments);",
        "\treturn fixed + value;",
        "}",
        "",
        "#undef WHE_ABI_EXTERN",
        ""
    }, "\n"))
    return source
end

local function write_cross_language_abi_sources(root)
    local c_callee = path.join(root, "basic_abi_c_callee.c")
    io.writefile(c_callee, table.concat({
        "struct empty_value",
        "{",
        "};",
        "",
        "struct singleton_value",
        "{",
        "\tint value;",
        "};",
        "",
        "struct nested_singleton_value",
        "{",
        "\tstruct singleton_value value;",
        "};",
        "",
        "struct pair_value",
        "{",
        "\tint left;",
        "\tint right;",
        "};",
        "",
        "__attribute__((noinline))",
        "struct empty_value gcc_wasm_c_abi_empty(struct empty_value value)",
        "{",
        "\treturn value;",
        "}",
        "",
        "__attribute__((noinline))",
        "struct singleton_value gcc_wasm_c_abi_singleton(struct singleton_value value)",
        "{",
        "\tstruct singleton_value result = {value.value + 10};",
        "\treturn result;",
        "}",
        "",
        "__attribute__((noinline))",
        "struct nested_singleton_value gcc_wasm_c_abi_nested(struct nested_singleton_value value)",
        "{",
        "\tstruct nested_singleton_value result = {{value.value.value + 20}};",
        "\treturn result;",
        "}",
        "",
        "__attribute__((noinline))",
        "struct pair_value gcc_wasm_c_abi_pair(struct pair_value value)",
        "{",
        "\tstruct pair_value result = {value.left + 30, value.right + 40};",
        "\treturn result;",
        "}",
        "",
        "__attribute__((noinline))",
        "int gcc_wasm_c_abi_varargs(int fixed, ...)",
        "{",
        "\t__builtin_va_list arguments;",
        "\t__builtin_va_start(arguments, fixed);",
        "\tint value = __builtin_va_arg(arguments, int);",
        "\t__builtin_va_end(arguments);",
        "\treturn fixed + value;",
        "}",
        ""
    }, "\n"))

    local cxx_caller = path.join(root, "basic_abi_cxx_caller.cpp")
    io.writefile(cxx_caller, table.concat({
        "struct empty_value",
        "{",
        "};",
        "",
        "struct singleton_value",
        "{",
        "\tint value;",
        "};",
        "",
        "struct nested_singleton_value",
        "{",
        "\tsingleton_value value;",
        "};",
        "",
        "struct pair_value",
        "{",
        "\tint left;",
        "\tint right;",
        "};",
        "",
        "extern \"C\" empty_value gcc_wasm_c_abi_empty(empty_value value);",
        "extern \"C\" singleton_value gcc_wasm_c_abi_singleton(singleton_value value);",
        "extern \"C\" nested_singleton_value gcc_wasm_c_abi_nested(nested_singleton_value value);",
        "extern \"C\" pair_value gcc_wasm_c_abi_pair(pair_value value);",
        "extern \"C\" int gcc_wasm_c_abi_varargs(int fixed, ...);",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "int gcc_wasm_cpp_calls_c(void)",
        "{",
        "\tempty_value empty_result = gcc_wasm_c_abi_empty({});",
        "\t(void)empty_result;",
        "\tsingleton_value singleton_result = gcc_wasm_c_abi_singleton({1});",
        "\tnested_singleton_value nested_result = gcc_wasm_c_abi_nested({{2}});",
        "\tpair_value pair_result = gcc_wasm_c_abi_pair({3, 4});",
        "\treturn 1 + singleton_result.value + nested_result.value.value",
        "\t\t+ pair_result.left + pair_result.right + gcc_wasm_c_abi_varargs(5, 6);",
        "}",
        ""
    }, "\n"))

    local cxx_callee = path.join(root, "basic_abi_cxx_callee.cpp")
    io.writefile(cxx_callee, table.concat({
        "struct empty_value",
        "{",
        "};",
        "",
        "struct singleton_value",
        "{",
        "\tint value;",
        "};",
        "",
        "struct nested_singleton_value",
        "{",
        "\tsingleton_value value;",
        "};",
        "",
        "struct pair_value",
        "{",
        "\tint left;",
        "\tint right;",
        "};",
        "",
        "extern \"C\" __attribute__((noinline))",
        "empty_value gcc_wasm_cpp_abi_empty(empty_value value)",
        "{",
        "\treturn value;",
        "}",
        "",
        "extern \"C\" __attribute__((noinline))",
        "singleton_value gcc_wasm_cpp_abi_singleton(singleton_value value)",
        "{",
        "\treturn {value.value + 1};",
        "}",
        "",
        "extern \"C\" __attribute__((noinline))",
        "nested_singleton_value gcc_wasm_cpp_abi_nested(nested_singleton_value value)",
        "{",
        "\treturn {{value.value.value + 2}};",
        "}",
        "",
        "extern \"C\" __attribute__((noinline))",
        "pair_value gcc_wasm_cpp_abi_pair(pair_value value)",
        "{",
        "\treturn {value.left + 3, value.right + 4};",
        "}",
        "",
        "extern \"C\" __attribute__((noinline))",
        "int gcc_wasm_cpp_abi_varargs(int fixed, ...)",
        "{",
        "\t__builtin_va_list arguments;",
        "\t__builtin_va_start(arguments, fixed);",
        "\tint value = __builtin_va_arg(arguments, int);",
        "\t__builtin_va_end(arguments);",
        "\treturn fixed + value;",
        "}",
        ""
    }, "\n"))

    local c_caller = path.join(root, "basic_abi_c_caller.c")
    io.writefile(c_caller, table.concat({
        "struct empty_value",
        "{",
        "};",
        "",
        "struct singleton_value",
        "{",
        "\tint value;",
        "};",
        "",
        "struct nested_singleton_value",
        "{",
        "\tstruct singleton_value value;",
        "};",
        "",
        "struct pair_value",
        "{",
        "\tint left;",
        "\tint right;",
        "};",
        "",
        "struct empty_value gcc_wasm_cpp_abi_empty(struct empty_value value);",
        "struct singleton_value gcc_wasm_cpp_abi_singleton(struct singleton_value value);",
        "struct nested_singleton_value gcc_wasm_cpp_abi_nested(struct nested_singleton_value value);",
        "struct pair_value gcc_wasm_cpp_abi_pair(struct pair_value value);",
        "int gcc_wasm_cpp_abi_varargs(int fixed, ...);",
        "",
        "__attribute__((visibility(\"default\"), noinline))",
        "int gcc_wasm_c_calls_cpp(void)",
        "{",
        "\tstruct empty_value empty = {};",
        "\tstruct empty_value empty_result = gcc_wasm_cpp_abi_empty(empty);",
        "\t(void)empty_result;",
        "\tstruct singleton_value singleton = {10};",
        "\tstruct singleton_value singleton_result = gcc_wasm_cpp_abi_singleton(singleton);",
        "\tstruct nested_singleton_value nested = {{20}};",
        "\tstruct nested_singleton_value nested_result = gcc_wasm_cpp_abi_nested(nested);",
        "\tstruct pair_value pair = {30, 40};",
        "\tstruct pair_value pair_result = gcc_wasm_cpp_abi_pair(pair);",
        "\treturn 1 + singleton_result.value + nested_result.value.value",
        "\t\t+ pair_result.left + pair_result.right + gcc_wasm_cpp_abi_varargs(7, 8);",
        "}",
        ""
    }, "\n"))

    return c_callee, cxx_caller, cxx_callee, c_caller
end

local function write_int128_abi_sources(root)
    local c_callee = path.join(root, "int128_abi_c_callee.c")
    io.writefile(c_callee, table.concat({
        "__attribute__((noinline))",
        "unsigned __int128 gcc_wasm_c_int128_identity(unsigned __int128 value)",
        "{",
        "\treturn value;",
        "}",
        ""
    }, "\n"))

    local cxx_caller = path.join(root, "int128_abi_cxx_caller.cpp")
    io.writefile(cxx_caller, table.concat({
        "extern \"C\" unsigned __int128 gcc_wasm_c_int128_identity(unsigned __int128 value);",
        "",
        "using int128_function = unsigned __int128 (*)(unsigned __int128);",
        "static int128_function volatile int128_target = &gcc_wasm_c_int128_identity;",
        "",
        "__attribute__((noinline))",
        "static unsigned __int128 call_int128_indirect(unsigned __int128 value)",
        "{",
        "\treturn int128_target(value);",
        "}",
        "",
        "static unsigned __int128 make_int128(unsigned long long low, unsigned long long high)",
        "{",
        "\treturn (static_cast<unsigned __int128>(high) << 64) | low;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "unsigned long long gcc_wasm_cpp_int128_calls_c_low(unsigned long long low, unsigned long long high)",
        "{",
        "\treturn static_cast<unsigned long long>(call_int128_indirect(make_int128(low, high)));",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "unsigned long long gcc_wasm_cpp_int128_calls_c_high(unsigned long long low, unsigned long long high)",
        "{",
        "\treturn static_cast<unsigned long long>(call_int128_indirect(make_int128(low, high)) >> 64);",
        "}",
        ""
    }, "\n"))

    local cxx_callee = path.join(root, "int128_abi_cxx_callee.cpp")
    io.writefile(cxx_callee, table.concat({
        "extern \"C\" __attribute__((noinline))",
        "unsigned __int128 gcc_wasm_cpp_int128_identity(unsigned __int128 value)",
        "{",
        "\treturn value;",
        "}",
        ""
    }, "\n"))

    local c_caller = path.join(root, "int128_abi_c_caller.c")
    io.writefile(c_caller, table.concat({
        "unsigned __int128 gcc_wasm_cpp_int128_identity(unsigned __int128 value);",
        "",
        "static unsigned __int128 make_int128(unsigned long long low, unsigned long long high)",
        "{",
        "\treturn ((unsigned __int128)high << 64) | low;",
        "}",
        "",
        "__attribute__((visibility(\"default\"), noinline))",
        "unsigned long long gcc_wasm_c_int128_calls_cpp_low(unsigned long long low, unsigned long long high)",
        "{",
        "\treturn (unsigned long long)gcc_wasm_cpp_int128_identity(make_int128(low, high));",
        "}",
        "",
        "__attribute__((visibility(\"default\"), noinline))",
        "unsigned long long gcc_wasm_c_int128_calls_cpp_high(unsigned long long low, unsigned long long high)",
        "{",
        "\treturn (unsigned long long)(gcc_wasm_cpp_int128_identity(make_int128(low, high)) >> 64);",
        "}",
        ""
    }, "\n"))

    return c_callee, cxx_caller, cxx_callee, c_caller
end

local function write_int128_runtime_source(root)
    local source = path.join(root, "int128_runtime.cpp")
    io.writefile(source, table.concat({
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "unsigned __int128 gcc_wasm_int128_multiply(unsigned __int128 left, unsigned __int128 right)",
        "{",
        "\treturn left * right;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "unsigned __int128 gcc_wasm_int128_unsigned_divide(unsigned __int128 left, unsigned __int128 right)",
        "{",
        "\treturn left / right;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "unsigned __int128 gcc_wasm_int128_unsigned_modulo(unsigned __int128 left, unsigned __int128 right)",
        "{",
        "\treturn left % right;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "__int128 gcc_wasm_int128_signed_divide(__int128 left, __int128 right)",
        "{",
        "\treturn left / right;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "__int128 gcc_wasm_int128_signed_modulo(__int128 left, __int128 right)",
        "{",
        "\treturn left % right;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "unsigned int gcc_wasm_int128_low32(unsigned __int128 value)",
        "{",
        "\treturn static_cast<unsigned int>(value);",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "unsigned short gcc_wasm_int128_low16(unsigned __int128 value)",
        "{",
        "\treturn static_cast<unsigned short>(value);",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "unsigned char gcc_wasm_int128_low8(unsigned __int128 value)",
        "{",
        "\treturn static_cast<unsigned char>(value);",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "int gcc_wasm_int128_signed_low8(unsigned __int128 value)",
        "{",
        "\treturn static_cast<signed char>(value);",
        "}",
        ""
    }, "\n"))
    return source
end

local function write_libcall_gc_source(root)
    local source = path.join(root, "libcall_gc.cpp")
    io.writefile(source, table.concat({
        "using uint128 = unsigned __int128;",
        "",
        "uint128 gcc_wasm_divide_uint128(uint128 numerator, uint128 denominator)",
        "{",
        "\treturn numerator / denominator;",
        "}",
        "",
        "template<unsigned index>",
        "uint128 gcc_wasm_instantiate_many_functions(uint128 value)",
        "{",
        "\tif constexpr (index == 0)",
        "\t\treturn value;",
        "\telse",
        "\t\treturn gcc_wasm_instantiate_many_functions<index - 1>(value) + index;",
        "}",
        "",
        "template uint128 gcc_wasm_instantiate_many_functions<64>(uint128);",
        ""
    }, "\n"))
    return source
end

local function write_libstdcxx_source(root)
    local source = path.join(root, "freestanding_libstdcxx.cpp")
    io.writefile(source, table.concat({
        "#include <array>",
        "#include <bit>",
        "#include <chrono>",
        "#include <cstddef>",
        "#include <cstdint>",
        "#include <cstdlib>",
        "#include <cstring>",
        "#include <format>",
        "#include <functional>",
        "#include <map>",
        "#include <memory>",
        "#include <ranges>",
        "#include <span>",
        "#include <stdexcept>",
        "#include <string>",
        "#include <type_traits>",
        "#include <unordered_map>",
        "#include <utility>",
        "#include <vector>",
        "#include <version>",
        "#include <bits/c++config.h>",
        "#include <bits/hash_bytes.h>",
        "",
        "static_assert(__STDC_HOSTED__ == 0);",
        "static_assert(_GLIBCXX_HOSTED == 0);",
        "static_assert(sizeof(std::size_t) == sizeof(std::uint32_t));",
        "static_assert(std::is_class_v<std::FILE>);",
        "static_assert(sizeof(std::FILE*) == sizeof(void*));",
        "static_assert(__cpp_lib_make_unique >= 201304L);",
        "static_assert(std::is_base_of_v<std::logic_error, std::out_of_range>);",
        "static_assert(std::is_constructible_v<std::out_of_range, const char*>);",
        "static_assert(std::is_copy_constructible_v<std::hash<std::thread::id>>);",
        "static_assert(std::abs(-7) == 7);",
        "static_assert(std::endian::native == std::endian::little);",
        "static_assert(std::is_same_v<decltype(std::declval<std::span<const std::uint8_t>>().size()), std::size_t>);",
        "",
        "alignas(std::max_align_t) static unsigned char smoke_heap[16384] = {};",
        "static std::size_t smoke_heap_used = 0;",
        "",
        "void* operator new(std::size_t size)",
        "{",
        "\tconstexpr std::size_t alignment = alignof(std::max_align_t);",
        "\tconst std::size_t offset = (smoke_heap_used + alignment - 1) & ~(alignment - 1);",
        "\tif (offset + size > sizeof(smoke_heap))",
        "\t\t__builtin_trap();",
        "",
        "\tvoid* result = smoke_heap + offset;",
        "\tsmoke_heap_used = offset + size;",
        "\treturn result;",
        "}",
        "",
        "void operator delete(void*) noexcept",
        "{",
        "}",
        "",
        "void operator delete(void*, std::size_t) noexcept",
        "{",
        "}",
        "",
        "template <typename type>",
        "class smoke_allocator",
        "{",
        "public:",
        "\tusing value_type = type;",
        "",
        "\tsmoke_allocator() noexcept = default;",
        "",
        "\ttemplate <typename other_type>",
        "\tsmoke_allocator(const smoke_allocator<other_type>&) noexcept",
        "\t{",
        "\t}",
        "",
        "\t[[nodiscard]] type* allocate(std::size_t count)",
        "\t{",
        "\t\tconst std::size_t next = this->used_ + count;",
        "\t\tif (next > this->capacity_)",
        "\t\t\t__builtin_trap();",
        "",
        "\t\ttype* result = reinterpret_cast<type*>(this->storage_) + this->used_;",
        "\t\tthis->used_ = next;",
        "\t\treturn result;",
        "\t}",
        "",
        "\tvoid deallocate(type*, std::size_t) noexcept",
        "\t{",
        "\t}",
        "",
        "\ttemplate <typename other_type>",
        "\tbool operator==(const smoke_allocator<other_type>&) const noexcept",
        "\t{",
        "\t\treturn true;",
        "\t}",
        "",
        "private:",
        "\tstatic inline constexpr std::size_t capacity_ = 8;",
        "\talignas(type) static inline unsigned char storage_[sizeof(type) * capacity_] = {};",
        "\tstatic inline std::size_t used_ = 0;",
        "};",
        "",
        "struct smoke_format_value",
        "{",
        "\tstd::uint32_t value;",
        "};",
        "",
        "template <>",
        "struct std::formatter<smoke_format_value>",
        "{",
        "\tconstexpr auto parse(std::format_parse_context& context)",
        "\t{",
        "\t\treturn context.begin();",
        "\t}",
        "",
        "\tauto format(const smoke_format_value& value, std::format_context& context) const",
        "\t{",
        "\t\treturn std::format_to(context.out(), \"{:02}\", value.value);",
        "\t}",
        "};",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_hash()",
        "{",
        "\tconstexpr std::array<std::uint8_t, 4> payload = {1, 2, 3, 4};",
        "\tconst std::span<const std::uint8_t> bytes(payload);",
        "\treturn static_cast<std::uint32_t>(std::_Fnv_hash_bytes(bytes.data(), bytes.size(), 2166136261U));",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_ordered_map()",
        "{",
        "\tusing value_type = std::pair<const std::uint32_t, std::uint32_t>;",
        "\tusing map_type = std::map<std::uint32_t, std::uint32_t, std::less<std::uint32_t>, smoke_allocator<value_type>>;",
        "\tmap_type values;",
        "\tvalues.emplace(3, 7);",
        "\tvalues.emplace(1, 5);",
        "\tvalues.emplace(2, 11);",
        "\tstd::erase_if(values, [](const auto& entry)",
        "\t{",
        "\t\treturn entry.first == 2;",
        "\t}",
        "\t);",
        "\tstd::uint32_t result = 0;",
        "\tfor (const auto& [key, value] : values)",
        "\t\tresult = result * 31 + key * 7 + value;",
        "\treturn result;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_string()",
        "{",
        "\tstd::string value = \"gcc-wasm-string-runtime\";",
        "\tvalue.append(20, 'x');",
        "\tconst std::size_t removed = std::erase(value, '-');",
        "\tconst std::size_t runtime_offset = value.find(\"runtime\");",
        "\treturn static_cast<std::uint32_t>(removed * 10000 + value.size() * 100 + runtime_offset);",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_integral_to_string()",
        "{",
        "\treturn std::to_string(-42) == \"-42\"",
        "\t\t&& std::to_string(42u) == \"42\"",
        "\t\t&& std::to_string(-2147483647L - 1L) == \"-2147483648\"",
        "\t\t&& std::to_string(4294967295UL) == \"4294967295\"",
        "\t\t&& std::to_string(-9223372036854775807LL - 1LL) == \"-9223372036854775808\"",
        "\t\t&& std::to_string(18446744073709551615ULL) == \"18446744073709551615\";",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_integral_abs()",
        "{",
        "\treturn static_cast<std::uint32_t>(std::abs(-7) + std::abs(-11L) + std::abs(-13LL));",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_vector()",
        "{",
        "\tstd::vector<std::uint32_t> values;",
        "\tfor (std::uint32_t value = 1; value <= 8; ++value)",
        "\t\tvalues.push_back(value * 3);",
        "\tconst std::size_t removed = std::erase_if(values, [](std::uint32_t value)",
        "\t{",
        "\t\treturn value % 2 == 0;",
        "\t}",
        "\t);",
        "\tstd::uint32_t result = 0;",
        "\tfor (std::uint32_t value : values)",
        "\t\tresult = result * 31 + value;",
        "\treturn result + static_cast<std::uint32_t>(removed * 100000);",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_make_unique()",
        "{",
        "\tauto scalar = std::make_unique<std::uint32_t>(37u);",
        "\tauto array = std::make_unique<std::uint32_t[]>(3);",
        "\tarray[0] = 1u;",
        "\tarray[1] = 2u;",
        "\tarray[2] = 3u;",
        "\tauto overwrite = std::make_unique_for_overwrite<std::uint32_t>();",
        "\t*overwrite = 11u;",
        "\treturn *scalar * 1000u + (array[0] + array[1] + array[2]) * 10u + *overwrite;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_shared_ptr()",
        "{",
        "\tauto first = std::make_shared<std::uint32_t>(37u);",
        "\tauto second = first;",
        "\tstd::weak_ptr<std::uint32_t> weak = first;",
        "\tif (first.use_count() != 2 || weak.expired())",
        "\t\treturn 0;",
        "\tsecond.reset();",
        "\tauto locked = weak.lock();",
        "\tif (!locked || locked.use_count() != 2)",
        "\t\treturn 0;",
        "\t*locked += 5u;",
        "\tfirst.reset();",
        "\tconst std::uint32_t value = *locked;",
        "\tlocked.reset();",
        "\treturn value * 100u + (weak.expired() ? 1u : 0u);",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_chrono_duration()",
        "{",
        "\tconst auto elapsed = std::chrono::minutes(3) + std::chrono::seconds(7);",
        "\treturn static_cast<std::uint32_t>(std::chrono::duration_cast<std::chrono::seconds>(elapsed).count());",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_chrono_calendar_time()",
        "{",
        "\tusing namespace std::chrono;",
        "\tconst year_month_day date = year{2026} / July / day{15};",
        "\tconst hh_mm_ss<system_clock::duration> time{hours{13} + minutes{47} + seconds{29} + milliseconds{321}};",
        "\tstd::uint32_t result = 17;",
        "\tconst auto mix = [&result](std::uint32_t value)",
        "\t{",
        "\t\tresult = result * 31u + value;",
        "\t};",
        "\tmix(static_cast<std::uint32_t>(static_cast<int>(date.year())));",
        "\tmix(static_cast<std::uint32_t>(static_cast<unsigned>(date.month())));",
        "\tmix(static_cast<std::uint32_t>(static_cast<unsigned>(date.day())));",
        "\tmix(static_cast<std::uint32_t>(time.hours().count()));",
        "\tmix(static_cast<std::uint32_t>(time.minutes().count()));",
        "\tmix(static_cast<std::uint32_t>(time.seconds().count()));",
        "\tmix(static_cast<std::uint32_t>(duration_cast<milliseconds>(time.subseconds()).count()));",
        "\treturn date.ok() && !time.is_negative() ? result : 0;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_ranges_to_vector()",
        "{",
        "\tconst std::array<std::uint32_t, 4> input{1, 3, 5, 7};",
        "\tconst auto values = input | std::views::transform([](std::uint32_t value)",
        "\t{",
        "\t\treturn value * 2u + 1u;",
        "\t}) | std::ranges::to<std::vector>();",
        "\tstd::uint32_t result = static_cast<std::uint32_t>(values.size());",
        "\tfor (std::uint32_t value : values)",
        "\t\tresult = result * 31u + value;",
        "\treturn result;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_cstring_memory()",
        "{",
        "\tconst std::uint8_t source[6] = {1, 2, 3, 4, 5, 6};",
        "\tstd::uint8_t destination[6] = {};",
        "\tconst std::uint8_t expected[6] = {1, 1, 2, 3, 9, 9};",
        "\tstd::memcpy(destination, source, sizeof(source));",
        "\tstd::memmove(destination + 1, destination, 5);",
        "\tstd::memset(destination + 4, 9, 2);",
        "\tif (std::memcmp(destination, expected, sizeof(expected)) != 0)",
        "\t\treturn 0;",
        "\tconst void* found = std::memchr(destination, 3, sizeof(destination));",
        "\treturn static_cast<std::uint32_t>((static_cast<const std::uint8_t*>(found) - destination) + destination[4] * 100);",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_format()",
        "{",
        "\tconst std::string value = std::format(\"id={} hex={:#x} {}\", smoke_format_value{7}, 42u, \"ok\");",
        "\treturn value == \"id=07 hex=0x2a ok\" ? 1u : 0u;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_single_thread_sync()",
        "{",
        "\tstd::mutex mutex;",
        "\tstd::unique_lock lock(mutex);",
        "\tstd::condition_variable condition;",
        "\tcondition.wait(lock, [] { return true; });",
        "\tstd::latch completion(1);",
        "\tcompletion.count_down();",
        "\tstd::shared_mutex shared_mutex;",
        "\tstd::shared_lock shared_lock(shared_mutex);",
        "\tstd::thread thread([] { __builtin_trap(); });",
        "\tstd::jthread joining_thread([] { __builtin_trap(); });",
        "\tstd::unordered_map<std::thread::id, std::uint32_t> thread_values;",
        "\tthread_values.emplace(std::this_thread::get_id(), 17u);",
        "\tconst std::stop_token token = joining_thread.get_stop_token();",
        "\tif (std::thread::hardware_concurrency() != 0 || thread.joinable()",
        "\t\t|| joining_thread.joinable() || !completion.try_wait()",
        "\t\t|| thread_values.at(std::this_thread::get_id()) != 17u)",
        "\t\treturn 0;",
        "\tjoining_thread.request_stop();",
        "\treturn token.stop_requested() ? 1u : 0u;",
        "}",
        "",
        "extern \"C\" __attribute__((visibility(\"default\"), noinline))",
        "std::uint32_t gcc_wasm_libstdcxx_callable_hash_map()",
        "{",
        "\tconst std::function<std::uint32_t(std::uint32_t)> add_bias = [bias = 5u](std::uint32_t value)",
        "\t{",
        "\t\treturn value + bias;",
        "\t};",
        "\tstd::unordered_map<std::uint32_t, std::uint32_t> values;",
        "\tvalues.emplace(3u, 7u);",
        "\tvalues.emplace(11u, 13u);",
        "\tif (!values.contains(3u) || values.contains(9u))",
        "\t\treturn 0;",
        "\treturn add_bias(values.at(3u)) * 100u + static_cast<std::uint32_t>(values.size());",
        "}",
        ""
    }, "\n"))
    return source
end

local function wat_function_signature(wat, function_name)
    local begin_marker = "  (func $" .. function_name .. " "
    local begin_pos = wat:find(begin_marker, 1, true)
    if not begin_pos then
        errors.fail("GCC WebAssembly WAT did not contain ABI probe function: %s", function_name)
    end
    local signature_end = wat:find("    ;; hard", begin_pos, true)
    if not signature_end then
        errors.fail("GCC WebAssembly WAT function signature was not terminated as expected: %s", function_name)
    end
    return wat:sub(begin_pos, signature_end - 1)
end

local function assert_wat_signature(wat, function_name, expected_parameters, expected_result)
    local signature = wat_function_signature(wat, function_name)
    local parameters = {}
    for parameter_type in signature:gmatch("%(param%s+%$[%w_]+%s+([%w%d]+)%)") do
        table.insert(parameters, parameter_type)
    end
    local results = {}
    local result_list = signature:match("%(result%s+([^%)]+)%)")
    if result_list then
        for result_type in result_list:gmatch("[%w%d]+") do
            table.insert(results, result_type)
        end
    end
    local expected_results = expected_result
    if type(expected_results) ~= "table" then
        expected_results = expected_results and {expected_results} or {}
    end
    local actual = table.concat(parameters, ",") .. "->"
        .. (#results > 0 and table.concat(results, ",") or "void")
    local expected = table.concat(expected_parameters, ",") .. "->"
        .. (#expected_results > 0 and table.concat(expected_results, ",") or "void")
    if actual ~= expected then
        errors.fail("GCC WebAssembly Basic C ABI signature mismatch for %s: expected %s, got %s",
            function_name, expected, actual)
    end
end

local function verify_basic_abi_wat(wat_file)
    local wat = io.readfile(wat_file)
    assert_wat_signature(wat, "gcc_wasm_abi_empty", {}, nil)
    assert_wat_signature(wat, "gcc_wasm_abi_singleton", {"i32"}, "i32")
    assert_wat_signature(wat, "gcc_wasm_abi_nested_singleton", {"i32"}, "i32")
    assert_wat_signature(wat, "gcc_wasm_abi_pair", {"i32", "i32"}, nil)
    assert_wat_signature(wat, "gcc_wasm_abi_varargs", {"i32", "i32"}, "i32")
end

local function verify_int128_abi_wat(wat_file, function_name)
    local wat = io.readfile(wat_file)
    assert_wat_signature(wat, function_name, {"i64", "i64"}, {"i64", "i64"})
end

local function verify_int128_low_truncation_wat(wat, function_name)
    local begin_marker = "  (func $" .. function_name .. " "
    local begin_pos = wat:find(begin_marker, 1, true)
    if not begin_pos then
        errors.fail("GCC WebAssembly WAT did not contain __int128 truncation probe: %s", function_name)
    end
    local end_marker = ") ;;" .. function_name
    local end_pos = wat:find(end_marker, begin_pos, true)
    if not end_pos then
        errors.fail("GCC WebAssembly WAT did not terminate __int128 truncation probe: %s", function_name)
    end
    local body = wat:sub(begin_pos, end_pos + #end_marker - 1)
    if not body:find("i32.wrap_i64", 1, true) then
        errors.fail("GCC WebAssembly __int128 truncation probe did not lower through i32.wrap_i64: %s",
            function_name)
    end
end

local function verify_atomic_compare_exchange_import_wat(wat_file)
    local wat = io.readfile(wat_file) or ""
    local import_marker = "(import \"env\" \"__atomic_compare_exchange_4\""
    local import_line = nil
    for line in wat:gmatch("[^\r\n]+") do
        if line:find(import_marker, 1, true) then
            import_line = line
            break
        end
    end
    if not import_line then
        errors.fail("GCC WebAssembly atomic compare-exchange probe did not emit the fixed-width libatomic import")
    end
    local parameter_list = import_line:match("%(param%s+([^%)]+)%)")
    local parameters = {}
    for parameter_type in (parameter_list or ""):gmatch("%S+") do
        table.insert(parameters, parameter_type)
    end
    if #parameters ~= 5 then
        errors.fail("GCC WebAssembly __atomic_compare_exchange_4 import must have 5 parameters, got %d",
            #parameters)
    end
    for _, parameter_type in ipairs(parameters) do
        if parameter_type ~= "i32" then
            errors.fail("GCC WebAssembly __atomic_compare_exchange_4 import used a non-i32 parameter: %s",
                parameter_type)
        end
    end
    if import_line:match("%(result%s+([^%)]+)%)") ~= "i32" then
        errors.fail("GCC WebAssembly __atomic_compare_exchange_4 import must return i32")
    end
end

function run_backend_smoke(target_os)
    target_os = target_os or "emscripten"
    if target_os ~= "emscripten" then
        errors.fail("GCC WebAssembly smoke test only supports the emscripten target")
    end
    local compiler = compiler_path(target_os, "c")
    local cxx_compiler = compiler_path(target_os, "c++")
    if not compiler then
        errors.fail("experimental GCC WebAssembly C compiler is not installed")
    end
    if not cxx_compiler then
        errors.fail("experimental GCC WebAssembly C++ compiler is not installed")
    end
    local linker = wasm_ld_path()
    local node = node_path()
    if not linker or not node then
        preflight(target_os)
    end
    local root, source, cxx_helper, cxx_entry = write_smoke_sources(target_os)
    local object = path.join(root, "basic_c_scalar.o")
    local module = path.join(root, "basic_c_scalar.wasm")
    run.run_program("compile GCC WebAssembly scalar C smoke object", compiler,
        {"-O2", "-ffreestanding", "-fno-builtin", "-c", source, "-o", object},
        {target_os = target_os, envs = envs.shell_envs(path.join(settings.gcc_prefix(target_os), "bin"))})
    if not os.isfile(object) then
        errors.fail("GCC WebAssembly compiler did not produce an object file: %s", object)
    end
    local archiver = installed_binary_tool_path(target_os, "ar")
    local ranlib = installed_binary_tool_path(target_os, "ranlib")
    if not archiver or not ranlib then
        errors.fail("installed GCC WebAssembly archive tools are incomplete")
    end
    local archive = path.join(root, "basic_c_scalar.a")
    os.rm(archive)
    run.run_program("archive GCC WebAssembly scalar C smoke object", archiver,
        {"rcs", archive, object}, {target_os = target_os})
    run.run_program("index GCC WebAssembly scalar C smoke archive", ranlib,
        {archive}, {target_os = target_os})
    run.run_program("list GCC WebAssembly scalar C smoke archive", archiver,
        {"t", archive}, {target_os = target_os})
    run.run_program("link GCC WebAssembly scalar C smoke module", linker, {
        "--no-entry",
        "--gc-sections",
        "--export=gcc_wasm_add",
        "--export=gcc_wasm_plain_char_is_signed",
        object,
        "-o", module
    }, {target_os = target_os})
    local script = table.concat({
        "const fs=require('fs');",
        "const bytes=fs.readFileSync(process.argv[1]);",
        "const compiled=new WebAssembly.Module(bytes);",
        "const imports={};",
        "for(const item of WebAssembly.Module.imports(compiled)){",
        " imports[item.module]??={};",
        " if(item.kind==='memory') imports[item.module][item.name]=new WebAssembly.Memory({initial:2});",
        " else if(item.kind==='table') imports[item.module][item.name]=new WebAssembly.Table({initial:1,element:'anyfunc'});",
        " else if(item.kind==='global') imports[item.module][item.name]=new WebAssembly.Global({value:'i32',mutable:true},0);",
        " else imports[item.module][item.name]=()=>0;",
        "}",
        "const instance=new WebAssembly.Instance(compiled,imports);",
        "if(instance.exports.gcc_wasm_add(19,23)!==42) throw new Error('scalar add ABI mismatch');",
        "if(instance.exports.gcc_wasm_plain_char_is_signed()!==1) throw new Error('plain char ABI is not signed');"
    }, "")
    run.run_program("execute GCC WebAssembly scalar C smoke module", node,
        {"-e", script, module}, {target_os = target_os})

    local cxx_flags = {
        "-std=c++26",
        "-O2",
        "-ffreestanding",
        "-fno-builtin",
        "-fno-exceptions",
        "-fno-rtti",
        "-fno-threadsafe-statics",
        "-fno-use-cxa-atexit",
        "-nostdinc++",
        "-c"
    }
    local cxx_helper_object = path.join(root, "freestanding_cxx_helper.o")
    local cxx_entry_object = path.join(root, "freestanding_cxx_entry.o")
    local cxx_envs = envs.shell_envs(path.join(settings.gcc_prefix(target_os), "bin"))
    local helper_args = table.clone(cxx_flags)
    table.insert(helper_args, cxx_helper)
    table.insert(helper_args, "-o")
    table.insert(helper_args, cxx_helper_object)
    run.run_program("compile GCC WebAssembly freestanding C++ helper", cxx_compiler,
        helper_args, {target_os = target_os, envs = cxx_envs})
    local entry_args = table.clone(cxx_flags)
    entry_args[2] = "-O0"
    table.insert(entry_args, cxx_entry)
    table.insert(entry_args, "-o")
    table.insert(entry_args, cxx_entry_object)
    run.run_program("compile GCC WebAssembly freestanding C++ entry", cxx_compiler,
        entry_args, {target_os = target_os, envs = cxx_envs})
    local cxx_module = path.join(root, "freestanding_cxx_frontend.wasm")
    run.run_program("link GCC WebAssembly freestanding C++ smoke module", linker, {
        "--no-entry",
        "--gc-sections",
        "--export=gcc_wasm_cxx_frontend",
        cxx_helper_object,
        cxx_entry_object,
        "-o", cxx_module
    }, {target_os = target_os})
    local cxx_script = table.concat({
        "const fs=require('fs');",
        "const bytes=fs.readFileSync(process.argv[1]);",
        "const compiled=new WebAssembly.Module(bytes);",
        "const imports={};",
        "for(const item of WebAssembly.Module.imports(compiled)){",
        " imports[item.module]??={};",
        " if(item.kind==='memory') imports[item.module][item.name]=new WebAssembly.Memory({initial:2});",
        " else if(item.kind==='table') imports[item.module][item.name]=new WebAssembly.Table({initial:1,element:'anyfunc'});",
        " else if(item.kind==='global') imports[item.module][item.name]=new WebAssembly.Global({value:'i32',mutable:true},0);",
        " else imports[item.module][item.name]=()=>0;",
        "}",
        "const instance=new WebAssembly.Instance(compiled,imports);",
        "if(instance.exports.gcc_wasm_cxx_frontend()!==42) throw new Error('freestanding C++ frontend mismatch');"
    }, "")
    run.run_program("execute GCC WebAssembly freestanding C++ smoke module", node,
        {"-e", cxx_script, cxx_module}, {target_os = target_os})

    local module_smoke = write_module_initializer_smoke_sources(root)
    local module_flags = {
        "-std=c++26",
        "-O0",
        "-ffreestanding",
        "-fno-builtin",
        "-fno-exceptions",
        "-fno-rtti",
        "-fno-threadsafe-statics",
        "-fno-use-cxa-atexit",
        "-nostdinc++",
        "-fmodules",
        "-fmodule-implicit-inline",
        "-c"
    }
    local function compile_module_initializer_smoke(label, source_file, mapper_file, object_file)
        local args = table.clone(module_flags)
        table.insert(args, "-fmodule-mapper=" .. base.shpath(mapper_file))
        table.insert(args, source_file)
        table.insert(args, "-o")
        table.insert(args, object_file)
        run.run_program(label, cxx_compiler, args, {target_os = target_os, envs = cxx_envs})
    end
    compile_module_initializer_smoke("compile GCC WebAssembly module initializer provider",
        module_smoke.provider_source, module_smoke.provider_mapper, module_smoke.provider_object)
    compile_module_initializer_smoke("compile GCC WebAssembly module initializer consumer",
        module_smoke.consumer_source, module_smoke.consumer_mapper, module_smoke.consumer_object)
    local module_initializer_module = path.join(root, "module_initializer_import.wasm")
    run.run_program("link GCC WebAssembly module initializer import smoke", linker, {
        "--no-entry",
        "--gc-sections",
        "--export=gcc_wasm_module_initializer_import",
        "--export-if-defined=__wasm_call_ctors",
        module_smoke.provider_object,
        module_smoke.consumer_object,
        "-o", module_initializer_module
    }, {target_os = target_os})
    local module_initializer_script = table.concat({
        "const fs=require('fs');",
        "const bytes=fs.readFileSync(process.argv[1]);",
        "const compiled=new WebAssembly.Module(bytes);",
        "const imports={};",
        "for(const item of WebAssembly.Module.imports(compiled)){",
        " imports[item.module]??={};",
        " if(item.kind==='memory') imports[item.module][item.name]=new WebAssembly.Memory({initial:2});",
        " else if(item.kind==='table') imports[item.module][item.name]=new WebAssembly.Table({initial:1,element:'anyfunc'});",
        " else if(item.kind==='global') imports[item.module][item.name]=new WebAssembly.Global({value:'i32',mutable:true},0);",
        " else imports[item.module][item.name]=()=>0;",
        "}",
        "const instance=new WebAssembly.Instance(compiled,imports);",
        "instance.exports.__wasm_call_ctors?.();",
        "if(instance.exports.gcc_wasm_module_initializer_import()!==42)",
        " throw new Error('cross-module initializer import mismatch');"
    }, "")
    run.run_program("execute GCC WebAssembly module initializer import smoke", node,
        {"-e", module_initializer_script, module_initializer_module}, {target_os = target_os})

    local abi_source = write_basic_abi_source(root)
    local abi_c_wat = path.join(root, "basic_c_abi_c.wat")
    run.run_program("compile GCC WebAssembly Basic C ABI C WAT probe", compiler, {
        "-std=gnu2x",
        "-O0",
        "-ffreestanding",
        "-fno-builtin",
        "-S", abi_source,
        "-o", abi_c_wat
    }, {target_os = target_os, envs = cxx_envs})
    verify_basic_abi_wat(abi_c_wat)
    local abi_cxx_wat = path.join(root, "basic_c_abi_cxx.wat")
    run.run_program("compile GCC WebAssembly Basic C ABI C++ WAT probe", cxx_compiler, {
        "-x", "c++",
        "-std=c++26",
        "-O0",
        "-ffreestanding",
        "-fno-builtin",
        "-fno-exceptions",
        "-fno-rtti",
        "-nostdinc++",
        "-S", abi_source,
        "-o", abi_cxx_wat
    }, {target_os = target_os, envs = cxx_envs})
    verify_basic_abi_wat(abi_cxx_wat)

    local c_callee, cxx_caller, cxx_callee, c_caller = write_cross_language_abi_sources(root)
    local int128_c_callee, int128_cxx_caller, int128_cxx_callee, int128_c_caller =
        write_int128_abi_sources(root)
    local int128_runtime = write_int128_runtime_source(root)
    local libcall_gc_source = write_libcall_gc_source(root)
    local libstdcxx_source = write_libstdcxx_source(root)
    local c_abi_flags = {
        "-std=gnu2x",
        "-O2",
        "-ffreestanding",
        "-fno-builtin",
        "-c"
    }
    local function compile_abi_object(label, driver, flags, source_file, object_file)
        local args = table.clone(flags)
        table.insert(args, source_file)
        table.insert(args, "-o")
        table.insert(args, object_file)
        run.run_program(label, driver, args, {target_os = target_os, envs = cxx_envs})
    end
    local c_callee_object = path.join(root, "basic_abi_c_callee.o")
    local cxx_caller_object = path.join(root, "basic_abi_cxx_caller.o")
    local cxx_callee_object = path.join(root, "basic_abi_cxx_callee.o")
    local c_caller_object = path.join(root, "basic_abi_c_caller.o")
    compile_abi_object("compile GCC WebAssembly C ABI callee", compiler,
        c_abi_flags, c_callee, c_callee_object)
    compile_abi_object("compile GCC WebAssembly C++ ABI caller", cxx_compiler,
        cxx_flags, cxx_caller, cxx_caller_object)
    compile_abi_object("compile GCC WebAssembly C++ ABI callee", cxx_compiler,
        cxx_flags, cxx_callee, cxx_callee_object)
    compile_abi_object("compile GCC WebAssembly C ABI caller", compiler,
        c_abi_flags, c_caller, c_caller_object)
    local int128_c_callee_wat = path.join(root, "int128_abi_c_callee.wat")
    run.run_program("compile GCC WebAssembly C __int128 ABI WAT probe", compiler, {
        "-std=gnu2x",
        "-O0",
        "-ffreestanding",
        "-fno-builtin",
        "-S", int128_c_callee,
        "-o", int128_c_callee_wat
    }, {target_os = target_os, envs = cxx_envs})
    verify_int128_abi_wat(int128_c_callee_wat, "gcc_wasm_c_int128_identity")
    local int128_cxx_callee_wat = path.join(root, "int128_abi_cxx_callee.wat")
    run.run_program("compile GCC WebAssembly C++ __int128 ABI WAT probe", cxx_compiler, {
        "-std=c++26",
        "-O0",
        "-ffreestanding",
        "-fno-builtin",
        "-fno-exceptions",
        "-fno-rtti",
        "-nostdinc++",
        "-S", int128_cxx_callee,
        "-o", int128_cxx_callee_wat
    }, {target_os = target_os, envs = cxx_envs})
    verify_int128_abi_wat(int128_cxx_callee_wat, "gcc_wasm_cpp_int128_identity")
    local int128_cxx_caller_wat = path.join(root, "int128_abi_cxx_caller.wat")
    run.run_program("compile GCC WebAssembly C++ indirect __int128 ABI WAT probe", cxx_compiler, {
        "-std=c++26",
        "-O2",
        "-ffreestanding",
        "-fno-builtin",
        "-fno-exceptions",
        "-fno-rtti",
        "-fno-threadsafe-statics",
        "-fno-use-cxa-atexit",
        "-nostdinc++",
        "-S", int128_cxx_caller,
        "-o", int128_cxx_caller_wat
    }, {target_os = target_os, envs = cxx_envs})
    if not (io.readfile(int128_cxx_caller_wat) or ""):find("call_indirect", 1, true) then
        errors.fail("GCC WebAssembly C++ __int128 ABI probe did not exercise an indirect call")
    end
    local int128_c_callee_object = path.join(root, "int128_abi_c_callee.o")
    local int128_cxx_caller_object = path.join(root, "int128_abi_cxx_caller.o")
    local int128_cxx_callee_object = path.join(root, "int128_abi_cxx_callee.o")
    local int128_c_caller_object = path.join(root, "int128_abi_c_caller.o")
    compile_abi_object("compile GCC WebAssembly C __int128 ABI callee", compiler,
        c_abi_flags, int128_c_callee, int128_c_callee_object)
    compile_abi_object("compile GCC WebAssembly C++ __int128 ABI caller", cxx_compiler,
        cxx_flags, int128_cxx_caller, int128_cxx_caller_object)
    compile_abi_object("compile GCC WebAssembly C++ __int128 ABI callee", cxx_compiler,
        cxx_flags, int128_cxx_callee, int128_cxx_callee_object)
    compile_abi_object("compile GCC WebAssembly C __int128 ABI caller", compiler,
        c_abi_flags, int128_c_caller, int128_c_caller_object)
    local int128_runtime_wat = path.join(root, "int128_runtime.wat")
    run.run_program("compile GCC WebAssembly C++ __int128 runtime WAT probe", cxx_compiler, {
        "-std=c++26",
        "-O0",
        "-ffreestanding",
        "-fno-builtin",
        "-fno-exceptions",
        "-fno-rtti",
        "-nostdinc++",
        "-S", int128_runtime,
        "-o", int128_runtime_wat
    }, {target_os = target_os, envs = cxx_envs})
    local int128_runtime_wat_content = io.readfile(int128_runtime_wat) or ""
    for _, symbol in ipairs({"__gnu_multi3", "__gnu_udivti3", "__gnu_umodti3", "__gnu_divti3", "__gnu_modti3"}) do
        if not int128_runtime_wat_content:find(symbol, 1, true) then
            errors.fail("GCC WebAssembly __int128 runtime probe did not emit expected libcall: %s", symbol)
        end
    end
    for _, symbol in ipairs({"__multi3", "__udivti3", "__umodti3", "__divti3", "__modti3"}) do
        if int128_runtime_wat_content:find(symbol, 1, true) then
            errors.fail("GCC WebAssembly __int128 runtime probe leaked canonical Emscripten/Rust libcall name: %s", symbol)
        end
    end
    for _, function_name in ipairs({
        "gcc_wasm_int128_low32",
        "gcc_wasm_int128_low16",
        "gcc_wasm_int128_low8",
        "gcc_wasm_int128_signed_low8"
    }) do
        verify_int128_low_truncation_wat(int128_runtime_wat_content, function_name)
    end
    local libcall_gc_wat = path.join(root, "libcall_gc.wat")
    run.run_program("compile GCC WebAssembly GC-rooted libcall WAT probe", cxx_compiler, {
        "-std=c++26",
        "-O0",
        "-ffreestanding",
        "-fno-builtin",
        "-fno-exceptions",
        "-fno-rtti",
        "-nostdinc++",
        "-ftemplate-depth=128",
        "--param=ggc-min-expand=0",
        "--param=ggc-min-heapsize=0",
        "-S", libcall_gc_source,
        "-o", libcall_gc_wat
    }, {target_os = target_os, envs = cxx_envs})
    if not (io.readfile(libcall_gc_wat) or ""):find("__gnu_udivti3", 1, true) then
        errors.fail("GCC WebAssembly GC-rooted libcall probe did not emit __gnu_udivti3")
    end
    local int128_runtime_object = path.join(root, "int128_runtime.o")
    local int128_runtime_flags = table.clone(cxx_flags)
    int128_runtime_flags[2] = "-O0"
    compile_abi_object("compile GCC WebAssembly C++ __int128 runtime object", cxx_compiler,
        int128_runtime_flags, int128_runtime, int128_runtime_object)
    local cross_abi_module = path.join(root, "basic_c_abi_cross_language.wasm")
    run.run_program("link GCC WebAssembly C and C++ ABI smoke module", linker, {
        "--no-entry",
        "--gc-sections",
        "--export=gcc_wasm_cpp_calls_c",
        "--export=gcc_wasm_c_calls_cpp",
        "--export=gcc_wasm_cpp_int128_calls_c_low",
        "--export=gcc_wasm_cpp_int128_calls_c_high",
        "--export=gcc_wasm_c_int128_calls_cpp_low",
        "--export=gcc_wasm_c_int128_calls_cpp_high",
        c_callee_object,
        cxx_caller_object,
        cxx_callee_object,
        c_caller_object,
        int128_c_callee_object,
        int128_cxx_caller_object,
        int128_cxx_callee_object,
        int128_c_caller_object,
        "-o", cross_abi_module
    }, {target_os = target_os})
    local cross_abi_script = table.concat({
        "const fs=require('fs');",
        "const bytes=fs.readFileSync(process.argv[1]);",
        "const compiled=new WebAssembly.Module(bytes);",
        "const imports={};",
        "for(const item of WebAssembly.Module.imports(compiled)){",
        " imports[item.module]??={};",
        " if(item.kind==='memory') imports[item.module][item.name]=new WebAssembly.Memory({initial:2});",
        " else if(item.kind==='table') imports[item.module][item.name]=new WebAssembly.Table({initial:1,element:'anyfunc'});",
        " else if(item.kind==='global') imports[item.module][item.name]=new WebAssembly.Global({value:'i32',mutable:true},0);",
        " else imports[item.module][item.name]=()=>0;",
        "}",
        "const instance=new WebAssembly.Instance(compiled,imports);",
        "if(instance.exports.gcc_wasm_cpp_calls_c()!==122) throw new Error('C++ to C Basic C ABI mismatch');",
        "if(instance.exports.gcc_wasm_c_calls_cpp()!==126) throw new Error('C to C++ Basic C ABI mismatch');",
        "const low=0x0123456789abcdefn;",
        "const high=0xfedcba9876543210n;",
        "const signedHigh=BigInt.asIntN(64,high);",
        "const expectI64=(name,actual,expected)=>{",
        " if(BigInt.asUintN(64,actual)!==expected) throw new Error(name+' __int128 ABI mismatch');",
        "};",
        "expectI64('C++ to C low',instance.exports.gcc_wasm_cpp_int128_calls_c_low(low,signedHigh),low);",
        "expectI64('C++ to C high',instance.exports.gcc_wasm_cpp_int128_calls_c_high(low,signedHigh),high);",
        "expectI64('C to C++ low',instance.exports.gcc_wasm_c_int128_calls_cpp_low(low,signedHigh),low);",
        "expectI64('C to C++ high',instance.exports.gcc_wasm_c_int128_calls_cpp_high(low,signedHigh),high);"
    }, "")
    run.run_program("execute GCC WebAssembly C and C++ ABI smoke module", node,
        {"-e", cross_abi_script, cross_abi_module}, {target_os = target_os})

    local int128_runtime_module = path.join(root, "int128_runtime.wasm")
    run.run_program("link GCC WebAssembly C++ __int128 runtime module", linker, {
        "--no-entry",
        "--gc-sections",
        "--export=gcc_wasm_int128_multiply",
        "--export=gcc_wasm_int128_unsigned_divide",
        "--export=gcc_wasm_int128_unsigned_modulo",
        "--export=gcc_wasm_int128_signed_divide",
        "--export=gcc_wasm_int128_signed_modulo",
        "--export=gcc_wasm_int128_low32",
        "--export=gcc_wasm_int128_low16",
        "--export=gcc_wasm_int128_low8",
        "--export=gcc_wasm_int128_signed_low8",
        int128_runtime_object,
        libgcc_path(target_os),
        "-o", int128_runtime_module
    }, {target_os = target_os})
    local int128_runtime_script = table.concat({
        "const fs=require('fs');",
        "const bytes=fs.readFileSync(process.argv[1]);",
        "const compiled=new WebAssembly.Module(bytes);",
        "const imports={};",
        "for(const item of WebAssembly.Module.imports(compiled)){",
        " imports[item.module]??={};",
        " if(item.kind==='memory') imports[item.module][item.name]=new WebAssembly.Memory({initial:2});",
        " else if(item.kind==='table') imports[item.module][item.name]=new WebAssembly.Table({initial:1,element:'anyfunc'});",
        " else if(item.kind==='global') imports[item.module][item.name]=new WebAssembly.Global({value:'i32',mutable:true},0);",
        " else imports[item.module][item.name]=()=>0;",
        "}",
        "const instance=new WebAssembly.Instance(compiled,imports);",
        "const split=value=>{",
        " const bits=BigInt.asUintN(128,value);",
        " return [BigInt.asIntN(64,bits),BigInt.asIntN(64,bits>>64n)];",
        "};",
        "const join=parts=>{",
        " if(!Array.isArray(parts)||parts.length!==2) throw new Error('__int128 result is not a two-value array');",
        " return BigInt.asUintN(128,BigInt.asUintN(64,parts[0])|(BigInt.asUintN(64,parts[1])<<64n));",
        "};",
        "const call=(name,left,right)=>join(instance.exports[name](...split(left),...split(right)));",
        "const callLow=(name,value)=>instance.exports[name](...split(value));",
        "const expect=(name,actual,expected)=>{",
        " if(actual!==expected) throw new Error(name+' mismatch: expected '+expected.toString(16)+', got '+actual.toString(16));",
        "};",
        "const expectI32=(name,actual,expected)=>{",
        " if(actual!==expected) throw new Error(name+' mismatch: expected '+expected.toString(16)+', got '+actual.toString(16));",
        "};",
        "const unsignedLeft=0xfedcba98765432100123456789abcdefn;",
        "const unsignedRight=0x123456789abcdefn;",
        "expect('multiply',call('gcc_wasm_int128_multiply',unsignedLeft,unsignedRight),BigInt.asUintN(128,unsignedLeft*unsignedRight));",
        "expect('unsigned divide',call('gcc_wasm_int128_unsigned_divide',unsignedLeft,unsignedRight),unsignedLeft/unsignedRight);",
        "expect('unsigned modulo',call('gcc_wasm_int128_unsigned_modulo',unsignedLeft,unsignedRight),unsignedLeft%unsignedRight);",
        "const signedLeft=-0x123456789abcdef0011223344556677n;",
        "const signedRight=0x123456789abcn;",
        "expect('signed divide',BigInt.asIntN(128,call('gcc_wasm_int128_signed_divide',signedLeft,signedRight)),signedLeft/signedRight);",
        "expect('signed modulo',BigInt.asIntN(128,call('gcc_wasm_int128_signed_modulo',signedLeft,signedRight)),signedLeft%signedRight);",
        "const truncationValue=0xfedcba98765432100123456789abcdefn;",
        "expectI32('low32',callLow('gcc_wasm_int128_low32',truncationValue)>>>0,0x89abcdef);",
        "expectI32('low16',callLow('gcc_wasm_int128_low16',truncationValue),0xcdef);",
        "expectI32('low8',callLow('gcc_wasm_int128_low8',truncationValue),0xef);",
        "expectI32('signed low8',callLow('gcc_wasm_int128_signed_low8',truncationValue),-17);"
    }, "")
    run.run_program("execute GCC WebAssembly C++ __int128 runtime module", node,
        {"-e", int128_runtime_script, int128_runtime_module}, {target_os = target_os})

    -- The former no-libc archive probe is kept as migration documentation but
    -- is not part of the hosted Emscripten profile. Its target-owned allocator
    -- and no-op synchronization types must never enter a production link.
    if false then
    local libstdcxx_object = path.join(root, "freestanding_libstdcxx.o")
    run.run_program("compile GCC WebAssembly freestanding libstdc++ smoke object", cxx_compiler, {
        "-std=c++26",
        "-O2",
        "-ffreestanding",
        "-fno-builtin",
        "-fno-exceptions",
        "-fno-rtti",
        "-fno-threadsafe-statics",
        "-fno-use-cxa-atexit",
        "-c", libstdcxx_source,
        "-o", libstdcxx_object
    }, {target_os = target_os, envs = cxx_envs})
    local libstdcxx_module = path.join(root, "freestanding_libstdcxx.wasm")
    run.run_program("link GCC WebAssembly freestanding libstdc++ smoke module", linker, {
        "--no-entry",
        "--gc-sections",
        "--export=gcc_wasm_libstdcxx_hash",
        "--export=gcc_wasm_libstdcxx_ordered_map",
        "--export=gcc_wasm_libstdcxx_string",
        "--export=gcc_wasm_libstdcxx_integral_to_string",
        "--export=gcc_wasm_libstdcxx_integral_abs",
        "--export=gcc_wasm_libstdcxx_vector",
        "--export=gcc_wasm_libstdcxx_make_unique",
        "--export=gcc_wasm_libstdcxx_shared_ptr",
        "--export=gcc_wasm_libstdcxx_chrono_duration",
        "--export=gcc_wasm_libstdcxx_chrono_calendar_time",
        "--export=gcc_wasm_libstdcxx_ranges_to_vector",
        "--export=gcc_wasm_libstdcxx_cstring_memory",
        "--export=gcc_wasm_libstdcxx_format",
        "--export=gcc_wasm_libstdcxx_single_thread_sync",
        "--export=gcc_wasm_libstdcxx_callable_hash_map",
        libstdcxx_object,
        libstdcxx_path(target_os),
        libgcc_path(target_os),
        "-o", libstdcxx_module
    }, {target_os = target_os})
    local libstdcxx_script = table.concat({
        "const fs=require('fs');",
        "const bytes=fs.readFileSync(process.argv[1]);",
        "const compiled=new WebAssembly.Module(bytes);",
        "const imports={};",
        "for(const item of WebAssembly.Module.imports(compiled)){",
        " imports[item.module]??={};",
        " if(item.kind==='memory') imports[item.module][item.name]=new WebAssembly.Memory({initial:2});",
        " else if(item.kind==='table') imports[item.module][item.name]=new WebAssembly.Table({initial:1,element:'anyfunc'});",
        " else if(item.kind==='global') imports[item.module][item.name]=new WebAssembly.Global({value:'i32',mutable:true},0);",
        " else imports[item.module][item.name]=()=>0;",
        "}",
        "const instance=new WebAssembly.Instance(compiled,imports);",
        "let expected=2166136261>>>0;",
        "for(const byte of [1,2,3,4]) expected=Math.imul(expected^byte,16777619)>>>0;",
        "const actual=instance.exports.gcc_wasm_libstdcxx_hash()>>>0;",
        "if(actual!==expected) throw new Error('freestanding libstdc++ archive hash mismatch');",
        "const orderedMap=instance.exports.gcc_wasm_libstdcxx_ordered_map()>>>0;",
        "if(orderedMap!==400) throw new Error('extended freestanding ordered map mismatch: '+orderedMap);",
        "const stringCore=instance.exports.gcc_wasm_libstdcxx_string()>>>0;",
        "if(stringCore!==34013) throw new Error('extended freestanding string mismatch: '+stringCore);",
        "const integralToString=instance.exports.gcc_wasm_libstdcxx_integral_to_string()>>>0;",
        "if(integralToString!==1) throw new Error('freestanding integral to_string mismatch: '+integralToString);",
        "const integralAbs=instance.exports.gcc_wasm_libstdcxx_integral_abs()>>>0;",
        "if(integralAbs!==31) throw new Error('freestanding integral abs mismatch: '+integralAbs);",
        "const vectorCore=instance.exports.gcc_wasm_libstdcxx_vector()>>>0;",
        "if(vectorCore!==498508) throw new Error('extended freestanding vector mismatch: '+vectorCore);",
        "const makeUnique=instance.exports.gcc_wasm_libstdcxx_make_unique()>>>0;",
        "if(makeUnique!==37071) throw new Error('freestanding make_unique mismatch: '+makeUnique);",
        "const sharedPtr=instance.exports.gcc_wasm_libstdcxx_shared_ptr()>>>0;",
        "if(sharedPtr!==4201) throw new Error('freestanding shared_ptr mismatch: '+sharedPtr);",
        "const chronoDuration=instance.exports.gcc_wasm_libstdcxx_chrono_duration()>>>0;",
        "if(chronoDuration!==187) throw new Error('freestanding chrono duration mismatch: '+chronoDuration);",
        "let expectedChronoCalendarTime=17>>>0;",
        "for(const value of [2026,7,15,13,47,29,321]) expectedChronoCalendarTime=(Math.imul(expectedChronoCalendarTime,31)+value)>>>0;",
        "const chronoCalendarTime=instance.exports.gcc_wasm_libstdcxx_chrono_calendar_time()>>>0;",
        "if(chronoCalendarTime!==expectedChronoCalendarTime) throw new Error('freestanding chrono calendar/time mismatch: '+chronoCalendarTime);",
        "let expectedRangesToVector=4>>>0;",
        "for(const value of [3,7,11,15]) expectedRangesToVector=(Math.imul(expectedRangesToVector,31)+value)>>>0;",
        "const rangesToVector=instance.exports.gcc_wasm_libstdcxx_ranges_to_vector()>>>0;",
        "if(rangesToVector!==expectedRangesToVector) throw new Error('freestanding ranges-to-vector mismatch: '+rangesToVector);",
        "const cstringMemory=instance.exports.gcc_wasm_libstdcxx_cstring_memory()>>>0;",
        "if(cstringMemory!==903) throw new Error('freestanding cstring memory mismatch: '+cstringMemory);",
        "const formatCore=instance.exports.gcc_wasm_libstdcxx_format()>>>0;",
        "if(formatCore!==1) throw new Error('extended freestanding format mismatch: '+formatCore);",
        "const singleThreadSync=instance.exports.gcc_wasm_libstdcxx_single_thread_sync()>>>0;",
        "if(singleThreadSync!==1) throw new Error('single-thread synchronization mismatch: '+singleThreadSync);",
        "const callableHashMap=instance.exports.gcc_wasm_libstdcxx_callable_hash_map()>>>0;",
        "if(callableHashMap!==1202) throw new Error('callable hash map mismatch: '+callableHashMap);"
    }, "")
    run.run_program("execute GCC WebAssembly freestanding libstdc++ smoke module", node,
        {"-e", libstdcxx_script, libstdcxx_module}, {target_os = target_os})
    end
    io.writefile(path.join(root, "backend.stamp"), smoke_signature(target_os))
    print("GCC WebAssembly compiler, archive tools, module initializer imports, Basic C ABI, cross-language ABI, and __int128 libgcc backend smoke passed: " .. module)
    return object, module
end

local function write_atomic_compare_exchange_probe_source(root)
    local source = path.join(root, "atomic_compare_exchange.cpp")
    io.writefile(source, [=[extern "C" __attribute__((visibility("default"), noinline))
bool gcc_wasm_atomic_compare_exchange(unsigned int* value, unsigned int* expected, unsigned int desired)
{
	return __atomic_compare_exchange_n(value, expected, desired, false,
		__ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}
]=])
    return source
end

local function write_emscripten_hosted_smoke_sources(root)
    local cxx_source = path.join(root, "emscripten_hosted_runtime.cpp")
    local std_module_source = path.join(root, "emscripten_std_module_abi.cpp")
    local rust_source = path.join(root, "emscripten_rust_atomic.rs")
    io.writefile(cxx_source, [=[#include <atomic>
#include <condition_variable>
#include <concepts>
#include <coroutine>
#include <cstdint>
#include <latch>
#include <memory>
#include <meta>
#include <mutex>
#include <thread>
#include <type_traits>
#include <utility>

#ifndef _GNU_SOURCE
#error "GCC Emscripten C++ driver must expose the GNU libc surface"
#endif

#ifndef _REENTRANT
#error "GCC Emscripten -pthread must define _REENTRANT"
#endif

#ifndef __EMSCRIPTEN_PTHREADS__
#error "GCC Emscripten -pthread must select the Emscripten pthread ABI"
#endif

#ifndef _GLIBCXX_HAS_GTHREADS
#error "hosted Emscripten libstdc++ must enable POSIX gthreads"
#endif

#ifndef _GLIBCXX_HAVE_TLS
#error "hosted Emscripten libstdc++ must enable thread-local storage"
#endif

#ifndef _GLIBCXX_ATOMIC_WORD_BUILTINS
#error "hosted Emscripten libstdc++ must use atomic word builtins"
#endif

#ifndef _GLIBCXX_HAVE_ATOMIC_LOCK_POLICY
#error "hosted Emscripten libstdc++ must use atomic shared_ptr reference counting"
#endif

template <typename type>
concept incrementable = requires(type value)
{
	{ value + 1 } -> std::same_as<type>;
};

struct reflected_payload
{
	std::uint32_t first;
	std::uint32_t second;
};

static_assert(incrementable<std::uint32_t>);
static_assert(std::meta::nonstatic_data_members_of(
	^^reflected_payload, std::meta::access_context::current()).size() == 2);

static int contract_checks = 0;

static bool contract_precondition(int value) noexcept
{
	++contract_checks;
	return value == 41;
}

static int contract_increment(int value) noexcept
	pre(contract_precondition(value))
	post(result: result == 42)
{
	return value + 1;
}

class smoke_task
{
public:
	struct promise_type;
	using handle_type = std::coroutine_handle<promise_type>;

	struct promise_type
	{
		int value = 0;

		smoke_task get_return_object() noexcept
		{
			return smoke_task(handle_type::from_promise(*this));
		}

		std::suspend_always initial_suspend() const noexcept
		{
			return {};
		}

		std::suspend_always final_suspend() const noexcept
		{
			return {};
		}

		void return_value(int result) noexcept
		{
			this->value = result;
		}

		void unhandled_exception() const noexcept
		{
			__builtin_trap();
		}
	};

	explicit smoke_task(handle_type coroutine) noexcept
		: coroutine_(coroutine)
	{
	}

	smoke_task(smoke_task&& other) noexcept
		: coroutine_(std::exchange(other.coroutine_, {}))
	{
	}

	~smoke_task()
	{
		if (this->coroutine_)
			this->coroutine_.destroy();
	}

	int run()
	{
		this->coroutine_.resume();
		return this->coroutine_.promise().value;
	}

private:
	handle_type coroutine_;
};

static smoke_task make_smoke_task()
{
	co_return 42;
}

extern "C" std::uint32_t rust_atomic_add(std::uint32_t value);
extern "C" std::uint32_t rust_atomic_load();
extern "C" void rust_atomic_reset();
extern "C" std::uint32_t rust_round_trip(std::uint32_t value);
extern "C" std::uint64_t rust_u128_divide_low(std::uint64_t low, std::uint64_t high,
	std::uint64_t divisor);
extern "C" int std_module_empty_abi_smoke();

extern "C" std::uint32_t gcc_wasm_cpp_increment(std::uint32_t value)
{
	return value + 2;
}

static std::uint64_t gcc_wasm_cpp_u128_divide_low(std::uint64_t low,
	std::uint64_t high, std::uint64_t divisor)
{
	auto value = (static_cast<unsigned __int128>(high) << 64) | low;
	return static_cast<std::uint64_t>(value / divisor);
}

thread_local int tls_value = 5;

]=] .. table.concat({
        'extern "C"',
        "{",
        '\tchar gcc_wasm_smoke_used_data[] = "' .. WASM_SMOKE_USED_DATA_MARKER .. '";',
        '\tchar gcc_wasm_smoke_unused_data[] = "' .. WASM_SMOKE_UNUSED_DATA_MARKER .. '";',
        "}",
        "",
        "__attribute__((noinline)) std::uint32_t gcc_wasm_name_section_marker(std::uint32_t value)",
        "{",
        "\treturn value + static_cast<std::uint32_t>(gcc_wasm_smoke_used_data[0] == 'G');",
        "}",
        "",
        'extern "C" __attribute__((noinline)) std::uint32_t gcc_wasm_smoke_unused_function(std::uint32_t value)',
        "{",
        "\treturn value * 7u + static_cast<std::uint32_t>(gcc_wasm_smoke_unused_data[0]);",
        "}",
        ""
    }, "\n") .. [=[
int main()
{
	if (std_module_empty_abi_smoke() != 42)
		return 20;

	if (contract_increment(41) != 42 || contract_checks != 1)
		return 11;

	auto coroutine = make_smoke_task();
	if (coroutine.run() != 42)
		return 12;

	std::mutex mutex;
	std::condition_variable condition;
	bool ready = false;
	int worker_tls = 0;
	std::thread tls_worker([&]
	{
		tls_value = 37;
		{
			std::lock_guard lock(mutex);
			worker_tls = tls_value;
			ready = true;
		}
		condition.notify_one();
	});
	{
		std::unique_lock lock(mutex);
		condition.wait(lock, [&] { return ready; });
	}
	tls_worker.join();
	if (worker_tls != 37 || tls_value != 5)
		return 13;

	std::atomic<int> phase = 0;
	std::thread notifier([&]
	{
		phase.store(42, std::memory_order_release);
		phase.notify_one();
	});
	phase.wait(0, std::memory_order_acquire);
	notifier.join();
	if (phase.load(std::memory_order_relaxed) != 42)
		return 14;

	rust_atomic_reset();
	std::atomic<int> cpp_atomic = 0;
	std::latch completion(2);
	std::thread first([&]
	{
		cpp_atomic.fetch_add(19, std::memory_order_relaxed);
		rust_atomic_add(19);
		completion.count_down();
	});
	std::thread second([&]
	{
		cpp_atomic.fetch_add(23, std::memory_order_relaxed);
		rust_atomic_add(23);
		completion.count_down();
	});
	completion.wait();
	first.join();
	second.join();
	if (cpp_atomic.load(std::memory_order_relaxed) != 42 || rust_atomic_load() != 42)
		return 15;
	if (rust_round_trip(40) != 42)
		return 16;
	if (rust_u128_divide_low(0, 1, 2) != (std::uint64_t{1} << 63)
		|| gcc_wasm_cpp_u128_divide_low(0, 1, 2) != (std::uint64_t{1} << 63))
		return 19;

	auto shared_value = std::make_shared<std::atomic<int>>(0);
	std::thread shared_first([shared_value]
	{
		shared_value->fetch_add(19, std::memory_order_relaxed);
	});
	std::thread shared_second([shared_value]
	{
		shared_value->fetch_add(23, std::memory_order_relaxed);
	});
	shared_first.join();
	shared_second.join();
	if (shared_value.use_count() != 1
		|| shared_value->load(std::memory_order_relaxed) != 42)
		return 17;

	std::atomic<std::uint32_t> compare_value = 19;
	std::uint32_t expected = 19;
	if (!compare_value.compare_exchange_strong(expected, 42,
			std::memory_order_seq_cst, std::memory_order_seq_cst)
		|| compare_value.load(std::memory_order_relaxed) != 42)
		return 18;

	if (gcc_wasm_name_section_marker(41) != 42)
		return 21;

	return 0;
}
]=])
    io.writefile(std_module_source, [=[import std;

extern "C" int std_module_empty_abi_smoke()
{
	const std::string value{"wasm"};
	const auto order = value.size() <=> std::size_t{4};
	return value == "wasm" && order == std::strong_ordering::equal ? 42 : 0;
}
]=])
    io.writefile(rust_source, [=[#![no_std]

use core::panic::PanicInfo;
use core::sync::atomic::{AtomicU32, Ordering};

#[panic_handler]
fn panic(_info: &PanicInfo) -> !
{
	loop {}
}

static VALUE: AtomicU32 = AtomicU32::new(0);

unsafe extern "C"
{
	fn gcc_wasm_cpp_increment(value: u32) -> u32;
}

#[unsafe(no_mangle)]
pub extern "C" fn rust_atomic_add(value: u32) -> u32
{
	VALUE.fetch_add(value, Ordering::SeqCst) + value
}

#[unsafe(no_mangle)]
pub extern "C" fn rust_atomic_load() -> u32
{
	VALUE.load(Ordering::SeqCst)
}

#[unsafe(no_mangle)]
pub extern "C" fn rust_atomic_reset()
{
	VALUE.store(0, Ordering::SeqCst);
}

#[unsafe(no_mangle)]
pub extern "C" fn rust_round_trip(value: u32) -> u32
{
	unsafe { gcc_wasm_cpp_increment(value) }
}

#[unsafe(no_mangle)]
pub extern "C" fn rust_u128_divide_low(low: u64, high: u64, divisor: u64) -> u64
{
	let value = ((high as u128) << 64) | low as u128;
	(value / divisor as u128) as u64
}
]=])
    return cxx_source, std_module_source, rust_source
end

local function write_emscripten_dwarf_canary_source(root)
    local source = path.join(root, "emscripten_dwarf_canary.cpp")
    io.writefile(source, table.concat({
        "static const char canary_data[] = \"GCC-WASM-DWARF-CANARY\";",
        "",
        "extern \"C\" unsigned int gcc_wasm_dwarf_canary(unsigned int value)",
        "{",
        "\tconst volatile char* data = canary_data;",
        "\treturn value + static_cast<unsigned int>(data[0]);",
        "}",
        ""
    }, "\n"))
    return source
end

local function write_emscripten_eh_trap_smoke_source(root)
    local source = path.join(root, "emscripten_eh_trap.cpp")
    io.writefile(source, table.concat({
        "#include <cstdio>",
        "#include <stdexcept>",
        "",
        "int main()",
        "{",
        "\tstd::puts(\"eh-smoke-before-throw\");",
        "\tstd::fflush(stdout);",
        "\ttry",
        "\t{",
        "\t\tthrow std::runtime_error(\"eh-smoke-payload\");",
        "\t}",
        "\tcatch (const std::exception&)",
        "\t{",
        "\t\tstd::puts(\"eh-smoke-caught\");",
        "\t\treturn 0;",
        "\t}",
        "\treturn 1;",
        "}",
        ""
    }, "\n"))
    return source
end

local function linked_artifact_bytes(file)
    -- io.readfile raises on a missing file; an empty string lets the marker
    -- assertions below report the real, catalogued failure instead
    if not os.isfile(file) then
        return ""
    end
    return io.readfile(file, {encoding = "binary"}) or ""
end

-- Size baseline for the hosted link smoke artifacts, kept host-local in the
-- state layer beside the smoke stamps: artifact sizes depend on the pinned
-- emsdk, the host, and the toolchain identity, so a repository-level baseline
-- would only produce cross-machine noise (promoting it is an owner decision
-- that additionally needs a fleet-wide size survey; the emcc version itself
-- is already pinned inside the signature since v43). Line 1 records the
-- sha256 of the full smoke signature: a signature change rebases silently,
-- while a >10% per-artifact drift under an unchanged signature warns and
-- rebases, so real size regressions surface without turning reruns into hard
-- failures.
local function record_smoke_sizes(root, target_os, artifacts)
    local signature_digest = hash.sha256(bytes(smoke_signature(target_os)))
    local lines = {"signature-sha256=" .. signature_digest}
    local summary = {}
    local baseline_file = path.join(root, "size_baseline.txt")
    local previous = os.isfile(baseline_file) and (io.readfile(baseline_file) or "") or ""
    local previous_matches = previous:match("signature%-sha256=(%x+)") == signature_digest
    for _, artifact in ipairs(artifacts) do
        local name = path.filename(artifact)
        local size = os.filesize(artifact) or 0
        table.insert(lines, name .. "=" .. size)
        table.insert(summary, name .. "=" .. size)
        if previous_matches then
            local recorded = tonumber(previous:match("\n" .. base.escape_pattern(name) .. "=(%d+)"))
            if recorded and recorded > 0 and math.abs(size - recorded) * 10 > recorded then
                -- "one tenth", not "10%": a literal percent sign is eaten by
                -- the xmake print/vformat layer on the way to the console
                errors.warn("wasm smoke artifact %s size drifted past the one-tenth tolerance under an unchanged smoke signature (baseline %d bytes, now %d bytes); baseline refreshed -- investigate if no smoke-source change explains it",
                    name, recorded, size)
            end
        end
    end
    io.writefile(baseline_file, table.concat(lines, "\n") .. "\n")
    return table.concat(summary, ", ")
end

function run_emscripten_link_smoke(target_os)
    target_os = target_os or "emscripten"
    local emcc = emcc_path()
    local sysroot = emscripten_sysroot()
    if not emcc or not sysroot then
        errors.fail("emcc and its initialized sysroot are required for the hosted GCC WebAssembly runtime smoke")
    end
    if not backend_only_smoke_current(target_os) then
        run_backend_smoke(target_os)
    end
    local root = smoke_dir(target_os)
    local cxx_source, std_module_source, rust_source = write_emscripten_hosted_smoke_sources(root)
    local atomic_compare_exchange_source = write_atomic_compare_exchange_probe_source(root)
    local atomic_compare_exchange_wat = path.join(root, "atomic_compare_exchange.wat")
    local cxx_object = path.join(root, "emscripten_hosted_runtime.o")
    local std_module_mapper = path.join(root, "emscripten_std_module.mapper")
    local std_module_bmi = path.join(root, "emscripten_std.gcm")
    local std_module_interface_object = path.join(root, "emscripten_std_module.o")
    local std_module_consumer_object = path.join(root, "emscripten_std_module_abi.o")
    local rust_object = path.join(root, "emscripten_rust_atomic.o")
    local output = path.join(root, "emscripten_hosted_runtime.js")
    local cxx_compiler = compiler_path(target_os, "c++")
    local cxx_envs = envs.shell_envs(path.join(settings.gcc_prefix(target_os), "bin"))
    local std_module_sources = os.files(path.join(settings.gcc_prefix(target_os),
        settings.managed_target(target_os), "include", "c++", "*", "bits", "std.cc"))
    if #std_module_sources ~= 1 then
        errors.fail("expected exactly one installed libstdc++ std module source, found %d", #std_module_sources)
    end
    base.writefile_bytes(std_module_mapper, table.concat({
        "$root " .. base.shpath(root),
        "std " .. path.filename(std_module_bmi),
        ""
    }, "\n"))
    local std_module_flags = {
        "-std=c++26",
        "-fmodules",
        "-fmodule-implicit-inline",
        "-fmodule-lazy",
        "-fmodule-version-ignore",
        "-pthread",
        "-fno-exceptions",
        "-fno-rtti",
        "-freflection",
        "-fcontracts",
        "-fcontract-evaluation-semantic=enforce",
        "-fmodule-mapper=" .. base.shpath(std_module_mapper)
    }
    local std_module_interface_args = {}
    table.join2(std_module_interface_args, std_module_flags)
    table.join2(std_module_interface_args, {
        "-x", "c++",
        "-c", std_module_sources[1],
        "-o", std_module_interface_object
    })
    run.run_program("compile hosted libstdc++ std module interface smoke", cxx_compiler,
        std_module_interface_args, {target_os = target_os, envs = cxx_envs, curdir = root})
    local std_module_consumer_args = {}
    table.join2(std_module_consumer_args, std_module_flags)
    table.join2(std_module_consumer_args, {
        "-O2",
        "-c", std_module_source,
        "-o", std_module_consumer_object
    })
    run.run_program("compile hosted libstdc++ std module empty-record ABI consumer", cxx_compiler,
        std_module_consumer_args, {target_os = target_os, envs = cxx_envs, curdir = root})
    run.run_program("compile GCC WebAssembly fixed-width atomic compare-exchange WAT probe", cxx_compiler, {
        "-std=c++26",
        "-O0",
        "-pthread",
        "-fno-exceptions",
        "-fno-rtti",
        "-S", atomic_compare_exchange_source,
        "-o", atomic_compare_exchange_wat
    }, {target_os = target_os, envs = cxx_envs})
    verify_atomic_compare_exchange_import_wat(atomic_compare_exchange_wat)
    run.run_program("compile hosted GCC WebAssembly language and pthread smoke", cxx_compiler, {
        "-std=c++26",
        "-O2",
        "-pthread",
        "-fno-exceptions",
        "-fno-rtti",
        "-freflection",
        "-fcontracts",
        "-fcontract-evaluation-semantic=enforce",
        "-c", cxx_source,
        "-o", cxx_object
    }, {target_os = target_os, envs = cxx_envs})

    -- DWARF canary (upstream watchdog): the GCC 17 wasm backend emits no
    -- debug output today, so -g must stay a warned byte-level no-op and
    -- production ships name-section debugging via emcc -g2 with symbols=none
    -- (toolchains.auto). The moment upstream grows real debug output these
    -- objects diverge and this assertion fires first, signalling that the
    -- wasm debug policy must be redesigned around real DWARF.
    local dwarf_canary_source = write_emscripten_dwarf_canary_source(root)
    local dwarf_canary_plain = path.join(root, "emscripten_dwarf_canary_plain.o")
    local dwarf_canary_debug = path.join(root, "emscripten_dwarf_canary_debug.o")
    run.run_program("compile GCC WebAssembly DWARF canary without -g", cxx_compiler, {
        "-std=c++26", "-O2", "-pthread", "-fno-exceptions", "-fno-rtti",
        "-c", dwarf_canary_source, "-o", dwarf_canary_plain
    }, {target_os = target_os, envs = cxx_envs})
    run.run_program("compile GCC WebAssembly DWARF canary with -g (expected warned no-op)", cxx_compiler, {
        "-std=c++26", "-O2", "-pthread", "-fno-exceptions", "-fno-rtti", "-g",
        "-c", dwarf_canary_source, "-o", dwarf_canary_debug
    }, {target_os = target_os, envs = cxx_envs})
    if linked_artifact_bytes(dwarf_canary_plain) ~= linked_artifact_bytes(dwarf_canary_debug) then
        errors.fail("GCC wasm backend DWARF canary tripped: -g changed the emitted object bytes, so the backend has grown debug output; revisit the wasm debug policy (symbols=none plus emcc -g2) before trusting this toolchain")
    end

    local rust_toolchain = import("toolchain", {rootdir = RUST_MODULES_DIR})
    local rust_runtime = import("wasm_runtime", {rootdir = RUST_MODULES_DIR})
    local rust_target = "wasm32-unknown-emscripten"
    rust_toolchain.install({rust_target})
    local runtime_rlibs = rust_runtime.ensure({})
    local rust_args = {
        "--target", rust_target,
        "--crate-type", "lib",
        "--crate-name", "gcc_wasm_rust_atomic_smoke",
        "--edition", "2024",
        "--emit", "obj=" .. rust_object,
        "-Cpanic=abort",
        "-Ccodegen-units=1",
        "-Ctarget-feature=+atomics,+bulk-memory,+mutable-globals",
        "-Zunstable-options",
        "-O",
    }
    for _, rlib in ipairs(runtime_rlibs) do
        table.insert(rust_args, "--extern")
        table.insert(rust_args, "noprelude:" .. rlib.name .. "=" .. rlib.path)
    end
    table.insert(rust_args, rust_source)
    run.run_program("compile Rust core atomic WebAssembly smoke", rust_toolchain.rustc_path(),
        rust_args, {target_os = target_os})

    local common_link_args = {
        cxx_object,
        std_module_interface_object,
        std_module_consumer_object,
        rust_object,
    }
    for _, rlib in ipairs(runtime_rlibs) do
        table.insert(common_link_args, rlib.path)
    end
    table.join2(common_link_args, {
        libstdcxx_exp_path(target_os),
        libstdcxx_path(target_os),
        libgcc_path(target_os),
        "-nostdlibxx",
        "-pthread",
        "-sPTHREAD_POOL_SIZE=4",
        "-sPROXY_TO_PTHREAD=1",
        "-sEXIT_RUNTIME=1",
        "-sIGNORE_MISSING_MAIN=0",
        "-sENVIRONMENT=node",
        -- mirrors the production toolchains.auto link: -g2 keeps the wasm
        -- name section (function-name debugging baseline) in both tiers
        "-g2"
    })
    run.run_program("link GCC and Rust objects through the Emscripten pthread runtime", emcc,
        table.join(common_link_args, {"-o", output}), {target_os = target_os})
    run.run_program("execute hosted GCC/Rust Emscripten pthread smoke", node_path(),
        {output}, {target_os = target_os, curdir = root})

    -- production-release mirror: the same inputs at -O3 -g2 must keep the
    -- full wasm-opt pipeline (a link-level -g would degrade it to "limited
    -- binaryen optimizations" and bloat the wasm with runtime-only DWARF)
    local opt_output = path.join(root, "emscripten_hosted_runtime_opt.js")
    run.run_program("link optimized GCC and Rust objects through the Emscripten pthread runtime", emcc,
        table.join(common_link_args, {"-O3", "-o", opt_output}), {target_os = target_os})
    run.run_program("execute optimized hosted GCC/Rust Emscripten pthread smoke", node_path(),
        {opt_output}, {target_os = target_os, curdir = root})

    local output_wasm = path.join(root, "emscripten_hosted_runtime.wasm")
    local opt_wasm = path.join(root, "emscripten_hosted_runtime_opt.wasm")
    local nonopt_bytes = linked_artifact_bytes(output_wasm)
    if not nonopt_bytes:find(WASM_SMOKE_NAME_SECTION_SYMBOL, 1, true) then
        errors.fail("linked wasm lost the GCC-side function name %s from its name section; emcc -g2 no longer provides the function-name debugging baseline",
            WASM_SMOKE_NAME_SECTION_SYMBOL)
    end
    for _, linked in ipairs({{output_wasm, nonopt_bytes}, {opt_wasm, linked_artifact_bytes(opt_wasm)}}) do
        if not linked[2]:find(WASM_SMOKE_USED_DATA_MARKER, 1, true) then
            errors.fail("linked wasm %s lost the reachable smoke data marker %s; the emcc link dropped live GCC data",
                path.filename(linked[1]), WASM_SMOKE_USED_DATA_MARKER)
        end
        if linked[2]:find(WASM_SMOKE_UNUSED_DATA_MARKER, 1, true) then
            errors.fail("linked wasm %s still contains the unreachable smoke data marker %s; symbol-granular dead-code GC regressed in the emcc link",
                path.filename(linked[1]), WASM_SMOKE_UNUSED_DATA_MARKER)
        end
    end
    local nonopt_size = os.filesize(output_wasm) or 0
    local opt_size = os.filesize(opt_wasm) or 0
    if opt_size <= 0 or opt_size * 10 >= nonopt_size * 9 then
        errors.fail("optimized wasm smoke artifact is not significantly smaller than the unoptimized one (%d vs %d bytes); the emcc -O3 wasm-opt pipeline did not take effect",
            opt_size, nonopt_size)
    end

    -- -fexceptions hardening (policy option B, docs/developer/wasm_exception_policy.md):
    -- on this target a throw must compile, trap at runtime (the libgcc
    -- unwinder is a __builtin_trap stub) and never reach a catch handler.
    -- Asserting that end-to-end turns any emcc/libgcc/backend change of
    -- exception semantics into a loud revalidation instead of silent drift.
    local eh_source = write_emscripten_eh_trap_smoke_source(root)
    local eh_object = path.join(root, "emscripten_eh_trap.o")
    local eh_output = path.join(root, "emscripten_eh_trap.js")
    local eh_log = path.join(root, "emscripten_eh_trap.log")
    run.run_program("compile GCC WebAssembly -fexceptions trap-policy smoke", cxx_compiler, {
        "-std=c++26", "-O2", "-pthread", "-fexceptions", "-fno-rtti",
        "-c", eh_source, "-o", eh_object
    }, {target_os = target_os, envs = cxx_envs})
    run.run_program("link GCC WebAssembly -fexceptions trap-policy smoke through emcc", emcc, {
        eh_object,
        libstdcxx_exp_path(target_os),
        libstdcxx_path(target_os),
        libgcc_path(target_os),
        "-nostdlibxx",
        "-pthread",
        "-sPTHREAD_POOL_SIZE=4",
        "-sPROXY_TO_PTHREAD=1",
        "-sEXIT_RUNTIME=1",
        "-sIGNORE_MISSING_MAIN=0",
        "-sENVIRONMENT=node",
        "-g2",
        "-o", eh_output
    }, {target_os = target_os})
    -- stdout and stderr need SEPARATE files: pointing both at one path makes
    -- xmake open two handles that each write from offset 0, and the stream
    -- flushed last silently overwrites the other (verified empirically) --
    -- which would erase the pre-throw stdout marker under the stderr trace.
    local eh_err_log = path.join(root, "emscripten_eh_trap.err.log")
    local eh_exit = os.execv(node_path(), {eh_output},
        {try = true, curdir = root, stdout = eh_log, stderr = eh_err_log})
    local eh_transcript = (os.isfile(eh_log) and (io.readfile(eh_log) or "") or "")
        .. "\n" .. (os.isfile(eh_err_log) and (io.readfile(eh_err_log) or "") or "")
    if eh_exit == 0 then
        errors.fail("wasm -fexceptions smoke exited 0: a throw no longer traps, so the documented exception policy (throw traps, catch unreachable) is stale; revisit docs/developer/wasm_exception_policy.md")
    end
    if not eh_transcript:find("eh-smoke-before-throw", 1, true) then
        errors.fail("wasm -fexceptions smoke never reached its throw site (missing pre-throw marker); transcript: %s",
            eh_transcript:sub(1, 400))
    end
    if eh_transcript:find("eh-smoke-caught", 1, true) then
        errors.fail("wasm -fexceptions smoke executed a catch handler: wasm exceptions became functional, so the documented trap policy is stale; revisit docs/developer/wasm_exception_policy.md")
    end

    local sizes_summary = record_smoke_sizes(root, target_os, {output, output_wasm, opt_output, opt_wasm})
    io.writefile(path.join(root, "emscripten.stamp"), smoke_signature(target_os))
    print("GCC concepts, contracts, coroutines, reflection, std-module empty-record ABI, pthread/TLS/atomic wait/shared_ptr, and Rust atomic Emscripten smoke passed: " .. output)
    print("wasm build-quality assertions passed (DWARF canary no-op, -g2 name section, symbol-granular GC, full -O3 wasm-opt pipeline, -fexceptions throw traps); sizes: " .. sizes_summary)
    return true
end

function capability_name()
    return WASM_CAPABILITY
end

function reset_build_cache(target_os)
    local build = settings.wabt_build_dir(target_os or "emscripten")
    if os.isdir(build) then
        layout.remove_toolchains_path(build)
    end
end
