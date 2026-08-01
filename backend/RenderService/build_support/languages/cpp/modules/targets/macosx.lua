-- macOS target provider: Apple host-tool wrapper staging, *_FOR_TARGET
-- build envs, the Darwin configure argument set (SDK sysroot, rpath,
-- deployment target), the Darwin libgcc_ehs makefile patch, and the macOS
-- preflight. macOS hosts keep using the Apple command-line tools and the
-- xcrun SDK probe. Non-macOS hosts cross-build against a user-provided
-- Apple SDK (--apple_sdk/APPLE_SDK; Apple's license terms do not allow
-- this manager to download one) with a staged Mach-O tool family: the LLD
-- darwin linker plus llvm-ar/ranlib/strip/nm from the managed Emscripten
-- toolset (or a host LLVM), a host-clang arm64 assembler wrapper, and
-- exit-0 lipo/dsymutil stubs. No project binutils are built for this
-- target. The smoke hooks assert Mach-O identity statically (llvm-readobj/
-- llvm-nm parse Mach-O through libObject, no AArch64 backend needed);
-- executing the artifacts needs a real mac and stays a manual step.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("hosttools", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("run", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("gccemsdk", {rootdir = path.join(os.scriptdir(), "..")})

-- ld64.lld -v with no -arch just errors, so GCC's ld64 version autodetect
-- comes up empty and would fall back to the ancient 85.2.1 flag path;
-- >= 512 selects the modern -platform_version/-macos_version_min handling.
local LD64_VERSION = "609"

-- Bump to force a smoke revalidation when the assertion set changes.
local MACHO_SMOKE_CAPABILITY = "macho-cross-static-asserts-object-exe-dylib-v1"

local llvm_tool_memo = {}
local assembler_clang_memo = {}
local clang_version_memo = {}

local function is_darwin_host()
    return base.host_os() == "macosx"
end

local function deployment_target()
    return tostring(settings.value_or("macosx_deployment_target", "11.0"))
end

local function xcrun_sdk_path()
    local ok_sdk, sdk = errors.trycall(function ()
        return os.iorunv("xcrun", {"--sdk", "macosx", "--show-sdk-path"})
    end)
    sdk = base.trim(sdk or "")
    if ok_sdk and sdk ~= "" and os.isdir(sdk) then
        return sdk
    end
end

-- Resolved Apple SDK root: the user-provided --apple_sdk/APPLE_SDK value on
-- any host first, then the xcrun probe on macOS hosts. Returns nil when
-- nothing resolves; completeness is judged separately below.
local function apple_sdk_root()
    local configured = tostring(settings.value_or("apple_sdk", "") or "")
    if configured ~= "" then
        return path.absolute(configured)
    end
    if is_darwin_host() then
        return xcrun_sdk_path()
    end
end

local function apple_sdk_version(sdk)
    if not sdk or sdk == "" then
        return ""
    end
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

-- Shared SDK completeness criteria (preflight and status): SDK metadata, a
-- materialized header tree, the libSystem TAPI text stub, and the framework
-- tree. ld64.lld reads .tbd stubs directly, so a plain SDK copy is fully
-- linkable without any Mach-O dylibs.
local function apple_sdk_completeness_warnings(sdk)
    local warnings = {}
    if not (os.isfile(path.join(sdk, "SDKSettings.plist")) or os.isfile(path.join(sdk, "SDKSettings.json"))) then
        table.insert(warnings, errors.message("the Apple SDK has no SDKSettings.plist/SDKSettings.json; point --apple_sdk at the MacOSX.sdk root itself: %s", sdk))
    end
    if not os.isfile(path.join(sdk, "usr", "include", "stdio.h")) then
        table.insert(warnings, errors.message("the Apple SDK is missing usr/include/stdio.h; copy the SDK with symlinks materialized (tar -h) so the header tree is complete: %s", sdk))
    end
    if not os.isfile(path.join(sdk, "usr", "lib", "libSystem.tbd")) then
        table.insert(warnings, errors.message("the Apple SDK is missing usr/lib/libSystem.tbd; the darwin linker needs the SDK's text-based stub libraries: %s", sdk))
    end
    if not os.isdir(path.join(sdk, "System", "Library", "Frameworks", "CoreFoundation.framework")) then
        table.insert(warnings, errors.message("the Apple SDK is missing System/Library/Frameworks/CoreFoundation.framework; the framework tree looks incomplete: %s", sdk))
    end
    return warnings
end

-- Mach-O LLVM tool resolution for non-macOS hosts: the managed Emscripten
-- LLVM first (zero extra downloads; installed()-gated and read-only), then
-- PATH, then well-known host LLVM install roots. Memoized so preflight,
-- status, staging, and the smoke all see one consistent answer.
local function host_llvm_candidates(name)
    local candidates = {}
    local executable = base.exe(name)
    if base.is_windows_host() then
        for _, root in ipairs({
            os.getenv("ProgramW6432"),
            os.getenv("ProgramFiles"),
            os.getenv("ProgramFiles(x86)")
        }) do
            if root and root ~= "" then
                table.insert(candidates, path.join(root, "LLVM", "bin", executable))
            end
        end
        local localappdata = os.getenv("LOCALAPPDATA")
        if localappdata and localappdata ~= "" then
            table.insert(candidates, path.join(localappdata, "Programs", "LLVM", "bin", executable))
        end
        local userprofile = os.getenv("USERPROFILE")
        if userprofile and userprofile ~= "" then
            table.insert(candidates, path.join(userprofile, "scoop", "apps", "llvm", "current", "bin", executable))
        end
        local programfiles = os.getenv("ProgramW6432") or os.getenv("ProgramFiles")
        if programfiles and programfiles ~= "" then
            for _, candidate in ipairs(os.files(path.join(programfiles, "Microsoft Visual Studio", "*", "*",
                "VC", "Tools", "Llvm", "x64", "bin", executable))) do
                table.insert(candidates, candidate)
            end
        end
    else
        for _, candidate in ipairs(os.files(path.join("/usr", "lib", "llvm*", "bin", executable))) do
            table.insert(candidates, candidate)
        end
    end
    return candidates
end

local function macho_llvm_tool(name)
    local memo = llvm_tool_memo[name]
    if memo ~= nil then
        return memo ~= "" and memo or nil
    end
    local found
    local bindir = gccemsdk.upstream_bin_dir()
    if bindir then
        local candidate = path.join(bindir, base.exe(name))
        if os.isfile(candidate) then
            found = candidate
        end
    end
    found = found or hosttools.find_tool_path(name)
    if not found then
        for _, candidate in ipairs(host_llvm_candidates(name)) do
            if os.isfile(candidate) then
                found = path.absolute(candidate)
                break
            end
        end
    end
    llvm_tool_memo[name] = found or ""
    return found
end

-- The darwin linker: any LLD universal driver works, but it must be staged
-- and invoked under its ld64.lld identity -- LLD selects its flavour from
-- argv[0], and a <triplet>-ld name silently selects the ELF linker (same
-- trap the wasm pipeline documented for wasm-ld).
local function macho_ld_path()
    for _, name in ipairs({"lld", "ld64.lld"}) do
        local found = macho_llvm_tool(name)
        if found then
            return found
        end
    end
end

local function clang_target_arch(target_os)
    local arch = settings.target_arch(target_os)
    return arch == "aarch64" and "arm64" or arch
end

local function clang_backend_name(target_os)
    local arch = settings.target_arch(target_os)
    return arch == "aarch64" and "aarch64" or (arch:gsub("_", "-"))
end

-- Assembler tier (owner decision B): the managed Emscripten clang has no
-- AArch64 backend (probe-verified 2026-07-17), so the arm64-apple assembler
-- is a thin wrapper over a user-provided host clang. A candidate is
-- accepted only when its `clang -print-targets` lists the target backend.
local function assembler_clang(target_os)
    local backend = clang_backend_name(target_os)
    local memo = assembler_clang_memo[backend]
    if memo ~= nil then
        return memo ~= "" and memo or nil
    end
    local candidates = {}
    local seen = {}
    local function add(candidate)
        if candidate and candidate ~= "" and os.isfile(candidate) and not seen[candidate] then
            seen[candidate] = true
            table.insert(candidates, candidate)
        end
    end
    add(hosttools.find_tool_path("clang"))
    for _, candidate in ipairs(host_llvm_candidates("clang")) do
        add(candidate)
    end
    local accepted
    for _, candidate in ipairs(candidates) do
        local ok, output = errors.trycall(function ()
            return os.iorunv(candidate, {"-print-targets"})
        end)
        if ok and tostring(output or ""):find(backend, 1, true) then
            accepted = path.absolute(candidate)
            break
        end
    end
    assembler_clang_memo[backend] = accepted or ""
    return accepted
end

local function clang_version_of(clang)
    if not clang or clang == "" then
        return ""
    end
    local memo = clang_version_memo[clang]
    if memo ~= nil then
        return memo
    end
    local ok, output = errors.trycall(function ()
        return os.iorunv(clang, {"--version"})
    end)
    local version = ok and tostring(output or ""):match("version%s+([%w%.%-%+]+)") or ""
    clang_version_memo[clang] = version
    return version
end

local function staged_ld64_path(target_os)
    return path.join(settings.gcc_prefix(target_os), "bin", base.exe("ld64.lld"))
end

local function staged_assembler_path(target_os)
    return path.join(settings.gcc_prefix(target_os), "bin", base.exe(settings.managed_target(target_os) .. "-as"))
end

local function stage_file_copy(real, staged)
    -- unconditional: a rebuilt same-size artifact (e.g. an equal-length
    -- deployment-target edit recompiled into the as-shim) must not leave
    -- prefix/bin stale, and staging only runs on toolchain operations, so
    -- the copy cost is irrelevant next to a GCC build
    os.cp(real, staged)
end

local function write_sh_script(launcher, body)
    io.writefile(launcher, "#!/bin/sh\n" .. body .. "\n")
    os.vrunv(hosttools.preferred_host_tool("chmod"), {"+x", launcher}, {try = true})
end

local function c_string_literal(value)
    return "\"" .. value:gsub("\\", "\\\\"):gsub("\"", "\\\"") .. "\""
end

-- Windows cannot stage sh wrappers. pex-win32 can spawn .bat files
-- (probe-verified via `gcc -wrapper`, 2026-07-17), but GCC's configure also
-- drives the assembler through the POSIX shell where .bat interop is not
-- guaranteed, so the durable form is a tiny compiled shim: it re-invokes
-- the real tool with the raw command-line tail passed through unmodified
-- (no requoting layer to get wrong).
local function windows_shim_compiler()
    local compiler = hosttools.windows_host_info().compiler
    if compiler and os.isfile(compiler) then
        return compiler
    end
    return hosttools.find_tool_path("gcc") or hosttools.find_tool_path("cc")
end

local function as_shim_source(clang, assembler_target)
    return table.concat({
        "#include <windows.h>",
        "#include <stdio.h>",
        "#include <string.h>",
        "",
        "static const char program[] = " .. c_string_literal(clang) .. ";",
        "static const char prefix[] = " .. c_string_literal("\"" .. clang .. "\" -c -target " .. assembler_target) .. ";",
        "static char command[65536];",
        "",
        "int main(void)",
        "{",
        "\tconst char* tail = GetCommandLineA();",
        "\tint quoted = 0;",
        "\twhile (*tail == ' ' || *tail == '\\t')",
        "\t\t++tail;",
        "",
        "\twhile (*tail != '\\0' && (quoted || (*tail != ' ' && *tail != '\\t')))",
        "\t{",
        "\t\tif (*tail == '\"')",
        "\t\t\tquoted = !quoted;",
        "",
        "\t\t++tail;",
        "\t}",
        "\tif (strlen(prefix) + strlen(tail) + 1 > sizeof(command))",
        "\t{",
        "\t\tfputs(\"Mach-O assembler shim: command line too long\\n\", stderr);",
        "\t\treturn 127;",
        "\t}",
        "\tstrcpy(command, prefix);",
        "\tstrcat(command, tail);",
        "\tSTARTUPINFOA startup;",
        "\tPROCESS_INFORMATION process;",
        "\tDWORD code = 127;",
        "\tmemset(&startup, 0, sizeof(startup));",
        "\tstartup.cb = sizeof(startup);",
        "\tif (!CreateProcessA(program, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process))",
        "\t{",
        "\t\tfprintf(stderr, \"Mach-O assembler shim: cannot start %s (error %lu)\\n\", program, (unsigned long)GetLastError());",
        "\t\treturn 127;",
        "\t}",
        "\tWaitForSingleObject(process.hProcess, INFINITE);",
        "\tGetExitCodeProcess(process.hProcess, &code);",
        "\tCloseHandle(process.hProcess);",
        "\tCloseHandle(process.hThread);",
        "\treturn (int)code;",
        "}",
        ""
    }, "\n")
end

local function noop_shim_source()
    return "int main(void)\n{\n\treturn 0;\n}\n"
end

local function ensure_windows_shim(target_os, name, source_code)
    local root = path.join(settings.state_cache_dir(target_os), "macho-tools")
    os.mkdir(root)
    local built = path.join(root, base.exe(name))
    local stamp = built .. ".cfg"
    if os.isfile(built) and os.isfile(stamp) and io.readfile(stamp) == source_code then
        return built
    end
    local compiler = windows_shim_compiler()
    if not compiler then
        errors.fail("no host C compiler was found to build the Mach-O tool shim: %s", name)
    end
    local source = path.join(root, name .. "-shim.c")
    io.writefile(source, source_code)
    run.run_program("building Mach-O tool shim " .. name, compiler, {"-O1", "-o", built, source}, {target_os = target_os})
    io.writefile(stamp, source_code)
    return built
end

-- Stages the full Mach-O cross tool family into prefix/bin and
-- prefix/<triplet>/bin. Idempotent by design: configure_gcc re-runs
-- stage_tools after the first staging pass in build_gcc_for.
local function stage_cross_tools(target_os)
    local triplet = settings.managed_target(target_os)
    local prefix = settings.gcc_prefix(target_os)
    local bindirs = {path.join(prefix, "bin"), path.join(prefix, triplet, "bin")}
    for _, bindir in ipairs(bindirs) do
        os.mkdir(bindir)
    end
    for _, tool in ipairs({{"ar", "llvm-ar"}, {"ranlib", "llvm-ranlib"}, {"strip", "llvm-strip"}, {"nm", "llvm-nm"}}) do
        local real = macho_llvm_tool(tool[2])
        if not real then
            errors.fail("a Mach-O capable %s tool was not found (%s); install the managed Emscripten toolset or a host LLVM", tool[1], tool[2])
        end
        for _, bindir in ipairs(bindirs) do
            local staged = path.join(bindir, base.exe(triplet .. "-" .. tool[1]))
            if base.is_windows_host() then
                stage_file_copy(real, staged)
            else
                write_sh_script(staged, "exec " .. base.shquote(real) .. " \"$@\"")
            end
        end
    end
    local ld = macho_ld_path()
    if not ld then
        errors.fail("no LLD darwin linker (ld64.lld) was found; install the managed Emscripten toolset or a host LLVM")
    end
    local staged_ld = staged_ld64_path(target_os)
    if base.is_windows_host() then
        stage_file_copy(ld, staged_ld)
    else
        write_sh_script(staged_ld, "exec " .. base.shquote(ld) .. " -flavor darwin \"$@\"")
    end
    local clang = assembler_clang(target_os)
    if not clang then
        errors.fail("no host clang with the %s backend was found for the Apple assembler wrapper; install an LLVM whose `clang -print-targets` lists %s",
            clang_backend_name(target_os), clang_backend_name(target_os))
    end
    local assembler_target = clang_target_arch(target_os) .. "-apple-macosx" .. deployment_target()
    local as_shim
    if base.is_windows_host() then
        as_shim = ensure_windows_shim(target_os, triplet .. "-as", as_shim_source(clang, assembler_target))
    end
    for _, bindir in ipairs(bindirs) do
        local staged = path.join(bindir, base.exe(triplet .. "-as"))
        if base.is_windows_host() then
            stage_file_copy(as_shim, staged)
        else
            write_sh_script(staged, "exec " .. base.shquote(clang) .. " -c -target " .. assembler_target .. " \"$@\"")
        end
    end
    -- exit-0 stubs: --disable-multilib never drives lipo, and DSYMUTIL_SPEC
    -- only fires for -g links of source files, which the toolchain build
    -- does not perform (target libraries build at -g0)
    local noop_shim
    if base.is_windows_host() then
        noop_shim = ensure_windows_shim(target_os, "macho-noop", noop_shim_source())
    end
    for _, name in ipairs({"lipo", "dsymutil"}) do
        for _, bindir in ipairs(bindirs) do
            local staged = path.join(bindir, base.exe(triplet .. "-" .. name))
            if base.is_windows_host() then
                stage_file_copy(noop_shim, staged)
            else
                write_sh_script(staged, "exit 0")
            end
        end
    end
end

function stage_tools(target_os)
    if target_os ~= "macosx" then
        return
    end
    if not is_darwin_host() then
        stage_cross_tools(target_os)
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

-- Replaces the binutils bring-up on non-macOS hosts: the managed Emscripten
-- toolset is the primary LLVM source, and a failed install degrades loudly
-- to PATH/host LLVM tools (mirroring the wasm pipeline's degrade contract).
function prepare_backend_tools(target_os)
    if target_os ~= "macosx" or is_darwin_host() then
        return
    end
    errors.log("preparing Mach-O cross linker and binary tools")
    local ensured, failure = errors.trycall(function ()
        return gccemsdk.ensure_installed()
    end)
    if not ensured then
        errors.warn("managed Emscripten toolset install failed; falling back to host LLVM tools from PATH for the Mach-O tool family: %s", tostring(failure))
    end
    llvm_tool_memo = {}
    stage_cross_tools(target_os)
end

function apply_envs(target_os, envs)
    if target_os ~= "macosx" then
        return envs
    end
    local triplet = settings.managed_target(target_os)
    envs.MACOSX_DEPLOYMENT_TARGET = deployment_target()
    envs.AR_FOR_TARGET = triplet .. "-ar"
    envs.AS_FOR_TARGET = triplet .. "-as"
    if is_darwin_host() then
        envs.LD_FOR_TARGET = triplet .. "-ld"
    else
        -- argv[0] flavour trap: a <triplet>-ld name would select LLD's ELF
        -- driver, so the staged linker keeps its ld64.lld identity (the
        -- toolchain prefix/bin is first on the build PATH)
        envs.LD_FOR_TARGET = "ld64.lld"
    end
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
    if target_os ~= "macosx" then
        return {}, {}
    end
    local warnings = {}
    if not settings.macosx_target_supported(target_os) then
        table.insert(warnings, errors.message("The selected GCC source profile does not support the macOS target: %s", settings.managed_target(target_os)))
    end
    -- reachable only through an explicit --toolchains_target override (the
    -- default triplet is aarch64-only by policy): x86_64-apple-darwin has
    -- never been validated by this manager and resolves to a source
    -- profile without the Darwin patches
    if settings.target_arch(target_os) ~= "aarch64" then
        table.insert(warnings, errors.message("macOS targets are aarch64-only in this manager (darwin-arm64 profile); the overridden target %s selects an unvalidated configuration.", settings.managed_target(target_os)))
    end
    if is_darwin_host() then
        local actions = {
            errors.message("Build macOS targets from a macOS host with Apple Command Line Tools installed."),
            errors.message("Check the SDK with: xcrun --sdk macosx --show-sdk-path"),
            errors.message("Darwin Arm64 automatically uses the project Darwin Arm64 GCC source profile; inspect it with `xmake toolchains status macosx`.")
        }
        local sdk = apple_sdk_root()
        if not sdk then
            table.insert(warnings, errors.message("Apple macOS SDK was not found through xcrun."))
        elseif tostring(settings.value_or("apple_sdk", "") or "") ~= "" then
            for _, warning in ipairs(os.isdir(sdk) and apple_sdk_completeness_warnings(sdk)
                or {errors.message("the configured Apple SDK root does not exist: %s", sdk)}) do
                table.insert(warnings, warning)
            end
        end
        for _, tool in ipairs({"as", "ld", "ar", "ranlib", "strip"}) do
            if not hosttools.find_tool_path(tool) then
                table.insert(warnings, errors.message("Required Apple command-line tool was not found in PATH: %s", tool))
            end
        end
        return warnings, actions
    end
    local actions = {
        errors.message("Provide a macOS SDK copied from your own Mac via --apple_sdk=<path> or APPLE_SDK; Apple's license terms do not allow this manager to download one."),
        errors.message("Copy the SDK with symlinks materialized, e.g. on the Mac: tar -C \"$(dirname \"$(xcrun --sdk macosx --show-sdk-path)\")\" -chzf MacOSX.sdk.tar.gz MacOSX.sdk"),
        errors.message("The ld64.lld linker and the llvm-ar/ranlib/strip/nm family come from the managed Emscripten toolset (installed automatically on demand) or a host LLVM install."),
        errors.message("The arm64 assembler wraps a host clang: install an LLVM whose `clang -print-targets` lists aarch64 (the managed Emscripten clang has no AArch64 backend)."),
        errors.message("Run `xmake toolchains status macosx` to inspect every detected path.")
    }
    local sdk = apple_sdk_root()
    if not sdk then
        table.insert(warnings, errors.message("No Apple macOS SDK is configured; pass --apple_sdk=<path> or set APPLE_SDK to a MacOSX.sdk copied from your own Mac."))
    elseif not os.isdir(sdk) then
        table.insert(warnings, errors.message("the configured Apple SDK root does not exist: %s", sdk))
    else
        for _, warning in ipairs(apple_sdk_completeness_warnings(sdk)) do
            table.insert(warnings, warning)
        end
    end
    if not macho_ld_path() then
        table.insert(warnings, errors.message("The LLD darwin linker (ld64.lld) was not found: the managed Emscripten toolset is missing and PATH provides no lld."))
    end
    for _, tool in ipairs({"llvm-ar", "llvm-ranlib", "llvm-strip", "llvm-nm"}) do
        if not macho_llvm_tool(tool) then
            table.insert(warnings, errors.message("Required Mach-O binary tool was not found: %s", tool))
        end
    end
    if not assembler_clang(target_os) then
        table.insert(warnings, errors.message("No host clang with the %s backend was found; the Apple assembler tier needs an LLVM whose `clang -print-targets` lists %s.",
            clang_backend_name(target_os), clang_backend_name(target_os)))
    end
    return warnings, actions
end

function preflight(target_os)
    if target_os ~= "macosx" then
        return
    end
    if not is_darwin_host() then
        -- the managed toolset is the primary LLVM source; a failed install
        -- degrades loudly to PATH/host LLVM in the probe below
        local ensured, failure = errors.trycall(function ()
            return gccemsdk.ensure_installed()
        end)
        if not ensured then
            errors.warn("managed Emscripten toolset install failed; falling back to host LLVM tools from PATH for the Mach-O tool family: %s", tostring(failure))
        end
        llvm_tool_memo = {}
    end
    local warnings, actions = preflight_warnings(target_os)
    if #warnings > 0 then
        run.stop_with_guidance(target_os, errors.message("macOS target settings are incomplete"), warnings, actions)
    end
end

function needs_binutils(target_os)
    return false
end

function configure_args(target_os, args)
    table.insert(args, "--enable-shared")
    table.insert(args, "--enable-threads=posix")
    table.insert(args, "--enable-darwin-at-rpath")
    table.insert(args, "--with-darwin-extra-rpath=@loader_path")
    table.insert(args, "MACOSX_DEPLOYMENT_TARGET=" .. deployment_target())
    local sdk = apple_sdk_root()
    if sdk and os.isdir(sdk) then
        table.insert(args, "--with-sysroot=" .. base.shpath(sdk))
    end
    if is_darwin_host() then
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
    -- staged-tool paths are deterministic, so the configure signature stays
    -- stable across tool-resolution churn (the resolved sources land in
    -- signature_extra instead); staging runs before configure in the build
    -- flow and is idempotent
    table.insert(args, "--with-as=" .. base.shpath(staged_assembler_path(target_os)))
    table.insert(args, "--with-ld=" .. base.shpath(staged_ld64_path(target_os)))
    table.insert(args, "--with-ld64-version=" .. LD64_VERSION)
    return args
end

-- Non-macOS hosts fold the external SDK and the resolved backend tools into
-- the configure signature: swapping the SDK (path or version), the LLVM
-- source, or the wrapped clang forces a reconfigure. macOS hosts return ""
-- so existing native build trees keep byte-stable signatures.
function signature_extra(target_os)
    if target_os ~= "macosx" or is_darwin_host() then
        return ""
    end
    local sdk = apple_sdk_root()
    local clang = assembler_clang(target_os)
    return table.concat({
        "apple_sdk=" .. tostring(sdk or ""),
        "apple_sdk_version=" .. apple_sdk_version(sdk),
        "macho_ld=" .. tostring(macho_ld_path() or ""),
        "macho_as_clang=" .. tostring(clang or ""),
        "macho_as_clang_version=" .. clang_version_of(clang)
    }, "\n") .. "\n"
end

function stamp_extra(target_os)
    return signature_extra(target_os)
end

-- SDK/tool drift visibility for the OUTER install gate (ios/linux/android
-- pattern): non-darwin hosts key the external SDK and the resolved Mach-O
-- backend tools into the install stamp, so swapping --apple_sdk or the
-- LLVM behind the staged wrappers invalidates the install (and with it the
-- smoke path) instead of silently reusing the old toolchain. Stamps
-- written before these keys existed are grandfathered on this read path;
-- the finalize write path migrates them once.
function installed_extra(target_os)
    if target_os ~= "macosx" or is_darwin_host() then
        return true
    end
    local stamp = settings.stamp_file(target_os)
    if not os.isfile(stamp) then
        return true
    end
    local content = io.readfile(stamp) or ""
    for line in tostring(signature_extra(target_os)):gmatch("[^\n]+") do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key then
            local recorded = content:match("[\r\n]" .. key .. "=([^\r\n]*)")
            if recorded ~= nil and recorded ~= value then
                return false
            end
        end
    end
    return true
end

function target_tools(target_os)
    return {ar = "ar", ranlib = "ranlib", strip_globs = {path.join("**", "*.dylib")}}
end

function patch_build_tree(target_os)
    if target_os ~= "macosx" then
        return
    end
    local slibgcc_fragment = path.join(settings.gcc_source_dir(target_os), "libgcc", "config", "t-slibgcc-darwin")
    if os.isfile(slibgcc_fragment) then
        local fragment = io.readfile(slibgcc_fragment)
        local patched_fragment = base.replace_plain(fragment,
            "\t    -Wl,-reexport_library,libgcc_ehs.$(SHLIB_SOVERSION)$(SHLIB_EXT)_T_$${mlib} \\\n\t    -install_name $(SHLIB_RPATH)/libgcc_s.1.dylib \\",
            "\t    -Wl,-reexport_library,libgcc_ehs.$(SHLIB_SOVERSION)$(SHLIB_EXT)_T_$${mlib} \\\n\t    -lSystem \\\n\t    -install_name $(SHLIB_RPATH)/libgcc_s.1.dylib \\")
        if patched_fragment ~= fragment then
            print("patching Darwin libgcc source fragment: link libgcc_s.1 with libSystem")
            io.writefile(slibgcc_fragment, patched_fragment)
        end
    end
    local libgcc_dir = path.join(settings.gcc_build_dir(target_os), settings.managed_target(target_os), "libgcc")
    local makefile = path.join(libgcc_dir, "Makefile")
    if not os.isfile(makefile) then
        return
    end
    local changed = false
    local content = io.readfile(makefile)
    local patched = content
    if not patched:find("$(srcdir)/config/t-darwin-ehs", 1, true) then
        patched = base.replace_plain(patched,
            "$(srcdir)/config/t-slibgcc-darwin",
            "$(srcdir)/config/t-darwin-ehs $(srcdir)/config/t-slibgcc-darwin")
    end
    patched = patched:gsub(
        "libgcc_s%$%(SHLIB_EXT%): %$%(libgcc%-s%-objects%) %$%(extra%-parts%) libgcc%.a[^\n]*",
        "libgcc_s$(SHLIB_EXT): $(libgcc-s-objects) $(extra-parts) libgcc.a")
    patched = base.replace_plain(patched,
        "@shlib_objs@,$(objects) unwind-dw2-fde-darwin.o libgcc.a,$(subst \\",
        "@shlib_objs@,$(objects) libgcc.a,$(subst \\")
    patched = patched:gsub("[\t ]*cat %$%(srcdir%)/config/darwin%-unwind%.ver >> tmp%-%$@\n", "")
    if patched ~= content then
        print("patching Darwin libgcc Makefile: enable libgcc_ehs reexports")
        io.writefile(makefile, patched)
        changed = true
    end
    for _, mapfile in ipairs({
        path.join(libgcc_dir, "libgcc.map"),
        path.join(libgcc_dir, "libgcc.map.in")
    }) do
        if os.isfile(mapfile) and io.readfile(mapfile):find("___register_frame_info", 1, true) then
            layout.remove_toolchains_path(mapfile)
            changed = true
        end
    end
    if changed then
        for _, file in ipairs(os.files(path.join(libgcc_dir, "libgcc_s*.dylib*"))) do
            if os.isfile(file) then
                layout.remove_toolchains_path(file)
            end
        end
        for _, file in ipairs(os.files(path.join(libgcc_dir, "libgcc_ehs*.dylib*"))) do
            if os.isfile(file) then
                layout.remove_toolchains_path(file)
            end
        end
    end
end

function build_plan(target_os, context)
    if not settings.is_cross_target(target_os) then
        return {
            {log = "building native GCC toolchain", targets = {"", "install"}}
        }
    end
    local function patch_darwin_libgcc()
        patch_build_tree(target_os)
    end
    return {
        {
            log = "building macOS GCC compiler and target runtime",
            targets = {"all-gcc", "install-gcc", "configure-target-libgcc"},
            patch = patch_darwin_libgcc
        },
        {
            targets = {"all-target-libgcc", "install-target-libgcc"},
            patch = patch_darwin_libgcc
        },
        {
            targets = {"configure-target-libstdc++-v3", "all-target-libstdc++-v3", "install-target-libstdc++-v3"},
            patch = true
        }
    }
end

-- Mach-O static smoke: cross-compile small C/C++ units, link an executable
-- and a dylib, and assert container identity through llvm-readobj/llvm-nm
-- (otool/nm on a macOS host without LLVM tools). Running the artifacts
-- needs a real mac and stays a manual verification step outside this hook.

local function smoke_dir(target_os)
    return path.join(settings.state_cache_dir(target_os), "macho-smoke")
end

local function smoke_compiler_path(target_os, language)
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

local function smoke_signature(target_os)
    local source = settings.gcc_source_profile(target_os)
    local sdk = apple_sdk_root()
    -- the staged compiler paths are deterministic, so the resolved backend
    -- tools must be keyed here too (same keys as signature_extra): swapping
    -- the host LLVM behind the staged as/ld64.lld wrappers must invalidate
    -- refresh.stamp/link.stamp instead of leaving smoke_state green
    local clang = assembler_clang(target_os)
    return table.concat({
        "smoke_capability=" .. MACHO_SMOKE_CAPABILITY,
        "gcc_ref=" .. source.ref,
        "triplet=" .. settings.managed_target(target_os),
        "deployment_target=" .. deployment_target(),
        "apple_sdk=" .. tostring(sdk or ""),
        "apple_sdk_version=" .. apple_sdk_version(sdk),
        "macho_ld=" .. tostring(macho_ld_path() or ""),
        "macho_as_clang=" .. tostring(clang or ""),
        "macho_as_clang_version=" .. clang_version_of(clang),
        "c_compiler=" .. tostring(smoke_compiler_path(target_os, "c") or ""),
        "cxx_compiler=" .. tostring(smoke_compiler_path(target_os, "c++") or "")
    }, "\n") .. "\n"
end

local function macho_reader()
    local readobj = macho_llvm_tool("llvm-readobj")
    if readobj then
        return "readobj", readobj
    end
    if is_darwin_host() then
        local otool = hosttools.find_tool_path("otool")
        if otool then
            return "otool", otool
        end
    end
end

-- expected_filetype: {readobj = "<FileType name>", otool = "<otool -hv name>"}
local function assert_macho(target_os, file, expected_filetype)
    local kind, reader = macho_reader()
    if not reader then
        errors.fail("no Mach-O inspection tool (llvm-readobj or otool) was found for the smoke assertions")
    end
    local args = kind == "readobj" and {"--file-header", file} or {"-hv", file}
    local ok, output = errors.trycall(function ()
        return os.iorunv(reader, args)
    end)
    if not ok then
        errors.fail("could not inspect the Mach-O smoke artifact: %s", file)
    end
    output = tostring(output or "")
    if kind == "readobj" then
        if not output:find("Format: Mach-O", 1, true) then
            errors.fail("Mach-O smoke artifact has the wrong container format: %s", file)
        end
        if settings.target_arch(target_os) == "aarch64" and not output:find("CpuType: Arm64", 1, true) then
            errors.fail("Mach-O smoke artifact is not arm64: %s", file)
        end
        if not output:find("FileType: " .. expected_filetype.readobj, 1, true) then
            errors.fail("Mach-O smoke artifact has file type other than %s: %s", expected_filetype.readobj, file)
        end
    else
        if settings.target_arch(target_os) == "aarch64" and not output:find("ARM64", 1, true) then
            errors.fail("Mach-O smoke artifact is not arm64: %s", file)
        end
        if not output:find(expected_filetype.otool, 1, true) then
            errors.fail("Mach-O smoke artifact has file type other than %s: %s", expected_filetype.otool, file)
        end
    end
end

local function assert_macho_symbol(file, symbol)
    local nm = macho_llvm_tool("llvm-nm") or (is_darwin_host() and hosttools.find_tool_path("nm") or nil)
    if not nm then
        errors.fail("no Mach-O symbol lister (llvm-nm or nm) was found for the smoke assertions")
    end
    local ok, output = errors.trycall(function ()
        return os.iorunv(nm, {file})
    end)
    if not ok or not tostring(output or ""):find(symbol, 1, true) then
        errors.fail("expected Mach-O symbol %s was not found in %s", symbol, file)
    end
end

local function write_smoke_sources(target_os)
    local root = smoke_dir(target_os)
    os.mkdir(root)
    local c_lines = {
        "#ifndef __APPLE__",
        "#error macOS target identity is missing __APPLE__",
        "#endif",
        "#ifndef __MACH__",
        "#error macOS target identity is missing __MACH__",
        "#endif"
    }
    if settings.target_arch(target_os) == "aarch64" then
        table.insert(c_lines, "#ifndef __aarch64__")
        table.insert(c_lines, "#error expected an AArch64 Apple target")
        table.insert(c_lines, "#endif")
    end
    table.insert(c_lines, "")
    table.insert(c_lines, "int gcc_macho_add(int left, int right)")
    table.insert(c_lines, "{")
    table.insert(c_lines, "\treturn left + right;")
    table.insert(c_lines, "}")
    table.insert(c_lines, "")
    local files = {
        c_source = path.join(root, "macho_smoke_c.c"),
        cxx_source = path.join(root, "macho_smoke_cxx.cpp"),
        main_source = path.join(root, "macho_smoke_main.cpp"),
        dylib_source = path.join(root, "macho_smoke_dylib.cpp"),
        c_object = path.join(root, "macho_smoke_c.o"),
        cxx_object = path.join(root, "macho_smoke_cxx.o"),
        executable = path.join(root, "macho_smoke_exe"),
        dylib = path.join(root, "libmacho_smoke.dylib")
    }
    io.writefile(files.c_source, table.concat(c_lines, "\n"))
    io.writefile(files.cxx_source, table.concat({
        "class accumulator",
        "{",
        "public:",
        "\texplicit accumulator(int value)",
        "\t\t: stored_value(value)",
        "\t{",
        "\t}",
        "",
        "\tint value() const",
        "\t{",
        "\t\treturn this->stored_value;",
        "\t}",
        "",
        "private:",
        "\tint stored_value;",
        "};",
        "",
        "extern \"C\" int gcc_macho_cxx_value(int value)",
        "{",
        "\taccumulator result(value);",
        "\treturn result.value() + 7;",
        "}",
        ""
    }, "\n"))
    io.writefile(files.main_source, table.concat({
        "extern \"C\" int gcc_macho_add(int left, int right);",
        "extern \"C\" int gcc_macho_cxx_value(int value);",
        "",
        "int main()",
        "{",
        "\treturn gcc_macho_add(gcc_macho_cxx_value(35), -42) == 0 ? 0 : 1;",
        "}",
        ""
    }, "\n"))
    io.writefile(files.dylib_source, table.concat({
        "extern \"C\" __attribute__((visibility(\"default\")))",
        "int gcc_macho_dylib_value(void)",
        "{",
        "\treturn 42;",
        "}",
        ""
    }, "\n"))
    return files
end

local function compile_smoke_objects(target_os)
    local cc = smoke_compiler_path(target_os, "c")
    local cxx = smoke_compiler_path(target_os, "c++")
    if not cc or not cxx then
        errors.fail("the macOS cross compilers are not installed; run `xmake toolchains install macosx` first")
    end
    local files = write_smoke_sources(target_os)
    run.run_program("compiling Mach-O C smoke object", cc,
        {"-O2", "-c", files.c_source, "-o", files.c_object}, {target_os = target_os})
    run.run_program("compiling Mach-O C++ smoke object", cxx,
        {"-O2", "-c", files.cxx_source, "-o", files.cxx_object}, {target_os = target_os})
    return files, cc, cxx
end

-- The `xmake toolchains smoke` command hooks; their presence is also the
-- dispatcher's capability gate for that command.

-- Consulted by the dispatcher BEFORE its install-or-refresh decision: on
-- native macOS hosts the engine test suites are the smoke, and building a
-- missing toolchain here would be a multi-hour side effect whose result
-- this command never uses.
function smoke_noop_reason(target_os)
    if target_os == "macosx" and is_darwin_host() then
        return "native macOS toolchains are smoked by the engine test suites; nothing to do here"
    end
end

function smoke_refresh(target_os)
    if target_os ~= "macosx" then
        return
    end
    -- native macOS toolchains keep their contract: the engine test suites
    -- are the smoke (matches the smoke command help and smoke_state)
    if is_darwin_host() then
        print("native macOS toolchains are smoked by the engine test suites; nothing to refresh here")
        return
    end
    errors.log("running Mach-O cross-compile static smoke")
    local files = compile_smoke_objects(target_os)
    assert_macho(target_os, files.c_object, {readobj = "Relocatable", otool = "OBJECT"})
    assert_macho(target_os, files.cxx_object, {readobj = "Relocatable", otool = "OBJECT"})
    assert_macho_symbol(files.c_object, "_gcc_macho_add")
    assert_macho_symbol(files.cxx_object, "_gcc_macho_cxx_value")
    io.writefile(path.join(smoke_dir(target_os), "refresh.stamp"), smoke_signature(target_os))
end

function smoke_link(target_os)
    if target_os ~= "macosx" then
        return
    end
    if is_darwin_host() then
        print("native macOS toolchains are smoked by the engine test suites; nothing to link here")
        return
    end
    errors.log("running Mach-O link smoke (executable + dylib static assertions)")
    local files, _, cxx = compile_smoke_objects(target_os)
    run.run_program("linking Mach-O smoke executable", cxx,
        {"-O2", files.main_source, files.c_object, files.cxx_object, "-o", files.executable},
        {target_os = target_os})
    run.run_program("linking Mach-O smoke dylib", cxx,
        {"-O2", "-dynamiclib", files.dylib_source, "-o", files.dylib},
        {target_os = target_os})
    assert_macho(target_os, files.executable, {readobj = "Executable", otool = "EXECUTE"})
    assert_macho(target_os, files.dylib, {readobj = "DynamicLibrary", otool = "DYLIB"})
    assert_macho_symbol(files.executable, "_main")
    assert_macho_symbol(files.dylib, "_gcc_macho_dylib_value")
    io.writefile(path.join(smoke_dir(target_os), "link.stamp"), smoke_signature(target_os))
    print("Mach-O static smoke passed; run the artifacts on a real mac to extend the evidence: " .. smoke_dir(target_os))
end

-- Post-build-plan hook (gccbuild). macOS-host native builds keep their
-- existing contract -- the engine test suites are the smoke -- so only
-- cross builds get the static Mach-O closure here.
function smoke(target_os)
    if target_os ~= "macosx" or is_darwin_host() then
        return
    end
    smoke_refresh(target_os)
    smoke_link(target_os)
end

-- Read-only matrix probe; never rebuilds or refreshes anything.
function smoke_state(target_os)
    if target_os ~= "macosx" then
        return "false"
    end
    if is_darwin_host() then
        -- native macOS toolchains are smoked by the engine test suites
        return "-"
    end
    local ok, state = errors.trycall(function ()
        local signature = smoke_signature(target_os)
        local refresh_stamp = path.join(smoke_dir(target_os), "refresh.stamp")
        local link_stamp = path.join(smoke_dir(target_os), "link.stamp")
        return os.isfile(refresh_stamp) and io.readfile(refresh_stamp) == signature
            and os.isfile(link_stamp) and io.readfile(link_stamp) == signature
    end)
    return tostring((ok and state) == true)
end

function status_lines(target_os)
    print("macOS min:       " .. deployment_target())
    local sdk = apple_sdk_root()
    print("apple sdk:       " .. tostring(sdk or "(not found: set --apple_sdk/APPLE_SDK" .. (is_darwin_host() and " or install Xcode CLT)" or ")")))
    if sdk then
        local version = apple_sdk_version(sdk)
        print("sdk version:     " .. (version ~= "" and version or "unknown"))
        local sdk_warnings = os.isdir(sdk) and apple_sdk_completeness_warnings(sdk)
            or {"the configured Apple SDK root does not exist: " .. sdk}
        print("sdk complete:    " .. tostring(#sdk_warnings == 0))
    end
    if is_darwin_host() then
        return
    end
    print("macho ld64:      " .. tostring(macho_ld_path() or "(missing)"))
    print("macho ar:        " .. tostring(macho_llvm_tool("llvm-ar") or "(missing)"))
    print("macho ranlib:    " .. tostring(macho_llvm_tool("llvm-ranlib") or "(missing)"))
    print("macho strip:     " .. tostring(macho_llvm_tool("llvm-strip") or "(missing)"))
    print("macho nm:        " .. tostring(macho_llvm_tool("llvm-nm") or "(missing)"))
    print("macho readobj:   " .. tostring(macho_llvm_tool("llvm-readobj") or "(missing)"))
    local clang = assembler_clang(target_os)
    print("apple as clang:  " .. tostring(clang or ("(missing: need clang with " .. clang_backend_name(target_os) .. " backend)")))
    if clang then
        local version = clang_version_of(clang)
        print("as clang ver:    " .. (version ~= "" and version or "unknown"))
    end
    print("macho smoke:     " .. smoke_state(target_os))
end
