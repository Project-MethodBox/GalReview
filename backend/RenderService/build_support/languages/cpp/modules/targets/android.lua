-- Android target provider: NDK layout probing (sysroot, LLVM bin, API
-- level, per-triplet include and stub-library directories), the GCC/NDK
-- header compatibility patches, Android compile/library/driver flag
-- composition, the ld.lld launcher staging, the Android build-tree makefile
-- and specs patch pass, and the Android preflight.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("run", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("androidndk", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("gccinstall", {rootdir = path.join(os.scriptdir(), "..")})

-- NDK discovery lives in core/modules/androidndk.lua (shared with the APK
-- packaging family); these historical entry points forward to it and keep
-- their gcctargets-facing signatures unchanged.
function android_ndk_sysroot()
    return androidndk.sysroot()
end

function android_ndk_bin_dir()
    return androidndk.llvm_bin_dir()
end

function sysroot(target_os)
    return android_ndk_sysroot()
end

function android_api_level()
    local api = tonumber(tostring(settings.value_or("android_api", "26")):match("%d+")) or 26
    if api < 26 then
        api = 26
    end
    return tostring(api)
end

function android_arch_include_dir(target_os)
    if target_os ~= "android" then
        return nil
    end
    local sysroot = android_ndk_sysroot()
    if not sysroot then
        return nil
    end
    local dir = path.join(sysroot, "usr", "include", settings.managed_target(target_os))
    if os.isdir(dir) then
        return dir
    end
end

function android_sysroot_include_dir(target_os)
    if target_os ~= "android" then
        return nil
    end
    local sysroot = android_ndk_sysroot()
    if not sysroot then
        return nil
    end
    local dir = path.join(sysroot, "usr", "include")
    if os.isdir(dir) then
        return dir
    end
end

function android_gcc_compat_header()
    local header = path.join(layout.tools_cache_dir(), "android", "gcc-ndk-compat.h")
    return header
end

function ensure_android_gcc_compat_header()
    -- Runs from script-scope callbacks only (toolchains task, rule hooks).
    -- Composed target flags reference this header by absolute path, so it
    -- must exist by the time any of them is used; failing to write it is a
    -- hard error, never a silent skip (the old capability guard here checked
    -- core.lua LOCALS that were invisible cross-chunk and skipped the write).
    local header = android_gcc_compat_header()
    local content = table.concat({
        "#ifndef XMAKE_ANDROID_GCC_NDK_COMPAT_H",
        "#define XMAKE_ANDROID_GCC_NDK_COMPAT_H",
        "#ifndef __clang__",
        "#define BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD 1",
        "#ifndef __has_feature",
        "#define __has_feature(x) 0",
        "#endif",
        "#ifndef __has_attribute",
        "#define __has_attribute(x) 0",
        "#endif",
        "#ifndef __has_include",
        "#define __has_include(x) 0",
        "#endif",
        "#ifndef _Nonnull",
        "#define _Nonnull",
        "#endif",
        "#ifndef _Nullable",
        "#define _Nullable",
        "#endif",
        "#ifndef _Null_unspecified",
        "#define _Null_unspecified",
        "#endif",
        "#ifndef __availability__",
        "#define __availability__(...)",
        "#endif",
        "#ifndef __enable_if__",
        "#define __enable_if__(...)",
        "#endif",
        "#ifndef __diagnose_if__",
        "#define __diagnose_if__(...)",
        "#endif",
        "#ifndef __diagnose_as_builtin__",
        "#define __diagnose_as_builtin__(...)",
        "#endif",
        "#ifndef __overloadable__",
        "#define __overloadable__",
        "#endif",
        "#ifndef __pass_object_size__",
        "#define __pass_object_size__(...)",
        "#endif",
        "#if !defined(__ASSEMBLER__) && !defined(__ASSEMBLY__)",
        "#include <sys/cdefs.h>",
        "#undef __BIONIC_AVAILABILITY",
        "#define __BIONIC_AVAILABILITY(...)",
        "#undef __INTRODUCED_IN",
        "#define __INTRODUCED_IN(api_level)",
        "#undef __INTRODUCED_IN_32",
        "#define __INTRODUCED_IN_32(api_level)",
        "#undef __INTRODUCED_IN_64",
        "#define __INTRODUCED_IN_64(api_level)",
        "#undef __DEPRECATED_IN",
        "#define __DEPRECATED_IN(api_level, msg)",
        "#undef __REMOVED_IN",
        "#define __REMOVED_IN(api_level, msg)",
        "#undef __printflike",
        "#define __printflike(x, y)",
        "#undef __scanflike",
        "#define __scanflike(x, y)",
        "#undef __strftimelike",
        "#define __strftimelike(x)",
        "#undef __enable_if",
        "#define __enable_if(cond, msg)",
        "#undef __clang_error_if",
        "#define __clang_error_if(cond, msg)",
        "#undef __clang_warning_if",
        "#define __clang_warning_if(cond, msg)",
        "#undef __diagnose_as_builtin",
        "#define __diagnose_as_builtin(...)",
        "#undef __overloadable",
        "#define __overloadable",
        "#endif",
        "#endif",
        "#endif",
        ""
    }, "\n")
    if not os.isfile(header) or io.readfile(header) ~= content then
        os.mkdir(path.directory(header))
        io.writefile(header, content)
        if not os.isfile(header) then
            errors.fail("failed to write Android GCC/NDK compatibility header: %s", header)
        end
    end
    return header
end

function patch_android_ndk_headers_for_gcc(target_os)
    if target_os ~= "android" then
        return
    end
    local sysroot = android_ndk_sysroot()
    if not sysroot then
        return
    end

    local function patch_file(file, label, patches)
        if not os.isfile(file) then
            return
        end
        local content = io.readfile(file)
        local patched = content
        for _, patch in ipairs(patches) do
            patched = base.replace_plain(patched, patch[1], patch[2])
        end
        if label == "string.h" then
            patched = patched:gsub("#if defined%(__cplusplus%)%s*&&%s*defined%(__clang__%)[^\n]*",
                "#if defined(__cplusplus) && defined(__clang__)")
        elseif label == "sys/cdefs.h" then
            local overloadable = table.concat({
                "#if defined(__clang__)",
                "#define __overloadable __attribute__((__overloadable__))",
                "#else",
                "#define __overloadable",
                "#endif"
            }, "\n")
            local diagnose = table.concat({
                "#if defined(__clang__)",
                "#define __diagnose_as_builtin(...) __attribute__((__diagnose_as_builtin__(__VA_ARGS__)))",
                "#else",
                "#define __diagnose_as_builtin(...)",
                "#endif"
            }, "\n")
            patched = base.replace_plain(patched, table.concat({
                "#if defined(__clang__)",
                "#if defined(__clang__)",
                "#define __overloadable __attribute__((__overloadable__))",
                "#else",
                "#define __overloadable",
                "#endif",
                "#else",
                "#define __overloadable",
                "#endif"
            }, "\n"), overloadable)
            patched = base.replace_plain(patched, table.concat({
                "#if defined(__clang__)",
                "#if defined(__clang__)",
                "#define __diagnose_as_builtin(...) __attribute__((__diagnose_as_builtin__(__VA_ARGS__)))",
                "#else",
                "#define __diagnose_as_builtin(...)",
                "#endif",
                "#else",
                "#define __diagnose_as_builtin(...)",
                "#endif"
            }, "\n"), diagnose)
        end
        if patched ~= content then
            print("patching Android NDK header for GCC: " .. label)
            base.writefile_bytes(file, patched)
        end
    end

    patch_file(path.join(sysroot, "usr", "include", "string.h"), "string.h", {
        {
            "/* Const-correct overloads. Placed after FORTIFY so we call those functions, if possible. */\n#if defined(__cplusplus)",
            "/* Const-correct overloads. Placed after FORTIFY so we call those functions, if possible. */\n#if defined(__cplusplus) && defined(__clang__)"
        }
    })
    patch_file(path.join(sysroot, "usr", "include", "sys", "cdefs.h"), "sys/cdefs.h", {
        {
            "#  define __pass_object_size_n(n) __attribute__((__pass_object_size__(n)))",
            "#  if defined(__clang__)\n#    define __pass_object_size_n(n) __attribute__((__pass_object_size__(n)))\n#  else\n#    define __pass_object_size_n(n)\n#  endif"
        },
        {
            "#define __overloadable __attribute__((__overloadable__))",
            "#if defined(__clang__)\n#define __overloadable __attribute__((__overloadable__))\n#else\n#define __overloadable\n#endif"
        },
        {
            "#define __diagnose_as_builtin(...) __attribute__((__diagnose_as_builtin__(__VA_ARGS__)))",
            "#if defined(__clang__)\n#define __diagnose_as_builtin(...) __attribute__((__diagnose_as_builtin__(__VA_ARGS__)))\n#else\n#define __diagnose_as_builtin(...)\n#endif"
        }
    })
end

function patch_android_libstdcxx_bionic_ctype(target_os, build)
    if target_os ~= "android" then
        return
    end

    local function patch_file(file, label)
        if not os.isfile(file) then
            return
        end
        local content = io.readfile(file)
        local patched = content
        if not patched:find("#include <ctype.h>", 1, true) then
            patched = base.replace_plain(patched,
                "// Information as gleaned from /usr/include/ctype.h\n",
                "// Information as gleaned from /usr/include/ctype.h\n\n#include <ctype.h>\n")
        end
        local replacements = {
            _U = "_CTYPE_U",
            _L = "_CTYPE_L",
            _N = "_CTYPE_D",
            _X = "_CTYPE_X",
            _S = "_CTYPE_S",
            _P = "_CTYPE_P",
            _B = "_CTYPE_B",
            _C = "_CTYPE_C"
        }
        for old, new in pairs(replacements) do
            patched = patched:gsub("([^%w_])" .. base.escape_pattern(old) .. "([^%w_])", "%1" .. new .. "%2")
        end
        if patched ~= content then
            print("patching GCC libstdc++ Bionic ctype for NDK r29: " .. label)
            base.writefile_bytes(file, patched)
        end
    end

    patch_file(path.join(settings.gcc_source_dir(target_os), "libstdc++-v3", "config", "os", "bionic", "ctype_base.h"),
        "source libstdc++-v3/config/os/bionic/ctype_base.h")

    if build then
        local libstdcxx = path.join(build, settings.managed_target(target_os), "libstdc++-v3")
        if os.isdir(libstdcxx) then
            for _, file in ipairs(os.files(path.join(libstdcxx, "**", "ctype_base.h"))) do
                patch_file(file, "build " .. path.relative(file, libstdcxx))
            end
        end
    end
end

function android_target_compile_flags(target_os)
    if target_os ~= "android" then
        return ""
    end
    local flags = {}
    local sysroot = android_ndk_sysroot()
    if sysroot then
        table.insert(flags, "--sysroot=" .. base.shpath(sysroot))
    end
    local arch_include = android_arch_include_dir(target_os)
    if arch_include then
        table.insert(flags, "-idirafter" .. base.shpath(arch_include))
    end
    local sysroot_include = android_sysroot_include_dir(target_os)
    if sysroot_include then
        table.insert(flags, "-idirafter" .. base.shpath(sysroot_include))
    end
    table.insert(flags, "-include " .. base.shpath(ensure_android_gcc_compat_header()))
    local api = android_api_level()
    table.insert(flags, "-D__ANDROID_API__=" .. api)
    table.insert(flags, "-D__ANDROID_MIN_SDK_VERSION__=" .. api)
    return table.concat(flags, " ")
end

function android_api_library_dir(target_os)
    if target_os ~= "android" then
        return nil
    end
    local sysroot = android_ndk_sysroot()
    if not sysroot then
        return nil
    end
    local libroot = path.join(sysroot, "usr", "lib", settings.managed_target(target_os))
    local api_lib = path.join(libroot, android_api_level())
    if os.isdir(api_lib) then
        return api_lib
    end
    if os.isdir(libroot) then
        return libroot
    end
end

function android_library_root(target_os)
    if target_os ~= "android" then
        return nil
    end
    local sysroot = android_ndk_sysroot()
    if not sysroot then
        return nil
    end
    local libroot = path.join(sysroot, "usr", "lib", settings.managed_target(target_os))
    if os.isdir(libroot) then
        return libroot
    end
end

function android_target_library_flags(target_os)
    if target_os ~= "android" then
        return ""
    end
    local sysroot = android_ndk_sysroot()
    if not sysroot then
        return ""
    end
    local libroot = path.join(sysroot, "usr", "lib", settings.managed_target(target_os))
    local flags = {}
    local api_lib = android_api_library_dir(target_os)
    table.insert(flags, "--sysroot=" .. base.shpath(sysroot))
    if api_lib then
        table.insert(flags, "-B" .. base.shpath(api_lib) .. "/")
        table.insert(flags, "-L" .. base.shpath(api_lib))
    end
    if os.isdir(libroot) then
        table.insert(flags, "-L" .. base.shpath(libroot))
    end
    return table.concat(flags, " ")
end

function android_target_driver_flags(target_os)
    if target_os ~= "android" then
        return ""
    end
    local flags = {}
    local compile_flags = android_target_compile_flags(target_os)
    if compile_flags ~= "" then
        table.insert(flags, compile_flags)
    end
    local api_lib = android_api_library_dir(target_os)
    local libroot = android_library_root(target_os)
    if api_lib then
        table.insert(flags, "-B" .. base.shpath(api_lib) .. "/")
        table.insert(flags, "-L" .. base.shpath(api_lib))
    end
    if libroot then
        table.insert(flags, "-L" .. base.shpath(libroot))
    end
    table.insert(flags, "-static-libgcc")
    return table.concat(flags, " ")
end

function stage_tools(target_os)
    if target_os ~= "android" then
        return
    end

    local ndk_bin = android_ndk_bin_dir()
    if not ndk_bin then
        errors.fail("cannot locate Android NDK LLVM bin directory; set android_ndk or ANDROID_NDK_HOME")
    end
    local lld = path.join(ndk_bin, base.exe("ld.lld"))
    if not os.isfile(lld) then
        errors.fail("cannot locate Android NDK ld.lld: %s", lld)
    end

    ensure_android_gcc_compat_header()
    patch_android_ndk_headers_for_gcc(target_os)

    local triplet = settings.managed_target(target_os)
    local function install_launcher(bindir, name)
        os.mkdir(bindir)
        local target = path.join(bindir, name)
        if base.is_windows_host() then
            os.cp(lld, target)
        else
            io.writefile(target, "#!/bin/sh\nexec " .. base.shquote(lld) .. " \"$@\"\n")
            run.run_program("making Android linker launcher executable", "chmod", {"+x", target}, {target_os = target_os})
        end
    end

    local prefix_bin = path.join(settings.gcc_prefix(target_os), "bin")
    for _, stale in ipairs({base.exe("ld"), base.exe("ld.lld")}) do
        local file = path.join(prefix_bin, stale)
        if os.exists(file) then
            os.rm(file)
        end
    end
    for _, name in ipairs({
        base.exe(triplet .. "-ld"),
        base.exe(triplet .. "-ld.lld")
    }) do
        install_launcher(prefix_bin, name)
    end

    local target_bin = path.join(settings.gcc_sysroot(target_os), "bin")
    for _, name in ipairs({
        base.exe("ld"),
        base.exe("ld.lld"),
        base.exe(triplet .. "-ld"),
        base.exe(triplet .. "-ld.lld")
    }) do
        install_launcher(target_bin, name)
    end

    if base.is_windows_host() then
        for _, bindir in ipairs({prefix_bin, target_bin}) do
            local libdir = path.join(path.directory(bindir), "lib")
            os.mkdir(libdir)
            for _, pattern in ipairs({"*.dll", "*.so", "*.so.*", "*.dylib"}) do
                for _, runtime in ipairs(os.files(path.join(ndk_bin, pattern))) do
                    os.cp(runtime, path.join(bindir, path.filename(runtime)))
                end
                for _, runtime in ipairs(os.files(path.join(ndk_bin, "..", "lib", pattern))) do
                    os.cp(runtime, path.join(libdir, path.filename(runtime)))
                end
            end
        end
    end
end

-- build_gcc_for hook: the source-tree Bionic ctype patch must land before
-- configure so the generated build trees inherit it.
function prepare_runtime_inputs(target_os)
    patch_android_libstdcxx_bionic_ctype(target_os)
end

function installed_extra(target_os)
    local stamp = settings.stamp_file(target_os)
    if not os.isfile(stamp) then
        return false
    end
    local content = io.readfile(stamp)
    if not content:find("android_libstdcxx_pic=true", 1, true) then
        return false
    end
    -- NDK drift visibility: stamps written since the androidndk unification
    -- record the resolved NDK root/version and android_api; any mismatch
    -- against the current resolution invalidates the install (the changed
    -- signature_extra then also forces a reconfigure). Older stamps without
    -- these keys are grandfathered until their next rebuild re-stamps them.
    local recorded_root = content:match("[\r\n]android_ndk=([^\r\n]*)")
    if recorded_root ~= nil then
        local resolved = androidndk.resolve()
        local recorded_version = content:match("[\r\n]android_ndk_version=([^\r\n]*)") or ""
        local recorded_api = content:match("[\r\n]android_api=([^\r\n]*)") or ""
        if recorded_root ~= tostring(resolved.root or "")
            or recorded_version ~= tostring(resolved.version or "")
            or recorded_api ~= android_api_level() then
            return false
        end
    end
    local prefix = settings.gcc_prefix(target_os)
    local has_meta = gccinstall.installed_cxx_header(prefix, "meta")
    local has_libstdcxx = gccinstall.installed_library(prefix, target_os, {"libstdc++.a"})
    local has_libstdcxxexp = gccinstall.installed_library(prefix, target_os, {"libstdc++exp.a"})
    return has_meta and has_libstdcxx and has_libstdcxxexp and gccinstall.installed_std_module_valid(prefix)
end

-- The resolved NDK identity joins both the install stamp and the
-- .xmake-configure signature: swapping the NDK version, moving its root, or
-- changing android_api must reconfigure and rebuild the Android toolchain
-- instead of silently reusing runtimes built against the old sysroot.
function signature_extra(target_os)
    local resolved = androidndk.resolve()
    return "android_ndk=" .. tostring(resolved.root or "") .. "\n"
        .. "android_ndk_version=" .. tostring(resolved.version or "") .. "\n"
        .. "android_api=" .. android_api_level() .. "\n"
end

function stamp_extra(target_os)
    return "android_libstdcxx_pic=true\n" .. signature_extra(target_os)
end

function configure_args(target_os, args)
    local sysroot_dir = android_ndk_sysroot()
    if sysroot_dir and os.isdir(sysroot_dir) then
        table.insert(args, "--with-sysroot=" .. base.shpath(sysroot_dir))
        table.insert(args, "--with-build-sysroot=" .. base.shpath(sysroot_dir))
        table.insert(args, "--disable-shared")
        table.insert(args, "--with-pic")
        table.insert(args, "CFLAGS_FOR_TARGET=" .. settings.target_cflags(target_os))
        table.insert(args, "CXXFLAGS_FOR_TARGET=" .. settings.target_cxxflags(target_os))
        table.insert(args, "LIBCFLAGS_FOR_TARGET=" .. settings.target_cflags(target_os))
        table.insert(args, "--enable-threads=posix")
    else
        table.insert(args, "--without-headers")
        table.insert(args, "--disable-shared")
        table.insert(args, "--disable-threads")
    end
    return args
end

-- Per-invocation Android makefile patch helpers bound to (target_os, build).
-- gccbuild's patch_gcc_makefile_for_windows weaves these into its host patch
-- pass: patch_target_flags per generated makefile, the rewrite_* helpers per
-- scanned makefile line, and the three cluster entry points before the
-- Windows-host gate. Both historical call points of the target-flag patching
-- are preserved intentionally (the pass is idempotent); do not merge them
-- without a full Android rebuild as evidence.
function makefile_patch_context(target_os, build)
    local target_triplet = settings.managed_target(target_os)
    local makefile = path.join(build, "Makefile")
    local android_flags = android_target_driver_flags(target_os)
    local android_lib_flags = android_target_library_flags(target_os)

    local function normalize_android_driver_flags(value)
        value = value or ""
        local api = android_api_level()
        value = value:gsub("%-D__ANDROID_API__=%d+", "-D__ANDROID_API__=" .. api)
        value = value:gsub("%-D__ANDROID_MIN_SDK_VERSION__=%d+", "-D__ANDROID_MIN_SDK_VERSION__=" .. api)
        local sysroot_include = android_sysroot_include_dir(target_os)
        sysroot_include = sysroot_include and base.shpath(sysroot_include) or nil
        local sysroot = android_ndk_sysroot()
        local sysroot_text = sysroot and base.shpath(sysroot) or nil
        local arch_include = android_arch_include_dir(target_os)
        arch_include = arch_include and base.shpath(arch_include) or nil
        local compat_header = base.shpath(android_gcc_compat_header())
        local libroot = android_library_root(target_os)
        local libroot_text = libroot and base.shpath(libroot) or nil
        if libroot then
            value = value:gsub(base.escape_pattern(libroot_text) .. "/%d+", libroot_text .. "/" .. api)
        end
        local source = {}
        for word in value:gmatch("%S+") do
            table.insert(source, word)
        end
        local words = {}
        local index = 1
        while index <= #source do
            local word = source[index]
            local next_word = source[index + 1]
            if (word == "-isystem" or word == "-idirafter") and sysroot_include and next_word == sysroot_include then
                index = index + 2
            elseif (word == "-isystem" or word == "-idirafter") and arch_include and next_word == arch_include then
                index = index + 2
            elseif sysroot_include and word == "-idirafter" .. sysroot_include then
                index = index + 1
            elseif arch_include and word == "-idirafter" .. arch_include then
                index = index + 1
            elseif word == "-include" and next_word == compat_header then
                index = index + 2
            elseif sysroot_text and word == "--sysroot=" .. sysroot_text then
                index = index + 1
            elseif word == "--sysroot" then
                index = index + 2
            elseif word:match("^%-D__ANDROID_API__=") or word:match("^%-D__ANDROID_MIN_SDK_VERSION__=") then
                index = index + 1
            elseif word == "-static-libgcc" then
                index = index + 1
            elseif libroot_text and word:match("^%-B" .. base.escape_pattern(libroot_text) .. "/%d+/?$") then
                index = index + 1
            elseif libroot_text and word:match("^%-L" .. base.escape_pattern(libroot_text) .. "/%d+$") then
                index = index + 1
            elseif libroot_text and word == "-L" .. libroot_text then
                index = index + 1
            else
                table.insert(words, word)
                index = index + 1
            end
        end
        return base.append_flags_once(table.concat(words, " "), android_flags)
    end

    local function patch_android_target_flags(file, label)
        if target_os ~= "android" or android_flags == "" or not os.isfile(file) then
            return
        end
        local lines = io.readfile(file):split("\n", {plain = true})
        local output = {}
        local patched = false
        for _, line in ipairs(lines) do
            local left, value = line:match("^(SYSROOT_CFLAGS_FOR_TARGET%s*=%s*)(.*)$")
            if left then
                table.insert(output, left .. normalize_android_driver_flags(value))
                patched = true
            else
                left, value = line:match("^([%w_]+%s*=%s*)(.*)$")
                if left and value:find("xgcc", 1, true) and (value:find("--sysroot=", 1, true) or value:find("gcc-ndk-compat", 1, true)) then
                    table.insert(output, left .. normalize_android_driver_flags(value))
                    patched = true
                else
                    table.insert(output, line)
                end
            end
        end
        local patched_content = table.concat(output, "\n")
        if label == "libgcc/Makefile" and android_lib_flags ~= "" then
            patched_content = patched_content:gsub("\n# xmake android libgcc link begin\n.-\n# xmake android libgcc link end\n?", "\n")
            patched_content = patched_content .. table.concat({
                "",
                "# xmake android libgcc link begin",
                "SHLIB_LC = " .. android_lib_flags .. " -lc",
                "SHLIB_LINK = $(CC) $(LIBGCC2_CFLAGS) -shared -nostartfiles -nodefaultlibs $(SHLIB_LDFLAGS) $(LDFLAGS) -o $(SHLIB_DIR)/$(SHLIB_SONAME).tmp @multilib_flags@ $(SHLIB_OBJS) $(SHLIB_LC) && rm -f $(SHLIB_DIR)/$(SHLIB_SOLINK) && if [ -f $(SHLIB_DIR)/$(SHLIB_SONAME) ]; then mv -f $(SHLIB_DIR)/$(SHLIB_SONAME) $(SHLIB_DIR)/$(SHLIB_SONAME).backup; else true; fi && mv $(SHLIB_DIR)/$(SHLIB_SONAME).tmp $(SHLIB_DIR)/$(SHLIB_SONAME) && $(SHLIB_MAKE_SOLINK) && $(SHLIB_MAKE_ASNEEDED_SOLINK)",
                "# xmake android libgcc link end",
                ""
            }, "\n")
            patched = true
        end
        if patched then
            print("patching GCC " .. label .. ": add Android target sysroot include/API flags")
            base.writefile_bytes(file, patched_content)
        end
    end

    local context = {}

    function context.patch_target_flags(file, label)
        patch_android_target_flags(file, label)
    end

    function context.patch_generated_makefiles()
        patch_android_libstdcxx_bionic_ctype(target_os, build)
        if target_os == "android" and os.isfile(makefile) then
            local content = io.readfile(makefile)
            local patched = base.replace_plain(content, "'--enable-shared'", "'--disable-shared'")
            patched = base.replace_plain(patched, "\"--enable-shared\"", "\"--disable-shared\"")
            patched = base.replace_plain(patched, "'-'--disable-shared'", "'--disable-shared'")
            patched = base.replace_plain(patched, "-shared-libgcc", "-static-libgcc")
            if patched ~= content then
                print("patching GCC top-level Makefile: Android static libgcc/libstdc++ target runtime")
                io.writefile(makefile, patched)
            end
        end
        patch_android_target_flags(makefile, "top-level Makefile")
        patch_android_target_flags(path.join(build, target_triplet, "libgcc", "Makefile"), "libgcc/Makefile")
        local libstdcxx = path.join(build, target_triplet, "libstdc++-v3")
        if os.isdir(libstdcxx) then
            patch_android_target_flags(path.join(libstdcxx, "Makefile"), "libstdc++-v3/Makefile")
            for _, generated in ipairs(os.files(path.join(libstdcxx, "**", "Makefile"))) do
                patch_android_target_flags(generated, "libstdc++-v3/" .. path.relative(generated, libstdcxx))
            end
        end
    end

    function context.clean_failed_libstdcxx_configure()
        if target_os ~= "android" then
            return
        end
        local libstdcxx = path.join(build, target_triplet, "libstdc++-v3")
        local config_log = path.join(libstdcxx, "config.log")
        local makefile = path.join(libstdcxx, "Makefile")
        if os.isdir(libstdcxx) and not os.isfile(makefile) and os.isfile(config_log) then
            local log = io.readfile(config_log)
            if log:find("configure: exit 1", 1, true) then
                print("cleaning failed Android libstdc++ configure directory")
                os.rm(libstdcxx)
            end
        end
    end

    function context.patch_gcc_specs()
        if target_os ~= "android" then
            return
        end
        local api_lib = android_api_library_dir(target_os)
        if not api_lib then
            return
        end
        local api = base.shpath(api_lib)
        local specs_files = {path.join(build, "gcc", "specs")}
        local gcc_lib_root = path.join(settings.gcc_prefix(target_os), "lib", "gcc", target_triplet)
        if os.isdir(gcc_lib_root) then
            for _, dir in ipairs(os.dirs(path.join(gcc_lib_root, "*"))) do
                table.insert(specs_files, path.join(dir, "specs"))
            end
        end
        local startfile = table.concat({
            "*startfile:",
            "%{shared:" .. api .. "/crtbegin_so.o;static:" .. api .. "/crtbegin_static.o;static-pie|pie:" .. api .. "/crtbegin_dynamic.o;:" .. api .. "/crtbegin_dynamic.o}",
            ""
        }, "\n")
        local endfile = table.concat({
            "*endfile:",
            "%{shared:" .. api .. "/crtend_so.o;:" .. api .. "/crtend_android.o}",
            ""
        }, "\n")
        for _, specs in ipairs(specs_files) do
            if os.isfile(specs) then
                local content = io.readfile(specs)
                local patched = content
                patched = patched:gsub("%*startfile:\n.-\n\n", function () return startfile .. "\n" end, 1)
                patched = patched:gsub("%*endfile:\n.-\n\n", function () return endfile .. "\n" end, 1)
                if settings.managed_target(target_os):find("aarch64", 1, true) then
                    patched = base.replace_plain(patched, "/system/bin/linker}", "/system/bin/linker64}")
                end
                if patched ~= content then
                    print("patching GCC specs for Android NDK CRT: " .. specs)
                    io.writefile(specs, patched)
                end
            elseif specs ~= specs_files[1] and os.isdir(path.directory(specs)) and os.isfile(specs_files[1]) then
                print("installing Android GCC specs: " .. specs)
                os.cp(specs_files[1], specs)
            end
        end
    end

    function context.rewrite_toplevel_sysroot_cflags(line)
        if not line:match("^SYSROOT_CFLAGS_FOR_TARGET%s*=") then
            return nil
        end
        local left, value = line:match("^(SYSROOT_CFLAGS_FOR_TARGET%s*=%s*)(.*)$")
        return left .. base.append_flags_once(value, android_flags)
    end

    function context.rewrite_gcc_stmp_fixinc(line)
        if line:match("^STMP_FIXINC%s*=%s*stmp%-fixinc") then
            return "STMP_FIXINC ="
        end
        return nil
    end

    return context
end

function build_plan(target_os, context)
    if not settings.is_cross_target(target_os) then
        return {
            {log = "building native GCC toolchain", targets = {"", "install"}}
        }
    end
    return {
        {
            log = "building Android GCC compiler and target runtime",
            targets = {"all-gcc", "install-gcc", "configure-target-libgcc"},
            patch = true
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

-- Read-only preflight probe: aggregates every warning without stopping, so
-- the matrix command can display missing prerequisites side-effect-free.
-- preflight() below turns a non-empty result into the loud stop.
function preflight_warnings(target_os)
    if target_os ~= "android" then
        return {}, {}
    end
    local warnings = {}
    local actions = {
        errors.message("Set an NDK explicitly: xmake f -p android -a arm64-v8a --android_ndk=<ndk-root> --android_api=26"),
        errors.message("Or export ANDROID_NDK_HOME/ANDROID_NDK_ROOT/NDK_HOME before running xmake."),
        errors.message("Or install one into the Android SDK: xmake android ndk install r27c (SDK-installed NDKs are discovered automatically)."),
        errors.message("Run `xmake toolchains status android` to re-check the detected paths.")
    }

    local api_text = tostring(settings.value_or("android_api", "26"))
    local api = tonumber((api_text:gsub("^android%-", "")))
    if not api then
        table.insert(warnings, errors.message("android_api is not numeric: %s", api_text))
    elseif api < 26 then
        table.insert(warnings, errors.message("android_api=%s is too old for the managed Android libstdc++/<meta> runtime; use 26 or newer.", api_text))
    end

    local resolved = androidndk.resolve()
    for _, problem in ipairs(resolved.problems) do
        table.insert(warnings, androidndk.problem_text(problem))
    end
    local root = resolved.root
    if not root then
        if #resolved.problems == 0 then
            table.insert(warnings, errors.message("Android NDK is not configured. The manager cannot provide Android headers, libc stubs, or ld.lld without it."))
        end
    else
        local host_tag = androidndk.host_tag()
        if not host_tag then
            table.insert(warnings, errors.message("No Android NDK prebuilt host tag is known for this host: %s", base.host_os()))
        elseif not os.isdir(path.join(root, "toolchains", "llvm", "prebuilt", host_tag)) then
            table.insert(warnings, errors.message("The Android NDK does not contain the expected LLVM prebuilt directory: toolchains/llvm/prebuilt/%s", host_tag))
        end

        local ndk_bin = android_ndk_bin_dir()
        if not ndk_bin then
            table.insert(warnings, errors.message("The Android NDK LLVM bin directory was not found under: %s", root))
        elseif not os.isfile(path.join(ndk_bin, base.exe("ld.lld"))) then
            table.insert(warnings, errors.message("The Android NDK linker ld.lld was not found in: %s", ndk_bin))
        end

        local sysroot = android_ndk_sysroot()
        if not sysroot then
            table.insert(warnings, errors.message("The Android NDK sysroot was not found under: %s", root))
        else
            local include_dir = android_sysroot_include_dir(target_os)
            local arch_include_dir = android_arch_include_dir(target_os)
            if not include_dir then
                table.insert(warnings, errors.message("The Android NDK common include directory is missing: %s", path.join(sysroot, "usr", "include")))
            end
            if not arch_include_dir then
                table.insert(warnings, errors.message("The Android NDK target include directory is missing for %s.", settings.managed_target(target_os)))
            end
            local libroot = android_library_root(target_os)
            if not libroot then
                table.insert(warnings, errors.message("The Android NDK target library root is missing for %s.", settings.managed_target(target_os)))
            elseif api and not os.isdir(path.join(libroot, tostring(api))) then
                table.insert(warnings, errors.message("The Android NDK does not provide stub libraries for android_api=%s at: %s", tostring(api), path.join(libroot, tostring(api))))
            end
        end
    end

    return warnings, actions
end

function preflight(target_os)
    if target_os ~= "android" then
        return
    end
    local warnings, actions = preflight_warnings(target_os)
    if #warnings > 0 then
        run.stop_with_guidance(target_os, errors.message("Android toolchain settings are incomplete"), warnings, actions)
    end
end
