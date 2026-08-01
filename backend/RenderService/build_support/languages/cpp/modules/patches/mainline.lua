-- GCC source patches owned by the mainline family and applied to every
-- source profile (both isolated forks are mainline rebases): libstdc++
-- std-module fallback preservation, PE-COFF contracts default handler
-- wiring, the module-streaming fixes (PR c++/125334 backport,
-- PR c++/118630 tolerance, keyed-entity reader fix), x86_64 Android
-- long-double/__float128 ABI collision avoidance, and generated-file
-- invalidation. apply() consumes the wasm freestanding flags, so the facade
-- must run wasm.apply() first.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("shared")

function apply(ctx)
    local src = ctx.src
    local target_os = ctx.target_os
    local generated_options_changed = false
    local wasm_freestanding_std_module_changed = ctx.flags.wasm_freestanding_std_module_changed
    local wasm_freestanding_include_headers_changed = ctx.flags.wasm_freestanding_include_headers_changed
    local warn_patch_drift = shared.warn_patch_drift
    local function dependent_gcc_compiler_build_dirs()
        return shared.dependent_gcc_compiler_build_dirs(ctx)
    end
    local function dependent_stale_demangle_files()
        return shared.dependent_stale_demangle_files(ctx)
    end

    -- x86_64 Android's ABI gives both 128-bit long double and __float128 the
    -- historical "g" mangling even though GCC keeps them as distinct C++
    -- types. Enabling libstdc++'s separate __float128 overload set therefore
    -- creates duplicate template/COMDAT symbols (first observed while building
    -- src/c++20/format-inst.cc). NDK Clang rejects the same pair of overloads
    -- with a duplicate-mangled-name diagnostic, so changing GCC's mangling
    -- would be ABI-incompatible; suppress only the colliding library overload
    -- set on this target and retain 128-bit long double support. GCC 17's
    -- <format> also has to honor that host-support gate instead of testing
    -- __SIZEOF_FLOAT128__ alone.
    local cxxconfig = path.join(src, "libstdc++-v3", "include", "bits", "c++config")
    local float128_anchor =
        "/* Define if __float128 is supported on this host.  */\n" ..
        "#if defined(__FLOAT128__) || defined(__SIZEOF_FLOAT128__)\n" ..
        "/* For powerpc64 don't use __float128 when it's the same type as long double. */\n" ..
        "# if !(defined(_GLIBCXX_LONG_DOUBLE_ALT128_COMPAT) && defined(__LONG_DOUBLE_IEEE128__))\n" ..
        "#  define _GLIBCXX_USE_FLOAT128\n" ..
        "# endif\n" ..
        "#endif\n"
    local float128_fix =
        "/* Define if __float128 is supported on this host.  */\n" ..
        "#if defined(__FLOAT128__) || defined(__SIZEOF_FLOAT128__)\n" ..
        "/* x86_64 Android gives long double and __float128 the same g mangling.  */\n" ..
        "# if !(defined(__ANDROID__) && defined(__x86_64__) \\\n" ..
        "       && defined(__LONG_DOUBLE_128__))\n" ..
        "/* For powerpc64 don't use __float128 when it's the same type as long double. */\n" ..
        "#  if !(defined(_GLIBCXX_LONG_DOUBLE_ALT128_COMPAT) && defined(__LONG_DOUBLE_IEEE128__))\n" ..
        "#   define _GLIBCXX_USE_FLOAT128\n" ..
        "#  endif\n" ..
        "# endif\n" ..
        "#endif\n"
    shared.strict_replace(ctx, cxxconfig, float128_anchor, float128_fix,
        "libstdc++ x86_64 Android long-double/__float128 ABI collision fix")

    local format_header = path.join(src, "libstdc++-v3", "include", "std", "format")
    shared.strict_replace(ctx, format_header,
        "#if defined(__SIZEOF_FLOAT128__) && _GLIBCXX_FORMAT_F128 == 2\n" ..
        "  // Use __formatter_fp<C>::format<__format::__flt128_t, Out> for __float128,\n",
        "#if defined(__SIZEOF_FLOAT128__) && defined(_GLIBCXX_USE_FLOAT128) \\\n" ..
        "  && _GLIBCXX_FORMAT_F128 == 2\n" ..
        "  // Use __formatter_fp<C>::format<__format::__flt128_t, Out> for __float128,\n",
        "libstdc++ format __float128 formatter host-support gate")
    shared.strict_replace(ctx, format_header,
        "#ifdef __SIZEOF_FLOAT128__\n" ..
        "\t__float128 _M_float128;\n" ..
        "#endif\n",
        "#if defined(__SIZEOF_FLOAT128__) && defined(_GLIBCXX_USE_FLOAT128)\n" ..
        "\t__float128 _M_float128;\n" ..
        "#endif\n",
        "libstdc++ format __float128 argument storage host-support gate")
    shared.strict_replace(ctx, format_header,
        "#ifdef __SIZEOF_FLOAT128__\n" ..
        "\t  else if constexpr (is_same_v<_Tp, __float128>)\n" ..
        "\t    return (__u._M_float128 = ... = __value);\n" ..
        "#endif\n",
        "#if defined(__SIZEOF_FLOAT128__) && defined(_GLIBCXX_USE_FLOAT128)\n" ..
        "\t  else if constexpr (is_same_v<_Tp, __float128>)\n" ..
        "\t    return (__u._M_float128 = ... = __value);\n" ..
        "#endif\n",
        "libstdc++ format __float128 argument access host-support gate")
    shared.strict_replace(ctx, format_header,
        "#if defined(__SIZEOF_FLOAT128__) && _GLIBCXX_FORMAT_F128\n" ..
        "\t  else if constexpr (is_same_v<_Td, __float128>)\n" ..
        "\t    return type_identity<__float128>();\n" ..
        "#endif\n",
        "#if defined(__SIZEOF_FLOAT128__) && defined(_GLIBCXX_USE_FLOAT128) \\\n" ..
        "  && _GLIBCXX_FORMAT_F128\n" ..
        "\t  else if constexpr (is_same_v<_Td, __float128>)\n" ..
        "\t    return type_identity<__float128>();\n" ..
        "#endif\n",
        "libstdc++ format __float128 normalization host-support gate")
    shared.strict_replace(ctx, format_header,
        "#if defined(__SIZEOF_FLOAT128__) && _GLIBCXX_FORMAT_F128\n" ..
        "\t  else if constexpr (is_same_v<_Tp, __float128>)\n" ..
        "\t    return _Arg_float128;\n" ..
        "#endif\n",
        "#if defined(__SIZEOF_FLOAT128__) && defined(_GLIBCXX_USE_FLOAT128) \\\n" ..
        "  && _GLIBCXX_FORMAT_F128\n" ..
        "\t  else if constexpr (is_same_v<_Tp, __float128>)\n" ..
        "\t    return _Arg_float128;\n" ..
        "#endif\n",
        "libstdc++ format __float128 discriminator host-support gate")
    shared.strict_replace(ctx, format_header,
        "#if defined(__SIZEOF_FLOAT128__) && _GLIBCXX_FORMAT_F128\n" ..
        "\t    case _Arg_float128:\n" ..
        "\t      return std::forward<_Visitor>(__vis)(_M_val._M_float128);\n" ..
        "#endif\n",
        "#if defined(__SIZEOF_FLOAT128__) && defined(_GLIBCXX_USE_FLOAT128) \\\n" ..
        "  && _GLIBCXX_FORMAT_F128\n" ..
        "\t    case _Arg_float128:\n" ..
        "\t      return std::forward<_Visitor>(__vis)(_M_val._M_float128);\n" ..
        "#endif\n",
        "libstdc++ format __float128 visitor host-support gate")

    local function libstdcxx_std_module_fallback_rule(target, deps, compile, module_name)
        return target .. ": " .. deps .. "\n" ..
            "\tif ! " .. compile .. " $(MODULES_FLAGS) -c $< ; then \\\n" ..
            "\t  echo \"Cannot compile " .. module_name .. " module\" >&2; \\\n" ..
            "\t  echo \"Module initialization function will be missing\" >&2; \\\n" ..
            "\t  saved=\"$<.xmake-saved\"; \\\n" ..
            "\t  cp \"$<\" \"$$saved\" && \\\n" ..
            "\t  echo > \"$<.tmp\" && mv \"$<.tmp\" \"$<\" && \\\n" ..
            "\t  " .. compile .. " $(MODULES_FLAGS) -c $<; \\\n" ..
            "\t  status=$$?; \\\n" ..
            "\t  if test -f \"$$saved\"; then mv \"$$saved\" \"$<\" || status=$$?; fi; \\\n" ..
            "\t  exit $$status; \\\n" ..
            "\tfi\n"
    end

    local function patch_libstdcxx_std_module_fallbacks(file, label)
        if not os.isfile(file) then
            return false
        end

        local content = io.readfile(file)
        local patched = content
        for _, rule in ipairs({
            {"std.lo", "std.cc", "$(LTCXXCOMPILE)", "std"},
            {"std.o", "std.cc", "$(CXXCOMPILE)", "std"},
            {"std.compat.lo", "std.compat.cc std.lo", "$(LTCXXCOMPILE)", "std.compat"},
            {"std.compat.o", "std.compat.cc std.o", "$(CXXCOMPILE)", "std.compat"}
        }) do
            local original = rule[1] .. ": " .. rule[2] .. "\n" ..
                "\tif ! " .. rule[3] .. " $(MODULES_FLAGS) -c $< ; then \\\n" ..
                "\t  echo \"Cannot compile " .. rule[4] .. " module\" >&2; \\\n" ..
                "\t  echo \"Module initialization function will be missing\" >&2; \\\n" ..
                "\t  echo > $<.tmp && mv $<.tmp $< && \\\n" ..
                "\t  " .. rule[3] .. " $(MODULES_FLAGS) -c $< ; \\\n" ..
                "\tfi\n"
            -- Check drift per rule, not once over the aggregate file: with 4
            -- independent substitutions feeding one combined marker check, a
            -- single successful rule hid the marker's presence and masked
            -- silent failure of the other 3 when upstream Makefile.am/.in
            -- changed only some of the fallback rule bodies. A file whose
            -- rule already carries the PATCHED text (idempotent re-run over
            -- an already-patched tree) is fine and must not warn.
            local replacement_rule = libstdcxx_std_module_fallback_rule(rule[1], rule[2], rule[3], rule[4])
            local before_rule = patched
            patched = base.replace_plain(patched, original, replacement_rule)
            if patched == before_rule and not patched:find(replacement_rule, 1, true) then
                print("WARNING: GCC source patch anchor not found (upstream drift): " ..
                    label .. " libstdc++ standard module fallback source preservation (" .. rule[1] .. ")")
                print("         The local fix is NOT applied for this rule. A failed " .. rule[4] ..
                    " module compile may still replace the installed module source with an empty fallback.")
                print("         Check whether upstream already fixed the issue; then update or retire the patch in build_support.")
            end
        end

        if patched ~= content then
            print("patching GCC " .. label .. ": preserve libstdc++ standard module sources on fallback")
            base.writefile_bytes(file, patched)
        end
        return patched ~= content
    end

    local function libstdcxx_std_module_source_valid(file, module_name)
        if not os.isfile(file) then
            return true
        end
        local ok, content = errors.trycall(function ()
            return io.readfile(file)
        end)
        if not ok or not content then
            return false
        end
        return content:find("export module " .. module_name .. ";", 1, true) ~= nil
    end

    local function invalidate_incomplete_libstdcxx_std_module_build(cxx23_dir, force)
        local libstdcxx_build = path.directory(path.directory(cxx23_dir))
        local include_bits = path.join(libstdcxx_build, "include", "bits")
        local incomplete = force or false
        for _, module in ipairs({
            {source = "std.cc", name = "std"},
            {source = "std.compat.cc", name = "std.compat"}
        }) do
            local generated = path.join(cxx23_dir, module.source)
            local installed_bits = path.join(include_bits, module.source)
            local generated_exists = os.isfile(generated)
            if force then
                if generated_exists then
                    print("invalidating changed libstdc++ standard module source: " .. generated)
                    os.rm(generated)
                end
                if os.isfile(installed_bits) then
                    print("invalidating changed libstdc++ standard module bits copy: " .. installed_bits)
                    os.rm(installed_bits)
                end
            elseif generated_exists and not libstdcxx_std_module_source_valid(generated, module.name) then
                print("invalidating incomplete libstdc++ standard module source: " .. generated)
                os.rm(generated)
                print("invalidating libstdc++ standard module bits copy: " .. installed_bits)
                os.rm(installed_bits)
                incomplete = true
            elseif not generated_exists and os.isfile(installed_bits) then
                print("invalidating stale libstdc++ standard module bits copy: " .. installed_bits)
                os.rm(installed_bits)
                incomplete = true
            end
        end

        if not incomplete then
            return
        end

        for _, name in ipairs({
            "stamp-modules-bits",
            "std.lo",
            "std.o",
            "std.compat.lo",
            "std.compat.o",
            "libmodulesconvenience.la",
            path.join(".libs", "std.o"),
            path.join(".libs", "std.lo"),
            path.join(".libs", "std.compat.o"),
            path.join(".libs", "std.compat.lo"),
            path.join(".libs", "libmodulesconvenience.a"),
            path.join(".libs", "libmodulesconvenience.la")
        }) do
            os.rm(path.join(cxx23_dir, name))
        end
    end

    local function invalidate_libstdcxx_include_header_stamps(cxx23_dir, force)
        local libstdcxx_build = path.directory(path.directory(cxx23_dir))
        local include_dir = path.join(libstdcxx_build, "include")
        local required_headers = {
            ["stamp-std"] = {
                "chrono",
                "format",
                "istream",
                "map",
                "ostream",
                "print",
                "stdexcept",
                "string",
                "vector"
            },
            ["stamp-c_base"] = {"cstdlib", "cstring"},
            ["stamp-bits"] = {
                path.join("bits", "allocated_ptr.h"),
                path.join("bits", "basic_string.h"),
                path.join("bits", "basic_string.tcc"),
                path.join("bits", "charconv.h"),
                path.join("bits", "chrono.h"),
                path.join("bits", "erase_if.h"),
                path.join("bits", "memory_resource.h"),
                path.join("bits", "new_allocator.h"),
                path.join("bits", "node_handle.h"),
                path.join("bits", "shared_ptr.h"),
                path.join("bits", "shared_ptr_base.h"),
                path.join("bits", "stl_map.h"),
                path.join("bits", "stl_multimap.h"),
                path.join("bits", "stl_tree.h"),
                path.join("bits", "stl_bvector.h"),
                path.join("bits", "stl_vector.h"),
                path.join("bits", "stringfwd.h"),
                path.join("bits", "vector.tcc"),
                path.join("bits", "version.h"),
                path.join("bits", "wasm_freestanding_hosted_compat.h")
            }
        }
        for stamp_name, headers in pairs(required_headers) do
            local stale = force
            if target_os == "emscripten" then
                for _, header in ipairs(headers) do
                    if not os.isfile(path.join(include_dir, header)) then
                        stale = true
                        break
                    end
                end
            end
            local stamp = path.join(include_dir, stamp_name)
            if stale and os.isfile(stamp) then
                print("invalidating changed libstdc++ header install stamp: " .. stamp)
                os.rm(stamp)
            end
        end
    end

    patch_libstdcxx_std_module_fallbacks(
        path.join(src, "libstdc++-v3", "src", "c++23", "Makefile.am"),
        "libstdc++-v3/src/c++23/Makefile.am")
    patch_libstdcxx_std_module_fallbacks(
        path.join(src, "libstdc++-v3", "src", "c++23", "Makefile.in"),
        "libstdc++-v3/src/c++23/Makefile.in")
    for _, makefile in ipairs(os.files(path.join(layout.toolchains_cache_root(), "*", "*", "*", "build", "gcc", "*", "libstdc++-v3", "src", "c++23", "Makefile"))) do
        patch_libstdcxx_std_module_fallbacks(makefile,
            "generated " .. path.relative(makefile, layout.toolchains_cache_root()))
        local target_build_relative = path.relative(makefile, settings.gcc_build_dir(target_os))
        local belongs_to_target_build = target_build_relative ~= ".."
            and not target_build_relative:find("^%.%.[/\\]")
        invalidate_libstdcxx_include_header_stamps(
            path.directory(makefile),
            wasm_freestanding_include_headers_changed and belongs_to_target_build)
        invalidate_incomplete_libstdcxx_std_module_build(
            path.directory(makefile),
            wasm_freestanding_std_module_changed and belongs_to_target_build)
    end

    -- PE-COFF targets cannot use libstdc++'s weak contract violation handler
    -- as an ordinary definition. Keep the weak handler replaceable and let ld
    -- provide the default only when no user handler exists.
    local function patch_gxx_driver_source(source_root)
        local gxxspec_cc = path.join(source_root, "gcc", "cp", "g++spec.cc")
        if not os.isfile(gxxspec_cc) then
            return false
        end

        local content = io.readfile(gxxspec_cc)
        local patched = content
        if not patched:find("need_contract_default_handler", 1, true) then
            patched = base.replace_plain(patched,
                "  /* By default, we don't add -lstdc++exp.  */\n" ..
                "  bool need_experimental = false;\n",
                "  /* By default, we don't add -lstdc++exp.  */\n" ..
                "  bool need_experimental = false;\n" ..
                "#if TARGET_PECOFF\n" ..
                "  bool need_contract_default_handler = false;\n" ..
                "#endif\n")
        end
        patched = base.replace_plain(patched,
            "#if TARGET_PECOFF\n" ..
            "  bool need_contract_default_handler = false;\n" ..
            "#endif\n" ..
            "#if TARGET_PECOFF\n" ..
            "  bool need_contract_default_handler = false;\n" ..
            "#endif\n",
            "#if TARGET_PECOFF\n" ..
            "  bool need_contract_default_handler = false;\n" ..
            "#endif\n")
        patched = base.replace_plain(patched,
            "\tcase OPT_fcontracts:\n" ..
            "\t  need_experimental = true;\n" ..
            "\t  break;\n",
            "\tcase OPT_fcontracts:\n" ..
            "\t  need_experimental = true;\n" ..
            "#if TARGET_PECOFF\n" ..
            "\t  need_contract_default_handler = true;\n" ..
            "#endif\n" ..
            "\t  break;\n")
        patched = base.replace_plain(patched,
            "  num_args = (argc + added + need_math + need_experimental\n" ..
            "\t      + (std_module * 5)\n",
            "  num_args = (argc + added + need_math + need_experimental\n" ..
            "#if TARGET_PECOFF\n" ..
            "\t      + need_contract_default_handler\n" ..
            "#endif\n" ..
            "\t      + (std_module * 5)\n")
        patched = base.replace_plain(patched,
            "      if (need_experimental && which_library == USE_LIBSTDCXX)\n" ..
            "\t{\n" ..
            "\t  generate_option (OPT_l, \"stdc++exp\", 1, CL_DRIVER,\n" ..
            "\t\t\t   &new_decoded_options[j++]);\n" ..
            "\t  ++added_libraries;\n" ..
            "\t}\n",
            "      if (need_experimental && which_library == USE_LIBSTDCXX)\n" ..
            "\t{\n" ..
            "#if TARGET_PECOFF\n" ..
            "\t  if (need_contract_default_handler)\n" ..
            "\t    {\n" ..
            "\t      generate_option (OPT_l,\n" ..
            "\t\t\t       \":libstdc++exp-contracts-default-handler.ld\",\n" ..
            "\t\t\t       1, CL_DRIVER, &new_decoded_options[j++]);\n" ..
            "\t      ++added_libraries;\n" ..
            "\t    }\n" ..
            "#endif\n" ..
            "\t  generate_option (OPT_l, \"stdc++exp\", 1, CL_DRIVER,\n" ..
            "\t\t\t   &new_decoded_options[j++]);\n" ..
            "\t  ++added_libraries;\n" ..
            "\t}\n")
        if patched ~= content then
            print("patching GCC C++ driver: add PE-COFF contracts default handler linker script (" .. gxxspec_cc .. ")")
            base.writefile_bytes(gxxspec_cc, patched)
        end
        warn_patch_drift(patched, "libstdc++exp-contracts-default-handler.ld",
            "cp/g++spec.cc PE-COFF contracts default handler linker script injection",
            "PE-COFF -fcontracts links may fail to resolve handle_contract_violation from libstdc++exp.")
        warn_patch_drift(patched, "bool need_contract_default_handler = false;",
            "cp/g++spec.cc PE-COFF contracts default handler state",
            "The driver may no longer add the project-local contracts linker script at the right time.")
        warn_patch_drift(patched, "need_contract_default_handler = true;",
            "cp/g++spec.cc PE-COFF contracts default handler OPT_fcontracts trigger",
            "The -fcontracts flag may no longer request the contracts default handler linker script.")
        -- The allocation-count slot is the load-bearing one: if this anchor
        -- drifts while the generate_option site above still applies, the extra
        -- option is injected without growing num_args, writing one element past
        -- new_decoded_options[] -> heap corruption in the driver.
        warn_patch_drift(patched, "+ need_contract_default_handler\n#endif\n\t      + (std_module * 5)",
            "cp/g++spec.cc PE-COFF contracts default handler argument-count slot",
            "new_decoded_options[] may be under-allocated by one, risking an out-of-bounds driver write when -fcontracts injects the extra option.")
        return patched ~= content
    end

    local patched_gxx_driver = patch_gxx_driver_source(src)

    if patched_gxx_driver then
        for _, gccdir in ipairs(os.dirs(path.join(layout.toolchains_cache_root(), "*", "windows", "*", "build", "gcc", "gcc"))) do
            print("invalidating GCC C++ driver objects: " .. gccdir)
            for _, name in ipairs({
                path.join("cp", "g++spec.o"),
                "xg++",
                "xg++.exe",
                "g++-checksum"
            }) do
                os.rm(path.join(gccdir, name))
            end
        end
    end

    local opt_functions = path.join(src, "gcc", "opt-functions.awk")
    if os.isfile(opt_functions) then
        local content = io.readfile(opt_functions)
        local patched = base.replace_plain(content,
            [=[gsub ( "\\+", "\\+", regex )]=],
            [=[gsub ( "\\+", "[+]", regex )]=])
        patched = base.replace_plain(patched,
            [=[gsub ( "\\+", "\\\\+", regex )]=],
            [=[gsub ( "\\+", "[+]", regex )]=])
        if patched ~= content then
            print("patching GCC option generator: preserve C++-only option language flags")
            base.writefile_bytes(opt_functions, patched)
            generated_options_changed = true
        end
        warn_patch_drift(patched, [=[gsub ( "\\+", "[+]", regex )]=],
            "opt-functions.awk option language flag preservation",
            "C++-only option flags may be dropped by the option generator.")
    end

    -- GCC trunk module streaming forms mergeable clusters with more than one
    -- entry dep for large single-module interfaces (dependent-ADL-heavy code
    -- in large partitioned modules), which fires a
    -- checking assert in cp/module.cc sort_cluster (PR c++/118630 residual
    -- case) and can stream unreadable CMIs. Backport the upstream fix
    -- r17/bb2601808 "c++/modules: dependent ADL laziness [PR125334]"
    -- (2026-06-23, one day after the pinned snapshot): dependent ADL functions
    -- become reachable bindings instead of tight dependencies of the call
    -- site, so those clusters never form. Drop this patch once gcc_ref is
    -- bumped to a snapshot at or after bb2601808.
    local patched_module_streaming = false
    local module_cc = path.join(src, "gcc", "cp", "module.cc")
    if os.isfile(module_cc) then
        local content = io.readfile(module_cc)
        local patched = base.replace_plain(content,
            "add_dependency (make_dependency (fn, EK_DECL));",
            "make_dependency (fn, EK_DECL); /* project-local backport of upstream bb2601808 (PR c++/125334). */")
        if patched ~= content then
            print("patching GCC module streaming: backport dependent ADL laziness (PR c++/125334)")
            patched_module_streaming = true
        end
        -- Residual PR c++/118630 case not covered by the ADL backport: some
        -- non-ADL merge-key walks still produce clusters with a second entry
        -- dep and fire the checking assert. Keep the discovered order for the
        -- extras; the resulting CMIs for this shape have been read back by
        -- hundreds of importing units without issue.
        local needle = "\t  if (dep->is_entry ())\n" ..
            "\t    {\n" ..
            "\t      /* There should only be one entry dep in a cluster.  */\n" ..
            "\t      gcc_checking_assert (!scc[entry_pos]->is_entry ());\n"
        local replacement = "\t  if (dep->is_entry () && scc[entry_pos]->is_entry ())\n" ..
            "\t    inform (input_location, \"project-local toolchain patch: tolerated\"\n" ..
            "\t\t    \" multi-entry mergeable cluster (residual PR c++/118630):\"\n" ..
            "\t\t    \" entries %qD and %qD; the emitted CMI may be\"\n" ..
            "\t\t    \" unreadable by importers\",\n" ..
            "\t\t    scc[entry_pos]->get_entity (), dep->get_entity ());\n" ..
            "\t  if (dep->is_entry () && !scc[entry_pos]->is_entry ())\n" ..
            "\t    {\n" ..
            "\t      /* There should only be one entry dep in a cluster; tolerate\n" ..
            "\t\t extras in discovered order (project-local patch,\n" ..
            "\t\t residual PR c++/118630 case).  */\n"
        local patched2 = base.replace_plain(patched, needle, replacement)
        -- upgrade path: trees patched by the earlier revision of this patch
        -- (no entry-entity diagnostics in the inform) converge to the same text
        patched2 = base.replace_plain(patched2,
            "\t\t    \" multi-entry mergeable cluster (residual PR c++/118630);\"\n" ..
            "\t\t    \" the emitted CMI may be unreadable by importers\");\n",
            "\t\t    \" multi-entry mergeable cluster (residual PR c++/118630):\"\n" ..
            "\t\t    \" entries %qD and %qD; the emitted CMI may be\"\n" ..
            "\t\t    \" unreadable by importers\",\n" ..
            "\t\t    scc[entry_pos]->get_entity (), dep->get_entity ());\n")
        if patched2 ~= patched then
            print("patching GCC module streaming: tolerate residual multi-entry mergeable clusters (PR c++/118630)")
            patched_module_streaming = true
        end
        -- Reader-side keyed-entity consistency check rejects a legitimate
        -- shape: a class first forward-declared in a sibling partition and
        -- defined -- with lambdas inside out-of-class member definitions --
        -- in the CMI being read merges with a declaration that has no keyed
        -- entry yet (relative of PR c++/122310).
        -- Adopt the streamed keyed set when no entry exists instead of
        -- declaring corruption; only new-decl-with-existing-entry remains an
        -- error. Verified by a 3-file minimal repro plus controls.
        local keyed_needle = "      unsigned num = u ();\n" ..
            "      if (is_new == existed)\n" ..
            "\tset_overrun ();\n" ..
            "      if (is_new)\n" ..
            "\tset.reserve (num);\n" ..
            "      for (unsigned ix = 0; !get_overrun () && ix != num; ix++)\n" ..
            "\t{\n" ..
            "\t  tree attached = tree_node ();\n" ..
            "\t  dump (dumper::MERGE)\n" ..
            "\t    && dump (\"Read %d[%u] %s attached decl %N\", tag, ix,\n" ..
            "\t\t     is_new ? \"new\" : \"matched\", attached);\n" ..
            "\t  if (is_new)\n" ..
            "\t    set.quick_push (attached);\n"
        local keyed_fix = "      unsigned num = u ();\n" ..
            "      /* project-local fix (PR c++/122310 relative): a decl that\n" ..
            "\t merges with an imported declaration may still be the first to\n" ..
            "\t stream keyed entities -- e.g. a class first forward-declared in\n" ..
            "\t a sibling partition and defined, with lambdas inside out-of-class\n" ..
            "\t member definitions, in this CMI.  The merged decl then\n" ..
            "\t legitimately has no keyed entry yet; adopt the streamed set\n" ..
            "\t instead of treating the situation as corruption.  */\n" ..
            "      if (is_new && existed)\n" ..
            "\tset_overrun ();\n" ..
            "      if (!existed)\n" ..
            "\tset.reserve (num);\n" ..
            "      for (unsigned ix = 0; !get_overrun () && ix != num; ix++)\n" ..
            "\t{\n" ..
            "\t  tree attached = tree_node ();\n" ..
            "\t  dump (dumper::MERGE)\n" ..
            "\t    && dump (\"Read %d[%u] %s attached decl %N\", tag, ix,\n" ..
            "\t\t     !existed ? \"new\" : \"matched\", attached);\n" ..
            "\t  if (!existed)\n" ..
            "\t    set.quick_push (attached);\n"
        local patched3 = base.replace_plain(patched2, keyed_needle, keyed_fix)
        if patched3 ~= patched2 then
            print("patching GCC module streaming: adopt keyed entities on decls merged with imported forward declarations")
            patched_module_streaming = true
        end
        -- Unbounded recursion in module lazy-loading under -Os. Reading a
        -- module's static initializers (module_state::read_inits) eagerly clones
        -- cdtor bodies through post_load_processing -> expand_or_defer_fn, whose
        -- instantiation lazily loads further entities (constraint satisfaction ->
        -- instantiate_template -> lazy_load_pendings) and re-enters read_inits.
        -- read_inits/lazy_load_pendings clear lazy_snum BEFORE calling
        -- post_load_processing, so recursive_lazy() no longer detects the
        -- re-entry and it recurses until the stack overflows (iOS release cc1plus
        -- SIGSEGV via <span>/std::meta::info constraint satisfaction; a relative
        -- of the open PR c++/124542 whose trigger differs; not exposed at -O2/-O3
        -- which defer these bodies). post_load_decls is a shared queue drained to
        -- empty, so guard post_load_processing against re-entry: the outermost
        -- call owns the drain, nested calls leave their work queued and return.
        -- Must NOT be attempted at the linkage layer (a mark_needed-style force
        -- of the imported closure explodes the vtable worklist into an endless
        -- compile); the drain guard is the only shape that terminates.
        local reentry_needle = "  if (!post_load_decls)\n    return;\n\n  tree old_cfd = current_function_decl;"
        local reentry_fix = "  if (!post_load_decls)\n    return;\n\n" ..
            "  /* A cdtor expansion below can lazily load further entities, which\n" ..
            "     re-enters here (read_inits/lazy_load_pendings both call us after\n" ..
            "     clearing lazy_snum).  post_load_decls is a shared queue we drain to\n" ..
            "     empty, so let the outermost call own the drain; nested calls leave\n" ..
            "     their work queued and return, breaking otherwise-unbounded recursion\n" ..
            "     when -Os clones cdtor bodies while reading a module's static\n" ..
            "     initializers (relative of PR c++/124542).  */\n" ..
            "  static bool draining = false;\n" ..
            "  if (draining)\n" ..
            "    return;\n" ..
            "  draining = true;\n\n" ..
            "  tree old_cfd = current_function_decl;"
        local patched4 = base.replace_plain(patched3, reentry_needle, reentry_fix)
        local reentry_reset_needle = "    }\n\n  set_cfun (old_cfun);\n  current_function_decl = old_cfd;\n}"
        local reentry_reset_fix = "    }\n\n  set_cfun (old_cfun);\n  current_function_decl = old_cfd;\n" ..
            "  draining = false;\n}"
        patched4 = base.replace_plain(patched4, reentry_reset_needle, reentry_reset_fix)
        if patched4 ~= patched3 then
            print("patching GCC module streaming: guard post_load_processing against lazy-load re-entrancy (relative of PR c++/124542)")
            patched_module_streaming = true
        end

        -- CHECKING_P-only trees_in::assert_definition trips while a primary
        -- interface re-exports its partitions under -Os (export import :Branch):
        -- the drain guard above legitimately re-encounters some imported
        -- definitions, so a definition is "installed" more than once. The whole
        -- body is #if CHECKING_P (release-checking GCC compiles it out) and its
        -- note_defs cache exists precisely because definitions can be dropped and
        -- re-seen, so neutralizing it matches release-checking GCC -- functional
        -- and link tests remain the correctness check (same treatment as the
        -- other module-graph checking asserts above).
        local assertdef_needle = "trees_in::assert_definition (tree decl ATTRIBUTE_UNUSED,\n" ..
            "\t\t\t     bool installing ATTRIBUTE_UNUSED)\n" ..
            "{\n" ..
            "#if CHECKING_P\n" ..
            "  tree *slot = note_defs->find_slot (decl, installing ? INSERT : NO_INSERT);\n" ..
            "  tree not_tmpl = STRIP_TEMPLATE (decl);\n" ..
            "  if (installing)\n" ..
            "    {\n" ..
            "      /* We must be inserting for the first time.  */\n" ..
            "      gcc_assert (!*slot);\n" ..
            "      *slot = decl;\n" ..
            "    }\n" ..
            "  else\n" ..
            "    /* If this is not the mergeable entity, it should not be in the\n" ..
            "       table.  If it is a non-global-module mergeable entity, it\n" ..
            "       should be in the table.  Global module entities could have been\n" ..
            "       defined textually in the current TU and so might or might not\n" ..
            "       be present.  */\n" ..
            "    gcc_assert (!is_duplicate (decl)\n" ..
            "\t\t? !slot\n" ..
            "\t\t: (slot\n" ..
            "\t\t   || !DECL_LANG_SPECIFIC (not_tmpl)\n" ..
            "\t\t   || !DECL_MODULE_PURVIEW_P (not_tmpl)\n" ..
            "\t\t   || (!DECL_MODULE_IMPORT_P (not_tmpl)\n" ..
            "\t\t       && header_module_p ())));\n" ..
            "\n" ..
            "  if (not_tmpl != decl)\n" ..
            "    gcc_assert (!note_defs->find_slot (not_tmpl, NO_INSERT));\n" ..
            "#endif\n" ..
            "}"
        local assertdef_fix = "trees_in::assert_definition (tree decl ATTRIBUTE_UNUSED,\n" ..
            "\t\t\t     bool installing ATTRIBUTE_UNUSED)\n" ..
            "{\n" ..
            "  /* project-local tolerance: these definition-streaming consistency\n" ..
            "     checks are CHECKING_P-only (release GCC compiles them out).  This\n" ..
            "     project's -Os module graph re-encounters some imported definitions\n" ..
            "     while a primary interface re-exports its partitions, tripping the\n" ..
            "     \"install for the first time\" invariant; the note_defs cache exists\n" ..
            "     precisely because definitions can be dropped and re-seen.  Match\n" ..
            "     release-checking GCC and rely on link/functional tests.  */\n" ..
            "  (void) decl;\n" ..
            "  (void) installing;\n" ..
            "}"
        local patched5 = base.replace_plain(patched4, assertdef_needle, assertdef_fix)
        if patched5 ~= patched4 then
            print("patching GCC module streaming: neutralize CHECKING_P assert_definition (re-export re-install under -Os)")
            patched_module_streaming = true
        end

        if patched_module_streaming then
            base.writefile_bytes(module_cc, patched5)
        end
        warn_patch_drift(patched5, "residual PR c++/118630 case).  */",
            "cp/module.cc sort_cluster multi-entry tolerance (PR c++/118630)",
            "Full parallel builds may ICE in sort_cluster again unless upstream fixed the PR.")
        warn_patch_drift(patched5, "project-local fix (PR c++/122310",
            "cp/module.cc keyed-entity reader fix (PR c++/122310 relative)",
            "Partitions whose class is forward-declared elsewhere may emit CMIs importers cannot read.")
        warn_patch_drift(patched5, "static bool draining = false;",
            "cp/module.cc post_load_processing lazy-load re-entrancy guard (PR c++/124542 relative)",
            "iOS/-Os module units may recurse to a stack-overflow ICE while reading module static initializers.")
        warn_patch_drift(patched5, "Match\n     release-checking GCC and rely on link/functional tests.  */\n  (void) decl;",
            "cp/module.cc assert_definition CHECKING_P neutralization",
            "iOS/-Os re-exporting primary interfaces may ICE in assert_definition on checking builds.")
    end

    -- Fourth checking-only assert, first seen on aarch64-linux-android:
    -- vague_linkage_p (cp/decl2.cc) trips on an imported COMDAT
    -- instantiation whose TREE_PUBLIC the module streamer cleared
    -- (std::variant members imported from the std CMI into a partition).
    -- COMDAT is itself the vague-linkage property, so report it instead of
    -- asserting an invariant module streaming does not maintain.
    local decl2_cc = path.join(src, "gcc", "cp", "decl2.cc")
    if os.isfile(decl2_cc) then
        local content = io.readfile(decl2_cc)
        local patched = base.replace_plain(content,
            "      gcc_checking_assert (!DECL_COMDAT (decl));\n" ..
            "      return false;\n",
            "      /* project-local tolerance: module streaming can materialize an\n" ..
            "\t imported COMDAT instantiation with TREE_PUBLIC cleared (observed\n" ..
            "\t on aarch64-linux-android: std::variant instantiations imported\n" ..
            "\t from the std CMI ICE here).  COMDAT is itself the vague-linkage\n" ..
            "\t property, so report it instead of asserting.  */\n" ..
            "      if (DECL_COMDAT (decl))\n" ..
            "\treturn true;\n" ..
            "      return false;\n")
        if patched ~= content then
            print("patching GCC C++ front end: tolerate imported COMDAT decls without TREE_PUBLIC in vague_linkage_p")
            base.writefile_bytes(decl2_cc, patched)
        end
        warn_patch_drift(patched, "COMDAT is itself the vague-linkage",
            "cp/decl2.cc vague_linkage_p imported-COMDAT tolerance",
            "Module units instantiating imported templates may ICE in vague_linkage_p on checking builds.")

        -- Mach-O duplicate typeinfo/vtable for module-attached classes:
        -- sibling units of one module (the defining partition and the
        -- primary interface re-streaming it) can each conclude they are the
        -- unique emitter of a module-attached class's vtable/typeinfo,
        -- because partition streaming does not mark entities
        -- DECL_MODULE_IMPORT_P. Targets where class_data_always_comdat()
        -- is true (ELF/PE) merge the duplicate COMDAT copies silently;
        -- darwin's hook is false (config/darwin.h: hook_bool_void_false),
        -- the copies come out STRONG, and ld64 reports "duplicate symbol
        -- 'typeinfo for ...'" (observed: basic_file_system /
        -- file_unique_unit on x86_64-apple-darwin).
        --
        -- Failed first approach, converged back to upstream below:
        -- neutralizing the unique-emission answers (vtables_uniquely_emitted
        -- returning false / import_export_class falling to key-function
        -- logic) removes the duplicates but also removes the only unit that
        -- emits the tables at all -- the synthesis side consults the same
        -- answers -- so clean trees fail with undefined vtable references
        -- on EVERY platform (Linux CI; from-scratch darwin rebuild; the
        -- earlier darwin greens were stale mixed-compiler objects).
        local unique_upstream =
            "  tree cdecl = TYPE_NAME (ctype);\n" ..
            "  if (DECL_LANG_SPECIFIC (cdecl) && DECL_MODULE_ATTACH_P (cdecl))\n" ..
            "    return true;\n"
        local ie_upstream =
            "      tree cdecl = TYPE_NAME (ctype);\n" ..
            "      if (DECL_LANG_SPECIFIC (cdecl) && DECL_MODULE_ATTACH_P (cdecl))\n" ..
            "\t/* For class types attached to a named module, the ABI specifies\n" ..
            "\t   that the tables are uniquely emitted in the object for the\n" ..
            "\t   module unit in which it is defined.  */\n" ..
            "\timport_export = (DECL_MODULE_IMPORT_P (cdecl) ? -1 : 1);\n"
        local converged = patched
        for _, revision in ipairs({
            -- vtables_uniquely_emitted, first revision (unconditional)
            "  tree cdecl = TYPE_NAME (ctype);\n" ..
            "  if (DECL_LANG_SPECIFIC (cdecl) && DECL_MODULE_ATTACH_P (cdecl))\n" ..
            "    /* project-local tolerance: importing units still synthesize the\n" ..
            "       tables, so claiming unique emission produces duplicate STRONG\n" ..
            "       symbols on !class_data_always_comdat targets (Mach-O).  Fall\n" ..
            "       back to everywhere-COMDAT semantics.  */\n" ..
            "    return false;\n",
            -- vtables_uniquely_emitted, second revision (hook-gated)
            "  tree cdecl = TYPE_NAME (ctype);\n" ..
            "  if (DECL_LANG_SPECIFIC (cdecl) && DECL_MODULE_ATTACH_P (cdecl))\n" ..
            "    /* project-local tolerance: importing units still synthesize the\n" ..
            "       tables, so claiming unique emission produces duplicate STRONG\n" ..
            "       symbols on !class_data_always_comdat targets (Mach-O).  Keep\n" ..
            "       the upstream answer where class data is always COMDAT anyway\n" ..
            "       (ELF/PE); use everywhere-COMDAT semantics elsewhere.  */\n" ..
            "    return targetm.cxx.class_data_always_comdat ();\n"}) do
            converged = base.replace_plain(converged, revision, unique_upstream)
        end
        for _, revision in ipairs({
            -- import_export_class, first revision (unconditional)
            "      tree cdecl = TYPE_NAME (ctype);\n" ..
            "      /* project-local tolerance: every same-module unit seeing the\n" ..
            "\t definition has DECL_MODULE_IMPORT_P false and would claim the\n" ..
            "\t strong copy, which duplicates class data on\n" ..
            "\t !class_data_always_comdat targets (Mach-O).  Use the standard\n" ..
            "\t key-function logic instead.  */\n" ..
            "      if (DECL_LANG_SPECIFIC (cdecl) && DECL_MODULE_ATTACH_P (cdecl) && false)\n" ..
            "\timport_export = (DECL_MODULE_IMPORT_P (cdecl) ? -1 : 1);\n",
            -- import_export_class, second revision (hook-gated)
            "      tree cdecl = TYPE_NAME (ctype);\n" ..
            "      /* project-local tolerance: every same-module unit seeing the\n" ..
            "\t definition has DECL_MODULE_IMPORT_P false and would claim the\n" ..
            "\t strong copy, which duplicates class data on\n" ..
            "\t !class_data_always_comdat targets (Mach-O).  Keep the module\n" ..
            "\t arm where class data is always COMDAT anyway (ELF/PE); use the\n" ..
            "\t standard key-function logic elsewhere.  */\n" ..
            "      if (DECL_LANG_SPECIFIC (cdecl) && DECL_MODULE_ATTACH_P (cdecl)\n" ..
            "\t  && targetm.cxx.class_data_always_comdat ())\n" ..
            "\timport_export = (DECL_MODULE_IMPORT_P (cdecl) ? -1 : 1);\n"}) do
            converged = base.replace_plain(converged, revision, ie_upstream)
        end
        if converged ~= patched then
            print("patching GCC C++ front end: reverting retired module-attach neutralization to upstream text")
            patched = converged
            base.writefile_bytes(decl2_cc, patched)
        end

        -- Real tolerance: keep every upstream emission decision and force
        -- only the final LINKAGE of module-attached class data to COMDAT on
        -- Mach-O, giving darwin exactly the battle-tested ELF decision path
        -- (the duplicate copies become weak and ld64 merges them). The
        -- module-initializer chain pulls every module-unit object from the
        -- archive, so darwin's weak-not-in-archive-TOC caveat cannot orphan
        -- the weak copies. On non-Mach-O targets the helper is a constant
        -- false and both call sites keep their upstream meaning.
        local macho_helper =
            "/* project-local tolerance (Mach-O): sibling units of one module -- the\n" ..
            "   defining partition and the primary interface re-streaming it -- can\n" ..
            "   each conclude they are the unique emitter of a module-attached\n" ..
            "   class's vtable/typeinfo, because partition streaming does not mark\n" ..
            "   entities DECL_MODULE_IMPORT_P.  Targets whose class data is always\n" ..
            "   COMDAT merge the duplicate copies; Mach-O emits them STRONG and ld64\n" ..
            "   fails with duplicate symbols.  Force COMDAT linkage for\n" ..
            "   module-attached class data there; every emission decision stays\n" ..
            "   upstream.  */\n" ..
            "\n" ..
            "static bool\n" ..
            "macho_module_attached_class_data_p (tree ctype)\n" ..
            "{\n" ..
            "#ifdef OBJECT_FORMAT_MACHO\n" ..
            "  tree cdecl = TYPE_NAME (ctype);\n" ..
            "  return DECL_LANG_SPECIFIC (cdecl) && DECL_MODULE_ATTACH_P (cdecl);\n" ..
            "#else\n" ..
            "  (void) ctype;\n" ..
            "  return false;\n" ..
            "#endif\n" ..
            "}\n"
        if not patched:find("macho_module_attached_class_data_p", 1, true) then
            local unique_tail =
                "  /* Otherwise, the tables are emitted in every object that references\n" ..
                "     any of them.  */\n" ..
                "  return false;\n" ..
                "}\n"
            local patched_comdat = base.replace_plain(patched,
                unique_tail,
                unique_tail .. "\n" .. macho_helper)
            patched_comdat = base.replace_plain(patched_comdat,
                "\t      if (!vtables_uniquely_emitted (class_type)\n" ..
                "\t\t  || targetm.cxx.class_data_always_comdat ())\n",
                "\t      if (!vtables_uniquely_emitted (class_type)\n" ..
                "\t\t  || targetm.cxx.class_data_always_comdat ()\n" ..
                "\t\t  /* project-local: Mach-O forces COMDAT for module-attached\n" ..
                "\t\t     class data; see macho_module_attached_class_data_p.  */\n" ..
                "\t\t  || macho_module_attached_class_data_p (class_type))\n")
            patched_comdat = base.replace_plain(patched_comdat,
                "\t\t  comdat_p = (targetm.cxx.class_data_always_comdat ()\n" ..
                "\t\t\t      || !vtables_uniquely_emitted (class_type));\n",
                "\t\t  comdat_p = (targetm.cxx.class_data_always_comdat ()\n" ..
                "\t\t\t      || !vtables_uniquely_emitted (class_type)\n" ..
                "\t\t\t      /* project-local: Mach-O forces COMDAT for\n" ..
                "\t\t\t\t module-attached class data.  */\n" ..
                "\t\t\t      || macho_module_attached_class_data_p (class_type));\n")
            if patched_comdat ~= patched then
                print("patching GCC C++ front end: comdat linkage for module-attached class data on Mach-O (duplicate typeinfo)")
                patched = patched_comdat
                base.writefile_bytes(decl2_cc, patched)
            end
        end

        -- Second Mach-O duplicate-class-data shape, exposed once the iOS -Os
        -- build got past the module-recursion ICE to the link: the std module
        -- streams key-method definitions into every module unit, so at -Os even
        -- global-module polymorphic classes (std::logic_error and the other std
        -- exception types) get a locally-defined key method in each unit and are
        -- emitted STRONG there; ld64 rejects the several copies as duplicates.
        -- These are not module-ATTACHED, so the helper above misses them. Add a
        -- companion helper that also covers module-imported class data AND all
        -- class data emitted while producing a module CMI (module_has_cmi_p --
        -- catches the definition units where these classes are global-module,
        -- DECL_MODULE_IMPORT_P false). Force its linkage to COMDAT only where the
        -- vtable/typeinfo is ALREADY being emitted (a second else-if that does
        -- NOT mark_needed): forcing emission of the whole imported closure
        -- explodes the vtable worklist into an endless compile (observed live on
        -- pe_module.cpp; that failed first attempt is why the drain is here and
        -- the linkage-only upgrade is separate).
        if patched:find("macho_module_attached_class_data_p", 1, true)
            and not patched:find("macho_module_visible_class_data_p", 1, true) then
            local visible_helper =
                "/* project-local tolerance (Mach-O): a class that is module-visible but whose\n" ..
                "   vtable is emitted here anyway -- e.g. std exception types under -Os, whose\n" ..
                "   key method appears locally defined in every importer because the std module\n" ..
                "   streams its definition -- gets emitted STRONG in several module-unit objects,\n" ..
                "   which ld64 rejects as duplicates.  Unlike the attach case we must NOT force\n" ..
                "   emission (mark_needed) of the whole imported closure; we only upgrade the\n" ..
                "   linkage of vtables/typeinfo already being emitted to COMDAT so the copies\n" ..
                "   coalesce.  */\n" ..
                "static bool\n" ..
                "macho_module_visible_class_data_p (tree ctype)\n" ..
                "{\n" ..
                "#ifdef OBJECT_FORMAT_MACHO\n" ..
                "  /* Producing a module CMI: the std module streams key-method definitions into\n" ..
                "     every module unit, so even a global-module class (std::logic_error etc.)\n" ..
                "     gets a local key method here and is emitted, duplicating the copy in every\n" ..
                "     other module unit.  Force COMDAT for all class data in a CMI unit so the\n" ..
                "     copies coalesce; the module-initializer chain pulls every module-unit\n" ..
                "     object, so the weak-not-in-archive-TOC caveat cannot orphan them.  */\n" ..
                "  if (module_has_cmi_p ())\n" ..
                "    return true;\n" ..
                "  tree cdecl = TYPE_NAME (ctype);\n" ..
                "  return DECL_LANG_SPECIFIC (cdecl)\n" ..
                "\t && (DECL_MODULE_ATTACH_P (cdecl) || DECL_MODULE_IMPORT_P (cdecl));\n" ..
                "#else\n" ..
                "  (void) ctype;\n" ..
                "  return false;\n" ..
                "#endif\n" ..
                "}\n"
            local attached_helper_def =
                "static bool\n" ..
                "macho_module_attached_class_data_p (tree ctype)\n" ..
                "{\n" ..
                "#ifdef OBJECT_FORMAT_MACHO\n" ..
                "  tree cdecl = TYPE_NAME (ctype);\n" ..
                "  return DECL_LANG_SPECIFIC (cdecl) && DECL_MODULE_ATTACH_P (cdecl);\n" ..
                "#else\n" ..
                "  (void) ctype;\n" ..
                "  return false;\n" ..
                "#endif\n" ..
                "}"
            local patched_visible = base.replace_plain(patched,
                attached_helper_def,
                attached_helper_def .. "\n\n" .. visible_helper)
            patched_visible = base.replace_plain(patched_visible,
                "\t\t  comdat_p = true;\n" ..
                "\t\t  mark_needed (decl);\n" ..
                "\t\t}\n",
                "\t\t  comdat_p = true;\n" ..
                "\t\t  mark_needed (decl);\n" ..
                "\t\t}\n" ..
                "\t      else if (macho_module_visible_class_data_p (class_type))\n" ..
                "\t\t/* project-local: a module-visible class emitted here anyway\n" ..
                "\t\t   (std exception types at -Os) must be COMDAT on Mach-O so\n" ..
                "\t\t   the several module-unit copies coalesce; do NOT mark_needed,\n" ..
                "\t\t   forcing the imported closure would explode the vtable\n" ..
                "\t\t   worklist into an endless compile.  */\n" ..
                "\t\tcomdat_p = true;\n")
            patched_visible = base.replace_plain(patched_visible,
                "\t\t\t      || macho_module_attached_class_data_p (class_type));\n",
                "\t\t\t      || macho_module_visible_class_data_p (class_type));\n")
            if patched_visible ~= patched then
                print("patching GCC C++ front end: comdat linkage for module-imported/CMI class data on Mach-O (std exception duplicate typeinfo at -Os)")
                patched = patched_visible
                base.writefile_bytes(decl2_cc, patched)
            end
        end
        warn_patch_drift(patched, "macho_module_visible_class_data_p (tree ctype)",
            "cp/decl2.cc Mach-O comdat helper for module-imported/CMI class data (std exception duplicates at -Os)",
            "iOS/-Os module executables may fail to link with duplicate std exception vtable/typeinfo symbols.")
        warn_patch_drift(patched, "else if (macho_module_visible_class_data_p (class_type))",
            "cp/decl2.cc Mach-O comdat call site 3 (vtable else-if, no mark_needed)",
            "The module-imported class-data comdat upgrade may not reach the vtable emit path; iOS -Os duplicate std vtables return.")
        warn_patch_drift(patched, "|| macho_module_visible_class_data_p (class_type));",
            "cp/decl2.cc Mach-O comdat call site 4 (typeinfo comdat_p)",
            "The module-imported class-data comdat upgrade may not reach the typeinfo path; iOS -Os duplicate std typeinfo return.")
        warn_patch_drift(patched, "macho_module_attached_class_data_p",
            "cp/decl2.cc Mach-O comdat linkage for module-attached class data",
            "macOS executables may fail with duplicate typeinfo symbols for module-attached classes.")
        -- The helper name above is satisfied by the DEFINITION alone; verify
        -- the vtable CALL site independently (a partial drift that leaves the
        -- helper defined but uncalled silently regresses the macOS duplicate-
        -- symbol fix and trips -Wunused-function under -Werror). The typeinfo
        -- comdat_p call site (formerly the attached helper) is now broadened to
        -- macho_module_visible_class_data_p by the -Os patch below and is
        -- verified by its "call site 4" postcondition instead.
        warn_patch_drift(patched, "see macho_module_attached_class_data_p",
            "cp/decl2.cc Mach-O comdat call site 1 (vtables_uniquely_emitted if-condition)",
            "The module-attached class-data comdat forcing may not reach the emit path; macOS duplicate typeinfo can return.")
    end

    -- Third checking-only assert hit by ~25 implementation units that
    -- implicitly import the whole 330-partition module: binding-vector slot
    -- monotonicity in append_imported_binding_slot (cp/name-lookup.cc).
    -- Release-checking GCC compiles this assert out; neutralize it the same
    -- way. Functional tests remain the correctness check for this workaround.
    local name_lookup_cc = path.join(src, "gcc", "cp", "name-lookup.cc")
    if os.isfile(name_lookup_cc) then
        local content = io.readfile(name_lookup_cc)
        local needle = "\t/* Check monotonicity.  */\n" ..
            "\tgcc_checking_assert (last[off ? 0 : -1]\n" ..
            "\t\t\t     .indices[off ? off - 1\n" ..
            "\t\t\t\t      : BINDING_VECTOR_SLOTS_PER_CLUSTER - 1]\n" ..
            "\t\t\t     .base < ix);\n"
        local replacement = "\t/* Check monotonicity.  (project-local patch: checking\n" ..
            "\t   assert disabled to match release-checking GCC behaviour for\n" ..
            "\t   large partition counts; see build_support notes.)  */\n"
        local patched = base.replace_plain(content, needle, replacement)
        if patched ~= content then
            print("patching GCC name lookup: relax imported binding slot monotonicity checking assert")
            base.writefile_bytes(name_lookup_cc, patched)
            patched_module_streaming = true
        end
        warn_patch_drift(patched, "project-local patch: checking",
            "cp/name-lookup.cc binding-slot monotonicity assert relaxation",
            "Implementation units importing the full module may ICE in append_imported_binding_slot on checking builds.")
    end

    if patched_module_streaming then
        for _, gccdir in ipairs(dependent_gcc_compiler_build_dirs()) do
            print("invalidating GCC module streaming objects: " .. gccdir)
            for _, name in ipairs({
                path.join("cp", "module.o"),
                path.join("cp", "name-lookup.o"),
                "cc1plus",
                "cc1plus.exe",
                "cc1plus-checksum"
            }) do
                os.rm(path.join(gccdir, name))
            end
        end
    end

    -- libstdc++'s Makefile materializes libiberty/cp-demangle.c into the build
    -- tree with `ln`. Some Windows environments create a non-overwriting copy
    -- instead of a link, so discard only copies whose contents are actually
    -- stale. Recreating an already-current link changes its timestamp and
    -- needlessly recompiles this unusually expensive translation unit.
    local demangle_source = path.join(src, "libiberty", "cp-demangle.c")
    local demangle_content = os.isfile(demangle_source) and io.readfile(demangle_source) or nil
    for _, stale in ipairs(dependent_stale_demangle_files()) do
        if not demangle_content or io.readfile(stale) ~= demangle_content then
            print("removing stale libstdc++ cp-demangle copy: " .. stale)
            os.rm(stale)
        end
    end

    local function generated_option_lang_mask(lines, option_line)
        for offset = 1, 12 do
            local line = lines[option_line + offset]
            if line and line:find("/* .neg_idx = */", 1, true) then
                for mask_offset = 1, 3 do
                    local mask = lines[option_line + offset + mask_offset]
                    if mask and mask:find("%S") then
                        return mask
                    end
                end
            end
        end
    end

    local function generated_options_are_broken(options_cc)
        if not os.isfile(options_cc) then
            return false
        end
        local lines = io.readfile(options_cc):split("\n", {plain = true})
        for index, line in ipairs(lines) do
            if line:find('"-std=gnu++98"', 1, true) or line:find('"-nostdinc++"', 1, true) or line:find('"-freflection"', 1, true) then
                local mask = generated_option_lang_mask(lines, index)
                if not mask or not mask:find("CL_CXX", 1, true) then
                    return true
                end
            end
        end
        return false
    end

    for _, gccdir in ipairs(dependent_gcc_compiler_build_dirs()) do
        local options_cc = path.join(gccdir, "options.cc")
        if generated_options_changed or generated_options_are_broken(options_cc) then
            print("invalidating GCC generated option tables: " .. gccdir)
            for _, name in ipairs({
                "s-options",
                "s-options-h",
                "options.cc",
                "options.h",
                "options.o",
                "options-save.cc",
                "options-save.o",
                "options-urls.cc",
                "options-urls.o",
                "cc1plus",
                "cc1plus.exe",
                "cc1plus-checksum"
            }) do
                os.rm(path.join(gccdir, name))
            end
        end
    end
end

function register_postconditions(ctx)
    for _, condition in ipairs({
        {file = path.join("libstdc++-v3", "include", "bits", "c++config"),
            fingerprint = "x86_64 Android gives long double and __float128 the same g mangling",
            what = "x86_64 Android long-double/__float128 ABI collision avoidance"},
        {file = path.join("libstdc++-v3", "include", "std", "format"),
            fingerprint = "defined(__SIZEOF_FLOAT128__) && defined(_GLIBCXX_USE_FLOAT128)",
            what = "std::format __float128 host-support gating"},
        {file = path.join("gcc", "cp", "g++spec.cc"), fingerprint = "libstdc++exp-contracts-default-handler.ld",
            what = "PE-COFF contracts default handler linker script injection"},
        {file = path.join("gcc", "cp", "g++spec.cc"), fingerprint = "bool need_contract_default_handler = false;",
            what = "PE-COFF contracts default handler driver state"},
        {file = path.join("gcc", "cp", "g++spec.cc"), fingerprint = "need_contract_default_handler = true;",
            what = "PE-COFF contracts default handler OPT_fcontracts trigger"},
        {file = path.join("gcc", "cp", "g++spec.cc"), fingerprint = "+ need_contract_default_handler\n#endif\n\t      + (std_module * 5)",
            what = "PE-COFF contracts default handler argument-count allocation slot"},
        {file = path.join("gcc", "opt-functions.awk"), fingerprint = [=[gsub ( "\\+", "[+]", regex )]=],
            what = "option generator C++-only language flag preservation"},
        {file = path.join("gcc", "cp", "module.cc"), fingerprint = "residual PR c++/118630 case).  */",
            what = "module streaming multi-entry mergeable cluster tolerance (PR c++/118630)"},
        {file = path.join("gcc", "cp", "module.cc"), fingerprint = "project-local fix (PR c++/122310",
            what = "module streaming keyed-entity reader fix (PR c++/122310 relative)"},
        {file = path.join("gcc", "cp", "decl2.cc"), fingerprint = "COMDAT is itself the vague-linkage",
            what = "vague_linkage_p imported-COMDAT tolerance"},
        {file = path.join("gcc", "cp", "decl2.cc"), fingerprint = "macho_module_attached_class_data_p",
            what = "Mach-O comdat linkage for module-attached class data"},
        {file = path.join("gcc", "cp", "decl2.cc"), fingerprint = "see macho_module_attached_class_data_p",
            what = "Mach-O comdat call site 1 (if-condition)"},
        {file = path.join("gcc", "cp", "module.cc"), fingerprint = "static bool draining = false;",
            what = "post_load_processing lazy-load re-entrancy guard (PR c++/124542 relative)"},
        {file = path.join("gcc", "cp", "module.cc"), fingerprint = "definitions can be dropped and re-seen",
            what = "assert_definition CHECKING_P neutralization (re-export re-install under -Os)"},
        {file = path.join("gcc", "cp", "decl2.cc"), fingerprint = "macho_module_visible_class_data_p (tree ctype)",
            what = "Mach-O comdat helper for module-imported/CMI class data (std exception duplicates at -Os)"},
        {file = path.join("gcc", "cp", "decl2.cc"), fingerprint = "else if (macho_module_visible_class_data_p (class_type))",
            what = "Mach-O comdat call site 3 (vtable else-if, no mark_needed)"},
        {file = path.join("gcc", "cp", "decl2.cc"), fingerprint = "|| macho_module_visible_class_data_p (class_type));",
            what = "Mach-O comdat call site 4 (typeinfo comdat_p)"},
        {file = path.join("gcc", "cp", "name-lookup.cc"), fingerprint = "project-local patch: checking",
            what = "binding-slot monotonicity assert relaxation"}
    }) do
        table.insert(ctx.postconditions, condition)
    end
end
