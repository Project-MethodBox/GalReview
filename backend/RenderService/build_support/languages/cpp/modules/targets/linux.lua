-- Linux target provider: libc selection (musl/gnu) and sysroot probing,
-- the project-managed musl download/configure/headers/runtime pipeline
-- (including its Windows-host configure and Makefile compatibility
-- shims), the Linux sysroot preparation and preflight, and the Linux
-- configure arguments and build plan. GNU cross targets without an
-- external linux_sysroot delegate to the project-managed glibc sysroot
-- pipeline in ../gccglibc.lua (kernel headers + stage1 GCC + glibc).

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
local defaults = import("defaults", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")}).values()
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("hosttools", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("envs", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("run", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("download", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("makerunner", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("gccsources", {rootdir = path.join(os.scriptdir(), "..")})
import("gccinstall", {rootdir = path.join(os.scriptdir(), "..")})
import("gccglibc", {rootdir = path.join(os.scriptdir(), "..")})

function linux_configured_sysroot()
    local root = settings.value_or("linux_sysroot", "")
    if root ~= "" then
        return path.absolute(root)
    end
end

function linux_target_uses_musl(target_os)
    return target_os == "linux" and settings.managed_target(target_os):find("musl", 1, true) ~= nil
end

function linux_target_uses_gnu(target_os)
    return target_os == "linux" and settings.managed_target(target_os):find("gnu", 1, true) ~= nil
end

function linux_target_libc(target_os)
    if linux_target_uses_musl(target_os) then
        return "musl"
    elseif linux_target_uses_gnu(target_os) then
        return "gnu"
    end
    return settings.linux_libc_kind()
end

function linux_sysroot_has_headers(sysroot)
    return os.isfile(path.join(sysroot, "usr", "include", "stdio.h")) or
           os.isfile(path.join(sysroot, "include", "stdio.h"))
end

function linux_sysroot_has_libc(sysroot)
    return #os.files(path.join(sysroot, "**", "libc.so")) > 0 or
           #os.files(path.join(sysroot, "**", "libc.a")) > 0
end

-- GNU cross targets without an external linux_sysroot use the
-- project-managed glibc sysroot (built by gccglibc.lua; Linux hosts only in
-- v1 -- preflight below guides other hosts). Native GNU builds keep using
-- the host libc directly and never enter managed mode.
function linux_glibc_managed(target_os)
    return linux_target_uses_gnu(target_os)
        and not linux_configured_sysroot()
        and settings.is_cross_target(target_os)
end

function sysroot(target_os)
    local configured = linux_configured_sysroot()
    if configured then
        return configured
    end
    if linux_target_uses_musl(target_os) then
        return settings.gcc_sysroot(target_os)
    end
    if linux_glibc_managed(target_os) then
        return settings.gcc_sysroot(target_os)
    end
end

local function find_extracted_musl_source(outputdir)
    if os.isfile(path.join(outputdir, "configure")) and os.isfile(path.join(outputdir, "Makefile")) then
        return outputdir
    end
    for _, dir in ipairs(os.dirs(path.join(outputdir, "*"))) do
        if os.isfile(path.join(dir, "configure")) and os.isfile(path.join(dir, "Makefile")) then
            return dir
        end
    end
    errors.fail("downloaded musl archive did not contain a musl source tree")
end

local function download_musl_snapshot(force)
    local url = settings.value_or("musl_snapshot_url", defaults.musl_snapshot_url)
    local src = layout.musl_source_dir()
    local stamp = path.join(src, ".xmake-source")
    local source_signature = url .. "\n"
    if not force and os.isfile(path.join(src, "configure")) and os.isfile(path.join(src, "Makefile"))
        and os.isfile(stamp) and io.readfile(stamp) == source_signature then
        return src
    end

    local cache = layout.download_cache_dir()
    local archive = path.join(cache, gccsources.archive_leaf_name(url, "musl.tar.gz"))
    local extracted = layout.extract_cache_dir("musl-source")
    download.download_and_extract_archive(url, archive, extracted, force)

    local source_root = find_extracted_musl_source(extracted)
    layout.remove_toolchains_path(src)
    os.mkdir(path.directory(src))
    os.mv(source_root, src)
    io.writefile(stamp, source_signature)
    layout.remove_toolchains_path(extracted)
    return src
end

function musl_arch_from_triplet(triplet)
    local arch = tostring(triplet or ""):match("^([^-]+)") or settings.configured_arch()
    arch = base.canonical_arch(arch, "linux")
    if arch == "i686" or arch == "i586" or arch == "i486" then
        return "i386"
    elseif arch == "armv7a" or arch == "armv7" then
        return "arm"
    end
    return arch
end

function ensure_musl_windows_configure_compat(src)
    if not base.is_windows_host() then
        return
    end
    local configure = path.join(src, "configure")
    if not os.isfile(configure) then
        return
    end
    local text = io.readfile(configure)
    local patched = text:gsub("%-o /dev/null", "-o ./conftest.out")
    if patched ~= text then
        io.writefile(configure, patched)
    end
end

function patch_musl_makefile_for_windows(build)
    if not base.is_windows_host() then
        return
    end
    local makefile = path.join(build, "Makefile")
    if not os.isfile(makefile) then
        return
    end
    local content = io.readfile(makefile)
    local patched = base.replace_plain(content, table.concat({
        "lib/libc.so: $(LOBJS) $(LDSO_OBJS)",
        "\t$(CC) $(CFLAGS_ALL) $(LDFLAGS_ALL) -nostdlib -shared \\",
        "\t-Wl,-e,_dlstart -o $@ $(LOBJS) $(LDSO_OBJS) $(LIBCC)"
    }, "\n"), table.concat({
        "lib/libc.so: $(LOBJS) $(LDSO_OBJS)",
        "\t@: $(file >obj/libc-so.rsp,$(LOBJS) $(LDSO_OBJS))",
        "\t$(CC) $(CFLAGS_ALL) $(LDFLAGS_ALL) -nostdlib -shared \\",
        "\t-Wl,-e,_dlstart -o $@ @obj/libc-so.rsp $(LIBCC)"
    }, "\n"))
    patched = base.replace_plain(patched, table.concat({
        "lib/libc.a: $(AOBJS)",
        "\trm -f $@",
        "\t$(AR) rc $@ $(AOBJS)",
        "\t$(RANLIB) $@"
    }, "\n"), table.concat({
        "lib/libc.a: $(AOBJS)",
        "\trm -f $@",
        "\t@: $(file >obj/libc-a.rsp,$(AOBJS))",
        "\t$(AR) rc $@ @obj/libc-a.rsp",
        "\t$(RANLIB) $@"
    }, "\n"))
    if patched ~= content then
        print("patching musl Makefile: use response files for libc links on Windows")
        io.writefile(makefile, patched)
    end
end

function install_musl_headers_without_configure(target_os, src, sysroot)
    local include_src = path.join(src, "include")
    local include_dst = path.join(sysroot, "usr", "include")
    local bits_dst = path.join(include_dst, "bits")
    local arch = musl_arch_from_triplet(settings.managed_target(target_os))
    local arch_bits = path.join(src, "arch", arch, "bits")
    local generic_bits = path.join(src, "arch", "generic", "bits")

    if not os.isdir(arch_bits) then
        errors.fail("musl does not provide headers for architecture '%s' from triplet '%s'", arch, settings.managed_target(target_os))
    end

    os.mkdir(include_dst)
    os.mkdir(bits_dst)
    for _, file in ipairs(os.files(path.join(include_src, "**.h"))) do
        local rel = path.relative(file, include_src)
        local dst = path.join(include_dst, rel)
        os.mkdir(path.directory(dst))
        os.cp(file, dst)
    end
    for _, file in ipairs(os.files(path.join(generic_bits, "*.h"))) do
        os.cp(file, path.join(bits_dst, path.filename(file)))
    end
    for _, file in ipairs(os.files(path.join(arch_bits, "*.h"))) do
        os.cp(file, path.join(bits_dst, path.filename(file)))
    end

    local shell = hosttools.preferred_posix_shell()
    local sed = hosttools.shell_host_tool("sed")
    local alltypes = path.join(bits_dst, "alltypes.h")
    local alltypes_cmd = string.format("%s -f %s %s %s > %s",
        base.shquote(sed),
        base.shquote(path.join(src, "tools", "mkalltypes.sed")),
        base.shquote(path.join(arch_bits, "alltypes.h.in")),
        base.shquote(path.join(src, "include", "alltypes.h.in")),
        base.shquote(alltypes))
    run.run_program("generating musl alltypes.h", shell, {"-c", alltypes_cmd}, {envs = envs.shell_envs(), target_os = target_os})

    local syscall_in = path.join(arch_bits, "syscall.h.in")
    if os.isfile(syscall_in) then
        local lines = {}
        local text = io.readfile(syscall_in)
        local trimmed = text:gsub("%s+$", "")
        table.insert(lines, trimmed)
        for line in text:gmatch("[^\r\n]+") do
            local converted = line:gsub("__NR_", "SYS_")
            if converted ~= line then
                table.insert(lines, converted)
            end
        end
        io.writefile(path.join(bits_dst, "syscall.h"), table.concat(lines, "\n") .. "\n")
    end
end

local function configure_musl(target_os)
    local src = download_musl_snapshot(false)
    ensure_musl_windows_configure_compat(src)
    local build = settings.musl_build_dir(target_os)
    local sysroot = settings.gcc_sysroot(target_os)
    local triplet = settings.managed_target(target_os)
    local relsrc = path.relative(src, build)
    local libgcc = gccinstall.target_libgcc_file(target_os)
    local args = {
        "--prefix=/usr",
        "--target=" .. triplet,
        "--syslibdir=/lib"
    }
    local compiler_stage = gccinstall.compiler_exists(target_os) and "target-compiler" or "headers-only"
    local libgcc_stage = libgcc and "with-libgcc" or "without-libgcc"
    local sigfile = path.join(build, ".xmake-configure")
    local signature = gccinstall.configure_signature(args, target_os) .. "compiler_stage=" .. compiler_stage .. "\nlibgcc_stage=" .. libgcc_stage .. "\n"
    local old_signature = os.isfile(sigfile) and base.trim(io.readfile(sigfile)) or ""
    if os.isfile(path.join(build, "config.mak")) and old_signature ~= base.trim(signature) then
        gccinstall.reset_build_dir(build)
    end
    os.mkdir(build)
    local envs = envs.shell_envs(path.join(settings.gcc_prefix(target_os), "bin"))
    if gccinstall.compiler_exists(target_os) then
        envs.CC = triplet .. "-gcc --sysroot=" .. base.shpath(sysroot)
        envs.AR = triplet .. "-ar"
        envs.RANLIB = triplet .. "-ranlib"
    end
    if libgcc then
        envs.LIBCC = base.shpath(libgcc)
    end
    if os.isfile(path.join(build, "config.mak")) then
        print("using existing musl build directory: " .. build)
    else
        gccsources.run_script(path.join(relsrc, "configure"), args, {curdir = build, envs = envs})
        io.writefile(sigfile, signature)
    end
    if libgcc then
        local config_mak = path.join(build, "config.mak")
        if os.isfile(config_mak) then
            local content = io.readfile(config_mak)
            local patched = content:gsub("\nLIBCC%s*=%s*[^\n]*", "\nLIBCC = " .. base.shpath(libgcc))
            if patched ~= content then
                io.writefile(config_mak, patched)
            end
        end
    end
    patch_musl_makefile_for_windows(build)
    return build, envs
end

local function run_musl_make(build, envs, target, destdir)
    local make = hosttools.preferred_host_tool(settings.value_or("toolchains_make", "make"))
    local args = makerunner.make_args_for(make, target, "DESTDIR=" .. base.shpath(destdir))
    args = table.join(args, makerunner.make_tool_args())
    print(string.format("running make target: %s (-j%d)", target, makerunner.make_jobs()))
    run.run_program("musl make", make, args, {curdir = build, envs = envs, target_os = settings.configured_target_os()})
end

-- The musl install links lib/ld-musl-<arch>.so.1 -> /usr/lib/libc.so with
-- an ABSOLUTE target: correct inside a running musl system, wrong as a
-- sysroot file on any build host. Windows cannot represent the symlink at
-- all, and on other hosts it resolves to the HOST's /usr/lib/libc.so --
-- sysroot-aware linkers rewrite it, but anything touching the file
-- directly (archiving, host-side execution through the loader) silently
-- gets the host libc (seen live 2026-07-17 on the Linux box: the symlink
-- pointed at host glibc and could not serve as the run loader).
-- Materialize a sysroot-local executable copy on every host; musl's
-- libc.so doubles as ld-musl, so the copy also lets hosts run dynamic
-- musl test binaries via `<sysroot>/lib/ld-musl-<arch>.so.1 <binary>`.
function repair_musl_runtime_loader(target_os)
    if not linux_target_uses_musl(target_os) then
        return
    end

    local sysroot = settings.gcc_sysroot(target_os)
    local arch = musl_arch_from_triplet(settings.managed_target(target_os))
    local loader = path.join(sysroot, "lib", "ld-musl-" .. arch .. ".so.1")
    local libc = path.join(sysroot, "usr", "lib", "libc.so")
    if os.islink(loader) and os.isfile(libc) then
        errors.warn("replacing the absolute musl loader symlink with a sysroot-local copy: %s", loader)
        layout.remove_toolchains_path(loader)
        -- never write through a surviving symlink: os.cp follows it and
        -- would create/overwrite the ABSOLUTE target path on the build host
        if os.islink(loader) then
            errors.fail("could not remove the musl loader symlink; refusing to copy through it: %s", loader)
        end
        os.cp(libc, loader)
    end
    if not base.is_windows_host() then
        for _, file in ipairs({libc, loader}) do
            if os.isfile(file) then
                os.vrunv(hosttools.preferred_host_tool("chmod"), {"+x", file}, {try = true})
            end
        end
    end
end

local function install_musl_headers(target_os)
    if not linux_target_uses_musl(target_os) then
        return
    end
    local sysroot = settings.gcc_sysroot(target_os)
    if linux_sysroot_has_headers(sysroot) then
        return
    end
    print("preparing project-local musl Linux headers")
    os.mkdir(sysroot)
    if gccinstall.compiler_exists(target_os) then
        local build, envs = configure_musl(target_os)
        run_musl_make(build, envs, "install-headers", sysroot)
    else
        local src = download_musl_snapshot(false)
        install_musl_headers_without_configure(target_os, src, sysroot)
    end
    if not os.isfile(path.join(sysroot, "usr", "include", "stdio.h")) then
        errors.fail("musl headers install is incomplete: %s", sysroot)
    end
end

local function install_musl_runtime(target_os)
    if not linux_target_uses_musl(target_os) then
        return
    end
    local sysroot = settings.gcc_sysroot(target_os)
    local function has_runtime_file(name)
        return os.isfile(path.join(sysroot, "lib", name)) or os.isfile(path.join(sysroot, "usr", "lib", name))
    end
    if has_runtime_file("libc.a") and
       has_runtime_file("libc.so") and
       has_runtime_file("crt1.o") and
       has_runtime_file("crti.o") and
       has_runtime_file("crtn.o") then
        repair_musl_runtime_loader(target_os)
        return
    end
    if not gccinstall.compiler_exists(target_os) then
        errors.fail("musl runtime requires the stage GCC compiler to be installed first")
    end
    print("building project-local musl Linux runtime")
    local build, envs = configure_musl(target_os)
    envs.CC = settings.managed_target(target_os) .. "-gcc --sysroot=" .. base.shpath(sysroot)
    envs.AR = settings.managed_target(target_os) .. "-ar"
    envs.RANLIB = settings.managed_target(target_os) .. "-ranlib"
    local libgcc = gccinstall.target_libgcc_file(target_os)
    if libgcc then
        envs.LIBCC = base.shpath(libgcc)
    end
    run_musl_make(build, envs, "install", sysroot)
    repair_musl_runtime_loader(target_os)
    if not has_runtime_file("libc.a") or
       not has_runtime_file("libc.so") or
       not has_runtime_file("crt1.o") or
       not has_runtime_file("crti.o") or
       not has_runtime_file("crtn.o") then
        errors.fail("musl runtime install is incomplete: %s", sysroot)
    end
end

function prepare_sysroot(target_os)
    if target_os ~= "linux" then
        return
    end
    if not settings.is_cross_target(target_os) and not linux_configured_sysroot() then
        return
    end
    local sysroot_dir = sysroot(target_os)
    if not sysroot_dir then
        errors.fail("Linux cross target requires a sysroot. Set linux_libc=musl for project-managed musl, or set linux_sysroot/LINUX_SYSROOT for GNU libc.")
    end
    if linux_target_uses_musl(target_os) then
        install_musl_headers(target_os)
        return
    end
    if linux_target_uses_gnu(target_os) then
        if linux_configured_sysroot() then
            -- external sysroot mode: only completeness is checked here
            if not os.isdir(sysroot_dir) or not linux_sysroot_has_headers(sysroot_dir) or not linux_sysroot_has_libc(sysroot_dir) then
                errors.fail("Linux GNU target requires a complete glibc sysroot with headers and libc. Set linux_sysroot/LINUX_SYSROOT to a usable sysroot, or use linux_libc=musl.")
            end
            return
        end
        gccglibc.prepare_gnu_sysroot(target_os)
    end
end

function configure_args(target_os, args)
    -- native means SAME TRIPLET, not merely "linux target on a linux host":
    -- with a cross triplet (aarch64-linux-gnu, x86_64-linux-musl) this branch
    -- must not fire, or the build configures without any sysroot and libgcc
    -- later dies on missing target headers with inhibit_libc baked in (seen
    -- live 2026-07-17 on the first linux-host -> aarch64-linux-gnu build:
    -- "cross build configured without --with-sysroot", pthread.h not found).
    if not settings.is_cross_target(target_os) then
        table.insert(args, "--enable-shared")
        table.insert(args, "--enable-threads=posix")
        return args
    end
    local sysroot_dir = sysroot(target_os)
    if sysroot_dir and os.isdir(sysroot_dir) then
        table.insert(args, "--with-sysroot=" .. base.shpath(sysroot_dir))
        table.insert(args, "--with-build-sysroot=" .. base.shpath(sysroot_dir))
        if linux_target_uses_musl(target_os) then
            table.insert(args, "--disable-shared")
            table.insert(args, "--enable-static")
        else
            table.insert(args, "--enable-shared")
        end
        table.insert(args, "--enable-threads=posix")
    else
        table.insert(args, "--without-headers")
        table.insert(args, "--disable-shared")
        table.insert(args, "--disable-threads")
    end
    return args
end

function stamp_extra(target_os)
    local extra = string.format("linux_libc=%s\nlinux_sysroot=%s\n", linux_target_libc(target_os), sysroot(target_os) or "")
    if linux_glibc_managed(target_os) then
        extra = extra .. string.format("linux_glibc_version=%s\n", tostring(gccglibc.resolve_version(target_os).version or ""))
    end
    return extra
end

-- Managed-glibc drift visibility for the OUTER install gate: without this,
-- toolchain_installed() never rereads the stamp's glibc version, so a pin
-- bump would print "already installed" and silently reuse the old sysroot
-- (signature_extra below only bites once a build actually reconfigures).
-- Same pattern as the android provider; stamps written before the key
-- existed are grandfathered until their next rebuild re-stamps them.
function installed_extra(target_os)
    local stamp = settings.stamp_file(target_os)
    if not os.isfile(stamp) then
        return not linux_glibc_managed(target_os)
    end
    local content = io.readfile(stamp) or ""
    -- libc-flavor drift: gnu and musl share one install prefix and the outer
    -- gate never compares provider stamp lines, so without this check
    -- switching --linux_libc silently reuses the other flavor's install
    -- (seen live 2026-07-17: a native-gnu install passed the gate under a
    -- musl configuration). Stamps without the key are grandfathered.
    local recorded_libc = content:match("[\r\n]linux_libc=([^\r\n]*)")
    if recorded_libc ~= nil and recorded_libc ~= linux_target_libc(target_os) then
        return false
    end
    if not linux_glibc_managed(target_os) then
        return true
    end
    local recorded = content:match("[\r\n]linux_glibc_version=([^\r\n]*)")
    if recorded ~= nil and recorded ~= tostring(gccglibc.resolve_version(target_os).version or "") then
        return false
    end
    return true
end

-- Managed-glibc identity for the configure signature (gccbuild wires this in
-- through gcctargets.signature_extra). Scoped to managed GNU mode only so
-- existing musl/external-sysroot build directories keep their signatures
-- (an unconditional extra would reset every cached cross build once).
-- Without it a glibc version bump would never reconfigure GCC, because the
-- managed sysroot path does not change with the version.
function signature_extra(target_os)
    if not linux_glibc_managed(target_os) then
        return ""
    end
    local resolved = gccglibc.resolve_version(target_os)
    return string.format("linux_glibc=managed\nlinux_glibc_version=%s\nlinux_kernel_headers=%s\n",
        tostring(resolved.version or ""), tostring(resolved.kernel_url or ""))
end

-- Shared by build_gcc_for's finalize step and finalize_existing_toolchain_install.
function finalize(target_os)
    repair_musl_runtime_loader(target_os)
end

function build_plan(target_os, context)
    if not settings.is_cross_target(target_os) then
        return {
            {log = "building native GCC toolchain", targets = {"", "install"}}
        }
    end
    if linux_target_uses_musl(target_os) then
        return {
            {
                log = "building Linux musl GCC compiler and target runtime",
                targets = {"all-gcc", "install-gcc"},
                patch = true
            },
            {
                targets = {"all-target-libgcc", "install-target-libgcc"},
                patch = true
            },
            {
                after = function ()
                    if not gccinstall.target_static_libgcc_available(target_os) then
                        errors.fail("Linux musl bootstrap did not install libgcc.a before libc")
                    end
                    install_musl_runtime(target_os)
                end
            },
            {
                targets = {"configure-target-libstdc++-v3", "all-target-libstdc++-v3", "install-target-libstdc++-v3"},
                patch = true
            }
        }
    end
    return {
        {
            log = "building cross GCC compiler and target runtime",
            targets = {"all-gcc", "install-gcc", "all-target-libgcc", "install-target-libgcc"},
            patch = true
        },
        {
            targets = {"configure-target-libstdc++-v3", "all-target-libstdc++-v3", "install-target-libstdc++-v3"},
            patch = true
        }
    }
end

function status_lines(target_os)
    print("linux libc:      " .. linux_target_libc(target_os))
    print("linux sysroot:   " .. tostring(sysroot(target_os) or ""))
    if linux_glibc_managed(target_os) then
        local resolved = gccglibc.resolve_version(target_os)
        if resolved.version then
            print("linux glibc:     " .. resolved.version .. " (managed, " .. tostring(resolved.source) .. ")")
        else
            print("linux glibc:     unresolved (" .. table.concat(resolved.problems, "; ") .. ")")
        end
    end
end

-- Read-only preflight probe (matrix-consumable); preflight() below turns a
-- non-empty result into the loud stop.
function preflight_warnings(target_os)
    if target_os ~= "linux" then
        return {}, {}
    end
    if not settings.is_cross_target(target_os) and not linux_configured_sysroot() then
        return {}, {}
    end
    if linux_target_uses_musl(target_os) then
        return {}, {}
    end
    if linux_glibc_managed(target_os) then
        return gccglibc.preflight_warnings(target_os)
    end
    local sysroot_dir = sysroot(target_os)
    local warnings = {}
    local actions = {
        errors.message("For a project-managed Linux cross runtime, use: xmake f -p linux -a <arch> --linux_libc=musl"),
        errors.message("For GNU/glibc targets, set a complete sysroot: xmake f -p linux -a <arch> --linux_libc=gnu --linux_sysroot=<sysroot>"),
        errors.message("The GNU sysroot must contain C headers and libc, for example usr/include/stdio.h and libc.so or libc.a.")
    }

    if not sysroot_dir then
        table.insert(warnings, errors.message("GNU/Linux cross target is selected, but linux_sysroot is not configured."))
    elseif not os.isdir(sysroot_dir) then
        table.insert(warnings, errors.message("linux_sysroot does not exist or is not a directory: %s", sysroot_dir))
    else
        if not linux_sysroot_has_headers(sysroot_dir) then
            table.insert(warnings, errors.message("linux_sysroot does not contain usable C headers: %s", sysroot_dir))
        end
        if not linux_sysroot_has_libc(sysroot_dir) then
            table.insert(warnings, errors.message("linux_sysroot does not contain libc.so or libc.a: %s", sysroot_dir))
        end
    end

    return warnings, actions
end

function preflight(target_os)
    if target_os ~= "linux" then
        return
    end
    local warnings, actions = preflight_warnings(target_os)
    if #warnings > 0 then
        run.stop_with_guidance(target_os, errors.message("Linux target sysroot settings are incomplete"), warnings, actions)
    end
end
