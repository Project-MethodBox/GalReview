-- Project-managed glibc sysroot pipeline (owned by targets/linux.lua the way
-- gccwasm is owned by targets/emscripten.lua; never a provider itself -- the
-- targets/ directory is enumerated as subjects). A GNU Linux cross target
-- without an external linux_sysroot gets its sysroot built here in three
-- idempotent stages, all before the main GCC configure (prepare_sysroot runs
-- inside configure_gcc, after binutils exist):
--   1. Linux kernel UAPI headers (pinned kernel.org full source archive,
--      `make headers_install`),
--   2. a throwaway stage1 GCC (--without-headers C-only compiler plus static
--      libgcc, installed into a build-cache prefix),
--   3. a full glibc build/install into the managed sysroot.
-- The main GCC configure then sees a complete sysroot and takes the ordinary
-- shared cross plan (--enable-shared, shared libgcc_s + libstdc++).
--
-- Version policy lives in core/modules/defaults.lua (glibc_versions /
-- glibc_default_version); resolve_version() below implements auto-follow.
-- v1 scope: the on-host build runs on Linux hosts only (the kernel header
-- tree contains case-colliding file names that silently drop files on
-- default Windows/macOS file systems, and glibc's build needs bash-family
-- host tools w64devkit does not provide); other hosts get preflight guidance
-- toward musl, an external sysroot, or a Linux-built copy.

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
import("gccsources")
import("gccinstall")

-- version helpers ------------------------------------------------------------

local function version_pair(version)
    local major, minor = tostring(version or ""):match("^(%d+)%.(%d+)")
    return tonumber(major or ""), tonumber(minor or "")
end

local function version_less(a, b)
    local amajor, aminor = version_pair(a)
    local bmajor, bminor = version_pair(b)
    if (amajor or 0) ~= (bmajor or 0) then
        return (amajor or 0) < (bmajor or 0)
    end
    return (aminor or 0) < (bminor or 0)
end

function supported_versions()
    local versions = {}
    for version, _ in pairs(defaults.glibc_versions) do
        table.insert(versions, version)
    end
    table.sort(versions, version_less)
    return versions
end

local host_version_cache

-- Host glibc probe (Linux hosts only): getconf first, ldd --version second.
function host_glibc_version()
    if base.host_os() ~= "linux" then
        return nil
    end
    if host_version_cache ~= nil then
        return host_version_cache ~= "" and host_version_cache or nil
    end
    local version
    local ok, out = errors.trycall(function ()
        return os.iorunv("getconf", {"GNU_LIBC_VERSION"}, {try = true})
    end)
    if ok and type(out) == "string" then
        version = out:match("(%d+%.%d+)")
    end
    if not version then
        ok, out = errors.trycall(function ()
            return os.iorunv("ldd", {"--version"}, {try = true})
        end)
        if ok and type(out) == "string" then
            local first_line = out:match("[^\r\n]+") or ""
            version = first_line:match("(%d+%.%d+)")
        end
    end
    host_version_cache = version or ""
    return version
end

local resolve_cache
local follow_warned

-- The single version-resolution truth source. Never raises; returns
--   {version, source, url, kernel_url, supported, problems}
-- with problems non-empty when the configured version cannot be honored
-- (preflight turns problems into the loud stop, prepare_gnu_sysroot fails).
function resolve_version(target_os)
    if resolve_cache then
        return resolve_cache
    end
    local result = {problems = {}, supported = supported_versions()}
    local configured = tostring(settings.value_or("linux_glibc_version", "auto"))
    if configured ~= "" and configured ~= "auto" then
        if not configured:match("^%d+%.%d+$") then
            table.insert(result.problems, string.format(
                "linux_glibc_version '%s' is not a glibc version; use auto or a version such as %s",
                configured, defaults.glibc_default_version))
        elseif not defaults.glibc_versions[configured] then
            table.insert(result.problems, string.format(
                "linux_glibc_version %s is not in the supported managed set (%s); pick a supported version or extend glibc_versions in core/modules/defaults.lua",
                configured, table.concat(result.supported, ", ")))
        else
            result.version = configured
            result.source = "option"
        end
    elseif base.host_os() ~= "linux" then
        result.version = defaults.glibc_default_version
        result.source = "default"
    else
        local host_version = host_glibc_version()
        if not host_version then
            result.version = defaults.glibc_default_version
            result.source = "default (host probe failed)"
        elseif defaults.glibc_versions[host_version] then
            result.version = host_version
            result.source = "host"
        else
            local nearest
            for _, candidate in ipairs(result.supported) do
                if not version_less(host_version, candidate) then
                    nearest = candidate
                end
            end
            if nearest then
                result.version = nearest
                result.source = "host-nearest"
                if not follow_warned then
                    follow_warned = true
                    errors.warn("host glibc %s has no exact managed match; following with the closest supported version %s (set --linux_glibc_version to override)",
                        host_version, nearest)
                end
            else
                result.version = result.supported[1]
                result.source = "host-oldest"
                if not follow_warned then
                    follow_warned = true
                    errors.warn("host glibc %s is older than every supported managed glibc version; using the oldest supported version %s",
                        host_version, result.version)
                end
            end
        end
    end
    if result.version then
        local entry = defaults.glibc_versions[result.version]
        result.url = settings.value_or("glibc_snapshot_url", entry.url)
        result.kernel_url = entry.kernel_headers_url
    end
    resolve_cache = result
    return result
end

-- sysroot completeness ---------------------------------------------------------

function glibc_ready(sysroot)
    if not os.isdir(sysroot) then
        return false
    end
    if not os.isfile(path.join(sysroot, "usr", "include", "stdio.h")) then
        return false
    end
    if not os.isfile(path.join(sysroot, "usr", "include", "linux", "version.h")) then
        return false
    end
    if #os.files(path.join(sysroot, "usr", "**", "crt1.o")) == 0 then
        return false
    end
    return #os.files(path.join(sysroot, "**", "libc.so.6")) > 0
        or #os.files(path.join(sysroot, "**", "libc.a")) > 0
end

-- read-only preflight probe (matrix-consumable) --------------------------------

function preflight_warnings(target_os)
    local warnings = {}
    local actions = {}
    local resolved = resolve_version(target_os)
    for _, problem in ipairs(resolved.problems) do
        table.insert(warnings, problem)
    end
    if #resolved.problems > 0 then
        table.insert(actions, errors.message("Supported managed glibc versions: %s (set with `xmake f --linux_glibc_version=<version>`).",
            table.concat(resolved.supported, ", ")))
    end
    if base.host_os() ~= "linux" then
        table.insert(warnings, errors.message(
            "linux_libc=gnu without linux_sysroot selects the project-managed glibc sysroot, which is only built on Linux hosts (current host: %s).",
            base.host_os()))
        table.insert(actions, errors.message("Use the project-managed musl runtime instead: xmake f -p linux -a <arch> --linux_libc=musl"))
        table.insert(actions, errors.message("Or point linux_sysroot at an existing glibc sysroot: xmake f -p linux -a <arch> --linux_libc=gnu --linux_sysroot=<sysroot>"))
        table.insert(actions, errors.message("Or run `xmake toolchains install linux` on a Linux host to build the managed glibc sysroot, copy it over, and set --linux_sysroot to the copy."))
        return warnings, actions
    end
    local missing = {}
    for _, tool in ipairs({"bison", "gawk", "python3"}) do
        if not hosttools.find_tool_path(tool) then
            table.insert(missing, tool)
        end
    end
    if #missing > 0 then
        table.insert(warnings, errors.message("the managed glibc sysroot build needs host tools that are missing from PATH: %s", table.concat(missing, ", ")))
        table.insert(actions, errors.message("Install the missing tools with the distribution package manager, then rerun the same xmake command."))
    end
    return warnings, actions
end

-- source archives ---------------------------------------------------------------

local function find_extracted_tree(outputdir, is_root)
    if is_root(outputdir) then
        return outputdir
    end
    for _, dir in ipairs(os.dirs(path.join(outputdir, "*"))) do
        if is_root(dir) then
            return dir
        end
    end
end

local function download_source_tree(url, src_leaf, extract_leaf, fallback_leaf, is_root, missing_message)
    local src = path.join(layout.source_cache_dir(), src_leaf)
    local stamp = path.join(src, ".xmake-source")
    local source_signature = url .. "\n"
    if is_root(src) and os.isfile(stamp) and io.readfile(stamp) == source_signature then
        return src
    end
    local cache = layout.download_cache_dir()
    local archive = path.join(cache, gccsources.archive_leaf_name(url, fallback_leaf))
    local extracted = layout.extract_cache_dir(extract_leaf)
    download.download_and_extract_archive(url, archive, extracted, false)
    local source_root = find_extracted_tree(extracted, is_root)
    if not source_root then
        errors.fail(missing_message)
    end
    layout.remove_toolchains_path(src)
    os.mkdir(path.directory(src))
    os.mv(source_root, src)
    io.writefile(stamp, source_signature)
    layout.remove_toolchains_path(extracted)
    return src
end

local function download_glibc_source(resolved)
    return download_source_tree(resolved.url, "glibc", "glibc-source", "glibc.tar.xz",
        function (dir)
            return os.isfile(path.join(dir, "configure")) and os.isfile(path.join(dir, "libc-abis"))
        end,
        "downloaded glibc archive did not contain a glibc source tree")
end

local function download_kernel_source(resolved)
    return download_source_tree(resolved.kernel_url, "linux-kernel", "linux-kernel-source", "linux.tar.xz",
        function (dir)
            return os.isfile(path.join(dir, "Makefile")) and os.isdir(path.join(dir, "include", "uapi"))
        end,
        "downloaded Linux kernel archive did not contain a Linux kernel source tree")
end

-- stage 1: kernel UAPI headers ---------------------------------------------------

local function kernel_arch_from_triplet(triplet)
    local arch = tostring(triplet or ""):match("^([^-]+)") or settings.configured_arch()
    arch = base.canonical_arch(arch, "linux")
    if arch == "x86_64" or arch == "i686" or arch == "i586" or arch == "i486" then
        return "x86"
    elseif arch == "aarch64" then
        return "arm64"
    elseif arch == "arm" or arch:match("^armv") then
        return "arm"
    elseif arch:match("^riscv") then
        return "riscv"
    elseif arch:match("^loongarch") then
        return "loongarch"
    elseif arch:match("^ppc") or arch:match("^powerpc") then
        return "powerpc"
    elseif arch:match("^s390") then
        return "s390"
    end
    return arch
end

local function install_kernel_headers(target_os, resolved, sysroot)
    local karch = kernel_arch_from_triplet(settings.managed_target(target_os))
    local stampfile = path.join(sysroot, ".xmake-linux-headers")
    local signature = resolved.kernel_url .. "\narch=" .. karch .. "\n"
    if os.isfile(path.join(sysroot, "usr", "include", "linux", "version.h"))
        and os.isfile(stampfile) and io.readfile(stampfile) == signature then
        return
    end
    print("installing Linux kernel headers into the managed glibc sysroot")
    local src = download_kernel_source(resolved)
    local build = settings.linux_headers_build_dir(target_os)
    os.mkdir(build)
    os.mkdir(path.join(sysroot, "usr"))
    local make = hosttools.preferred_host_tool(settings.value_or("toolchains_make", "make"))
    local args = makerunner.make_args_for(make, "headers_install",
        "ARCH=" .. karch,
        "O=" .. base.shpath(build),
        "INSTALL_HDR_PATH=" .. base.shpath(path.join(sysroot, "usr")))
    args = table.join(args, makerunner.make_tool_args())
    run.run_program("installing Linux kernel headers", make, args,
        {curdir = src, envs = envs.shell_envs(), target_os = target_os})
    if not os.isfile(path.join(sysroot, "usr", "include", "linux", "version.h")) then
        errors.fail("Linux kernel headers install is incomplete: %s", sysroot)
    end
    io.writefile(stampfile, signature)
end

-- stage 2: throwaway stage1 GCC ---------------------------------------------------

local function stage1_prefix(target_os)
    return path.join(settings.build_cache_dir(target_os), "gcc-stage1-prefix")
end

local function stage1_gcc_file(target_os)
    return path.join(stage1_prefix(target_os), "bin",
        base.exe(settings.managed_target(target_os) .. "-gcc"))
end

local function build_stage1_gcc(target_os, resolved, sysroot)
    local src = settings.gcc_source_dir(target_os)
    local build = settings.gcc_stage1_build_dir(target_os)
    local prefix = stage1_prefix(target_os)
    local main_prefix = settings.gcc_prefix(target_os)
    local triplet = settings.managed_target(target_os)
    local args = {
        "--prefix=" .. base.shpath(prefix),
        "--build=" .. settings.host_triplet(),
        "--host=" .. settings.host_triplet(),
        "--target=" .. triplet,
        "--with-sysroot=" .. base.shpath(sysroot),
        "--with-glibc-version=" .. resolved.version,
        "--with-newlib",
        "--without-headers",
        "--enable-languages=c",
        "--disable-bootstrap",
        "--disable-multilib",
        "--disable-nls",
        "--disable-shared",
        "--disable-threads",
        "--disable-libatomic",
        "--disable-libgomp",
        "--disable-libquadmath",
        "--disable-libssp",
        "--disable-libvtv",
        "--disable-libsanitizer",
        "--disable-libstdcxx",
        "--disable-lto",
        "--disable-plugin"
    }
    -- binutils were installed into the MAIN prefix tooldir before
    -- configure_gcc ran; the stage1 prefix has no tooldir of its own, so pin
    -- the assembler/linker explicitly instead of gambling on a PATH probe
    local tooldir_as = path.join(main_prefix, triplet, "bin", base.exe("as"))
    local tooldir_ld = path.join(main_prefix, triplet, "bin", base.exe("ld"))
    if os.isfile(tooldir_as) and os.isfile(tooldir_ld) then
        table.insert(args, "--with-as=" .. base.shpath(tooldir_as))
        table.insert(args, "--with-ld=" .. base.shpath(tooldir_ld))
    end
    local sigfile = path.join(build, ".xmake-configure")
    local signature = gccinstall.configure_signature(args, target_os, src, "glibc_stage=stage1\n")
    local old_signature = os.isfile(sigfile) and base.trim(io.readfile(sigfile)) or ""
    if os.isfile(stage1_gcc_file(target_os)) and old_signature == base.trim(signature) then
        return
    end
    print("building stage1 GCC for the managed glibc sysroot (C-only, static libgcc)")
    if os.isfile(path.join(build, "Makefile")) and old_signature ~= base.trim(signature) then
        gccinstall.reset_build_dir(build)
        if os.isdir(prefix) then
            layout.remove_toolchains_path(prefix)
        end
    end
    os.mkdir(build)
    local buildenvs = settings.apply_build_envs(envs.shell_envs(path.join(main_prefix, "bin")), target_os)
    buildenvs.MAKEINFO = "true"
    if not os.isfile(path.join(build, "Makefile")) then
        gccsources.run_script(path.join(path.relative(src, build), "configure"), args,
            {curdir = build, envs = buildenvs})
        io.writefile(sigfile, signature)
    end
    gccsources.sync_gcc_generated_sources_to_build(src, build)
    local make = hosttools.preferred_host_tool(settings.value_or("toolchains_make", "make"))
    for _, make_target in ipairs({"all-gcc", "install-gcc", "all-target-libgcc", "install-target-libgcc"}) do
        makerunner.run_make_target(make, build, buildenvs, make_target)
    end
    if not os.isfile(stage1_gcc_file(target_os)) then
        errors.fail("stage1 GCC for the managed glibc sysroot is incomplete: %s", prefix)
    end
end

-- stage 3: glibc -------------------------------------------------------------------

-- On lib64 targets glibc never creates <sysroot>/usr/lib, but GCC's multilib
-- os-suffix search walks the LITERAL path usr/lib/../lib64 -- and path
-- resolution requires the intermediate component to exist, so a missing
-- usr/lib turns every startfile/library probe into ENOENT and the shared
-- libgcc link dies on "cannot find crti.o / -lc" even though the files sit
-- in usr/lib64 (seen live 2026-07-17). Called on every prepare pass so
-- already-populated sysroots self-heal.
local function ensure_sysroot_layout_anchors(sysroot)
    os.mkdir(path.join(sysroot, "usr", "lib"))
    os.mkdir(path.join(sysroot, "lib"))
end

local function build_and_install_glibc(target_os, resolved, sysroot)
    local src = download_glibc_source(resolved)
    local build = settings.glibc_build_dir(target_os)
    local main_prefix = settings.gcc_prefix(target_os)
    local triplet = settings.managed_target(target_os)
    local args = {
        "--prefix=/usr",
        "--host=" .. triplet,
        "--build=" .. settings.host_triplet(),
        "--with-headers=" .. base.shpath(path.join(sysroot, "usr", "include")),
        "--disable-werror",
        "--disable-nscd",
        -- No target C++ compiler exists at this stage (stage1 GCC is C-only);
        -- without this pre-seeded cache answer glibc's configure falls back
        -- to the HOST g++ and feeds x86-64 objects to the target linker
        -- (links-dso-program.o: "Relocations in generic ELF (EM: 62)",
        -- 2026-07-17). Seeding no makes configure clear CXX and skip the
        -- C++-only test helpers; the final GCC supplies the real C++ later.
        "libc_cv_cxx_link_ok=no"
    }
    local tooldir_bin = path.join(main_prefix, triplet, "bin")
    if os.isdir(tooldir_bin) then
        table.insert(args, "--with-binutils=" .. base.shpath(tooldir_bin))
    end
    local sigfile = path.join(build, ".xmake-configure")
    local signature = gccinstall.configure_signature(args, target_os, nil,
        "glibc_version=" .. resolved.version .. "\nglibc_url=" .. resolved.url .. "\ncompiler_stage=stage1\n")
    local old_signature = os.isfile(sigfile) and base.trim(io.readfile(sigfile)) or ""
    if os.isfile(path.join(build, "config.make")) and old_signature ~= base.trim(signature) then
        gccinstall.reset_build_dir(build)
    end
    os.mkdir(build)
    local buildenvs = envs.shell_envs(path.join(stage1_prefix(target_os), "bin"), path.join(main_prefix, "bin"))
    buildenvs.CC = base.shpath(stage1_gcc_file(target_os))
    buildenvs.BUILD_CC = "gcc"
    if os.isfile(path.join(build, "config.make")) then
        print("using existing glibc build directory: " .. build)
    else
        gccsources.run_script(path.join(path.relative(src, build), "configure"), args,
            {curdir = build, envs = buildenvs})
        io.writefile(sigfile, signature)
    end
    local make = hosttools.preferred_host_tool(settings.value_or("toolchains_make", "make"))
    makerunner.run_make_target(make, build, buildenvs, "")
    print("installing glibc into the managed sysroot: " .. sysroot)
    local install_args = makerunner.make_args_for(make, "install", "install_root=" .. base.shpath(sysroot))
    install_args = table.join(install_args, makerunner.make_tool_args())
    -- glibc's install rules only skip the info manual when MAKEINFO is the
    -- literal ":" (its Makefiles test that exact spelling); the shared
    -- make_tool_args() "MAKEINFO=true" spelling claims success while
    -- generating nothing, so install then fails copying the missing
    -- libc.info (seen live 2026-07-17). Last command-line assignment wins.
    table.insert(install_args, "MAKEINFO=:")
    run.run_program("glibc make install", make, install_args,
        {curdir = build, envs = buildenvs, target_os = target_os})
    ensure_sysroot_layout_anchors(sysroot)
    if not glibc_ready(sysroot) then
        errors.fail("managed glibc sysroot install is incomplete: %s", sysroot)
    end
end

-- orchestration ---------------------------------------------------------------------

local GLIBC_OWNED_SYSROOT_LEAVES = {"usr", "etc", "var", "sbin", "share", "libexec"}
-- lib/lib64 are SHARED with binutils: its install drops <sysroot>/lib/ldscripts
-- (emulation linker scripts) into the same tree before this cleanup can ever
-- rerun, so these two are cleared entry-by-entry with the linker-script
-- directory preserved.
local GLIBC_SHARED_SYSROOT_LEAVES = {"lib", "lib64"}

local function sysroot_stamp_file(sysroot)
    return path.join(sysroot, ".xmake-glibc")
end

local function sysroot_stamp_signature(resolved)
    return string.format("format:glibc-managed-v1\nversion=%s\nglibc_url=%s\nkernel_url=%s\n",
        resolved.version, resolved.url, resolved.kernel_url)
end

-- Idempotent entry point called by targets/linux.lua prepare_sysroot for
-- managed GNU cross targets. Raises on non-Linux hosts (preflight gives the
-- same three-way guidance before any build starts).
function prepare_gnu_sysroot(target_os)
    local resolved = resolve_version(target_os)
    if #resolved.problems > 0 then
        errors.fail("cannot resolve the managed glibc version: %s", table.concat(resolved.problems, "; "))
    end
    if base.host_os() ~= "linux" then
        errors.fail("the managed glibc sysroot can only be built on a Linux host; use linux_libc=musl, set linux_sysroot to an existing glibc sysroot, or build the managed sysroot on a Linux host and copy it here")
    end
    local sysroot = settings.gcc_sysroot(target_os)
    local stampfile = sysroot_stamp_file(sysroot)
    local signature = sysroot_stamp_signature(resolved)
    if glibc_ready(sysroot) and os.isfile(stampfile) and io.readfile(stampfile) == signature then
        ensure_sysroot_layout_anchors(sysroot)
        return
    end
    if os.isfile(stampfile) and io.readfile(stampfile) ~= signature then
        -- pin changed: drop only the glibc/kernel-owned trees; the binutils
        -- tooldir (<sysroot>/bin) must survive
        print("managed glibc sysroot pin changed; resetting the glibc-owned sysroot trees: " .. sysroot)
        for _, leaf in ipairs(GLIBC_OWNED_SYSROOT_LEAVES) do
            local dir = path.join(sysroot, leaf)
            if os.exists(dir) then
                layout.remove_toolchains_path(dir)
            end
        end
        for _, leaf in ipairs(GLIBC_SHARED_SYSROOT_LEAVES) do
            local dir = path.join(sysroot, leaf)
            if os.isdir(dir) then
                for _, entry in ipairs(os.filedirs(path.join(dir, "*"))) do
                    if path.filename(entry) ~= "ldscripts" then
                        layout.remove_toolchains_path(entry)
                    end
                end
            end
        end
        layout.remove_toolchains_path(stampfile)
    end
    print(string.format("preparing project-managed glibc %s sysroot (kernel headers, stage1 GCC, glibc)", resolved.version))
    os.mkdir(sysroot)
    install_kernel_headers(target_os, resolved, sysroot)
    build_stage1_gcc(target_os, resolved, sysroot)
    build_and_install_glibc(target_os, resolved, sysroot)
    if not glibc_ready(sysroot) then
        errors.fail("managed glibc sysroot install is incomplete: %s", sysroot)
    end
    io.writefile(stampfile, signature)
end
