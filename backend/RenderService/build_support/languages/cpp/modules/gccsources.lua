-- Project-local GCC toolchain source acquisition (C++-specific): host build
-- prerequisite and generator-tool checks, git source sync (shallow clone /
-- fetch with retries and LF checkout), GCC prerequisite library staging
-- (gettext/gmp/mpfr/mpc/isl with checksum verification), generated-source
-- (gengtype lexer) handling, and the sync_gcc_source driver that applies the
-- gccpatches module after every source sync.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
local defaults = import("defaults", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")}).values()
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("hosttools", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("envs", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("run", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("download", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("makerunner", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("install_lock", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("gccpatches")

-- Mirrored option fallbacks. options.lua owns the description-scope
-- originals (option() defaults are evaluated before any module can load, so
-- they cannot move here), and script scope cannot see description globals.
function run_script(script, argv, opt)
    argv = argv or {}
    opt = opt or {}
    local command = hosttools.preferred_posix_shell()
    local script_arg = base.is_windows_host() and base.shpath(script) or script
    argv = table.join({script_arg}, argv)
    local ok = errors.trycall(function ()
        run.execv(command, argv, opt)
    end)
    if not ok then
        run.print_error_context("script execution", settings.configured_target_os(), {
            {"command", base.command_text(command, argv)},
            {"working directory", opt.curdir}
        })
        errors.fail("script step failed; fix the reported prerequisite/source issue and rerun the same xmake command")
    end
end

function print_host_toolchain_install_guide(missing, target_os)
    target_os = target_os or settings.configured_target_os()
    print("")
    print("GCC bootstrap host-toolchain guide")
    print("  owner root:      " .. layout.owner_root())
    print("  toolchains home: " .. layout.toolchains_home())
    print("  install layout:  " .. path.join(layout.toolchains_home(), "<host>", "<target>", "<arch>"))
    print("  example:         " .. path.join(layout.toolchains_home(), base.host_os(), "windows", "x64"))
    print("  GCC source:      " .. settings.gcc_source_dir(target_os))
    print("  host cache:      " .. path.join(layout.toolchains_cache_root(), "<host>", "<target>", "<arch>"))
    print("")
    if base.is_windows_host() then
        print("  Windows hosts need a MinGW-style GCC bootstrap toolchain with POSIX build tools.")
        print("  First build requirement: gcc/g++, git, make, sh, sed, awk, grep, tar, gzip, bzip2, xz, install, and coreutils.")
        print("  If a complete MinGW bootstrap is not found, toolchains_bootstrap=auto downloads a temporary latest w64devkit release.")
        print("  Detected host compilers must pass a compile/link/run smoke test; shim or wrapper compilers (for example opam/DKML shims) are rejected and the portable bootstrap is used instead.")
        print("  Optional helper tools: flex and bison. If they are missing and Scoop is available, xmake can install winflexbison without UAC.")
        print("  Manual fallback choices: MSYS2 UCRT64 or w64devkit. Put the selected bin directory in PATH before running xmake.")
    elseif base.host_os() == "macosx" then
        print("  macOS hosts need Apple Command Line Tools plus the usual POSIX build tools.")
        print("  First build requirement: clang/gcc, clang++/g++, git, make, sh, sed, awk, grep, tar, gzip, bzip2, install, and coreutils-compatible tools.")
        print("  Optional helper tools: flex and bison. The project tries to reuse generated GCC files when these are older.")
    else
        print("  Linux hosts need the usual native build tools: gcc/g++, git, make, sh, sed, awk, grep, tar, gzip, bzip2, xz, install, and coreutils.")
        print("  Install them with your distribution package manager before running xmake.")
    end
    print("  Use HTTP_PROXY, HTTPS_PROXY, or ALL_PROXY if source downloads need a proxy.")
    if missing and #missing > 0 then
        print("  Missing now: " .. table.concat(missing, ", "))
    end
    print("")
end

local function maybe_print_first_source_sync_guide(target_os)
    if os.isfile(path.join(settings.gcc_source_dir(target_os), "configure")) then
        return
    end
    print_host_toolchain_install_guide(nil, target_os)
end

function ensure_build_prerequisites()
    local missing = {}
    local checks = {
        {"MinGW GCC", {settings.host_triplet() .. "-gcc", "gcc"}},
        {"MinGW G++", {settings.host_triplet() .. "-g++", "g++"}},
        {"git", {"git"}},
        {"GNU make", {settings.value_or("toolchains_make", "make")}},
        {"POSIX shell", {"sh"}},
        {"sed", {"sed"}},
        {"awk", {"gawk", "awk"}},
        {"grep", {"grep"}},
        {"tar", {"tar"}},
        {"gzip", {"gzip"}},
        {"bzip2", {"bzip2"}},
        {"install", {"install"}},
        {"cp", {"cp"}},
        {"mv", {"mv"}},
        {"rm", {"rm"}},
        {"mkdir", {"mkdir"}},
        {"tr", {"tr"}},
        {"cmp", {"cmp"}},
        {"sort", {"sort"}},
        {"sha512sum", {"sha512sum"}}
    }
    for _, check in ipairs(checks) do
        if not hosttools.tool_exists_any(check[2]) then
            table.insert(missing, check[1])
        end
    end
    if not hosttools.tool_exists("xz") and not hosttools.tar_supports_xz() then
        table.insert(missing, "xz")
    end
    if base.is_windows_host() and not hosttools.windows_host_sysroot() then
        table.insert(missing, "complete MinGW sysroot (include/stdio.h and lib/crt2.o)")
    end
    if #missing > 0 then
        print_host_toolchain_install_guide(missing)
        if base.is_windows_host() then
            errors.fail("missing required MinGW bootstrap tools: %s. A bare gcc.exe is not enough; use a MinGW distribution that includes POSIX build tools, such as w64devkit or MSYS2/UCRT64", table.concat(missing, ", "))
        else
            errors.fail("missing required host build tools: %s", table.concat(missing, ", "))
        end
    end
    if base.is_windows_host() and not os.isfile(hosttools.preferred_posix_shell()) then
        print_host_toolchain_install_guide({"POSIX shell"})
        errors.fail("missing POSIX shell for GCC configure. Use a MinGW distribution that provides sh.exe")
    end
    local cc = hosttools.preferred_host_tool_any({settings.host_triplet() .. "-gcc", "gcc"})
    local cxx = hosttools.preferred_host_tool_any({settings.host_triplet() .. "-g++", "g++"})
    if not hosttools.compiler_smoke_ok(cc, cxx) then
        print_host_toolchain_install_guide({"a host compiler that passes a compile/link/run smoke test"})
        if base.is_windows_host() then
            errors.fail("host compiler failed the smoke test: %s. It is likely a shim or wrapper (opam/DKML, package-manager launcher); rerun with --toolchains_bootstrap=portable to force a project-private bootstrap toolchain, or put a real MinGW distribution such as w64devkit or MSYS2/UCRT64 first in PATH", cc)
        else
            errors.fail("host compiler failed the smoke test: %s. Reinstall the native build tools (gcc/g++ or clang with libstdc++/libc++ development headers) with your platform package manager", cc)
        end
    end
end

function archive_leaf_name(url, fallback)
    local clean = (url or ""):gsub("[#%?].*$", "")
    local name = clean:match("[^/\\]+$")
    if not name or name == "" then
        return fallback
    end
    return name
end

local function managed_toolchains_win_cmd_arg(value)
    local text = tostring(value)
    if os.exists(text) then
        text = hosttools.windows_short_path(text)
    end
    -- Refuse anything cmd.exe treats specially outside quotes (whitespace,
    -- &|<>, %-expansion, ^-escape, !-delayed-expansion, "() ) rather than
    -- trying to escape it -- this project's git args come from local config,
    -- not untrusted input, but a value containing one of these should never
    -- silently be parsed as something other than a literal argument.
    if text:find("[%s&|<>%%%^!\"()]") then
        errors.fail("cannot pass a value with cmd.exe metacharacters to cmd safely: %s", text)
    end
    return text
end

local function managed_toolchains_git_command_text(git, args)
    if base.is_windows_host() then
        local command = managed_toolchains_win_cmd_arg(git)
        for _, arg in ipairs(args) do
            command = command .. " " .. managed_toolchains_win_cmd_arg(arg)
        end
        return command
    end
    local command = base.shquote(git)
    for _, arg in ipairs(args) do
        command = command .. " " .. base.shquote(arg)
    end
    return command
end

-- A user-exported GIT_DIR/GIT_WORK_TREE redirects every `git -C` call to the
-- wrong repository (GIT_DIR wins over -C discovery). They cannot be
-- neutralized through the envs option — an empty value is "set but empty" to
-- git, still an error — so unset them for real inside the wrapping shell.
local MANAGED_TOOLCHAINS_GIT_HOSTILE_ENVS = {
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE"
}

local MANAGED_TOOLCHAINS_GIT_RUN_INDEX

local function managed_toolchains_git_unset_prefix()
    if base.is_windows_host() then
        -- quote-free `set VAR=&&` on purpose: embedded double quotes do not
        -- survive the argv round-trip into cmd reliably, and a space before
        -- && would set the variable to a single space instead of unsetting
        local parts = {}
        for _, key in ipairs(MANAGED_TOOLCHAINS_GIT_HOSTILE_ENVS) do
            table.insert(parts, "set " .. key .. "=")
        end
        return table.concat(parts, "&&") .. "&&"
    end
    return "unset " .. table.concat(MANAGED_TOOLCHAINS_GIT_HOSTILE_ENVS, " ") .. "; "
end

function managed_toolchains_run_git(git, args, opt)
    opt = opt or {}
    print("git " .. table.concat(args, " "))
    local logdir = path.join(layout.toolchains_cache_dir(base.host_os()), "logs")
    os.mkdir(logdir)
    MANAGED_TOOLCHAINS_GIT_RUN_INDEX = (MANAGED_TOOLCHAINS_GIT_RUN_INDEX or 0) + 1
    local logfile = path.join(logdir, string.format("%04d-git.out", MANAGED_TOOLCHAINS_GIT_RUN_INDEX))
    local errfile = path.join(logdir, string.format("%04d-git.err", MANAGED_TOOLCHAINS_GIT_RUN_INDEX))
    local command = managed_toolchains_git_unset_prefix() .. managed_toolchains_git_command_text(git, args)
    local shell
    local shell_args
    if base.is_windows_host() then
        shell = "cmd"
        shell_args = {"/d", "/s", "/c", command .. " > " .. managed_toolchains_win_cmd_arg(logfile) .. " 2> " .. managed_toolchains_win_cmd_arg(errfile)}
    else
        shell = hosttools.preferred_posix_shell()
        shell_args = {"-c", command .. " > " .. base.shquote(logfile) .. " 2> " .. base.shquote(errfile)}
    end
    local ok = errors.trycall(function ()
        os.runv(shell, shell_args, {envs = opt.envs, stdin = opt.stdin, timeout = opt.timeout})
        return true
    end)
    local output = ""
    if os.isfile(logfile) then
        output = output .. (io.readfile(logfile) or "")
    end
    if os.isfile(errfile) then
        output = output .. (io.readfile(errfile) or "")
    end
    output = base.trim(output)
    if ok then
        return true, output
    end
    if output ~= "" then
        print(output)
    end
    if opt.try then
        return false, output
    end
    run.print_error_context("git", opt.target_os or settings.configured_target_os(), {
        {"command", "git " .. table.concat(args, " ")},
        {"stdout log", logfile},
        {"stderr log", errfile}
    })
    errors.fail("git command failed: git %s", table.concat(args, " "))
end

local MANAGED_TOOLCHAINS_NETWORK_ATTEMPTS = 3
-- A shallow fetch of exactly the pinned ref is the small, correct transport. It fails
-- almost always on a transient network blip, so retry it hard before ever considering a
-- full-history fetch: escalating a transient blip into a multi-GB unshallow clone makes
-- flaky-network hosts dramatically worse (observed on a host whose git connection times
-- out on large transfers -- shallow succeeded, the full-history recovery it triggered did
-- not, and it cascaded across every platform).
local MANAGED_TOOLCHAINS_SHALLOW_FETCH_ATTEMPTS = 6

-- Retry one shallow transport (plain or blob-filtered) with backoff. Returns true on the
-- first success. Kept separate so both cheap transports get the full retry budget before
-- any heavy fallback is even considered.
local function managed_toolchains_try_shallow_fetch(git, src, ref, envs, filter_blobs, label)
    local attempts = MANAGED_TOOLCHAINS_SHALLOW_FETCH_ATTEMPTS
    for attempt = 1, attempts do
        local args = {"-C", src, "fetch", "origin", ref, "--depth=1", "--no-tags"}
        if filter_blobs then
            table.insert(args, "--filter=blob:none")
        end
        if managed_toolchains_run_git(git, args, {envs = envs, try = true}) then
            return true
        end
        if attempt < attempts then
            errors.warn("%s GCC fetch failed (attempt %d/%d); retrying after a short delay", label, attempt, attempts)
            errors.sleep(2 * attempt)
        end
    end
    return false
end

function managed_toolchains_fetch_gcc_ref(git, src, ref, envs, filter_blobs, fallback_filter_blobs)
    -- Primary transport: shallow fetch of exactly the pinned ref, retried hard.
    if managed_toolchains_try_shallow_fetch(git, src, ref, envs, filter_blobs, "shallow") then
        return true, filter_blobs == true
    end

    -- Alternate cheap transport: blob-filtered shallow (also small), retried hard.
    if fallback_filter_blobs and not filter_blobs then
        print("plain shallow GCC fetch exhausted; retrying with a blob-filtered shallow transport")
        if managed_toolchains_try_shallow_fetch(git, src, ref, envs, true, "blob-filtered shallow") then
            return true, true
        end
    end

    -- LAST RESORT ONLY -- a heavy full-history fetch, reserved for the rare case where the
    -- server genuinely cannot serve the ref shallow (e.g. an unadvertised SHA on a repo
    -- without uploadpack.allowReachableSHA1InWant). Reached only after both shallow
    -- transports are fully exhausted, never on a transient network blip.
    local attempts = MANAGED_TOOLCHAINS_NETWORK_ATTEMPTS
    errors.warn("shallow GCC fetch exhausted on every transport; falling back to a heavy full-history fetch")
    if managed_toolchains_run_git(git, {"-C", src, "fetch", "--unshallow", "origin", ref, "--no-tags"}, {envs = envs, try = true}) then
        return true, false
    end
    for attempt = 1, attempts - 1 do
        if managed_toolchains_run_git(git, {"-C", src, "fetch", "origin", ref, "--no-tags"}, {envs = envs, try = true}) then
            return true, false
        end
        errors.warn("full GCC fetch failed (attempt %d/%d); retrying after a short delay", attempt, attempts)
        errors.sleep(2 * attempt)
    end
    managed_toolchains_run_git(git, {"-C", src, "fetch", "origin", ref, "--no-tags"}, {envs = envs})
    return true, false
end

local function managed_toolchains_checkout_gcc_source(git, src, envs)
    local attempts = MANAGED_TOOLCHAINS_NETWORK_ATTEMPTS
    local args = {"-C", src, "checkout", "--force", "FETCH_HEAD"}
    -- the tree is about to move: the memoized revision (if any) is stale
    managed_toolchains_forget_gcc_source_revision(src)
    for attempt = 1, attempts do
        if attempt == attempts then
            managed_toolchains_run_git(git, args, {envs = envs})
            return
        end
        local ok = managed_toolchains_run_git(git, args, {envs = envs, try = true})
        if ok then
            return
        end
        errors.warn("GCC source checkout failed (attempt %d/%d); retrying after a short delay", attempt, attempts)
        errors.sleep(2 * attempt)
    end
end

local MANAGED_TOOLCHAINS_GIT_OBJECT_BATCH = 4000

local function managed_toolchains_missing_gcc_objects(git, src, envs)
    local _, output = managed_toolchains_run_git(git, {
        "-C", src, "rev-list", "--objects", "--missing=print", "FETCH_HEAD"
    }, {envs = envs})
    local missing = {}
    local seen = {}
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local oid = line:match("^%?([0-9a-fA-F]+)")
        if oid and (#oid == 40 or #oid == 64) and not seen[oid] then
            seen[oid] = true
            table.insert(missing, oid)
        end
    end
    return missing
end

local function managed_toolchains_materialize_gcc_objects(git, src, envs)
    local missing = managed_toolchains_missing_gcc_objects(git, src, envs)
    if #missing == 0 then
        return
    end

    local batch_size = MANAGED_TOOLCHAINS_GIT_OBJECT_BATCH
    local batch_count = math.ceil(#missing / batch_size)
    local input = path.join(src, ".git", "xmake-missing-objects.stdin")
    local args = {
        "-c", "fetch.negotiationAlgorithm=noop",
        "-C", src, "fetch", "origin",
        "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no",
        "--filter=blob:none", "--stdin"
    }
    print(string.format("materializing %d promised GCC objects in %d bounded batches", #missing, batch_count))
    for batch_index = 1, batch_count do
        local first = (batch_index - 1) * batch_size + 1
        local last = math.min(batch_index * batch_size, #missing)
        local lines = {}
        for index = first, last do
            table.insert(lines, missing[index])
        end
        base.writefile_bytes(input, table.concat(lines, "\n") .. "\n")
        print(string.format("fetching promised GCC object batch %d/%d (%d objects)",
            batch_index, batch_count, #lines))
        for attempt = 1, MANAGED_TOOLCHAINS_NETWORK_ATTEMPTS do
            if attempt == MANAGED_TOOLCHAINS_NETWORK_ATTEMPTS then
                managed_toolchains_run_git(git, args, {envs = envs, stdin = input})
                break
            end
            local ok = managed_toolchains_run_git(git, args,
                {envs = envs, stdin = input, try = true})
            if ok then
                break
            end
            errors.warn("GCC object batch %d/%d failed (attempt %d/%d); retrying after a short delay",
                batch_index, batch_count, attempt, MANAGED_TOOLCHAINS_NETWORK_ATTEMPTS)
            errors.sleep(2 * attempt)
        end
    end
    os.rm(input)

    local remaining = managed_toolchains_missing_gcc_objects(git, src, envs)
    if #remaining > 0 then
        errors.fail("GCC object materialization completed with %d promised objects still missing", #remaining)
    end
end

function managed_toolchains_preferred_git()
    local git = hosttools.preferred_host_tool("git")
    if base.is_windows_host() then
        local normalized = git:gsub("/", "\\")
        local root = normalized:match("^(.*)\\cmd\\git%.exe$")
        if root then
            local real = path.join(root, "mingw64", "bin", "git.exe")
            if os.isfile(real) then
                return real
            end
        end
    end
    return git
end

local function managed_toolchains_configure_gcc_git_text_checkout(git, src, envs)
    local git_dir = path.join(src, ".git")
    if not os.isdir(git_dir) then
        return
    end

    managed_toolchains_run_git(git, {"-C", src, "config", "--local", "core.autocrlf", "false"}, {envs = envs})
    managed_toolchains_run_git(git, {"-C", src, "config", "--local", "core.eol", "lf"}, {envs = envs})

    local attributes = path.join(git_dir, "info", "attributes")
    local marker_begin = "# xmake managed toolchains LF checkout begin\n"
    local marker_end = "# xmake managed toolchains LF checkout end\n"
    local block = marker_begin .. "* text=auto eol=lf\n" .. marker_end
    local content = os.isfile(attributes) and io.readfile(attributes) or ""
    if not content:find(marker_begin, 1, true) then
        if content ~= "" and content:sub(-1) ~= "\n" then
            content = content .. "\n"
        end
        io.writefile(attributes, content .. block)
    end
end

local function managed_toolchains_gcc_source_patch_marker(src, target_os)
    return path.join(src, gccpatches.source_patch_marker_name(target_os))
end

local function managed_toolchains_clean_gcc_source_update_artifacts(git, src, envs)
    if not os.isdir(path.join(src, ".git")) then
        return
    end

    -- every stamp generation ever written must stay on the cleanup list;
    -- deriving it from the current version keeps future bumps automatic
    local names = {".xmake-source"}
    for version = 1, gccpatches.source_patch_stamp_max_version() do
        table.insert(names, ".xmake-gcc-source-patched-v" .. version)
    end
    table.join2(names, {
        "gcc/gengtype-lex.cc",
        "libgcc/config/aarch64/t-darwin-no-eh",
        "gcc/config/darwin-ios.h",
        "gcc/config/wasm/wasm-emscripten.h",
        "gcc/config/wasm/wasm-wasi.h",
        "libgcc/config/wasm/int128.c",
        "libgcc/config/wasm/memory.c",
        "libgcc/config/wasm/unwind-abort.c",
        "libstdc++-v3/include/bits/wasm_freestanding_hosted_compat.h"
    })
    managed_toolchains_run_git(git, table.join({"-C", src, "clean", "-fd", "--"}, names), {envs = envs})
end

function managed_toolchains_is_mounted_windows_drive_path(value)
    local text = tostring(value or "")
    if text == "" or not text:match("^/") then
        return false
    end
    if base.host_os() ~= "linux" then
        return false
    end

    if os.iorunv then
        local findmnt = os.iorunv("findmnt", {"-T", text, "-no", "FSTYPE,OPTIONS"}, {try = true})
        if findmnt then
            local lower = tostring(findmnt):lower()
            if lower:find("drvfs", 1, true) then
                return true
            end
            if text:match("^/mnt/%a/") and (lower:find("^%s*9p") or lower:find("^%s*v9fs")) then
                return true
            end
        end

        local stat = os.iorunv("stat", {"-f", "-c", "%T", text}, {try = true})
        if stat then
            local fstype = tostring(stat):lower():gsub("^%s+", ""):gsub("%s+$", "")
            if fstype == "drvfs" then
                return true
            end
            if text:match("^/mnt/%a/") and (fstype == "9p" or fstype == "v9fs") then
                return true
            end
        end
    end

    return false
end

-- Per-directory memoized: signature/stamp checks ask for the revision once
-- per module unit (observed: 400+ identical `git rev-parse HEAD` spawns per
-- wasm build), and the answer only changes when THIS module syncs the tree
-- (sync_gcc_git_source drops the entry below).
local source_revision_cache = {}

-- Short repository probes (rev-parse and friends) run at every build
-- startup, and the process-wait layer can lose a child's exit notification
-- (observed live 2026-08-08: git long exited, the waiting xmake asleep at
-- zero CPU forever). Timer wakeups travel a different scheduler channel
-- than process events, so a generous timeout plus one retry turns that
-- freeze into a bounded self-heal. Transfers (clone/fetch/bundle) keep
-- unbounded time: minutes-long runs are legitimate there, and this wrapper
-- must never cover them.
local MANAGED_TOOLCHAINS_GIT_PROBE_TIMEOUT_MS = 60000

function managed_toolchains_probe_git(git, args, opt)
    opt = opt or {}
    local timeout = opt.timeout or MANAGED_TOOLCHAINS_GIT_PROBE_TIMEOUT_MS
    local ok, output = managed_toolchains_run_git(git, args,
        {envs = opt.envs, try = true, timeout = timeout})
    if not ok then
        errors.warn("git probe did not complete (failure or lost process-exit wakeup); retrying once: git %s",
            table.concat(args, " "))
        ok, output = managed_toolchains_run_git(git, args,
            {envs = opt.envs, try = true, timeout = timeout})
    end
    return ok, output
end

-- Resolve a checkout's HEAD commit by reading the repository files instead of
-- spawning `git rev-parse`. Every managed source tree is checked out detached
-- (`checkout --force FETCH_HEAD`), so .git/HEAD holds the raw commit and this
-- is a single file read; symbolic HEADs resolve through the loose ref and then
-- packed-refs. Returns nil when the layout is anything else, leaving the git
-- fallback in charge.
--
-- Why read files instead of asking git: the revision is queried many times per
-- build (source identity, stamps, configure signatures), and each query used to
-- spawn a process for what is one small read. Avoiding the spawn also keeps
-- these probes clear of the lost-child-exit-notification defect in xmake 3.0.9
-- and older, where a short-lived child's exit wakeup can go missing and the
-- build then sleeps forever at zero CPU (observed 2026-08-11 on a host still
-- running 3.0.9; hosts on 3.1.0+ do not show it).
function managed_toolchains_read_git_head(src)
    local gitdir = path.join(src, ".git")
    if not os.isdir(gitdir) then
        return nil
    end
    -- io.readfile raises on a missing file, so every read here is gated
    local headfile = path.join(gitdir, "HEAD")
    if not os.isfile(headfile) then
        return nil
    end
    local head = base.trim(io.readfile(headfile) or "")
    local commit = head:match("^(%x+)$")
    if commit and #commit == 40 then
        return commit
    end
    local ref = head:match("^ref:%s+(%S+)$")
    if not ref then
        return nil
    end
    -- ref is a slash-separated git path; file APIs accept it verbatim on every host
    local loosefile = path.join(gitdir, ref)
    if os.isfile(loosefile) then
        commit = base.trim(io.readfile(loosefile) or ""):match("^(%x+)$")
        if commit and #commit == 40 then
            return commit
        end
    end
    local packedfile = path.join(gitdir, "packed-refs")
    if os.isfile(packedfile) then
        for line in (io.readfile(packedfile) or ""):gmatch("[^\r\n]+") do
            local packed_commit, packed_ref = line:match("^(%x+)%s+(%S+)$")
            if packed_ref == ref and #packed_commit == 40 then
                return packed_commit
            end
        end
    end
    return nil
end

function managed_toolchains_gcc_source_revision(src)
    local key = path.absolute(src)
    local cached = source_revision_cache[key]
    if cached ~= nil then
        return cached
    end
    local revision = managed_toolchains_read_git_head(src) or ""
    if revision == "" and os.isdir(path.join(src, ".git")) then
        local git = managed_toolchains_preferred_git()
        local ok, output = managed_toolchains_probe_git(git, {"-C", src, "rev-parse", "HEAD"}, {envs = envs.proxy_envs()})
        if ok then
            revision = base.trim(output or "")
        end
    end
    source_revision_cache[key] = revision
    return revision
end

function managed_toolchains_forget_gcc_source_revision(src)
    source_revision_cache[path.absolute(src)] = nil
end

-- Offline source insurance: a git bundle created from a synced tree lets any
-- host recreate the exact pinned checkout with no remote available -- the
-- durable escape when a rebased upstream branch drops the pinned revision.
-- Bundles are keyed by cache name + revision, so a stale bundle can never be
-- silently substituted for a different pin.
-- Bundles are looked up in the machine-local cache first and in the
-- repository's shipped seed directory second. The seed copy is what makes a
-- pin restorable on a fresh checkout with nothing pre-seeded: the lines whose
-- pins exist on no public remote ride along in git (thin, see the
-- wasm_gcc_base_ref note in core/modules/defaults.lua). The cache still wins
-- when both exist, so a locally regenerated bundle overrides the shipped one
-- without touching the working tree.
function managed_toolchains_source_bundle_file(cache_name, revision)
    local leaf = cache_name .. "-" .. revision .. ".bundle"
    local cached = path.join(layout.bundles_cache_dir(), leaf)
    if os.isfile(cached) then
        return cached
    end
    local seeded = path.join(os.scriptdir(), "..", "bundles", leaf)
    if os.isfile(seeded) then
        return path.absolute(seeded)
    end
    return cached
end

-- The managed source trees are shallow, so a bundle carries a boundary
-- commit without its parents. Restoring must mark that commit shallow
-- BEFORE fetching: without the marker git traverses toward the missing
-- parents and rejects the bundle with "did not send all necessary objects"
-- (both directions verified empirically, 2026-07-17).
local function managed_toolchains_mark_shallow_boundary(src, revision)
    local shallow = path.join(src, ".git", "shallow")
    local content = os.isfile(shallow) and (io.readfile(shallow) or "") or ""
    if content:find(revision, 1, true) then
        return
    end
    if content ~= "" and not content:match("\n$") then
        content = content .. "\n"
    end
    io.writefile(shallow, content .. revision .. "\n")
end

-- base_ref, when given, means the bundle is THIN: it packs only base..pin and
-- git will refuse it ("did not send all necessary objects") unless the base
-- object is already present. So the base is shallow-fetched from the remote
-- first -- which also plants the shallow boundary, and is why the tip must NOT
-- be marked shallow in that case: doing so would declare the pinned commit
-- parentless and orphan the very commits the bundle just supplied.
function managed_toolchains_restore_source_from_bundle(git, src, cache_name, ref, envs, base_ref)
    local bundle = managed_toolchains_source_bundle_file(cache_name, ref)
    if not os.isfile(bundle) then
        return false
    end
    print("restoring source from local bundle: " .. bundle)
    if base_ref and base_ref ~= "" then
        if not managed_toolchains_run_git(git,
                {"-C", src, "fetch", "--depth=1", "origin", base_ref, "--no-tags"},
                {envs = envs, try = true}) then
            errors.warn("cannot fetch the bundle's base commit %s, so the thin bundle cannot be applied: %s",
                base_ref, bundle)
            return false
        end
    else
        managed_toolchains_mark_shallow_boundary(src, ref)
    end
    local ok = managed_toolchains_run_git(git, {"-C", src, "fetch", bundle, "HEAD", "--no-tags"}, {envs = envs, try = true})
    if not ok then
        errors.warn("local source bundle could not be read; falling back to a normal fetch: %s", bundle)
        return false
    end
    return true
end

function create_gcc_source_bundle(target_os)
    local source = settings.gcc_source_profile(target_os)
    local src = settings.gcc_source_dir(target_os)
    if not os.isdir(path.join(src, ".git")) then
        errors.fail("no synced GCC source tree to bundle; run `xmake toolchains fetch %s` first", tostring(target_os))
    end
    local git = managed_toolchains_preferred_git()
    local revision = managed_toolchains_gcc_source_revision(src)
    if revision == "" then
        errors.fail("cannot determine the GCC source revision to bundle: %s", src)
    end
    if revision:lower() ~= tostring(source.ref):lower() then
        errors.warn("bundling revision %s while the configured ref is %s; fresh syncs only consume a bundle matching their pinned ref",
            revision:sub(1, 12), tostring(source.ref))
    end
    local bundle = managed_toolchains_source_bundle_file(source.cache_name, revision)
    os.mkdir(path.directory(bundle))
    local tmp = layout.unique_cache_path(bundle, "bundles")
    os.mkdir(path.directory(tmp))
    managed_toolchains_run_git(git, {"-C", src, "bundle", "create", tmp, "HEAD"}, {envs = envs.proxy_envs()})
    if os.isfile(bundle) then
        os.rm(bundle)
    end
    os.mv(tmp, bundle)
    print("created source bundle: " .. bundle)
    print("fresh syncs of this pinned revision now restore from the bundle before trying any remote")
    return bundle
end

-- After an explicit `update` of a profile pinned from a rebased upstream
-- line, report where that line has moved. The pin never follows
-- automatically; bumps stay a deliberate, validated decision.
function report_tracking_branch_drift(target_os)
    local source = settings.gcc_source_profile(target_os)
    local branch = source.tracking_branch
    local pinned = #tostring(source.ref) == 40 and tostring(source.ref):match("^[0-9a-fA-F]+$") ~= nil
    if not branch or not pinned then
        return
    end
    local src = settings.gcc_source_dir(target_os)
    if not os.isdir(path.join(src, ".git")) then
        return
    end
    local git = managed_toolchains_preferred_git()
    local ok, output = managed_toolchains_run_git(git,
        {"-C", src, "ls-remote", "origin", "refs/heads/" .. branch}, {envs = envs.proxy_envs(), try = true})
    local tip = ok and tostring(output or ""):match("^(%x+)") or nil
    if not tip or #tip ~= 40 then
        errors.warn("could not resolve the upstream tracking branch %s; the pinned revision stays %s", branch, source.ref:sub(1, 12))
        return
    end
    if tip:lower() == source.ref:lower() then
        print(string.format("upstream %s still points at the pinned revision %s", branch, source.ref:sub(1, 12)))
        return
    end
    print(string.format("upstream %s has moved to %s (pinned revision: %s)", branch, tip:sub(1, 12), source.ref:sub(1, 12)))
    print("the pin does not follow automatically: validate the new revision end-to-end first, then")
    print("update the pinned ref in core/modules/defaults.lua and languages/cpp/options.lua together")
end

function sync_gcc_git_source(target_os, force, refresh)
    local source = settings.gcc_source_profile(target_os)
    local url = source.url
    local ref = source.ref
    local pinned_commit = #ref == 40 and ref:match("^[0-9a-fA-F]+$") ~= nil
    local src = settings.gcc_source_dir(target_os)
    local stamp = path.join(src, ".xmake-source")
    local source_signature = "profile=" .. source.name .. "\nurl=" .. url .. "\nref=" .. ref .. "\n"
    local git = managed_toolchains_preferred_git()
    if os.isdir(path.join(src, ".git")) then
        managed_toolchains_configure_gcc_git_text_checkout(git, src, envs.proxy_envs())
    end
    if not force and not refresh and os.isfile(path.join(src, "configure")) and os.isfile(stamp) then
        local stamp_content = io.readfile(stamp) or ""
        local actual_revision = managed_toolchains_gcc_source_revision(src)
        local stamped_revision = stamp_content:match("\nrevision=([^\r\n]+)") or ""
        if stamp_content:sub(1, #source_signature) == source_signature
            and actual_revision ~= ""
            and stamped_revision == actual_revision
            and (not pinned_commit or actual_revision == ref) then
            return src
        end
        errors.warn("cached GCC source identity does not match its source stamp; resynchronizing %s", src)
    end

    if force and os.isdir(src) and not os.isdir(path.join(src, ".git")) then
        layout.remove_toolchains_path(src)
    end

    if not os.isdir(path.join(src, ".git")) then
        layout.remove_toolchains_path(src)
        os.mkdir(src)
        -- Prefer a direct shallow `git clone` for the very first sync over
        -- `git init` + `remote add` + `fetch --depth=1`: fetching into an
        -- already-initialized EMPTY repo skips git/GitHub's server-optimized
        -- shallow-clone fast path. Empirically (2026-07-09, verified on a
        -- macOS host with otherwise fast, healthy network to github.com --
        -- a plain HTTPS HEAD request and a standalone `git clone` both
        -- succeeded quickly): `git init` + `fetch --depth=1` of this
        -- multi-hundred-MB repo stalled and was disconnected mid-transfer
        -- after 9-14 minutes, reproducibly, on both HTTP/2 and forced
        -- HTTP/1.1 (`curl 92 ... stream ... CANCEL` / `curl 18 transfer
        -- closed with outstanding read data remaining`). A plain
        -- `git clone --depth=1` of the identical repo and ref completed in
        -- about 35 seconds. --no-checkout defers populating the working
        -- tree so the LF-checkout config below still applies before any
        -- files are written. Falls back to the proven init+fetch path
        -- (with its own retry/unshallow logic) if the configured ref isn't
        -- a resolvable branch/tag name (e.g. a raw commit SHA) or the clone
        -- fails for any other reason.
        local cloned = false
        if not pinned_commit then
            print("cloning GCC git source: " .. url)
            cloned = managed_toolchains_run_git(git,
                {"clone", "--depth=1", "--no-tags", "--no-checkout", "--branch", ref, url, src},
                {envs = envs.proxy_envs(), try = true})
        end
        if not cloned then
            if pinned_commit then
                print("GCC source is pinned to a commit; using init+fetch instead of an invalid --branch clone")
            else
                print("shallow branch clone did not succeed; falling back to init+fetch")
            end
            layout.remove_toolchains_path(src)
            os.mkdir(src)
            print("initializing GCC git source: " .. url)
            managed_toolchains_run_git(git, {"-C", src, "init"}, {envs = envs.proxy_envs()})
        end
        managed_toolchains_configure_gcc_git_text_checkout(git, src, envs.proxy_envs())
    end
    managed_toolchains_configure_gcc_git_text_checkout(git, src, envs.proxy_envs())
    -- a fresh clone/init may shadow an earlier memoized "" (no tree yet)
    managed_toolchains_forget_gcc_source_revision(src)

    print("configuring GCC git remote: " .. url)
    local git_config = path.join(src, ".git", "config")
    local has_origin = os.isfile(git_config) and io.readfile(git_config):find('%[remote "origin"%]', 1, false)
    if has_origin then
        managed_toolchains_run_git(git, {"-C", src, "remote", "set-url", "origin", url}, {envs = envs.proxy_envs()})
    else
        managed_toolchains_run_git(git, {"-C", src, "remote", "add", "origin", url}, {envs = envs.proxy_envs()})
    end

    -- A local bundle of the exact pinned revision short-circuits the remote
    -- fetch entirely: it is both the offline path and the recovery path when
    -- a rebased upstream branch no longer carries the pinned commit.
    local restored_from_bundle = pinned_commit
        and managed_toolchains_restore_source_from_bundle(git, src, source.cache_name, ref,
            envs.proxy_envs(), source.base_ref)
    local fetched_with_blob_filter = false
    if not restored_from_bundle then
        print("fetching GCC ref with git: " .. ref)
        -- A pinned commit has no cloneable branch name. Linux prefers one complete
        -- shallow pack because it avoids checkout-time promisor requests. The
        -- Sourceware HTTPS endpoint has repeatedly closed that large response five
        -- bytes early on Windows and through the required macOS proxy, so those
        -- hosts use the server's blob-filtered transport and materialize the tree
        -- during the retried checkout instead.
        local wasm_pinned_commit = source.name == "wasm-experimental" and pinned_commit
        local filter_blobs = source.name == "wasm-experimental"
            and (not pinned_commit or base.host_os() ~= "linux")
        local fallback_filter_blobs = wasm_pinned_commit and not filter_blobs
        local _
        _, fetched_with_blob_filter = managed_toolchains_fetch_gcc_ref(git, src, ref,
            envs.proxy_envs(), filter_blobs, fallback_filter_blobs)
    end
    managed_toolchains_run_git(git, {
        "-C", src, "update-ref", "refs/xmake/gcc-source", "FETCH_HEAD"
    }, {envs = envs.proxy_envs()})
    if fetched_with_blob_filter then
        managed_toolchains_materialize_gcc_objects(git, src, envs.proxy_envs())
    end
    if refresh and not force then
        local current_revision = managed_toolchains_gcc_source_revision(src)
        local ok, fetched_revision = managed_toolchains_run_git(git, {"-C", src, "rev-parse", "FETCH_HEAD"}, {envs = envs.proxy_envs(), try = true})
        fetched_revision = ok and base.trim(fetched_revision or "") or ""
        if current_revision ~= "" and fetched_revision ~= "" and current_revision == fetched_revision then
            print("GCC source is already at fetched revision: " .. current_revision:sub(1, 12) .. "; refreshing the working tree")
        end
    end
    managed_toolchains_clean_gcc_source_update_artifacts(git, src, envs.proxy_envs())
    managed_toolchains_checkout_gcc_source(git, src, envs.proxy_envs())
    if force then
        managed_toolchains_run_git(git, {"-C", src, "clean", "-xfd"}, {envs = envs.proxy_envs()})
    end
    if not os.isfile(path.join(src, "configure")) or not os.isdir(path.join(src, "gcc")) then
        errors.fail("GCC git checkout did not contain a GCC source tree")
    end
    local revision = managed_toolchains_gcc_source_revision(src)
    if #ref == 40 and ref:match("^[0-9a-fA-F]+$") and revision ~= ref then
        errors.fail("GCC checkout revision mismatch: expected %s, got %s", ref, revision)
    end
    io.writefile(stamp, source_signature .. "revision=" .. revision .. "\n")
    return src
end

local function find_extracted_autotools_source(outputdir)
    if os.isfile(path.join(outputdir, "configure")) and os.isfile(path.join(outputdir, "Makefile.in")) then
        return outputdir
    end
    for _, dir in ipairs(os.dirs(path.join(outputdir, "*"))) do
        if os.isfile(path.join(dir, "configure")) and os.isfile(path.join(dir, "Makefile.in")) then
            return dir
        end
    end
    errors.fail("downloaded archive did not contain a configure-based source tree")
end

local function ensure_project_autotool(name, default_url, executable, configure_args, envs_extra)
    if base.is_windows_host() then
        return
    end

    local prefix = path.join(layout.tools_cache_dir(), name)
    local program = path.join(prefix, "bin", executable)
    if os.isfile(program) then
        return program
    end

    local url = default_url
    local cache = layout.download_cache_dir()
    local archive = path.join(cache, archive_leaf_name(url, name .. ".tar.gz"))
    local extracted = layout.extract_cache_dir(name .. "-source")
    local build = path.join(layout.toolchains_cache_dir(base.host_os()), "build", "tools", name)

    layout.remove_toolchains_path(extracted)
    layout.remove_toolchains_path(build)
    os.mkdir(build)
    download.download_and_extract_archive(url, archive, extracted, false)

    local source = find_extracted_autotools_source(extracted)
    local relsrc = path.relative(source, build)
    local args = {
        "--prefix=" .. base.shpath(prefix),
        "--disable-shared"
    }
    if configure_args then
        for _, arg in ipairs(configure_args) do
            table.insert(args, arg)
        end
    end

    local build_envs = envs.shell_envs()
    if envs_extra then
        for key, value in pairs(envs_extra) do
            build_envs[key] = value
        end
    end

    print("building project-local " .. name)
    run_script(path.join(relsrc, "configure"), args, {curdir = build, envs = build_envs})
    if name == "m4" then
        local config_h = path.join(build, "lib", "config.h")
        if os.isfile(config_h) then
            local content = io.readfile(config_h)
            local patched = content:gsub("# define _GL_ATTRIBUTE_NODISCARD %[%[__nodiscard__%]%]", "# define _GL_ATTRIBUTE_NODISCARD")
            if patched ~= content then
                print("patching project-local m4: disable C nodiscard attribute for GCC")
                base.writefile_bytes(config_h, patched)
            end
        end
    end
    makerunner.run_make_target(settings.value_or("toolchains_make", "make"), build, build_envs, "")
    makerunner.run_make_target(settings.value_or("toolchains_make", "make"), build, build_envs, "install")

    if not os.isfile(program) then
        errors.fail("failed to install project-local %s at %s", name, program)
    end

    layout.remove_toolchains_path(extracted)
    return program
end

local ensure_windows_generator_tools

local function ensure_unix_generator_tools()
    if base.is_windows_host() then
        return
    end

    local m4 = hosttools.find_tool_path("m4")
    if not m4 then
        m4 = ensure_project_autotool("m4", defaults.m4_url, "m4")
    end

    local flex = hosttools.find_tool_path("flex")
    if not flex then
        flex = ensure_project_autotool("flex", defaults.flex_url, "flex", nil, {M4 = m4})
    end
    return flex
end

function ensure_generator_tools()
    ensure_windows_generator_tools()
    ensure_unix_generator_tools()
end

function ensure_windows_generator_tools()
    if not base.is_windows_host() then
        return
    end

    local existing_flex = hosttools.find_tool_path("flex") or hosttools.find_tool_path("win_flex")
    local existing_bison = hosttools.find_tool_path("bison") or hosttools.find_tool_path("win_bison")
    if existing_flex and existing_bison then
        print("using existing Windows generator tools: " .. existing_flex .. ", " .. existing_bison)
        return
    end

    local dir = path.join(layout.tools_cache_dir(), "winflexbison")
    local flex = path.join(dir, base.exe("win_flex"))
    local bison = path.join(dir, base.exe("win_bison"))
    if os.isfile(flex) and os.isfile(bison) then
        return
    end

    local auto_install = tostring(settings.value_or("toolchains_auto_install_tools", "true")):lower()
    local package_manager = tostring(settings.value_or("toolchains_package_manager", "auto")):lower()
    if auto_install ~= "false" and auto_install ~= "0" and auto_install ~= "off" and auto_install ~= "no"
        and (package_manager == "auto" or package_manager == "scoop") then
        local scoop = hosttools.find_tool_path("scoop.cmd") or hosttools.find_tool_path("scoop")
        if scoop then
            local package = defaults.winflexbison_package
            print("Windows generator tools are missing; trying user-level Scoop package: " .. package)
            os.vrunv(scoop, {"install", package}, {envs = envs.proxy_envs(), try = true})
            existing_flex = hosttools.find_tool_path("flex") or hosttools.find_tool_path("win_flex")
            existing_bison = hosttools.find_tool_path("bison") or hosttools.find_tool_path("win_bison")
            if existing_flex and existing_bison then
                print("using Scoop generator tools: " .. existing_flex .. ", " .. existing_bison)
                return
            end
            print("Scoop did not provide usable flex/bison; falling back to project-local winflexbison download")
        elseif package_manager == "scoop" then
            print("Scoop was requested for helper tools, but scoop was not found in PATH")
        end
    end

    local cache = layout.download_cache_dir()
    local url = defaults.winflexbison_url
    local archive = path.join(cache, archive_leaf_name(url, "winflexbison.zip"))
    local extracted = layout.extract_cache_dir("winflexbison")
    layout.remove_toolchains_path(dir)
    os.mkdir(dir)
    download.download_and_extract_archive(url, archive, extracted, false)
    os.cp(path.join(extracted, "*"), dir)
    if not os.isfile(flex) then
        errors.fail("win_flex was not found in downloaded winflexbison archive")
    end
    if not os.isfile(bison) then
        errors.fail("win_bison was not found in downloaded winflexbison archive")
    end
    layout.remove_toolchains_path(extracted)
end

function ensure_gcc_generated_sources(src)
    local generated = path.join(src, "gcc", "gengtype-lex.cc")

    local function ensure_gengtype_lexer_wrapper(file)
        local content = io.readfile(file)
        if content:find('#include "system.h"', 1, true) then
            return
        end
        print("patching GCC gengtype lexer wrapper: " .. path.relative(file, src))
        io.writefile(file, table.concat({
            "#ifdef HOST_GENERATOR_FILE",
            '#include "config.h"',
            "#else",
            '#include "bconfig.h"',
            "#endif",
            "#define FLEX_SCANNER",
            '#include "system.h"',
            "#undef FLEX_SCANNER",
            ""
        }, "\n") .. content)
    end

    if os.isfile(generated) then
        ensure_gengtype_lexer_wrapper(generated)
        return
    end

    local lexer = path.join(src, "gcc", "gengtype-lex.l")
    local flex = hosttools.find_tool_path("flex") or hosttools.find_tool_path("win_flex")
    if flex and os.isfile(lexer) then
        print("generating GCC gengtype lexer with: " .. flex)
        run.run_program("generating GCC gengtype lexer", flex, {"-o" .. base.shpath(generated), base.shpath(lexer)}, {envs = envs.make_envs(), target_os = settings.configured_target_os()})
    end
    if os.isfile(generated) then
        ensure_gengtype_lexer_wrapper(generated)
        return
    end

    local candidates = os.files(path.join(layout.toolchains_cache_root(), "*", "build", "*", "gcc", "gcc", "gengtype-lex.cc"))
    if #candidates > 0 then
        print("restoring GCC generated gengtype lexer from: " .. candidates[1])
        os.cp(candidates[1], generated)
        ensure_gengtype_lexer_wrapper(generated)
        return
    end

    errors.fail("GCC mainline source is missing gcc/gengtype-lex.cc; install flex or allow xmake to bootstrap project-local generator tools")
end

function sync_gcc_generated_sources_to_build(src, build)
    local source = path.join(src, "gcc", "gengtype-lex.cc")
    local target = path.join(build, "gcc", "gengtype-lex.cc")
    if not os.isfile(source) or not os.isdir(path.directory(target)) then
        return
    end

    local content = io.readfile(source)
    if not content then
        return
    end

    if os.isfile(target) and io.readfile(target) == content then
        return
    end

    print("syncing GCC generated gengtype lexer to build tree: " .. target)
    base.writefile_bytes(target, content)
end

local function managed_toolchains_gcc_prerequisite_package_name(archive)
    return (tostring(archive):gsub("%.tar%.gz$", ""):gsub("%.tar%.bz2$", ""):gsub("%.tar%.xz$", ""):gsub("%.tgz$", ""))
end

local function managed_toolchains_gcc_prerequisite_link_name(package)
    return (tostring(package):gsub("%-.*$", ""))
end

local function managed_toolchains_gcc_prerequisite_marker_text(archive)
    return tostring(archive) .. "\nstaging=preserve-mtime-v1\n"
end

local function managed_toolchains_gcc_prerequisite_marker_matches(file, archive)
    if not os.isfile(file) then
        return false
    end
    return (io.readfile(file) or "") == managed_toolchains_gcc_prerequisite_marker_text(archive)
end

local function managed_toolchains_gcc_prerequisite_checksum_line(src, archive)
    local checksum_file = path.join(src, "contrib", "prerequisites.sha512")
    if not os.isfile(checksum_file) then
        errors.fail("GCC prerequisite checksum file is missing: %s", checksum_file)
    end
    local escaped = base.escape_pattern(tostring(archive))
    for line in (io.readfile(checksum_file) or ""):gmatch("[^\r\n]+") do
        -- "%s*$" with zero repetitions already covers the bare "$" case.
        if line:match("%s" .. escaped .. "%s*$") then
            return line
        end
    end
    errors.fail("GCC prerequisite checksum line is missing for %s in %s", archive, checksum_file)
end

local function managed_toolchains_gcc_prerequisites_from_source(src)
    local file = path.join(src, "contrib", "download_prerequisites")
    if not os.isfile(file) then
        errors.fail("GCC prerequisite script is missing: %s", file)
    end

    local content = io.readfile(file) or ""
    local names = {"gettext", "gmp", "mpfr", "mpc", "isl"}
    local archives = {}
    for _, name in ipairs(names) do
        local escaped = base.escape_pattern(name)
        local archive = content:match("[\r\n]" .. escaped .. "%s*=%s*'([^']+)'")
            or content:match("[\r\n]" .. escaped .. '%s*=%s*"([^"]+)"')
        if not archive or archive == "" then
            errors.fail("GCC prerequisite archive variable is missing in %s: %s", file, name)
        end
        table.insert(archives, archive)
    end
    return archives
end

local function managed_toolchains_verify_gcc_prerequisite_archive(src, archive)
    archive = base.trim(tostring(archive))
    if archive:find("[\r\n]") then
        errors.fail("GCC prerequisite archive name contains a newline: %s", archive)
    end
    local checksum = managed_toolchains_gcc_prerequisite_checksum_line(src, archive)
    local expected = tostring(checksum):match("^%s*([0-9a-fA-F]+)")
    if not expected or expected == "" then
        errors.fail("GCC prerequisite checksum entry is malformed for %s", archive)
    end
    local archive_path = path.join(src, archive)
    if not os.isfile(archive_path) then
        errors.fail("GCC prerequisite archive is missing before verification: %s", archive_path)
    end
    local checkfile = path.join(layout.toolchains_cache_dir(base.host_os()), "checksums", archive .. ".sha512")
    layout.remove_toolchains_path(checkfile)
    os.mkdir(path.directory(checkfile))
    base.writefile_bytes(checkfile, expected .. "  " .. archive .. "\n")
    local sha512sum = hosttools.preferred_host_tool("sha512sum")
    run.run_program("verifying GCC prerequisite " .. archive, sha512sum, {"-c", base.shpath(checkfile)}, {curdir = src, envs = envs.shell_envs(), target_os = settings.configured_target_os()})
end

local function managed_toolchains_find_extracted_prerequisite_source(outputdir, package)
    local direct = path.join(outputdir, package)
    if os.isdir(direct) then
        return direct
    end
    for _, dir in ipairs(os.dirs(path.join(outputdir, "*"))) do
        if path.filename(dir) == package then
            return dir
        end
    end
    for _, dir in ipairs(os.dirs(path.join(outputdir, "*"))) do
        if os.isfile(path.join(dir, "configure")) or os.isfile(path.join(dir, "config.guess")) or os.isdir(path.join(dir, "src")) then
            return dir
        end
    end
    errors.fail("GCC prerequisite archive did not contain the expected package directory: %s", package)
end

local function managed_toolchains_copy_gcc_prerequisite_dir(source, target, marker_text)
    layout.remove_toolchains_path(target)
    os.mkdir(target)

    local tar = hosttools.preferred_host_tool("tar")
    local script = "cd " .. base.shquote(source) .. " && " .. base.shquote(tar) .. " -cf - . | "
        .. "(cd " .. base.shquote(target) .. " && " .. base.shquote(tar) .. " -xf -)"
    local copied = errors.trycall(function ()
        run.execv(hosttools.preferred_posix_shell(), {"-c", script}, {envs = envs.shell_envs(), target_os = settings.configured_target_os()})
        return true
    end)
    if not copied then
        errors.warn("timestamp-preserving prerequisite copy failed; falling back to xmake copy and generated timestamp refresh")
        layout.remove_toolchains_path(target)
        os.mkdir(target)
        os.cp(path.join(source, "*"), target)
    end

    if marker_text then
        base.writefile_bytes(path.join(target, ".xmake-prerequisite"), marker_text)
    end
end

local function managed_toolchains_refresh_gcc_prerequisite_generated_timestamps(root, label)
    if not os.isdir(root) then
        return
    end

    local touch = hosttools.preferred_host_tool("touch")
    local touched = 0
    local seen = {}
    local function touch_file(file)
        if not os.isfile(file) or seen[file] then
            return
        end
        seen[file] = true
        os.vrunv(touch, {"-c", base.is_windows_host() and base.shpath(file) or file})
        touched = touched + 1
    end
    local function touch_named(name)
        touch_file(path.join(root, name))
    end
    local function touch_pattern(pattern)
        for _, file in ipairs(os.files(path.join(root, pattern))) do
            touch_file(file)
        end
    end
    local function touch_gperf_outputs()
        for _, file in ipairs(os.files(path.join(root, "*.gperf"))) do
            touch_file((file:gsub("%.gperf$", ".h")))
        end
        for _, file in ipairs(os.files(path.join(root, "**", "*.gperf"))) do
            touch_file((file:gsub("%.gperf$", ".h")))
        end
    end

    touch_named("aclocal.m4")
    touch_pattern("**/aclocal.m4")
    touch_named("configure")
    touch_pattern("**/configure")
    touch_named("config.h.in")
    touch_pattern("*.h.in")
    touch_pattern("**/*.h.in")
    touch_named("Makefile.in")
    touch_pattern("**/Makefile.in")
    touch_gperf_outputs()

    if touched > 0 then
        errors.log(string.format("refreshed GCC prerequisite generated timestamps: %s (%d files)", label, touched))
    end
end

local function repair_gettext_runtime(src)
    local aux = path.join(src, "gettext", "build-aux")
    local runtime = path.join(src, "gettext", "gettext-runtime")
    if not os.isdir(aux) or not os.isdir(runtime) then
        return
    end

    for _, name in ipairs({"config.rpath", "ltmain.sh", "config.guess", "config.sub", "compile", "missing", "install-sh"}) do
        local source = path.join(aux, name)
        local target = path.join(runtime, name)
        if os.isfile(source) and not os.isfile(target) then
            os.cp(source, target)
        end
    end
end

function managed_toolchains_install_gcc_prerequisites(src)
    local base_url = defaults.gcc_prerequisites_base_url:gsub("/+$", "")
    local archives = managed_toolchains_gcc_prerequisites_from_source(src)
    errors.log("installing GCC prerequisites with xmake-managed downloads")
    for _, archive in ipairs(archives) do
        local package = managed_toolchains_gcc_prerequisite_package_name(archive)
        local linkname = managed_toolchains_gcc_prerequisite_link_name(package)
        local archive_path = path.join(src, archive)
        local package_dir = path.join(src, package)
        local link_dir = path.join(src, linkname)
        local marker = path.join(package_dir, ".xmake-prerequisite")
        local marker_text = managed_toolchains_gcc_prerequisite_marker_text(archive)
        local package_staged = false

        if not managed_toolchains_gcc_prerequisite_marker_matches(marker, archive) then
            local extracted = layout.extract_cache_dir(path.join("gcc-prerequisites", package))
            download.download_and_extract_archive(base_url .. "/" .. archive, archive_path, extracted, false, function ()
                managed_toolchains_verify_gcc_prerequisite_archive(src, archive)
            end)
            local source_root = managed_toolchains_find_extracted_prerequisite_source(extracted, package)
            errors.log("staging GCC prerequisite " .. package)
            managed_toolchains_copy_gcc_prerequisite_dir(source_root, package_dir, marker_text)
            layout.remove_toolchains_path(extracted)
            package_staged = true
        else
            errors.log("reusing GCC prerequisite " .. package)
        end
        if package_staged then
            managed_toolchains_refresh_gcc_prerequisite_generated_timestamps(package_dir, package)
        end

        if link_dir ~= package_dir then
            local link_marker = path.join(link_dir, ".xmake-prerequisite")
            local link_staged = false
            if managed_toolchains_gcc_prerequisite_marker_matches(link_marker, archive) then
                errors.log("reusing GCC prerequisite link " .. linkname)
            else
                managed_toolchains_copy_gcc_prerequisite_dir(package_dir, link_dir, marker_text)
                link_staged = true
            end
            if link_staged then
                managed_toolchains_refresh_gcc_prerequisite_generated_timestamps(link_dir, linkname)
            end
        end
    end
    repair_gettext_runtime(src)
end

function patch_gcc_libcody_revision_makefile(file, enabled)
    if not os.isfile(file) then
        return false
    end

    local content = io.readfile(file)
    if not content then
        return false
    end

    local needle = "revision.stamp: $(srcdir)/.\n" ..
        "\t@revision=`git -C $(srcdir) rev-parse HEAD 2>/dev/null` ;\\\n" ..
        "\tif test -n \"$$revision\" ;\\\n" ..
        "\tthen revision=git-$$revision ;\\\n" ..
        "\t  if git -C $(srcdir) status --porcelain 2>/dev/null | grep -vq '^  ' ;\\\n" ..
        "\t  then revision=$${revision}M ;\\\n" ..
        "\t  fi ;\\\n" ..
        "\telse revision=unknown ;\\\n" ..
        "\tfi ;\\\n" ..
        "\techo $$revision > $@\n"
    local replacement = "revision.stamp: $(srcdir)/.\n" ..
        "\t@echo unknown > $@\n"

    if enabled then
        local patched = base.replace_plain(content, needle, replacement)
        if patched ~= content then
            print("patching GCC libcody revision stamp for mounted Windows-drive source tree: avoid build-time git status (" .. file .. ")")
            base.writefile_bytes(file, patched)
            return true
        end

        if content:find("git -C $(srcdir) status --porcelain", 1, true) then
            print("WARNING: GCC libcody revision patch anchor not found (upstream drift): " .. file)
            print("         Mounted Windows-drive source tree builds may hang while libcody scans the full GCC git worktree.")
        end
        return false
    end

    local restored = base.replace_plain(content, replacement, needle)
    if restored ~= content then
        print("restoring GCC libcody revision stamp: keep upstream git revision logic (" .. file .. ")")
        base.writefile_bytes(file, restored)
        return true
    end

    if not content:find("git -C $(srcdir) status --porcelain", 1, true) then
        print("WARNING: GCC libcody revision patch anchor not found (upstream drift): " .. file)
        print("         Builds outside mounted Windows-drive source trees should keep the upstream git revision logic unless a platform-specific patch enables otherwise.")
    end
    return false
end

local function patch_windows_configure_sysroots(src)
    if not base.is_windows_host() then
        return
    end

    for _, file in ipairs(os.files(path.join(src, "**", "configure"))) do
        local content = io.readfile(file)
        if content:find("The sysroot must be an absolute path.", 1, true) then
            local patched = content
            for _, sed in ipairs({"sed", "$SED"}) do
                local needle = " /*)\n   lt_sysroot=`echo \"$with_sysroot\" | " .. sed .. " -e \"$sed_quote_subst\"`\n   ;; #("
                local replacement = " /*|[A-Za-z]:/*)\n   lt_sysroot=`echo \"$with_sysroot\" | " .. sed .. " -e \"$sed_quote_subst\"`\n   ;; #("
                patched = base.replace_plain(patched, needle, replacement)
            end
            if patched ~= content then
                print("patching configure sysroot path check: " .. path.relative(file, src))
                base.writefile_bytes(file, patched)
            end
        end
    end
end

function sync_gcc_source(target_os, download_prerequisites, force, refresh)
    -- Cross-process SOURCE-tree lock: Windows/Linux/Android share the mainline
    -- source tree and macOS/iOS share darwin-arm64, so two targets syncing (git
    -- fetch/checkout + Lua patching) the same tree at once -- or a `toolchains
    -- fetch/update` racing another target's build -- would interleave writes
    -- into one shared tree. Key by the source PROFILE so distinct profiles never
    -- contend. This nests inside build_gcc_for's per-prefix install lock (a
    -- different lock file, always acquired prefix->source, so no deadlock);
    -- fetch/update reach here holding only this lock.
    local source_profile = settings.gcc_source_profile(target_os)
    local source_lock = path.join(layout.toolchains_home(), ".locks",
        "gcc-source-" .. tostring(source_profile.name):gsub("[^%w%-]", "_") .. ".lock")
    return install_lock.guard(source_lock, function ()
    maybe_print_first_source_sync_guide(target_os)
    ensure_build_prerequisites()
    ensure_generator_tools()
    local src = sync_gcc_git_source(target_os, force, refresh)
    if force or refresh then
        layout.remove_toolchains_path(managed_toolchains_gcc_source_patch_marker(src, target_os))
    end
    local legacy_gcc_source = path.join(layout.source_cache_dir(), "gcc-mainline")
    if base.normalized_path(legacy_gcc_source) ~= base.normalized_path(src) and os.isdir(legacy_gcc_source) then
        print("removing legacy host-scoped GCC source cache: " .. legacy_gcc_source)
        layout.remove_toolchains_path(legacy_gcc_source)
    end
    local prerequisites = path.join(src, "contrib", "download_prerequisites")
    if download_prerequisites and os.isfile(prerequisites) then
        managed_toolchains_install_gcc_prerequisites(src)
    end
    local mounted_windows_drive_source = managed_toolchains_is_mounted_windows_drive_path(src)
    -- A stamped tree that still carries every patch fingerprint is final:
    -- skip the re-patch pass entirely (no needless rewrite churn, and
    -- mounted Windows-drive trees keep avoiding redundant cross-host
    -- writes -- this check subsumes the earlier marker-only mounted skip
    -- with a stronger fingerprint probe). Everything else is restored to
    -- the pristine pinned checkout first and re-patched from scratch: the
    -- pending-snapshot layer edits text inside the anchored patches' own
    -- replacement regions, so re-running the families over a final tree
    -- would trip their strict anchor probes, and a stale tree patched in
    -- place could stack states no probe anticipates. git restores tracked
    -- files only; patch-materialized new files are untracked and their
    -- owned writes are content-idempotent.
    local patches_current = os.isfile(managed_toolchains_gcc_source_patch_marker(src, target_os))
        and gccpatches.verify_patched_source(src, target_os)
    if not patches_current and os.isdir(path.join(src, ".git")) then
        errors.log("restoring the pristine GCC source checkout before patching")
        managed_toolchains_run_git(managed_toolchains_preferred_git(),
            {"-C", src, "reset", "--hard"}, {envs = envs.proxy_envs()})
    end
    patch_gcc_libcody_revision_makefile(path.join(src, "libcody", "Makefile.in"), mounted_windows_drive_source)
    errors.log("patching GCC configure metadata")
    patch_windows_configure_sysroots(src)
    errors.log("patching GCC source")
    if patches_current then
        errors.log("GCC source patches are current (stamp marker and fingerprints verified); skipping re-patch")
    else
        gccpatches.patch_gcc_source(src, target_os)
    end
    errors.log("ensuring GCC generated sources")
    ensure_gcc_generated_sources(src)
    end)
end
