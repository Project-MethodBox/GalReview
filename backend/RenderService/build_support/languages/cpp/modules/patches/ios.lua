-- GCC source patches owned by the iOS target. iOS support is carried as an
-- additive patch layer on the shared darwin-arm64 source tree (owner
-- decision, phase E1): a real *-*-ios* target triplet with iOS platform
-- marks (.build_version ios / -platform_version ios), layered as pure
-- insertions next to the upstream Darwin cases so the darwin.lua anchors
-- stay untouched.
--
-- apply() is profile gated in addition to the per-patch anchor gating:
-- unlike the darwin.lua libgcc anchor, most iOS anchors (the dragonfly
-- insertion points, the "build_version macos" directive, the configure
-- flavor cases) exist verbatim in the mainline and wasm trees too, so
-- anchor self-gating alone would silently patch those trees and change the
-- established mainline/wasm patch behavior. The gate keeps iOS patches a
-- darwin-arm64-tree concern; within the darwin tree the anchors stay
-- self-gated with drift warnings, and the profile-gated postconditions in
-- gccpatches.lua turn surviving drift into the loud failure.
--
-- Every anchor below was extracted byte-exactly from the pinned
-- iains/gcc-darwin-arm64 tree (f4e36f15) and verified unique (2026-07-17).

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
local defaults = import("defaults", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")}).values()
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("shared")

local function ios_profile_active(ctx)
    return ctx.target_os ~= nil
        and settings.gcc_source_profile(ctx.target_os).name == "darwin-arm64"
end

-- The compiled-in iOS minimum must stay equal to the ios_deployment_target
-- option default; both read the defaults.lua single source. Changing that
-- default only reaches already-patched trees after a stamp version bump in
-- gccpatches.lua (the applied-fingerprint skip keeps old text otherwise).
local function ios_min_version()
    return tostring(defaults.ios_deployment_target)
end

-- Soft variant of shared.strict_replace: skip when the applied fingerprint
-- is already present, splice at the pinned anchor, warn (not fail) on
-- drift. The hard failure lives in the postcondition checkpoint.
local function splice(ctx, relfile, patch)
    local file = path.join(ctx.src, relfile)
    local content = os.isfile(file) and io.readfile(file) or ""
    if content:find(patch.fingerprint, 1, true) then
        return
    end
    if not content:find(patch.anchor, 1, true) then
        shared.warn_patch_drift(content, patch.anchor, patch.what, patch.consequence)
        return
    end
    print("patching " .. patch.what .. ": " .. relfile)
    base.writefile_bytes(file, base.replace_plain(content, patch.anchor, patch.replacement))
end

-- Retire an exact block an older stamp generation of THIS family inserted.
-- splice() skips as soon as its fingerprint is present, so a tree patched by
-- the earlier shape would keep it forever; dropping the superseded text first
-- lets the current splice re-insert. Fresh syncs never take this path.
local function retire_superseded(ctx, relfile, old_block, what)
    local file = path.join(ctx.src, relfile)
    if not os.isfile(file) then
        return
    end
    local content = io.readfile(file)
    if not content:find(old_block, 1, true) then
        return
    end
    print("retiring superseded iOS patch block (" .. what .. "): " .. relfile)
    base.writefile_bytes(file, base.replace_plain(content, old_block, ""))
end

-- v66 inserted the AArch64 iOS libgcc case with the Apple heap-trampoline
-- fragment; v67 drops it (see libgcc_cpu_case_patch). Trees patched at v66
-- must lose that exact block for the current one to splice in.
local function libgcc_cpu_case_v66_block()
    return table.concat({
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
end

-- gcc/config.gcc: the iOS target OS case (inserted after the Darwin OS
-- block, before *-*-dragonfly*). Skeleton replicated from the *-*-darwin*)
-- block with iOS semantics: no darwin<N> version parsing (the triplet is
-- unversioned; an explicit aarch64-apple-ios<V> suffix still wins), no
-- DARWIN_USE_KERNEL_VERS, modern ld64 and object alignment directly, and
-- the darwin-ios.h override header appended after ${cpu_type}/darwin.h.
local function config_gcc_os_case_patch()
    local anchor = '\n*-*-dragonfly*)\n  tmake_file="t-slibgcc"\n'
    local ios_case = table.concat({
        '',
        '*-*-ios*)',
        '  case ${target} in',
        '    *-*-ios*-simulator*)',
        '      echo "Error: iOS simulator triplets are not supported yet: ${target}" 1>&2',
        '      exit 1',
        '      ;;',
        '  esac',
        '  tmake_file="t-darwin "',
        '  tm_file="${tm_file} darwin.h"',
        '  ios_min=`echo ${target} | sed \'s/.*-ios//\'`',
        '  if test x"${ios_min}" = x; then',
        '    ios_min=' .. ios_min_version(),
        '  fi',
        '  def_ld64=609.0',
        '  tm_defines="$tm_defines L2_MAX_OFILE_ALIGNMENT=28U"',
        '  tm_defines="$tm_defines DEF_MIN_OSX_VERSION=\\\\\\"${ios_min}\\\\\\""',
        '  tm_defines="$tm_defines DEF_LD64=\\\\\\"${def_ld64}\\\\\\""',
        '  tm_file="${tm_file} ${cpu_type}/darwin.h darwin-ios.h"',
        '  tm_p_file="${tm_p_file} darwin-protos.h"',
        '  target_gtfiles="$target_gtfiles \\$(srcdir)/config/darwin.cc"',
        '  extra_options="${extra_options} rpath.opt darwin.opt"',
        '  c_target_objs="${c_target_objs} darwin-c.o"',
        '  cxx_target_objs="${cxx_target_objs} darwin-c.o"',
        '  d_target_objs="${d_target_objs} darwin-d.o"',
        '  fortran_target_objs="darwin-f.o"',
        '  rust_target_objs="${rust_target_objs} darwin-rust.o"',
        '  target_has_targetcm=yes',
        '  target_has_targetdm=yes',
        '  target_has_targetrustm=yes',
        '  extra_objs="${extra_objs} darwin.o"',
        '  extra_gcc_objs="darwin-driver.o"',
        '  default_use_cxa_atexit=yes',
        '  use_gcc_stdint=wrap',
        '  case ${enable_threads} in',
        '    "" | yes | posix) thread_file=\'posix\' ;;',
        '  esac',
        '  ;;'
    }, "\n")
    return {
        anchor = anchor,
        replacement = ios_case .. anchor,
        fingerprint = "\n*-*-ios*)\n",
        what = "iOS target OS case (gcc/config.gcc)",
        consequence = "aarch64-apple-ios configures fail as an unreleased macOS version."
    }
end

-- gcc/config.gcc: arm64 iOS heap trampolines / variadic handling, same
-- values as the arm64 Darwin case it is inserted before.
-- HEAP_TRAMPOLINES_INIT=1 stays even though the iOS libgcc case ships no
-- heap-trampoline runtime (see libgcc_cpu_case_patch): the alternative is
-- executable-stack trampolines, which iOS refuses at run time, so keeping
-- the define converts "uses a GNU C nested-function pointer on iOS" from a
-- silent runtime trap into a link error naming the missing helper.
local function config_gcc_trampoline_patch()
    local anchor = "aarch64*-*-darwin2*)\n  # This applies to arm64 Darwin variadic funtions.\n"
    local ios_case = table.concat({
        'aarch64*-*-ios*)',
        '  # arm64 iOS follows arm64 Darwin: variadic args and no executable stack.',
        '  tm_defines="$tm_defines STACK_USE_CUMULATIVE_ARGS_INIT=1"',
        '  tm_defines="$tm_defines HEAP_TRAMPOLINES_INIT=1"',
        '  ;;',
        ''
    }, "\n")
    return {
        anchor = anchor,
        replacement = ios_case .. anchor,
        fingerprint = "aarch64*-*-ios*)",
        what = "iOS AArch64 heap-trampoline defines (gcc/config.gcc)",
        consequence = "arm64 iOS objects would use executable-stack trampolines and the wrong variadic ABI."
    }
end

-- gcc/config.gcc: the per-CPU iOS case, a verbatim copy of the
-- aarch64-*-darwin* block it follows (errata header, Darwin AArch64
-- fragments, async unwind tables, apple-m1 default CPU).
local function config_gcc_cpu_case_patch()
    local anchor = 'aarch64*-*-freebsd*)\n\ttm_file="${tm_file} elfos.h ${fbsd_tm_file}"\n'
    local ios_case = table.concat({
        'aarch64-*-ios* )',
        '\ttm_file="${tm_file} aarch64/aarch64-errata.h"',
        '\ttmake_file="${tmake_file} aarch64/t-aarch64 aarch64/t-aarch64-darwin"',
        '\ttm_defines="${tm_defines} TARGET_DEFAULT_ASYNC_UNWIND_TABLES=1"',
        '\ttm_defines="${tm_defines} DISABLE_AARCH64_AS_CRC_BUGFIX=1"',
        '\t# Choose a default CPU version that will work for all current releases.',
        '\twith_cpu=${with_cpu:-apple-m1}',
        '\t;;',
        ''
    }, "\n")
    return {
        anchor = anchor,
        replacement = ios_case .. anchor,
        fingerprint = "aarch64-*-ios* )",
        what = "iOS AArch64 per-CPU case (gcc/config.gcc)",
        consequence = "aarch64-apple-ios would miss the Darwin AArch64 machine fragments and default CPU."
    }
end

-- gcc/config/darwin.cc: emit ".build_version ios" instead of macos when the
-- target is iOS. This is what stamps LC_BUILD_VERSION platform=IOS.
local function darwin_cc_patch()
    local anchor = '    directive = "build_version macos, ";\n'
    local replacement = table.concat({
        '#ifdef DARWIN_TARGET_IOS',
        '    directive = "build_version ios, ";',
        '#else',
        '    directive = "build_version macos, ";',
        '#endif',
        ''
    }, "\n")
    return {
        anchor = anchor,
        replacement = replacement,
        fingerprint = 'build_version ios, ',
        what = "iOS .build_version directive (gcc/config/darwin.cc)",
        consequence = "iOS objects would carry a macOS LC_BUILD_VERSION and be rejected by ld64."
    }
end

-- gcc/config/darwin-c.cc: publish the iOS environment minimum macro that
-- AvailabilityInternal.h derives __IPHONE_OS_VERSION_MIN_REQUIRED from.
-- macosx_version_as_macro() already yields the six-digit iOS format for
-- modern versions (15.0 -> 150000).
local function darwin_c_cc_patch()
    local anchor = '  builtin_define_with_value ("__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__",\n'
        .. '\t\t\t     macosx_version_as_macro(), false);\n'
    local replacement = table.concat({
        '#ifdef DARWIN_TARGET_IOS',
        '  builtin_define_with_value ("__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__",',
        '\t\t\t     macosx_version_as_macro(), false);',
        '#else',
        '  builtin_define_with_value ("__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__",',
        '\t\t\t     macosx_version_as_macro(), false);',
        '#endif',
        ''
    }, "\n")
    return {
        anchor = anchor,
        replacement = replacement,
        fingerprint = "__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__",
        what = "iOS deployment-minimum macro (gcc/config/darwin-c.cc)",
        consequence = "iOS SDK availability headers would see no deployment minimum."
    }
end

-- gcc/configure (generated file; configure.ac is deliberately untouched to
-- avoid maintainer-mode regeneration): extend the six target-keyed Darwin
-- cases to iOS. The $target_os case is the E1 lifeline -- without it the
-- -mmacosx-version-min/.build_version assembler probes never run, so
-- darwin_file_start would emit no platform directive at all.
local function gcc_configure_patches()
    return {
        {
            anchor = '    *darwin*)\n\tld64_flag=yes # Darwin can only use a ld64-compatible linker.\n',
            replacement = '    *darwin* | *-*-ios*)\n\tld64_flag=yes # Darwin can only use a ld64-compatible linker.\n',
            fingerprint = '    *darwin* | *-*-ios*)',
            what = "iOS default-linker flavor (gcc/configure ld64_flag)",
            consequence = "iOS builds would not treat the linker as ld64 (wrong dsymutil/ld defaults)."
        },
        {
            anchor = '  *-*-darwin*)\n    as_flavor=darwin\n',
            replacement = '  *-*-darwin* | *-*-ios*)\n    as_flavor=darwin\n',
            fingerprint = '  *-*-darwin* | *-*-ios*)\n    as_flavor=darwin',
            what = "iOS assembler flavor (gcc/configure as_flavor)",
            consequence = "iOS builds would misdetect the Apple assembler flavor."
        },
        {
            anchor = '  *-*-darwin*)\n    ld_flavor=darwin\n',
            replacement = '  *-*-darwin* | *-*-ios*)\n    ld_flavor=darwin\n',
            fingerprint = '  *-*-darwin* | *-*-ios*)\n    ld_flavor=darwin',
            what = "iOS linker flavor (gcc/configure ld_flavor)",
            consequence = "iOS builds would misdetect the Apple linker flavor."
        },
        {
            anchor = '  *-*-darwin*)\n    # Darwin as has some visibility support, though with a different syntax.\n',
            replacement = '  *-*-darwin* | *-*-ios*)\n    # Darwin as has some visibility support, though with a different syntax.\n',
            fingerprint = '  *-*-darwin* | *-*-ios*)\n    # Darwin as has some visibility support',
            what = "iOS assembler visibility support (gcc/configure gcc_cv_as_hidden)",
            consequence = "iOS builds would lose symbol-visibility support in the assembler."
        },
        {
            anchor = '      *-*-darwin*)\n\t# Darwin ld has some visibility support.\n',
            replacement = '      *-*-darwin* | *-*-ios*)\n\t# Darwin ld has some visibility support.\n',
            fingerprint = '      *-*-darwin* | *-*-ios*)\n\t# Darwin ld has some visibility support.',
            what = "iOS linker visibility support (gcc/configure gcc_cv_ld_hidden)",
            consequence = "iOS builds would lose symbol-visibility support in the linker."
        },
        {
            anchor = 'case "$target_os" in\n  darwin*)\n',
            replacement = 'case "$target_os" in\n  darwin* | ios*)\n',
            fingerprint = 'darwin* | ios*)',
            what = "iOS platform assembler probes (gcc/configure target_os case)",
            consequence = "HAVE_AS_MMACOSX_VERSION_MIN_OPTION/HAVE_AS_MACOS_BUILD_VERSION stay undefined; no LC_BUILD_VERSION is ever emitted."
        }
    }
end

-- libgcc/config.host: the iOS OS-level case (before *-*-dragonfly*). Unlike
-- Darwin it installs no t-darwin-min-* fragment -- forcing
-- -mmacosx-version-min=11 would stamp every libgcc object as macOS; the iOS
-- minimum comes from the compiled-in driver default instead. No rpath
-- handling either: only libgcc itself is shared (--enable-shared=libgcc,
-- see targets/ios.lua), the engine consumes the runtimes statically, and
-- iOS app bundles embed their libraries.
local function libgcc_os_case_patch()
    local anchor = '\n*-*-dragonfly*)\n  tmake_file="$tmake_file t-crtstuff-pic t-libgcc-pic t-eh-dw2-dip"\n'
    local ios_case = table.concat({
        '',
        '*-*-ios*)',
        '  asm_hidden_op=.private_extern',
        '  tmake_file="$tmake_file t-darwin ${cpu_type}/t-darwin t-libgcc-pic"',
        '  # The unwinder comes from the system libraries; only libgcc itself is',
        '  # shared (--enable-shared=libgcc). The deployment minimum comes from',
        '  # the compiler driver default (no t-darwin-min-* fragment) so objects',
        '  # stay iOS-marked.',
        '  tmake_file="$tmake_file t-slibgcc-darwin"',
        '  extra_parts="crt3.o crttms.o crttme.o libemutls_w.a "',
        '  ;;'
    }, "\n")
    return {
        anchor = anchor,
        replacement = ios_case .. anchor,
        fingerprint = "\n*-*-ios*)\n  asm_hidden_op",
        what = "iOS libgcc OS case (libgcc/config.host)",
        consequence = "iOS libgcc would fall back to macOS 10.5 fragments with macOS-marked objects."
    }
end

-- libgcc/config.host: the AArch64 iOS case, a near-copy of the (already
-- darwin.lua-patched) aarch64*-*-darwin* block, including the
-- t-darwin-no-eh fragment that darwin.apply() materializes first. The one
-- deliberate divergence is the heap-trampoline runtime, see below.
local function libgcc_cpu_case_patch()
    local anchor = 'aarch64*-*-freebsd*)\n\textra_parts="$extra_parts crtfastmath.o"\n'
    local ios_case = table.concat({
        'aarch64*-*-ios*)',
        '\textra_parts="$extra_parts crtfastmath.o"',
        '\ttmake_file="${tmake_file} ${cpu_type}/t-darwin-no-eh"',
        '\ttmake_file="${tmake_file} ${cpu_type}/t-aarch64"',
        '\ttmake_file="${tmake_file} ${cpu_type}/t-lse"',
        '\ttmake_file="${tmake_file} t-crtfm t-dfprules"',
        '\ttmake_file="${tmake_file} ${cpu_type}/t-softfp t-softfp"',
        '\t# No ${cpu_type}/t-heap-trampoline (and hence no libheapt_w.a in',
        '\t# extra_parts, whose t-darwin rule needs heap-trampoline_s.o): the',
        '\t# Apple path of libgcc/config/aarch64/heap-trampoline.c calls',
        '\t# pthread_jit_write_protect_np, which Apple declares',
        '\t# __API_AVAILABLE(macos(11.0)) __API_UNAVAILABLE(ios) and the',
        '\t# iPhoneOS system-library stubs do not export -- the runtime is',
        '\t# macOS-only by construction, so shipping it here is impossible',
        '\t# rather than merely undesirable (verified 2026-07-17: libgcc_s',
        '\t# link, undefined _pthread_jit_write_protect_np).  Nested-function',
        '\t# pointers (a GNU C extension this C++ engine never uses) are',
        '\t# therefore an unsupported extension on iOS: with',
        '\t# HEAP_TRAMPOLINES_INIT=1 still set on the compiler side, using one',
        '\t# fails loudly at link time instead of silently trapping on a',
        '\t# non-executable stack at run time.',
        '\tmd_unwind_def_header=aarch64/aarch64-unwind-def.h',
        '\tmd_unwind_header=aarch64/aarch64-unwind.h',
        '\t;;',
        ''
    }, "\n")
    return {
        anchor = anchor,
        replacement = ios_case .. anchor,
        fingerprint = "\naarch64*-*-ios*)\n",
        what = "iOS AArch64 libgcc case (libgcc/config.host)",
        consequence = "arm64 iOS libgcc would miss the AArch64 runtime fragments and system-unwinder setup."
    }
end

-- libstdc++-v3: extend the cross-build OS dispatch (generated configure)
-- and the os_include_dir selection to iOS; without these the libstdc++
-- configure stops with "No support for this host/target combination".
local function libstdcxx_configure_patch()
    return {
        anchor = '  *-darwin*)\n    # Darwin versions vary, but the linker should work in a cross environment,\n',
        replacement = '  *-darwin* | *-ios*)\n    # Darwin versions vary, but the linker should work in a cross environment,\n',
        fingerprint = '*-darwin* | *-ios*)',
        what = "iOS crossconfig case (libstdc++-v3/configure)",
        consequence = "libstdc++ cross configure rejects aarch64-apple-ios as an unsupported host."
    }
end

-- libstdc++-v3/configure: the C locale model auto-detection. Without an iOS
-- arm the target falls through to the generic model while configure.host
-- (patched above) still selects the os/bsd/darwin includes -- and the two
-- disagree: the darwin ctype_inline.h defines the wchar_t ctype members
-- inline that generic/ctype_members.cc then defines again ("redefinition of
-- std::ctype<wchar_t>::do_is", seen live 2026-07-17). The proven macosx
-- build resolves CCTYPE_CC=config/locale/darwin/ctype_members.cc; iOS wants
-- exactly the same model, so it joins the darwin arm rather than getting a
-- new one.
local function libstdcxx_clocale_patch()
    return {
        anchor = '      darwin*)\n\tenable_clocale_flag=darwin\n',
        replacement = '      darwin* | ios*)\n\tenable_clocale_flag=darwin\n',
        fingerprint = 'darwin* | ios*)\n\tenable_clocale_flag=darwin',
        what = "iOS C locale model case (libstdc++-v3/configure)",
        consequence = "iOS libstdc++ takes the generic locale model and its ctype members collide with the darwin inlines."
    }
end

local function libstdcxx_configure_host_patch()
    return {
        anchor = '  darwin*)\n    # Post Darwin8, defaults should be sufficient.\n',
        replacement = '  darwin* | ios*)\n    # Post Darwin8, defaults should be sufficient.\n',
        fingerprint = 'darwin* | ios*)',
        what = "iOS os_include_dir case (libstdc++-v3/configure.host)",
        consequence = "libstdc++ would miss the os/bsd/darwin ctype configuration for iOS."
    }
end

-- gcc/config/darwin-ios.h: the iOS override header appended after
-- ${cpu_type}/darwin.h in tm_file. Both overridden macros expand at their
-- use sites, so redefining them here reaches ASM_SPEC and the link spec.
local function write_ios_override_header(ctx)
    local marker = "WhiteHopeEngine build_support owned file"
    local content = table.concat({
        '/* iOS target overrides, appended after ${cpu_type}/darwin.h in tm_file.',
        '   ' .. marker .. ' (patches/ios.lua); regenerated by the managed',
        '   toolchains source patcher.  */',
        '',
        '#define DARWIN_TARGET_IOS 1',
        '',
        '/* Every ld64 new enough for iOS 15+ understands -platform_version;',
        '   emit the iOS platform id unconditionally instead of the macOS',
        '   three-way LD64_HAS_* choice.  */',
        '#undef DARWIN_PLATFORM_ID',
        '#define DARWIN_PLATFORM_ID \\',
        '  "%{mmacosx-version-min=*: -platform_version ios %* 0.0} "',
        '',
        '/* No heap-trampoline wrapper library on iOS.',
        '',
        '   ${cpu_type}/darwin.h hands every link " -lheapt_w " through',
        '   DARWIN_SHARED_WEAK_ADDS, but the iOS libgcc case deliberately ships',
        '   no libheapt_w.a (its heap-trampoline.c needs a macOS-only runtime',
        '   API; see patches/ios.lua).  Leaving the option in place made the',
        '   driver unable to link ANYTHING -- "ld: library \'heapt_w\' not',
        '   found" -- which in turn made libstdc++ configure conclude the',
        '   compiler cannot produce executables and abort its first link test',
        '   ("Link tests are not allowed after GCC_NO_EXECUTABLES",',
        '   2026-07-17).  Empty is exactly how rs6000/darwin.h spells "this',
        '   Darwin target has no heap trampoline library"; tm_file appends this',
        '   header after ${cpu_type}/darwin.h, so this override wins.',
        '',
        '   HEAP_TRAMPOLINES_INIT=1 still stands on the compiler side, so a GNU',
        '   C nested-function pointer -- which this C++ engine never uses --',
        '   fails loudly at link time on the missing',
        '   __gcc_nested_func_ptr_created instead of silently trapping on a',
        '   non-executable stack at run time.  */',
        '#undef DARWIN_HEAP_T_LIB',
        '#define DARWIN_HEAP_T_LIB " "',
        '',
        '/* Tell the assembler it is targeting iOS, not the host macOS.',
        '',
        '   Apple\'s /usr/bin/as is a clang driver: given only -arch it targets',
        '   the HOST macOS, so every .build_version ios directive draws',
        '   ".build_version ios used while targeting macosxN" on stderr, and a',
        '   platform flag alone (with the default macOS sysroot) trades it for',
        '   -Wincompatible-sysroot.  The object comes out correctly marked',
        '   either way -- the directive wins -- but the noise is not cosmetic:',
        '   libtool\'s "can the compiler do -c -o" probe treats ANY stderr',
        '   output as failure, so it silently fell back to compile-then-mv and',
        '   broke libstdc++\'s -S rules (cxx11-ios_failure-lt.s: "mv: rename',
        '   cxx11-ios_failure.o ... No such file", 2026-07-17).  Forwarding the',
        '   driver-synthesized version as the iOS spelling and handing over the',
        '   iPhoneOS sysroot silences it at the source (verified: empty stderr,',
        '   object still LC_BUILD_VERSION platform 2 / minos 15.0).  */',
        '#undef ASM_MMACOSX_VERSION_MIN_SPEC',
        '#define ASM_MMACOSX_VERSION_MIN_SPEC \\',
        '  "%{asm_macosx_version_min=*: -miphoneos-version-min=%* } \\',
        '   %<asm_macosx_version_min=* "',
        '',
        '/* Same shape as the darwin.h default plus the sysroot.  The two-arm',
        '   isysroot form and the trailing slash after %R are darwin.h\'s own',
        '   idioms (its SYSROOT_SPEC / LINK_SYSROOT_SPEC pair, including the',
        '   comment that appending / is the only working way to get a space',
        '   after %R) -- only the option spelling differs.  */',
        '#undef ASM_SPEC',
        '#define ASM_SPEC \\',
        '  "%{static} -arch %(darwin_arch) " \\',
        '  "%{!isysroot*:-isysroot %R/ } %{isysroot*:-isysroot %*} " \\',
        '  ASM_MMACOSX_VERSION_MIN_SPEC',
        ''
    }, "\n")
    shared.strict_write_owned(ctx, path.join(ctx.src, "gcc", "config", "darwin-ios.h"),
        content, marker, "iOS target override header (gcc/config/darwin-ios.h)")
end

function apply(ctx)
    if not ios_profile_active(ctx) then
        return
    end
    splice(ctx, path.join("gcc", "config.gcc"), config_gcc_os_case_patch())
    splice(ctx, path.join("gcc", "config.gcc"), config_gcc_trampoline_patch())
    splice(ctx, path.join("gcc", "config.gcc"), config_gcc_cpu_case_patch())
    write_ios_override_header(ctx)
    splice(ctx, path.join("gcc", "config", "darwin.cc"), darwin_cc_patch())
    splice(ctx, path.join("gcc", "config", "darwin-c.cc"), darwin_c_cc_patch())
    for _, patch in ipairs(gcc_configure_patches()) do
        splice(ctx, path.join("gcc", "configure"), patch)
    end
    splice(ctx, path.join("libgcc", "config.host"), libgcc_os_case_patch())
    retire_superseded(ctx, path.join("libgcc", "config.host"), libgcc_cpu_case_v66_block(),
        "AArch64 iOS libgcc case with the macOS-only heap-trampoline fragment")
    splice(ctx, path.join("libgcc", "config.host"), libgcc_cpu_case_patch())
    splice(ctx, path.join("libstdc++-v3", "configure"), libstdcxx_configure_patch())
    splice(ctx, path.join("libstdc++-v3", "configure"), libstdcxx_clocale_patch())
    splice(ctx, path.join("libstdc++-v3", "configure.host"), libstdcxx_configure_host_patch())
end

function register_postconditions(ctx)
    if not ios_profile_active(ctx) then
        return
    end
    local conditions = {
        {file = path.join("gcc", "config.gcc"), fingerprint = "\n*-*-ios*)\n",
            what = "iOS target OS case"},
        {file = path.join("gcc", "config.gcc"), fingerprint = "aarch64-*-ios* )",
            what = "iOS AArch64 per-CPU case"},
        {file = path.join("gcc", "config.gcc"), fingerprint = "aarch64*-*-ios*)\n  # arm64 iOS follows arm64 Darwin",
            what = "iOS AArch64 heap-trampoline defines"},
        {file = path.join("gcc", "config", "darwin-ios.h"), fingerprint = "-platform_version ios",
            what = "iOS target override header"},
        {file = path.join("gcc", "config", "darwin-ios.h"), fingerprint = "#define DARWIN_HEAP_T_LIB \" \"",
            what = "iOS heap-trampoline library suppression"},
        {file = path.join("gcc", "config", "darwin-ios.h"), fingerprint = "-miphoneos-version-min=%*",
            what = "iOS assembler platform forwarding"},
        {file = path.join("gcc", "config", "darwin.cc"), fingerprint = "build_version ios, ",
            what = "iOS .build_version directive"},
        {file = path.join("gcc", "config", "darwin-c.cc"), fingerprint = "__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__",
            what = "iOS deployment-minimum macro"},
        {file = path.join("gcc", "configure"), fingerprint = "darwin* | ios*)",
            what = "iOS platform assembler probes"},
        {file = path.join("gcc", "configure"), fingerprint = "    *darwin* | *-*-ios*)",
            what = "iOS default-linker flavor"},
        {file = path.join("gcc", "configure"), fingerprint = "  *-*-darwin* | *-*-ios*)\n    as_flavor=darwin",
            what = "iOS assembler flavor"},
        {file = path.join("gcc", "configure"), fingerprint = "  *-*-darwin* | *-*-ios*)\n    ld_flavor=darwin",
            what = "iOS linker flavor"},
        {file = path.join("gcc", "configure"), fingerprint = "  *-*-darwin* | *-*-ios*)\n    # Darwin as has some visibility support",
            what = "iOS assembler visibility support"},
        {file = path.join("gcc", "configure"), fingerprint = "      *-*-darwin* | *-*-ios*)\n\t# Darwin ld has some visibility support.",
            what = "iOS linker visibility support"},
        {file = path.join("libgcc", "config.host"), fingerprint = "\n*-*-ios*)\n  asm_hidden_op",
            what = "iOS libgcc OS case"},
        {file = path.join("libgcc", "config.host"), fingerprint = "aarch64*-*-ios*)",
            what = "iOS AArch64 libgcc case"},
        {file = path.join("libstdc++-v3", "configure"), fingerprint = "*-darwin* | *-ios*)",
            what = "iOS libstdc++ crossconfig case"},
        {file = path.join("libstdc++-v3", "configure"), fingerprint = "darwin* | ios*)\n\tenable_clocale_flag=darwin",
            what = "iOS C locale model case"},
        {file = path.join("libstdc++-v3", "configure.host"), fingerprint = "darwin* | ios*)",
            what = "iOS libstdc++ os_include_dir case"}
    }
    for _, condition in ipairs(conditions) do
        table.insert(ctx.postconditions, condition)
    end
end
