-- WebAssembly source-patch witnesses.
--
-- This profile used to carry the whole experimental backend as anchored
-- patches applied on top of a pinned upstream checkout. On 2026-08-12 the
-- toolchain line was ported onto GCC master and now tracks it, so the pinned
-- commit carries every one of those changes itself: all 42 witnesses below
-- verified present in the PRISTINE checkout, and re-applying the patches
-- could only fail on anchors that no longer exist. The apply machinery was
-- retired with them (gccpatches skips this profile's patch families) and this
-- file kept just what stays load-bearing.
--
-- The witnesses ARE the guarantee now: they are what a wrong, rolled-back or
-- truncated pin would silently lose, and the postcondition checkpoint in
-- gccpatches fails the sync when any one of them is absent. Add an entry for
-- every fix this profile depends on -- that is far cheaper than discovering
-- the loss later, as a compiler defect.
function register_postconditions(ctx)
    local target_os = ctx.target_os
    if target_os == "emscripten" then
        for _, owned in ipairs({
            path.join("gcc", "config", "wasm", "wasm-emscripten.h"),
            path.join("gcc", "config", "wasm", "wasm-emscripten.opt"),
            path.join("gcc", "config", "wasm", "wasm-emscripten.opt.urls"),
            path.join("gcc", "config", "wasm", "wasm.opt"),
            path.join("gcc", "config", "wasm", "wasm.opt.urls"),
            path.join("gcc", "config", "wasm", "wasm_simd128.h"),
            path.join("gcc", "config", "wasm", "wasm-wasi.h"),
            path.join("libgcc", "config", "wasm", "cpp-exception-tag.wat"),
            path.join("libgcc", "config", "wasm", "int128.c"),
            path.join("libgcc", "config", "wasm", "memory.c"),
            path.join("libgcc", "config", "wasm", "unwind-abort.c"),
            path.join("libstdc++-v3", "include", "bits", "wasm_freestanding_hosted_compat.h")
        }) do
            table.insert(ctx.postconditions, {file = owned, what = "WebAssembly project-owned source file"})
        end
        -- One witness per fix the profile depends on. The list grew as the
        -- toolchain line did, so it reads chronologically rather than by
        -- subsystem: exception handling, then wasm64, SIMD, tail calls, bulk
        -- memory, the debug channel, and the pass fixes.
        for _, condition in ipairs({
            {file = path.join("gcc", "config.gcc"),
                fingerprint = "wasm/wasm.opt",
                what = "WebAssembly backend option record registration"},
            {file = path.join("gcc", "config", "wasm", "wasm-asm.cc"),
                fingerprint = "wasm_output_call_maybe_eh",
                what = "WebAssembly call-site exception trampoline emission"},
            {file = path.join("gcc", "config", "wasm", "wasm-cg.cc"),
                fingerprint = "case WASM_BUILTIN_THROW:",
                what = "WebAssembly throw builtin expansion"},
            {file = path.join("gcc", "config", "wasm", "wasm-passes.cc"),
                fingerprint = "goto restart;",
                what = "WebAssembly inject_trap iterator-invalidation fix"},
            {file = path.join("gcc", "config", "wasm", "wasm-protos.h"),
                fingerprint = "WASM_BUILTIN_THROW",
                what = "WebAssembly machine builtin declarations"},
            {file = path.join("gcc", "config", "wasm", "wasm.cc"),
                fingerprint = "TARGET_EXPAND_BUILTIN wasm_expand_builtin",
                what = "WebAssembly builtin target hooks"},
            {file = path.join("gcc", "config", "wasm", "wasm.h"),
                fingerprint = "MAKE_DECL_ONE_ONLY(DECL) (DECL_WEAK (DECL) = 1)",
                what = "WebAssembly weak one-only linkage approximation"},
            {file = path.join("gcc", "config", "wasm", "wasm.h"),
                fingerprint = "TARGET_WASM64 ? DImode : SImode",
                what = "WebAssembly wasm64 pointer-width parameterization"},
            {file = path.join("gcc", "config", "wasm", "wasm.md"),
                fingerprint = "(throw $__cpp_exception",
                what = "WebAssembly throw instruction pattern"},
            {file = path.join("libgcc", "config", "wasm", "t-wasm"),
                fingerprint = "cpp-exception-tag$(objext)",
                what = "WebAssembly exception tag object in libgcc"},
            {file = path.join("libgcc", "config", "wasm", "unwind-abort.c"),
                fingerprint = "__builtin_wasm_throw (0, exception_object)",
                what = "WebAssembly throw-based unwind runtime"},
            {file = path.join("libstdc++-v3", "configure.host"),
                fingerprint = "native wasm exception handling",
                what = "libstdc++ exceptions and RTTI enabled for WebAssembly"},
            {file = path.join("libstdc++-v3", "include", "bits", "c++config"),
                fingerprint = "_GLIBCXX_USE_WEAK_REF 0",
                what = "libstdc++ WebAssembly weak-reference gate"},
            {file = path.join("libstdc++-v3", "libsupc++", "eh_personality.cc"),
                fingerprint = "__wlsda_match",
                what = "libsupc++ WebAssembly catch-selection matcher"},
            {file = path.join("gcc", "config", "wasm", "attrs.md"),
                fingerprint = "define_mode_iterator VALL",
                what = "WebAssembly SIMD lane-shape mode iterators"},
            {file = path.join("gcc", "config", "wasm", "constraints.md"),
                fingerprint = "wasm_v128_register_operand",
                what = "WebAssembly v128 register predicate"},
            {file = path.join("gcc", "config", "wasm", "t-wasm"),
                fingerprint = "MULTILIB_OPTIONS = mwasm64",
                what = "WebAssembly wasm64 multilib option record"},
            {file = path.join("gcc", "config", "wasm", "wasm-emscripten.h"),
                fingerprint = "%{mwasm64:-mwasm64}",
                what = "WebAssembly memory64 linker emulation selection"},
            {file = path.join("gcc", "config", "wasm", "wasm-modes.def"),
                fingerprint = "WebAssembly extra machine modes",
                what = "WebAssembly vector and binary128 machine modes"},
            {file = path.join("gcc", "config", "wasm", "wasm-cg.cc"),
                fingerprint = "WASM_BUILTIN_SIMD_BASE",
                what = "WebAssembly SIMD builtin table"},
            {file = path.join("gcc", "config", "wasm", "wasm-passes.def"),
                fingerprint = "wasm_ehsel",
                what = "WebAssembly per-pad selector rewrite pass"},
            {file = path.join("gcc", "config", "wasm", "wasm.h"),
                fingerprint = "DWARF2_LINENO_DEBUGGING_INFO",
                what = "WebAssembly line-number debug channel"},
            {file = path.join("gcc", "config", "wasm", "wasm.md"),
                fingerprint = "return_call",
                what = "WebAssembly tail-call instruction patterns"},
            {file = path.join("gcc", "config", "wasm", "wasm.md"),
                fingerprint = "memory.copy",
                what = "WebAssembly bulk-memory expanders"},
            {file = path.join("gcc", "config", "wasm", "wasm.md"),
                fingerprint = "i8x16.shuffle",
                what = "WebAssembly SIMD permute patterns"},
            {file = path.join("gcc", "config", "wasm", "wasm.md"),
                fingerprint = "one_cmpl<mode>2",
                what = "WebAssembly inline bitwise complement (keeps 128-bit ~ off a libgcc libcall)"},
            {file = path.join("gcc", "config", "wasm", "wasm-asm.cc"),
                fingerprint = "\"(param %s)\\n\", TARGET_WASM64",
                what = "WebAssembly pointer-width argv in a synthesized __main_argc_argv signature"},
            {file = path.join("gcc", "df-scan.cc"),
                fingerprint = "targetm.no_register_allocation",
                what = "df-scan no-register-allocation assert arm"},
            {file = path.join("gcc", "optabs.cc"),
                fingerprint = "The call itself must never be hoisted",
                what = "libcall block hoist guard"},
            {file = path.join("libgcc", "Makefile.in"),
                fingerprint = "auto-target.h:config.in",
                what = "libgcc header stamp relative template"}
        }) do
            table.insert(ctx.postconditions, condition)
        end
    end
end
