-- Host bootstrap toolchain provisioning (C++-specific): w64devkit alias
-- detection and readelf-alias repair, host binutils aliasing into the
-- project-local prefix (Windows and native Linux), managed-tool resolution,
-- and the temporary portable Windows bootstrap toolchain lifecycle
-- (resolve/download/activate/cleanup).

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
local defaults = import("defaults", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")}).values()
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("hosttools", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("run", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("download", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("gccsources")

-- Mirrored option fallbacks. options.lua owns the description-scope
-- originals (option() defaults are evaluated before any module can load, so
-- they cannot move here), and script scope cannot see description globals.
-- `xmake toolchains rebuild` sets this through set_force_private_bootstrap()
-- (previously the description-scope global of the same name) so a clean
-- recompile always uses a reliable project-private bootstrap regardless of
-- the configured provider.
local MANAGED_TOOLCHAINS_FORCE_PRIVATE_BOOTSTRAP

function set_force_private_bootstrap(value)
    MANAGED_TOOLCHAINS_FORCE_PRIVATE_BOOTSTRAP = value
end

function managed_toolchains_is_w64devkit_alias(file)
    if not os.isfile(file) then
        return false
    end
    local leaf = (path.filename(file) or ""):lower()
    local size = os.filesize and os.filesize(file) or 0
    if leaf:find("readelf", 1, true) and size > 0 and size < 65536 then
        return true
    end
    local ok, content = errors.trycall(function ()
        -- Read raw bytes: io.readfile defaults to a text/encoding mode that
        -- inflates and mangles a binary .exe (a 17 KB alias stub reads back as
        -- ~22 KB), so the "w64devkit (alias)" marker was never found. The
        -- triplet drivers then looked like real binaries and were never
        -- replaced, and a private-bootstrap GCC build died at configure with
        -- "cannot execute 'cc1'" (the surviving alias resolves the driver
        -- through PATH, which the build PATH does not satisfy).
        return io.readfile(file, {encoding = "binary"})
    end)
    return ok and content and content:find("w64devkit (alias)", 1, true) ~= nil
end

function repair_windows_readelf_aliases(target_os)
    if target_os ~= "windows" or not base.is_windows_host() then
        return
    end
    local triplet = settings.managed_target(target_os)
    for _, dir in ipairs({
        path.join(settings.gcc_prefix(target_os), "bin"),
        path.join(settings.gcc_sysroot(target_os), "bin")
    }) do
        for _, file in ipairs({
            path.join(dir, base.exe("readelf")),
            path.join(dir, base.exe(triplet .. "-readelf"))
        }) do
            if os.exists(file) and managed_toolchains_is_w64devkit_alias(file) then
                print("removing recursive w64devkit readelf alias: " .. file)
                layout.remove_toolchains_path(file)
            end
        end
    end
end

function ensure_windows_host_binutils_aliases(target_os)
    if target_os ~= "windows" or not base.is_windows_host() then
        return
    end

    local triplet = settings.managed_target(target_os)
    local prefix_bin = path.join(settings.gcc_prefix(target_os), "bin")
    local target_bin = path.join(settings.gcc_sysroot(target_os), "bin")
    repair_windows_readelf_aliases(target_os)
    if not os.isdir(target_bin) then
        return
    end

    os.mkdir(prefix_bin)
    for _, name in ipairs({
        "addr2line", "ar", "as", "dlltool", "ld", "ld.bfd", "nm",
        "objcopy", "objdump", "ranlib", "readelf", "size", "strings",
        "strip", "windmc", "windres"
    }) do
        local source = nil
        for _, candidate in ipairs({
            path.join(target_bin, base.exe(name)),
            path.join(target_bin, base.exe(triplet .. "-" .. name))
        }) do
            if os.isfile(candidate) then
                source = candidate
                break
            end
        end
        if name == "readelf" and source and managed_toolchains_is_w64devkit_alias(source) then
            source = nil
        end
        if name == "readelf" then
            for _, target in ipairs({
                path.join(prefix_bin, base.exe(triplet .. "-" .. name)),
                path.join(prefix_bin, base.exe(name))
            }) do
                if os.exists(target) and managed_toolchains_is_w64devkit_alias(target) then
                    layout.remove_toolchains_path(target)
                end
            end
        end
        if source then
            for _, target in ipairs({
                path.join(prefix_bin, base.exe(triplet .. "-" .. name)),
                path.join(prefix_bin, base.exe(name))
            }) do
                if source ~= target then
                    os.cp(source, target)
                end
            end
        end
    end
end

-- Native Linux builds don't stage a private target sysroot/bin the way
-- Windows does (prepare_windows_target_sysroot copies host MinGW binutils
-- into the sysroot first) -- a native Linux GCC just uses the host's as/ld
-- via PATH during its own build, so nothing ever copies objcopy et al. into
-- the project-local prefix under the triplet-prefixed name managed_tool()
-- looks for. That leaves toolset.objcopy resolved to a non-existent
-- fallback path, only surfacing at actual strip/debug-symbol-split time
-- ("cannot runv(.../x86_64-linux-gnu-objcopy ...), No such file or
-- directory"). Alias the host's own binutils into the prefix bin dir here,
-- mirroring the Windows function above; cross Linux targets are excluded
-- since those build a private binutils from source with the correct
-- foreign-triplet tools already.
function ensure_linux_host_binutils_aliases(target_os)
    if target_os ~= "linux" or base.host_os() ~= "linux" or settings.is_cross_target(target_os) then
        return
    end

    local triplet = settings.managed_target(target_os)
    local prefix_bin = path.join(settings.gcc_prefix(target_os), "bin")
    os.mkdir(prefix_bin)
    for _, name in ipairs({
        "addr2line", "ar", "as", "ld", "ld.bfd", "nm",
        "objcopy", "objdump", "ranlib", "readelf", "size", "strings", "strip"
    }) do
        local source = hosttools.find_tool_path(triplet .. "-" .. name) or hosttools.find_tool_path(name)
        if source then
            for _, target in ipairs({
                path.join(prefix_bin, base.exe(triplet .. "-" .. name)),
                path.join(prefix_bin, base.exe(name))
            }) do
                if source ~= target and not os.isfile(target) then
                    os.cp(source, target)
                end
            end
        end
    end
end

function managed_tool(bindir, triplet, name)
    local prefix = path.directory(bindir)
    local target_bindir = path.join(prefix, triplet, "bin")
    return base.first_existing({
        path.join(bindir, base.exe(triplet .. "-" .. name)),
        path.join(bindir, base.exe(name)),
        path.join(target_bindir, base.exe(triplet .. "-" .. name)),
        path.join(target_bindir, base.exe(name))
    }, path.join(bindir, base.exe(triplet .. "-" .. name)))
end

local function managed_toolchains_windows_bootstrap_asset_pattern()
    local arch = settings.host_arch_folder()
    if arch == "x64" then
        return "w64devkit%-x64%-[^\"%s/\\]+%.7z%.exe"
    elseif arch == "x86" then
        return "w64devkit%-x86%-[^\"%s/\\]+%.7z%.exe"
    end
    errors.fail("no default Windows bootstrap asset is known for host architecture: %s", tostring(arch))
end

local function managed_toolchains_windows_bootstrap_archive_leaf_name(url)
    return gccsources.archive_leaf_name(url, "windows-bootstrap.7z.exe")
end

local function managed_toolchains_resolve_windows_bootstrap_url()
    local configured = base.trim(settings.value_or("toolchains_bootstrap_url", defaults.windows_bootstrap_url or "latest"))
    if configured ~= "" and configured ~= "auto" and configured ~= "latest" then
        return configured
    end

    local metadata = path.join(layout.download_cache_dir(), "w64devkit-latest.json")
    local api = "https://api.github.com/repos/skeeto/w64devkit/releases/latest"
    print("resolving latest Windows bootstrap toolchain from: " .. api)
    local fetched = errors.trycall(function ()
        download.download_file(api, metadata, true)
        return true
    end)
    local content = fetched and (io.readfile(metadata) or "") or ""
    local asset = managed_toolchains_windows_bootstrap_asset_pattern()
    local url = content:match('"browser_download_url"%s*:%s*"(https://github%.com/skeeto/w64devkit/releases/download/[^"]+/' .. asset .. ')"')
    if url and url ~= "" then
        return (url:gsub("\\/", "/"))
    end

    local tag = content:match('"tag_name"%s*:%s*"([^"]+)"')
    if tag and tag ~= "" then
        local version = tag:gsub("^v", "")
        local arch = settings.host_arch_folder()
        if arch == "x64" or arch == "x86" then
            return "https://github.com/skeeto/w64devkit/releases/download/" .. tag .. "/w64devkit-" .. arch .. "-" .. version .. ".7z.exe"
        end
    end

    -- the unauthenticated GitHub API is often rate-limited on CI and shared
    -- IPs; fall back to a pinned known-good release instead of failing
    local fallback = defaults["windows_bootstrap_fallback_url_" .. settings.host_arch_folder()]
    if fallback and fallback ~= "" then
        errors.warn("could not resolve the latest w64devkit release (GitHub API unreachable or rate-limited); using the pinned fallback: %s", fallback)
        return fallback
    end
    errors.fail("could not resolve a matching w64devkit asset from GitHub latest release metadata; set --toolchains_bootstrap_url=<archive-url> to use an explicit portable MinGW archive")
end

local function managed_toolchains_windows_bootstrap_root()
    return path.join(layout.toolchains_cache_dir(base.host_os()), "bootstrap", settings.host_arch_folder())
end

-- Reader-writer guard for the shared Windows bootstrap directory. Every
-- Windows-hosted toolchain build (windows, linux, android, wasm ...) is
-- configured against the same .cache/windows/bootstrap/<arch> tree, and cc1 is
-- located through PATH during configure, so one build may still need the
-- bootstrap long after another has finished. A build that may use the
-- bootstrap holds a SHARED lock for its whole lifetime; cleanup takes an
-- EXCLUSIVE lock and only deletes when no other process still holds the shared
-- lock, so a concurrent build is never robbed of the cc1 it is configuring
-- against. OS advisory locks release on process death, so a crashed build can
-- never wedge the directory. The lockfile is a sibling of the root, so
-- deleting the tree never removes it out from under a concurrent waiter.
function windows_bootstrap_use_lockfile(root)
    return (root or managed_toolchains_windows_bootstrap_root()) .. ".use.lock"
end

local function managed_toolchains_acquire_windows_bootstrap_use_lock()
    local state = hosttools.windows_bootstrap_state()
    if state.use_lock then
        return
    end
    -- The sandbox lock:lock() raises on failure and returns nothing on success,
    -- so a locked handle is only worth keeping when the whole acquire runs
    -- clean. Failing to guard is non-fatal: the build just loses the advisory
    -- concurrency protection, exactly the pre-guard behavior.
    local lockfile = windows_bootstrap_use_lockfile()
    local ok, lock = errors.trycall(function ()
        os.mkdir(path.directory(lockfile))
        local handle = io.openlock(lockfile)
        handle:lock({shared = true})
        return handle
    end)
    if ok and lock then
        hosttools.set_windows_bootstrap_use_lock(lock)
    end
end

-- Drops the shared use-lock when the caller decided NOT to use the managed
-- bootstrap after all (e.g. the auto path found no cached tree and falls back
-- to the host toolchain), so it does not needlessly block another build's
-- cleanup for the rest of this process.
local function managed_toolchains_release_windows_bootstrap_use_lock()
    local state = hosttools.windows_bootstrap_state()
    local lock = state.use_lock
    if not lock then
        return
    end
    hosttools.set_windows_bootstrap_use_lock(nil)
    errors.trycall(function () lock:unlock() end)
    errors.trycall(function () lock:close() end)
end

-- Field failure shape (2026-07-18): the bootstrap gcc/g++ drivers survive on
-- disk while the backend executables are gone -- an interrupted extraction,
-- or an antivirus quarantining cc1/cc1plus (a notorious MinGW false
-- positive). The driver alone still answers -v and -print-sysroot, so every
-- earlier probe passes and configure then dies with the cryptic
-- "cannot execute 'cc1'". Ask the driver itself: -print-prog-name resolves
-- through the driver's own search dirs and echoes the bare name back when
-- nothing was found. Returns the missing backend name and the driver's
-- answer, or nil when everything resolves. opt.resolve/opt.isfile are
-- fixture injection seams.
function bootstrap_backend_missing(gcc, gxx, opt)
    opt = opt or {}
    local resolve = opt.resolve or function (driver, name)
        local ok, out = errors.trycall(function ()
            return os.iorunv(driver, {"-print-prog-name=" .. name})
        end)
        if not ok then
            return nil
        end
        return base.trim(tostring(out or ""))
    end
    local isfile = opt.isfile or os.isfile
    for _, probe in ipairs({{gcc, "cc1"}, {gxx, "cc1plus"}}) do
        local driver, name = probe[1], probe[2]
        if driver then
            local resolved = resolve(driver, name)
            if not resolved or resolved == "" or not resolved:find("[/\\]") or not isfile(resolved) then
                return name, tostring(resolved or "")
            end
        end
    end
end

local function managed_toolchains_windows_bootstrap_bin_is_usable(bindir)
    if not bindir or not os.isdir(bindir) then
        return false
    end
    -- Plain gcc/g++ first: in w64devkit trees those are the real drivers,
    -- while the triplet-prefixed names are alias stubs whose
    -- -print-prog-name introspection answers a bare "cc1" even when the
    -- backend is present (observed with w64devkit 2.8.0) -- probing them
    -- would fail bootstrap_backend_missing below against a perfectly whole
    -- toolchain. The aliases compile fine; the probe just must ask a driver
    -- whose introspection is trustworthy.
    local gcc = path.join(bindir, base.exe("gcc"))
    if not os.isfile(gcc) then
        gcc = path.join(bindir, base.exe(settings.host_triplet() .. "-gcc"))
    end
    local gxx = path.join(bindir, base.exe("g++"))
    if not os.isfile(gxx) then
        gxx = path.join(bindir, base.exe(settings.host_triplet() .. "-g++"))
    end
    if not os.isfile(gcc) or not os.isfile(gxx) then
        return false
    end
    if hosttools.windows_mingw_sysroot_from_compiler(gcc) == nil then
        return false
    end
    local missing_backend, resolved_backend = bootstrap_backend_missing(gcc, gxx)
    if missing_backend then
        errors.warn("Windows bootstrap toolchain at %s is missing its %s backend (the driver resolves it to '%s'). Likely an interrupted extraction or an antivirus quarantine; ignoring this copy so a fresh bootstrap can be provisioned", bindir, missing_backend, resolved_backend)
        return false
    end
    local shell = path.join(bindir, base.exe("sh"))
    return hosttools.compiler_smoke_ok(gcc, gxx, os.isfile(shell) and shell or nil)
end

local function managed_toolchains_find_windows_bootstrap_bin(root)
    if not root or root == "" then
        return nil
    end
    root = path.absolute(root)
    local candidates = {}
    local function add(dir)
        if dir and dir ~= "" then
            table.insert(candidates, dir)
        end
    end
    add(root)
    add(path.join(root, "bin"))
    add(path.join(root, "w64devkit", "bin"))
    for _, child in ipairs(os.dirs(path.join(root, "*"))) do
        add(path.join(child, "bin"))
        add(path.join(child, "w64devkit", "bin"))
    end
    for _, bindir in ipairs(candidates) do
        if managed_toolchains_windows_bootstrap_bin_is_usable(bindir) then
            return hosttools.windows_short_path(path.absolute(bindir))
        end
    end
end

local function managed_toolchains_prepare_windows_bootstrap_aliases(bindir)
    if not base.is_windows_host() or not bindir or bindir == "" then
        return
    end
    local awk = path.join(bindir, base.exe("awk"))
    local gawk = path.join(bindir, base.exe("gawk"))
    if os.isfile(awk) and not os.isfile(gawk) then
        os.cp(awk, gawk)
    end
    -- w64devkit's triplet-prefixed tools are tiny alias launchers that resolve
    -- a same-named binary through PATH and run it with the alias path as
    -- argv[0]. When the installed project toolchain's bin directory precedes
    -- the bootstrap bin on the build PATH (as during a rebuild of an already
    -- installed toolchain), the alias starts the *project* gcc, which then
    -- self-locates via argv[0] into the bootstrap tree and cannot find a cc1
    -- of its own version: "fatal error: cannot execute 'cc1'". Replace the
    -- alias stubs with copies of the real bootstrap binaries so they always
    -- self-locate inside the bootstrap tree, independent of PATH order.
    for _, file in ipairs(os.files(path.join(bindir, settings.host_triplet() .. "-*" .. (base.is_windows_host() and ".exe" or "")))) do
        local leaf = path.filename(file)
        local plain_name = leaf:sub(#settings.host_triplet() + 2)
        local plain = path.join(bindir, plain_name)
        if os.isfile(plain) and managed_toolchains_is_w64devkit_alias(file)
            and not managed_toolchains_is_w64devkit_alias(plain) then
            print("replacing w64devkit PATH-resolving alias with real binary: " .. leaf)
            os.cp(plain, file)
        end
    end
end

local function managed_toolchains_activate_windows_bootstrap_bin(bindir, cleanup_root, cleanup_archive)
    bindir = hosttools.windows_short_path(path.absolute(bindir))
    managed_toolchains_prepare_windows_bootstrap_aliases(bindir)
    hosttools.set_windows_bootstrap_active_bin(bindir)
    hosttools.set_windows_bootstrap_cleanup(cleanup_root, cleanup_archive)
    hosttools.invalidate_windows_host_info()
    if os.setenv then
        local old = os.getenv("PATH") or ""
        local key = bindir:gsub("\\", "/"):lower()
        local found = false
        for _, dir in ipairs(old:split(base.pathsep(), {plain = true})) do
            if dir:gsub("\\", "/"):lower() == key then
                found = true
                break
            end
        end
        if not found then
            os.setenv("PATH", bindir .. base.pathsep() .. old)
        end
    end
    print("using temporary Windows bootstrap toolchain: " .. bindir)
end

local function managed_toolchains_windows_host_bootstrap_needed()
    if not base.is_windows_host() then
        return false
    end
    if not hosttools.windows_host_sysroot() then
        local rejected = hosttools.windows_host_info().smoke_rejected
        if rejected then
            return true, "a working MinGW host compiler (PATH candidate failed the compile smoke test: " .. rejected .. ")"
        end
        return true, "complete MinGW-w64 sysroot"
    end
    for _, check in ipairs({
        {"MinGW GCC", {settings.host_triplet() .. "-gcc", "gcc"}},
        {"MinGW G++", {settings.host_triplet() .. "-g++", "g++"}},
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
        {"sort", {"sort"}}
    }) do
        if not hosttools.tool_exists_any(check[2]) then
            return true, check[1]
        end
    end
    return false
end

function ensure_windows_host_bootstrap_toolchain(target_os)
    if not base.is_windows_host() then
        return
    end
    local provider = base.trim(settings.value_or("toolchains_bootstrap", "auto")):lower()
    if provider == "" or provider == "true" or provider == "on" then
        provider = "auto"
    elseif provider == "false" or provider == "off" or provider == "0" then
        provider = "none"
    elseif provider == "force" then
        provider = "portable"
    end
    -- `xmake toolchains rebuild` sets this so a clean recompile always uses a
    -- reliable project-private bootstrap regardless of the configured provider.
    if MANAGED_TOOLCHAINS_FORCE_PRIVATE_BOOTSTRAP and (provider == "auto" or provider == "none") then
        provider = "portable"
    end

    local needed, reason = managed_toolchains_windows_host_bootstrap_needed()
    -- provider=portable/path/force provisions and prepends a project-private
    -- bootstrap even when host tools are already on PATH. This is what the GCC
    -- build actually needs: cc1 is located through PATH, so a host MinGW whose
    -- bin directory is not effectively first on the build PATH (e.g. it lives
    -- under a spaced "C:\Program Files\..." path shadowed by other entries)
    -- makes configure fail with "cannot execute 'cc1'". A private bootstrap is
    -- extracted under the space-free .toolchains cache and prepended, so it is
    -- always found. auto keeps the old behavior: provision only when needed.
    local force_bootstrap = (provider == "portable" or provider == "path")
    if not needed and not force_bootstrap then
        -- Prefer an already-provisioned project-private bootstrap over host
        -- tools even when the host looks complete: the private one lives under
        -- a space-free cache path and is what existing build directories were
        -- configured against.
        if provider == "auto" then
            -- Hold the shared use-lock ACROSS find+activate so a concurrent
            -- build's cleanup cannot delete the tree in the window between
            -- locating it and using it; release if nothing is cached to protect.
            managed_toolchains_acquire_windows_bootstrap_use_lock()
            local cached = managed_toolchains_find_windows_bootstrap_bin(managed_toolchains_windows_bootstrap_root())
            if cached then
                print("reusing cached temporary Windows bootstrap toolchain: " .. cached)
                managed_toolchains_activate_windows_bootstrap_bin(cached)
            else
                managed_toolchains_release_windows_bootstrap_use_lock()
            end
        end
        return
    end
    if not needed then
        reason = reason or "a project-private bootstrap toolchain (toolchains_bootstrap=" .. provider .. ")"
    end
    if provider == "none" then
        gccsources.print_host_toolchain_install_guide({reason})
        return
    end

    local configured_path = base.trim(settings.value_or("toolchains_bootstrap_path", ""))
    if configured_path ~= "" then
        local bindir = managed_toolchains_find_windows_bootstrap_bin(configured_path)
        if bindir then
            managed_toolchains_activate_windows_bootstrap_bin(bindir)
            return
        end
        if provider == "path" then
            run.stop_with_guidance(target_os, "Windows bootstrap toolchain path is not usable", {
                "The configured toolchains_bootstrap_path does not contain a complete MinGW-w64 GCC sysroot."
            }, {
                "Point --toolchains_bootstrap_path to a portable MinGW root or bin directory.",
                "Or use --toolchains_bootstrap=auto to let xmake fetch a temporary portable bootstrap toolchain."
            })
        end
        errors.warn("configured toolchains_bootstrap_path is not usable: %s", configured_path)
    elseif provider == "path" then
        run.stop_with_guidance(target_os, "Windows bootstrap toolchain path is not configured", {
            "toolchains_bootstrap=path requires toolchains_bootstrap_path."
        }, {
            "Set --toolchains_bootstrap_path=<portable-mingw-root-or-bin>.",
            "Or use --toolchains_bootstrap=auto."
        })
    end

    if provider ~= "auto" and provider ~= "portable" then
        run.stop_with_guidance(target_os, "Windows bootstrap provider is not supported", {
            "Unsupported toolchains_bootstrap value: " .. tostring(provider)
        }, {
            "Use --toolchains_bootstrap=auto, portable, path, or none."
        })
    end

    local url = managed_toolchains_resolve_windows_bootstrap_url()
    local archive = path.join(layout.download_cache_dir(), managed_toolchains_windows_bootstrap_archive_leaf_name(url))
    -- Hold the shared use-lock across the whole managed-tree span (cached find,
    -- download+extract, alias prepare, activate, and the build that follows) so
    -- a concurrent cleanup cannot delete it out from under this build. This path
    -- always ends up using the managed tree, so there is nothing to release.
    managed_toolchains_acquire_windows_bootstrap_use_lock()
    local extracted = managed_toolchains_windows_bootstrap_root()
    local cached_bindir = managed_toolchains_find_windows_bootstrap_bin(extracted)
    if cached_bindir then
        print("reusing cached temporary Windows bootstrap toolchain: " .. cached_bindir)
        managed_toolchains_activate_windows_bootstrap_bin(cached_bindir, extracted, archive)
        return
    end
    print("Windows host bootstrap is missing " .. tostring(reason) .. "; fetching a temporary portable MinGW toolchain.")
    download.download_and_extract_archive(url, archive, extracted, false)
    local bindir = managed_toolchains_find_windows_bootstrap_bin(extracted)
    if not bindir then
        layout.remove_toolchains_path(extracted)
        run.stop_with_guidance(target_os, "Downloaded Windows bootstrap toolchain is not usable", {
            "The archive did not expose a complete MinGW-w64 GCC sysroot after extraction."
        }, {
            "Set --toolchains_bootstrap_url=<archive-url> to a portable MinGW archive with gcc, g++, sh, make, headers, and CRT libraries.",
            "Or install MSYS2 UCRT64/w64devkit and put its bin directory in PATH.",
            "If antivirus software quarantined parts of the extracted toolchain (cc1/cc1plus are common MinGW false positives), restore them, add an exclusion for the .toolchains directory, then retry."
        })
    end
    managed_toolchains_activate_windows_bootstrap_bin(bindir, extracted, archive)
end

function cleanup_windows_bootstrap_toolchain()
    local state = hosttools.windows_bootstrap_state()
    if not state.cleanup_root and not state.cleanup_archive then
        return
    end
    local root = state.cleanup_root
    local archive = state.cleanup_archive
    local use_lock = state.use_lock
    hosttools.clear_windows_bootstrap_state()
    hosttools.invalidate_windows_host_info()

    -- Drop our own shared lock first so it cannot block our exclusive probe,
    -- then only delete when nobody else still holds the shared bootstrap. A
    -- failed exclusive acquire means a concurrent build is still using the
    -- tree: leave it in place (it is reused, and cleaned up by whoever is
    -- last). Any lock error defaults to NOT deleting -- never remove a
    -- bootstrap another build may still need. Lock ops raise on failure and
    -- return nothing on success, so they run inside trycall.
    if use_lock then
        errors.trycall(function () use_lock:unlock() end)
        errors.trycall(function () use_lock:close() end)
    end
    local held, exclusive = errors.trycall(function ()
        local handle = io.openlock(windows_bootstrap_use_lockfile(root))
        if handle and handle:trylock() then
            return handle
        end
        if handle then
            handle:close()
        end
        return nil
    end)
    if not (held and exclusive) then
        print("keeping shared Windows bootstrap directory: another build is still using it")
        return
    end

    local ok = errors.trycall(function ()
        if root and os.exists(root) then
            print("removing temporary Windows bootstrap directory: " .. root)
            layout.remove_toolchains_path(root)
        end
        if archive and os.exists(archive) then
            print("removing temporary Windows bootstrap archive: " .. archive)
            layout.remove_toolchains_path(archive)
        end
        return true
    end)
    errors.trycall(function () exclusive:unlock() end)
    errors.trycall(function () exclusive:close() end)
    if not ok then
        errors.warn("failed to remove temporary Windows bootstrap files; they can be deleted from .toolchains/.cache/windows/bootstrap manually")
    end
end
