-- Fixture regression for whole-family patch application: darwin.lua and
-- ios.lua run against a SYNTHETIC mini source tree that carries only the
-- pinned upstream anchor lines. This is the in-repo twin of the real-tree
-- battery (stamp-delete repatch): primitives are covered by
-- patches_shared_cases, this suite covers the families' own wiring --
-- facade apply order, profile gating, v66 retirement, postcondition
-- registration -- without needing a GCC checkout.
--
-- The anchor literals below are byte-copies of the family sources
-- (patches/{darwin,ios}.lua). Drift here only weakens the fixture; the
-- real tree stays guarded by the postcondition checkpoint.
--
-- wasm and the broad mainline payloads are deliberately NOT applied here:
-- their families are dominated by multi-thousand-line patch payloads whose
-- anchors cannot be synthesized meaningfully; the real-tree battery owns
-- them. The small x86_64 Android float128 patch is exercised explicitly.

local REPLICA_SUBDIRS = {
    "core/modules",
    "languages/cpp/modules",
    "languages/cpp/modules/patches"
}

local function fresh_families(t)
    local replica = t.replicate_build_support(REPLICA_SUBDIRS, "patchfam-sandbox")
    local patches = path.join(replica, "languages", "cpp", "modules", "patches")
    local darwin = import("darwin", {rootdir = patches, anonymous = true})
    local ios = import("ios", {rootdir = patches, anonymous = true})
    return darwin, ios
end

local function fresh_mainline(t)
    local replica = t.replicate_build_support(REPLICA_SUBDIRS, "mainline-patchfam-sandbox")
    return import("mainline", {
        rootdir = path.join(replica, "languages", "cpp", "modules", "patches"),
        anonymous = true
    })
end

local function build_mainline_float128_tree(t)
    local src = t.tmpdir("patchfam-mainline-float128")
    local cxxconfig = path.join(src, "libstdc++-v3", "include", "bits", "c++config")
    os.mkdir(path.directory(cxxconfig))
    io.writefile(cxxconfig, table.concat({
        "/* synthetic c++config */",
        "/* Define if __float128 is supported on this host.  */",
        "#if defined(__FLOAT128__) || defined(__SIZEOF_FLOAT128__)",
        "/* For powerpc64 don't use __float128 when it's the same type as long double. */",
        "# if !(defined(_GLIBCXX_LONG_DOUBLE_ALT128_COMPAT) && defined(__LONG_DOUBLE_IEEE128__))",
        "#  define _GLIBCXX_USE_FLOAT128",
        "# endif",
        "#endif",
        ""
    }, "\n"))

    local format_header = path.join(src, "libstdc++-v3", "include", "std", "format")
    os.mkdir(path.directory(format_header))
    io.writefile(format_header, table.concat({
        "#if defined(__SIZEOF_FLOAT128__) && _GLIBCXX_FORMAT_F128 == 2",
        "  // Use __formatter_fp<C>::format<__format::__flt128_t, Out> for __float128,",
        "",
        "#ifdef __SIZEOF_FLOAT128__",
        "\t__float128 _M_float128;",
        "#endif",
        "",
        "#ifdef __SIZEOF_FLOAT128__",
        "\t  else if constexpr (is_same_v<_Tp, __float128>)",
        "\t    return (__u._M_float128 = ... = __value);",
        "#endif",
        "",
        "#if defined(__SIZEOF_FLOAT128__) && _GLIBCXX_FORMAT_F128",
        "\t  else if constexpr (is_same_v<_Td, __float128>)",
        "\t    return type_identity<__float128>();",
        "#endif",
        "",
        "#if defined(__SIZEOF_FLOAT128__) && _GLIBCXX_FORMAT_F128",
        "\t  else if constexpr (is_same_v<_Tp, __float128>)",
        "\t    return _Arg_float128;",
        "#endif",
        "",
        "#if defined(__SIZEOF_FLOAT128__) && _GLIBCXX_FORMAT_F128",
        "\t    case _Arg_float128:",
        "\t      return std::forward<_Visitor>(__vis)(_M_val._M_float128);",
        "#endif",
        ""
    }, "\n"))
    return src, cxxconfig, format_header
end

-- The synthetic tree: every file the two families touch, reduced to the
-- pinned anchors plus neutral filler.
local function build_tree(t, name)
    local src = t.tmpdir(name)
    local function put(rel, content)
        local file = path.join(src, rel)
        os.mkdir(path.directory(file))
        io.writefile(file, content)
    end
    put("gcc/config.gcc",
        "# synthetic config.gcc\n"
        .. "aarch64*-*-darwin2*)\n  # This applies to arm64 Darwin variadic funtions.\n"
        .. "  ;;\n"
        .. "\n*-*-dragonfly*)\n  tmake_file=\"t-slibgcc\"\n  ;;\n"
        .. "aarch64*-*-freebsd*)\n\ttm_file=\"${tm_file} elfos.h ${fbsd_tm_file}\"\n\t;;\n")
    put("gcc/config/darwin.cc",
        "static void darwin_file_start (void)\n{\n"
        .. "    directive = \"build_version macos, \";\n"
        .. "}\n")
    put("gcc/config/darwin-c.cc",
        "static void builtin_defines (void)\n{\n"
        .. "  builtin_define_with_value (\"__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__\",\n"
        .. "\t\t\t     macosx_version_as_macro(), false);\n"
        .. "}\n")
    put("gcc/configure",
        "# synthetic gcc/configure\n"
        .. "    *darwin*)\n\tld64_flag=yes # Darwin can only use a ld64-compatible linker.\n"
        .. "  *-*-darwin*)\n    as_flavor=darwin\n"
        .. "  *-*-darwin*)\n    ld_flavor=darwin\n"
        .. "  *-*-darwin*)\n    # Darwin as has some visibility support, though with a different syntax.\n"
        .. "      *-*-darwin*)\n\t# Darwin ld has some visibility support.\n"
        .. "case \"$target_os\" in\n  darwin*)\n"
        .. "  ;;\nesac\n")
    put("libgcc/config.host",
        "# synthetic libgcc config.host\n"
        .. "aarch64*-*-darwin*)\n"
        .. "\ttmake_file=\"${tmake_file} ${cpu_type}/t-aarch64\"\n"
        .. "\t;;\n"
        .. "\n*-*-dragonfly*)\n  tmake_file=\"$tmake_file t-crtstuff-pic t-libgcc-pic t-eh-dw2-dip\"\n  ;;\n"
        .. "aarch64*-*-freebsd*)\n\textra_parts=\"$extra_parts crtfastmath.o\"\n\t;;\n")
    put("libstdc++-v3/configure",
        "# synthetic libstdc++ configure\n"
        .. "  *-darwin*)\n    # Darwin versions vary, but the linker should work in a cross environment,\n"
        .. "      darwin*)\n\tenable_clocale_flag=darwin\n")
    put("libstdc++-v3/configure.host",
        "# synthetic configure.host\n"
        .. "  darwin*)\n    # Post Darwin8, defaults should be sufficient.\n")
    return src
end

local function tree_snapshot(src)
    local snapshot = {}
    for _, file in ipairs(os.files(path.join(src, "**"))) do
        snapshot[path.relative(file, src)] = io.readfile(file)
    end
    return snapshot
end

local function apply_families(darwin, ios, src, target_os)
    -- facade order (gccpatches.patch_gcc_source): darwin runs for every
    -- profile and materializes t-darwin-no-eh, which the ios libgcc case
    -- reuses; ios follows
    local ctx = {src = src, target_os = target_os, flags = {}, postconditions = {}}
    darwin.apply(ctx)
    ios.apply(ctx)
    darwin.register_postconditions(ctx)
    ios.register_postconditions(ctx)
    return ctx
end

function run(t)
    os.setenv("TOOLCHAINS_TARGET", "")

    t.case("patch families: darwin then ios apply cleanly and satisfy every postcondition", function ()
        local darwin, ios = fresh_families(t)
        local src = build_tree(t, "patchfam-apply")
        local ctx = apply_families(darwin, ios, src, "ios")
        t.assert_true(#ctx.postconditions > 0, "families must register postconditions")
        for _, condition in ipairs(ctx.postconditions) do
            local content = io.readfile(path.join(src, condition.file)) or ""
            if condition.fingerprint then
                t.assert_true(content:find(condition.fingerprint, 1, true) ~= nil,
                    "unmet postcondition: " .. tostring(condition.what))
            else
                t.assert_true(os.isfile(path.join(src, condition.file)),
                    "missing postcondition file: " .. tostring(condition.what))
            end
        end
        local header = io.readfile(path.join(src, "gcc", "config", "darwin-ios.h")) or ""
        t.assert_match(header, "WhiteHopeEngine build_support owned file", "owned override header marker")
        t.assert_match(io.readfile(path.join(src, "libgcc", "config.host")) or "",
            "${cpu_type}/t-darwin-no-eh", "darwin no-EH fragment ordering reached the synthetic tree")
    end)

    t.case("patch families: a second apply is a byte-level no-op", function ()
        local darwin, ios = fresh_families(t)
        local src = build_tree(t, "patchfam-idempotent")
        apply_families(darwin, ios, src, "ios")
        local before = tree_snapshot(src)
        apply_families(darwin, ios, src, "ios")
        local after = tree_snapshot(src)
        for rel, content in pairs(before) do
            t.assert_true(after[rel] == content, "file changed on the second apply: " .. rel)
        end
        for rel in pairs(after) do
            t.assert_true(before[rel] ~= nil, "file appeared on the second apply: " .. rel)
        end
    end)

    t.case("patch families: the v66 heap-trampoline block is retired and re-spliced", function ()
        local darwin, ios = fresh_families(t)
        local src = build_tree(t, "patchfam-retire")
        -- byte-copy of the block the v66 stamp generation inserted
        -- (patches/ios.lua libgcc_cpu_case_v66_block); a tree patched at v66
        -- carries it and the fingerprint-idempotent splice would keep it
        -- forever unless retire_superseded removes it first
        local v66 = table.concat({
            'aarch64*-*-ios*)',
            '\textra_parts="$extra_parts crtfastmath.o libheapt_w.a"',
            '\ttmake_file="${tmake_file} ${cpu_type}/t-darwin-no-eh"',
            '\ttmake_file="${tmake_file} ${cpu_type}/t-aarch64"',
            '\ttmake_file="${tmake_file} ${cpu_type}/t-lse"',
            '\ttmake_file="${tmake_file} t-crtfm t-dfprules"',
            '\ttmake_file="${tmake_file} ${cpu_type}/t-softfp t-softfp"',
            '\ttmake_file="${tmake_file} ${cpu_type}/t-heap-trampoline"',
            '\tmd_unwind_def_header=aarch64/aarch64-unwind-def.h',
            '\tmd_unwind_header=aarch64/aarch64-unwind.h',
            '\t;;',
            ''
        }, "\n")
        local config_host = path.join(src, "libgcc", "config.host")
        local seeded = (io.readfile(config_host) or ""):gsub(
            "aarch64%*%-%*%-freebsd%*%)", v66 .. "aarch64*-*-freebsd*)", 1)
        io.writefile(config_host, seeded)
        apply_families(darwin, ios, src, "ios")
        local content = io.readfile(config_host) or ""
        -- the v67 block's own comment names libheapt_w.a while explaining
        -- its absence, so the negative assertions target the v66 signature
        -- LINES rather than the bare library name
        t.assert_true(not content:find('crtfastmath.o libheapt_w.a', 1, true),
            "the v66 extra_parts with the heap-trampoline library must be retired")
        t.assert_true(not content:find('\ttmake_file="${tmake_file} ${cpu_type}/t-heap-trampoline"', 1, true),
            "the v66 heap-trampoline fragment line must be retired")
        t.assert_match(content, "No ${cpu_type}/t-heap-trampoline",
            "the v67 iOS libgcc case must be re-spliced after retirement")
    end)

    t.case("patch families: mainline guards the x86_64 Android float128 ABI collision", function ()
        local mainline = fresh_mainline(t)
        local src, cxxconfig, format_header = build_mainline_float128_tree(t)
        local ctx = {
            src = src,
            target_os = "android",
            flags = {},
            postconditions = {}
        }

        mainline.apply(ctx)
        local first = io.readfile(cxxconfig)
        t.assert_match(first,
            "defined(__ANDROID__) && defined(__x86_64__)",
            "Android x86_64 guard")
        t.assert_match(first,
            "&& defined(__LONG_DOUBLE_128__)",
            "binary128 long-double guard")
        t.assert_match(first,
            "#   define _GLIBCXX_USE_FLOAT128",
            "float128 remains enabled outside the guarded ABI")
        local first_format = io.readfile(format_header)
        local _, format_guard_count = first_format:gsub("_GLIBCXX_USE_FLOAT128", "")
        t.assert_eq(format_guard_count, 6,
            "every std::format __float128 path must honor the host-support gate")
        t.assert_match(first_format,
            "_GLIBCXX_FORMAT_F128 == 2",
            "the independent _Float128 formatting mode remains intact")

        mainline.apply(ctx)
        t.assert_eq(io.readfile(cxxconfig), first,
            "Android float128 patch must be byte-level idempotent")
        t.assert_eq(io.readfile(format_header), first_format,
            "Android std::format float128 patch must be byte-level idempotent")

        mainline.register_postconditions(ctx)
        local registered_cxxconfig = false
        local registered_format = false
        for _, condition in ipairs(ctx.postconditions) do
            if condition.fingerprint == "x86_64 Android gives long double and __float128 the same g mangling" then
                registered_cxxconfig = true
            elseif condition.fingerprint == "defined(__SIZEOF_FLOAT128__) && defined(_GLIBCXX_USE_FLOAT128)" then
                registered_format = true
            end
        end
        t.assert_true(registered_cxxconfig,
            "Android float128 c++config patch postcondition must be registered")
        t.assert_true(registered_format,
            "Android std::format float128 patch postcondition must be registered")
    end)

    t.case("patch families: ios stays inert outside the darwin-arm64 profile", function ()
        local _, ios = fresh_families(t)
        local src = build_tree(t, "patchfam-gating")
        local before = tree_snapshot(src)
        local ctx = {src = src, target_os = "windows", flags = {}, postconditions = {}}
        ios.apply(ctx)
        ios.register_postconditions(ctx)
        local after = tree_snapshot(src)
        for rel, content in pairs(before) do
            t.assert_true(after[rel] == content, "ios family touched a non-darwin tree: " .. rel)
        end
        t.assert_true(after[path.join("gcc", "config", "darwin-ios.h")] == nil
                and not os.isfile(path.join(src, "gcc", "config", "darwin-ios.h")),
            "the iOS override header must not be written outside the darwin profile")
        t.assert_eq(#ctx.postconditions, 0, "no ios postconditions outside the darwin profile")
    end)

    -- Call-surface guards. The patch pipeline only runs when a GCC source tree
    -- is actually re-synced, which on an installed checkout can be months
    -- apart -- so a helper deleted along with the code that seemed to be its
    -- only caller stays invisible until the next upstream bump, and then the
    -- whole sync dies on "attempt to call a nil value". Both variants shipped
    -- in 53c1907 and surfaced together on 2026-08-12: shared.warn_patch_drift
    -- was removed while 18 call sites remained, and the facade still called
    -- wasm.apply() after that family was reduced to witnesses. These two cases
    -- are the cheap, general guard; they read the real sources, not a replica.
    local SUPPORT = path.join(os.projectdir(), "build_support", "languages", "cpp", "modules")

    t.case("patch families: every shared.<helper> the families call is defined", function ()
        local patches = path.join(SUPPORT, "patches")
        local shared = import("shared", {rootdir = patches, anonymous = true})
        local missing = {}
        for _, file in ipairs(os.files(path.join(patches, "*.lua"))) do
            if path.filename(file) ~= "shared.lua" then
                for name in (io.readfile(file) or ""):gmatch("shared%.([%w_]+)") do
                    if type(shared[name]) ~= "function" then
                        table.insert(missing, path.filename(file) .. " -> shared." .. name)
                    end
                end
            end
        end
        t.assert_true(#missing == 0,
            "patch families call helpers shared.lua does not define: " .. table.concat(missing, ", "))
    end)

    t.case("patch facade: every family entry point gccpatches calls is defined", function ()
        local patches = path.join(SUPPORT, "patches")
        local families = {}
        for _, name in ipairs({"darwin", "ios", "mainline", "wasm"}) do
            families[name] = import(name, {rootdir = patches, anonymous = true})
        end
        local facade = io.readfile(path.join(SUPPORT, "gccpatches.lua")) or ""
        local missing = {}
        local seen = 0
        for family, entry in facade:gmatch("([%w_]+)%.([%w_]+)%(ctx") do
            if families[family] then
                seen = seen + 1
                if type(families[family][entry]) ~= "function" then
                    table.insert(missing, family .. "." .. entry)
                end
            end
        end
        t.assert_true(seen > 0, "the facade call scan found no family calls at all")
        t.assert_true(#missing == 0,
            "gccpatches calls family entry points that do not exist: " .. table.concat(missing, ", "))
    end)
end
