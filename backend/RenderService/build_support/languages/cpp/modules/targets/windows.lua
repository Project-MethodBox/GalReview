-- Windows target provider: MinGW sysroot preparation from the host
-- compiler, MinGW-w64 source download and headers/CRT/winpthreads
-- component builds, project binutils staging into the target sysroot, the
-- w64devkit readelf configure-cache repair, the PE/COFF contracts
-- default-handler link script, and the Windows configure arguments,
-- build plan, and preflight.

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
import("hostboot", {rootdir = path.join(os.scriptdir(), "..")})
import("gccinstall", {rootdir = path.join(os.scriptdir(), "..")})

function repair_windows_readelf_config_cache(target_os)
    if target_os ~= "windows" or not base.is_windows_host() then
        return
    end
    local gcc_config_dir = path.join(settings.gcc_build_dir(target_os), "gcc")
    local cache = path.join(gcc_config_dir, "config.cache")
    if not os.isfile(cache) then
        return
    end
    local content = io.readfile(cache)
    if not content:find("gcc_cv_readelf", 1, true) then
        return
    end
    if not content:find("w64devkit", 1, true)
        and not content:find(".toolchains/windows/x86_64-w64-mingw32/bin", 1, true)
        and not content:find(".toolchains/windows/windows/", 1, true) then
        return
    end
    print("removing stale GCC readelf configure cache: " .. cache)
    for _, file in ipairs({
        cache,
        path.join(gcc_config_dir, "config.status"),
        path.join(gcc_config_dir, "Makefile")
    }) do
        if os.exists(file) then
            layout.remove_toolchains_path(file)
        end
    end
end

local function copy_dir_contents(source, target)
    if os.isdir(source) then
        os.mkdir(target)
        os.cp(path.join(source, "*"), target)
        return true
    end
    return false
end

local function prepare_windows_target_sysroot(target_os)
    if target_os ~= "windows" then
        return
    end


    if not base.is_windows_host() or settings.is_cross_target(target_os) then
        install_mingw_w64_headers(target_os)
        return
    end

    local host_root = hosttools.windows_host_sysroot()
    if not host_root then
        errors.fail("cannot locate the host MinGW sysroot from %s; install a MinGW-style host compiler or put it in PATH", hosttools.windows_host_compiler())
    end

    local sysroot = settings.gcc_sysroot(target_os)
    local stamp = path.join(sysroot, ".xmake-host-sysroot")
    local old_stamp = os.isfile(stamp) and base.trim(io.readfile(stamp)) or ""
    local stamp_text = "v2\n" .. host_root
    local include_dir = path.join(sysroot, "include")
    local lib_dir = path.join(sysroot, "lib")
    local have_required_headers = os.isfile(path.join(include_dir, "stdio.h"))
        and os.isfile(path.join(include_dir, "stdarg.h"))
        and os.isfile(path.join(include_dir, "limits.h"))
    local have_required_crt = os.isfile(path.join(lib_dir, "crt2.o"))
    os.mkdir(sysroot)
    if old_stamp ~= stamp_text or not have_required_headers or not have_required_crt then
        print("preparing project-local MinGW sysroot from: " .. host_root)
        layout.remove_toolchains_path(include_dir)
        layout.remove_toolchains_path(lib_dir)
        if not copy_dir_contents(path.join(host_root, "include"), include_dir) then
            errors.fail("cannot copy MinGW headers from %s", path.join(host_root, "include"))
        end
        if not copy_dir_contents(path.join(host_root, "lib"), lib_dir) then
            errors.fail("cannot copy MinGW libraries from %s", path.join(host_root, "lib"))
        end
        if not os.isfile(path.join(include_dir, "stdio.h")) or not os.isfile(path.join(lib_dir, "crt2.o")) then
            errors.fail("copied MinGW sysroot is incomplete: %s", sysroot)
        end
        io.writefile(stamp, stamp_text .. "\n")
    end

    local host_bin = path.directory(hosttools.windows_host_compiler())
    local target_bin = path.join(sysroot, "bin")
    os.mkdir(target_bin)
    for _, name in ipairs({
        "as", "ld", "ar", "ranlib", "nm", "objcopy", "objdump",
        "strip", "dlltool", "windres", "readelf", "addr2line"
    }) do
        local plain = base.exe(name)
        local prefixed = base.exe(settings.managed_target(target_os) .. "-" .. name)
        local plain_source = path.join(host_bin, plain)
        local prefixed_source = path.join(host_bin, prefixed)
        local plain_target = path.join(target_bin, plain)
        local prefixed_target = path.join(target_bin, prefixed)
        if name == "readelf" then
            if os.exists(plain_target) and hostboot.managed_toolchains_is_w64devkit_alias(plain_target) then
                layout.remove_toolchains_path(plain_target)
            end
            if os.exists(prefixed_target) and hostboot.managed_toolchains_is_w64devkit_alias(prefixed_target) then
                layout.remove_toolchains_path(prefixed_target)
            end
            if not hostboot.managed_toolchains_is_w64devkit_alias(plain_source) then
                base.copy_if_exists(plain_source, plain_target)
            end
            if not hostboot.managed_toolchains_is_w64devkit_alias(prefixed_source) then
                base.copy_if_exists(prefixed_source, prefixed_target)
            end
        else
            base.copy_if_exists(plain_source, plain_target)
            base.copy_if_exists(prefixed_source, prefixed_target)
        end
    end
    hostboot.ensure_windows_host_binutils_aliases(target_os)
end

function sysroot(target_os)
    return settings.gcc_sysroot(target_os)
end

-- configure_gcc hook: build the MinGW sysroot, then clear any readelf
-- configure cache the w64devkit bootstrap may have poisoned (both original
-- call points ran back to back).
function prepare_sysroot(target_os)
    prepare_windows_target_sysroot(target_os)
    repair_windows_readelf_config_cache(target_os)
end

-- toolchain_installed hook: repair w64devkit readelf aliases and the
-- poisoned configure cache before the install is validated.
function repair_installed_tree(target_os)
    hostboot.repair_windows_readelf_aliases(target_os)
    repair_windows_readelf_config_cache(target_os)
end

local function find_extracted_mingw_w64_source(outputdir)
    if os.isfile(path.join(outputdir, "mingw-w64-headers", "configure"))
        and os.isfile(path.join(outputdir, "mingw-w64-crt", "configure")) then
        return outputdir
    end
    for _, dir in ipairs(os.dirs(path.join(outputdir, "*"))) do
        if os.isfile(path.join(dir, "mingw-w64-headers", "configure"))
            and os.isfile(path.join(dir, "mingw-w64-crt", "configure")) then
            return dir
        end
    end
    errors.fail("downloaded MinGW-w64 archive did not contain generated configure scripts")
end

local function patch_mingw_w64_source(src)
    local file = path.join(src, "mingw-w64-crt", "ssp", "stack_chk_guard.c")
    if not os.isfile(file) then
        return
    end

    local content = io.readfile(file)
    local patched = content
    patched = base.replace_plain(patched, "void *__stack_chk_guard;", "uintptr_t __stack_chk_guard;")
    patched = base.replace_plain(patched, "__stack_chk_guard = (void*)(intptr_t)ui;", "__stack_chk_guard = (uintptr_t)ui;")
    patched = base.replace_plain(patched, "__stack_chk_guard = (void*)(((intptr_t)__stack_chk_guard) << 32 | ui);", "__stack_chk_guard = (__stack_chk_guard << 32) | ui;")
    patched = base.replace_plain(patched, "__stack_chk_guard = (void*)0xdeadbeefdeadbeefULL;", "__stack_chk_guard = (uintptr_t)0xdeadbeefdeadbeefULL;")
    patched = base.replace_plain(patched, "__stack_chk_guard = (void*)0xdeadbeef;", "__stack_chk_guard = (uintptr_t)0xdeadbeef;")
    if patched ~= content then
        print("patching MinGW-w64 stack guard for GCC mainline")
        base.writefile_bytes(file, patched)
    end
end

local function download_mingw_w64_snapshot(force)
    local url = settings.value_or("mingw_w64_snapshot_url", defaults.mingw_w64_snapshot_url)
    local src = layout.mingw_w64_source_dir()
    local stamp = path.join(src, ".xmake-source")
    local source_signature = url .. "\n"
    if not force and os.isfile(path.join(src, "mingw-w64-headers", "configure"))
        and os.isfile(path.join(src, "mingw-w64-crt", "configure"))
        and os.isfile(stamp) and io.readfile(stamp) == source_signature then
        patch_mingw_w64_source(src)
        return src
    end

    local cache = layout.download_cache_dir()
    local archive = path.join(cache, gccsources.archive_leaf_name(url, "mingw-w64.tar.bz2"))
    local extracted = layout.extract_cache_dir("mingw-w64-source")
    download.download_and_extract_archive(url, archive, extracted, force)

    local source_root = find_extracted_mingw_w64_source(extracted)
    layout.remove_toolchains_path(src)
    os.mkdir(path.directory(src))
    os.mv(source_root, src)
    io.writefile(stamp, source_signature)
    layout.remove_toolchains_path(extracted)
    patch_mingw_w64_source(src)
    return src
end

-- build_binutils_for hook: refresh the project binutils copies in the GCC
-- prefix and the target sysroot bin directory.
function stage_binutils(target_os)
    if target_os ~= "windows" then
        return
    end

    local build = settings.binutils_build_dir(target_os)
    local prefix_bindir = path.join(settings.gcc_prefix(target_os), "bin")
    local target_bindir = path.join(settings.gcc_sysroot(target_os), "bin")
    local triplet = settings.managed_target(target_os)
    os.mkdir(prefix_bindir)
    local function replace_tool(source, target)
        if os.isfile(source) then
            if os.exists(target) then
                layout.remove_toolchains_path(target)
            end
            os.cp(source, target)
        end
    end
    if os.isdir(build) then
        for _, item in ipairs({
            {path.join(build, "gas", "as-new"), "as"},
            {path.join(build, "ld", "ld-new"), "ld"},
            {path.join(build, "ld", "ld-new"), "ld.bfd"},
            {path.join(build, "binutils", "addr2line"), "addr2line"},
            {path.join(build, "binutils", "ar"), "ar"},
            {path.join(build, "binutils", "dlltool"), "dlltool"},
            {path.join(build, "binutils", "nm-new"), "nm"},
            {path.join(build, "binutils", "objcopy"), "objcopy"},
            {path.join(build, "binutils", "objdump"), "objdump"},
            {path.join(build, "binutils", "ranlib"), "ranlib"},
            {path.join(build, "binutils", "readelf"), "readelf"},
            {path.join(build, "binutils", "size"), "size"},
            {path.join(build, "binutils", "strings"), "strings"},
            {path.join(build, "binutils", "strip-new"), "strip"},
            {path.join(build, "binutils", "windmc"), "windmc"},
            {path.join(build, "binutils", "windres"), "windres"}
        }) do
            replace_tool(item[1], path.join(prefix_bindir, base.exe(triplet .. "-" .. item[2])))
        end
    end
    os.mkdir(target_bindir)
    for _, name in ipairs({
        "addr2line", "ar", "as", "dlltool", "ld", "ld.bfd", "nm",
        "objcopy", "objdump", "ranlib", "readelf", "size", "strings",
        "strip", "windmc", "windres"
    }) do
        local prefixed = base.exe(triplet .. "-" .. name)
        base.copy_if_exists(path.join(prefix_bindir, prefixed), path.join(target_bindir, prefixed))
        base.copy_if_exists(path.join(prefix_bindir, prefixed), path.join(target_bindir, base.exe(name)))
    end
end

local function mingw_w64_arch_args(target_os)
    local triplet = settings.managed_target(target_os)
    if triplet:find("^x86_64") then
        return {"--enable-lib64", "--disable-lib32"}
    elseif triplet:find("^i[3-6]86") then
        return {"--enable-lib32", "--disable-lib64"}
    end
    return {}
end

local function mingw_w64_target_envs(target_os)
    local triplet = settings.managed_target(target_os)
    local prefix = settings.gcc_prefix(target_os)
    local envs = envs.make_envs(path.join(prefix, "bin"), path.join(settings.gcc_sysroot(target_os), "bin"))
    envs.CC = triplet .. "-gcc"
    envs.CXX = triplet .. "-g++"
    envs.AR = triplet .. "-ar"
    envs.AS = triplet .. "-as"
    envs.LD = triplet .. "-ld"
    envs.NM = triplet .. "-nm"
    envs.RANLIB = triplet .. "-ranlib"
    envs.STRIP = triplet .. "-strip"
    envs.DLLTOOL = triplet .. "-dlltool"
    envs.WINDRES = triplet .. "-windres"
    return envs
end

local function configure_mingw_w64_component(target_os, component, source_subdir, args, envs)
    local src = download_mingw_w64_snapshot(false)
    local source = path.join(src, source_subdir)
    local build = settings.mingw_w64_build_dir(target_os, component)
    local relsrc = path.relative(source, build)
    local sigfile = path.join(build, ".xmake-configure")
    local signature = gccinstall.configure_signature(args, target_os)
    local old_signature = os.isfile(sigfile) and base.trim(io.readfile(sigfile)) or ""
    if os.isfile(path.join(build, "Makefile")) and old_signature ~= base.trim(signature) then
        gccinstall.reset_build_dir(build)
    end
    os.mkdir(build)
    if os.isfile(path.join(build, "Makefile")) then
        print("using existing MinGW-w64 " .. component .. " build directory: " .. build)
    else
        gccsources.run_script(path.join(relsrc, "configure"), args, {curdir = build, envs = envs})
        io.writefile(sigfile, signature)
    end
    return build, envs
end

function install_mingw_w64_headers(target_os)
    if target_os ~= "windows" then
        return
    end

    local sysroot = settings.gcc_sysroot(target_os)
    local include_dir = path.join(sysroot, "include")
    if os.isfile(path.join(include_dir, "stdio.h"))
        and os.isfile(path.join(include_dir, "stdarg.h"))
        and os.isfile(path.join(include_dir, "_mingw.h")) then
        return
    end

    print("preparing project-local MinGW-w64 headers")
    local triplet = settings.managed_target(target_os)
    local args = {
        "--prefix=" .. base.shpath(sysroot),
        "--build=" .. settings.host_triplet(),
        "--host=" .. triplet,
        "--enable-sdk=all",
        "--enable-idl"
    }
    local build, envs = configure_mingw_w64_component(target_os, "headers", "mingw-w64-headers", args, envs.shell_envs(path.join(settings.gcc_prefix(target_os), "bin")))
    makerunner.run_make_target(hosttools.preferred_host_tool(settings.value_or("toolchains_make", "make")), build, envs, "install")
    if not os.isfile(path.join(include_dir, "stdio.h")) or not os.isfile(path.join(include_dir, "stdarg.h")) then
        errors.fail("MinGW-w64 headers install is incomplete: %s", include_dir)
    end
end

function install_mingw_w64_crt(target_os)
    if target_os ~= "windows" or (base.is_windows_host() and not settings.is_cross_target(target_os)) then
        return
    end

    local sysroot = settings.gcc_sysroot(target_os)
    local lib_dir = path.join(sysroot, "lib")
    if os.isfile(path.join(lib_dir, "crt2.o")) and os.isfile(path.join(lib_dir, "libkernel32.a")) then
        return
    end
    if not gccinstall.compiler_exists(target_os) then
        errors.fail("MinGW-w64 CRT requires the stage GCC compiler to be installed first")
    end

    install_mingw_w64_headers(target_os)
    stage_binutils(target_os)
    print("building project-local MinGW-w64 CRT")
    local triplet = settings.managed_target(target_os)
    local args = {
        "--prefix=" .. base.shpath(sysroot),
        "--build=" .. settings.host_triplet(),
        "--host=" .. triplet,
        "--with-sysroot=" .. base.shpath(sysroot),
        "--with-default-msvcrt=" .. settings.value_or("mingw_msvcrt", defaults.mingw_msvcrt)
    }
    for _, item in ipairs(mingw_w64_arch_args(target_os)) do
        table.insert(args, item)
    end
    local build, envs = configure_mingw_w64_component(target_os, "crt", "mingw-w64-crt", args, mingw_w64_target_envs(target_os))
    gccinstall.remove_empty_archives(build)
    local make = hosttools.preferred_host_tool(settings.value_or("toolchains_make", "make"))
    makerunner.run_make_target(make, build, envs, "")
    makerunner.run_make_target(make, build, envs, "install")
    if not os.isfile(path.join(lib_dir, "crt2.o")) or not os.isfile(path.join(lib_dir, "libkernel32.a")) then
        errors.fail("MinGW-w64 CRT install is incomplete: %s", lib_dir)
    end
end

function install_mingw_w64_winpthreads(target_os)
    if target_os ~= "windows" or (base.is_windows_host() and not settings.is_cross_target(target_os)) then
        return
    end

    local sysroot = settings.gcc_sysroot(target_os)
    local include_dir = path.join(sysroot, "include")
    local lib_dir = path.join(sysroot, "lib")
    if os.isfile(path.join(include_dir, "pthread.h")) and os.isfile(path.join(lib_dir, "libwinpthread.a")) then
        return
    end

    print("building project-local MinGW-w64 winpthreads")
    local triplet = settings.managed_target(target_os)
    local args = {
        "--prefix=" .. base.shpath(sysroot),
        "--build=" .. settings.host_triplet(),
        "--host=" .. triplet,
        "--enable-static",
        "--enable-shared"
    }
    local build, envs = configure_mingw_w64_component(target_os, "winpthreads", path.join("mingw-w64-libraries", "winpthreads"), args, mingw_w64_target_envs(target_os))
    local make = hosttools.preferred_host_tool(settings.value_or("toolchains_make", "make"))
    makerunner.run_make_target(make, build, envs, "")
    makerunner.run_make_target(make, build, envs, "install")
    if not os.isfile(path.join(include_dir, "pthread.h")) or not os.isfile(path.join(lib_dir, "libwinpthread.a")) then
        errors.fail("MinGW-w64 winpthreads install is incomplete: %s", sysroot)
    end
end

local function install_pecoff_contracts_default_handler_script(target_os)
    if target_os ~= "windows" then
        return
    end

    local prefix = settings.gcc_prefix(target_os)
    local content =
        "PROVIDE(_Z25handle_contract_violationRKNSt9contracts18contract_violationE = " ..
        "_Z27__handle_contract_violationRKNSt9contracts18contract_violationE);\n"
    for _, libdir in ipairs({
        path.join(prefix, "lib"),
        path.join(prefix, settings.managed_target(target_os), "lib")
    }) do
        if os.isdir(libdir) or os.isfile(path.join(libdir, "libstdc++exp.a")) then
            os.mkdir(libdir)
            local script = path.join(libdir, "libstdc++exp-contracts-default-handler.ld")
            if not os.isfile(script) or io.readfile(script) ~= content then
                io.writefile(script, content)
            end
        end
    end
end

function finalize(target_os)
    install_pecoff_contracts_default_handler_script(target_os)
end

function configure_args(target_os, args)
    table.insert(args, "--with-native-system-header-dir=" .. base.shpath(path.join(settings.gcc_sysroot(target_os), "include")))
    table.insert(args, "--disable-shared")
    table.insert(args, "--enable-static")
    table.insert(args, "--enable-threads=posix")
    return args
end

function target_tools(target_os)
    return {strip_globs = {path.join("**", "*.exe"), path.join("**", "*.dll")}}
end

function build_plan(target_os, context)
    if base.is_windows_host() and not settings.is_cross_target(target_os) then
        return {
            {
                log = "building native Windows GCC compiler pieces",
                targets = {"all-gcc", "all-c++tools", "all-target-libgcc", "configure-target-libstdc++-v3"},
                patch = true
            },
            {
                before = context.patch,
                targets = {"all-target-libstdc++-v3"},
                patch = true
            },
            {
                targets = {"install-gcc", "install-c++tools", "install-target-libgcc", "install-target-libstdc++-v3"}
            }
        }
    end
    return {
        {
            log = "building cross Windows GCC compiler pieces",
            targets = {"all-gcc", "all-c++tools", "install-gcc", "install-c++tools"},
            patch = true
        },
        {
            after = function ()
                install_mingw_w64_crt(target_os)
                install_mingw_w64_winpthreads(target_os)
            end
        },
        {
            targets = {"all-target-libgcc", "install-target-libgcc"},
            patch = true
        },
        {
            targets = {"configure-target-libstdc++-v3", "all-target-libstdc++-v3", "install-target-libstdc++-v3"},
            patch = true
        }
    }
end

-- Read-only preflight probe (matrix-consumable); preflight() below turns a
-- non-empty result into the loud stop. The host sysroot probe queries the
-- host compiler once -- read-only, but second-scale.
function preflight_warnings(target_os)
    if target_os ~= "windows" then
        return {}, {}
    end
    if not base.is_windows_host() or settings.is_cross_target(target_os) then
        return {}, {}
    end
    local warnings = {}
    local actions = {
        errors.message("Keep the default --toolchains_bootstrap=auto so xmake can fetch a temporary latest w64devkit bootstrap toolchain."),
        errors.message("Or use a MinGW-w64 distribution with headers, libraries, and POSIX build tools in PATH, such as MSYS2 UCRT64 or w64devkit."),
        errors.message("Set --toolchains_bootstrap_path=<path> to an existing portable MinGW root/bin directory, or --toolchains_bootstrap=none to require a system toolchain."),
        errors.message("A bare gcc.exe is not enough for a native Windows GCC bootstrap."),
        errors.message("Then rerun plain `xmake` or `xmake toolchains install windows`.")
    }
    local sysroot = hosttools.windows_host_sysroot()
    if not sysroot then
        table.insert(warnings, errors.message("The host GCC does not expose a usable MinGW-w64 sysroot."))
    end
    return warnings, actions
end

function preflight(target_os)
    local warnings, actions = preflight_warnings(target_os)
    if #warnings > 0 then
        run.stop_with_guidance(target_os, errors.message("Windows host MinGW settings are incomplete"), warnings, actions)
    end
end
