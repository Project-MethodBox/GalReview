-- GCC source patches owned by the wasm-experimental source profile
-- (target_os == "emscripten"): WebAssembly backend ABI state, assembly
-- and pass fixes, Emscripten/WASI target identity, libgcc runtime pieces,
-- and the freestanding libstdc++ header and std-module surface. Applied
-- idempotently; anchors that disappear upstream fail hard through the
-- strict helpers in shared.lua.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("gccwasmcompat", {rootdir = path.join(os.scriptdir(), "..")})
import("shared")

function apply(ctx)
    if ctx.target_os ~= "emscripten" then
        return
    end
    local wasm_header, wasm_hooks = _apply_backend_abi(ctx)
    _apply_assembly(ctx, wasm_header, wasm_hooks)
    _apply_target_identity(ctx)
    _apply_libgcc(ctx)
    _apply_libstdcxx_config(ctx)
    local headers_flags = _apply_freestanding_headers(ctx)
    _apply_std_module(ctx, headers_flags)
end

function register_postconditions(ctx)
    local target_os = ctx.target_os
    if target_os == "emscripten" then
        for _, owned in ipairs({
            path.join("gcc", "config", "wasm", "wasm-emscripten.h"),
            path.join("gcc", "config", "wasm", "wasm-emscripten.opt"),
            path.join("gcc", "config", "wasm", "wasm-emscripten.opt.urls"),
            path.join("gcc", "config", "wasm", "wasm-wasi.h"),
            path.join("libgcc", "config", "wasm", "int128.c"),
            path.join("libgcc", "config", "wasm", "memory.c"),
            path.join("libgcc", "config", "wasm", "unwind-abort.c"),
            path.join("libstdc++-v3", "include", "bits", "wasm_freestanding_hosted_compat.h")
        }) do
            table.insert(ctx.postconditions, {file = owned, what = "WebAssembly project-owned source file"})
        end
    end
end

function _apply_backend_abi(ctx)
    local src = ctx.src
    local function strict_replace(file, original, replacement, label)
        return shared.strict_replace(ctx, file, original, replacement, label)
    end
    local function strict_replace_migrated(file, original, previous, replacement, label)
        return shared.strict_replace_migrated(ctx, file, original, previous, replacement, label)
    end
    local function remove_exact_patch(file, patch, label)
        return shared.remove_exact_patch(ctx, file, patch, label)
    end

    -- TYPE_EMPTY_P is target ABI state computed by layout_type. GCC's C++
    -- module streamer preserves the language-level CLASSTYPE_EMPTY_P bit,
    -- but not this target-level bit. An imported empty standard-library tag
    -- therefore reaches the WebAssembly backend as a non-empty aggregate:
    -- callers pass an i32 while the textually compiled libstdc++ definition
    -- has no parameter, and wasm-ld emits a signature_mismatch trap. Stream
    -- the bit beside the other type_common flags so an imported std CMI uses
    -- exactly the same ABI lowering as the libstdc++ archive.
    local module_cc = path.join(src, "gcc", "cp", "module.cc")
    strict_replace(module_cc,
        "      WB (t->type_common.string_flag);\n" ..
        "      WB (t->type_common.lang_flag_0);",
        "      WB (t->type_common.string_flag);\n" ..
        "      /* project-local WebAssembly ABI fix: preserve target empty-record\n" ..
        "\t state across named-module serialization.  */\n" ..
        "      WB (t->type_common.empty_flag);\n" ..
        "      WB (t->type_common.lang_flag_0);",
        "GCC WebAssembly C++ module empty-record ABI serialization")
    strict_replace(module_cc,
        "      RB (t->type_common.string_flag);\n" ..
        "      RB (t->type_common.lang_flag_0);",
        "      RB (t->type_common.string_flag);\n" ..
        "      /* project-local WebAssembly ABI fix: restore target empty-record\n" ..
        "\t state before target argument lowering.  */\n" ..
        "      RB (t->type_common.empty_flag);\n" ..
        "      RB (t->type_common.lang_flag_0);",
        "GCC WebAssembly C++ module empty-record ABI deserialization")

    local wasm_header = path.join(src, "gcc", "config", "wasm", "wasm.h")
    strict_replace(wasm_header,
        "#define DEFAULT_SIGNED_CHAR 0",
        "#define DEFAULT_SIGNED_CHAR 1",
        "GCC WebAssembly Basic C ABI signed plain char")
    strict_replace(wasm_header,
        "#define WCHAR_TYPE \"long int\"",
        "#define WCHAR_TYPE \"int\"",
        "GCC WebAssembly Basic C ABI wchar_t type")
    local upstream_word_size =
        "#define UNITS_PER_WORD 8\n#define MIN_UNITS_PER_WORD 4"
    local global_int128_libgcc_word_size =
        "#define UNITS_PER_WORD 8\n" ..
        "#ifdef IN_LIBGCC2\n" ..
        "#define MIN_UNITS_PER_WORD UNITS_PER_WORD\n" ..
        "#else\n" ..
        "#define MIN_UNITS_PER_WORD 4\n" ..
        "#endif"
    if io.readfile(wasm_header):find(global_int128_libgcc_word_size, 1, true) then
        strict_replace(wasm_header,
            global_int128_libgcc_word_size,
            upstream_word_size,
            "GCC WebAssembly selective 128-bit integer libgcc migration")
    end
    strict_replace(wasm_header,
        "#define WASM_RETURN_REGNUM 0",
        "#define WASM_RETURN_REGNUM 0\n#define WASM_RETURN_HIGH_REGNUM 7",
        "GCC WebAssembly 128-bit integer high return register")
    strict_replace(wasm_header,
        [=[    "$base",		\
    "general0",		\
    "general1",		\
    "general2",		\
    "general3",		\
  }

#define TARGET_NO_REGISTER_ALLOCATION true
#define FIRST_PSEUDO_REGISTER 11
#define FIXED_REGISTERS	    { 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 }
#define CALL_USED_REGISTERS { 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 }]=],
        [=[    "$base",		\
    "$return_high",	\
    "general0",		\
    "general1",		\
    "general2",		\
    "general3",		\
  }

#define TARGET_NO_REGISTER_ALLOCATION true
#define FIRST_PSEUDO_REGISTER 12
#define FIXED_REGISTERS	    { 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 }
#define CALL_USED_REGISTERS { 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 }]=],
        "GCC WebAssembly 128-bit integer return register allocation")
    strict_replace(wasm_header,
        "#define CC1PLUS_SPEC \"-stdlib=libc++\"",
        "#define CC1PLUS_SPEC \"\"",
        "GCC WebAssembly removal of the Clang-only C++ standard-library option")
    if io.readfile(wasm_header):find(
        "  machine_mode return_mode;\n  bool wat_result_p;\n  bool stdarg_p;", 1, true) then
        strict_replace(wasm_header,
            "  machine_mode return_mode;\n  bool wat_result_p;\n  bool stdarg_p;",
            "  machine_mode return_mode;\n  bool stdarg_p;",
            "GCC WebAssembly cached WAT result state removal")
    end
    strict_replace(wasm_header,
        "/* Calling convention.  */\n#define PARM_BOUNDARY 8",
        "/* Return aggregates according to TARGET_RETURN_IN_MEMORY instead of the" ..
        " legacy PCC convention.  */\n" ..
        "#define DEFAULT_PCC_STRUCT_RETURN 0\n\n" ..
        "/* Calling convention.  */\n#define PARM_BOUNDARY 8",
        "GCC WebAssembly target-controlled aggregate returns")
    strict_replace(wasm_header,
        "      cpp_define (parse_in, \"__wasi__\");",
        "      /* Target OS macros are supplied by a subtarget header.  */",
        "GCC WebAssembly target OS identity separation")

    local wasm_hooks = path.join(src, "gcc", "config", "wasm", "wasm.cc")
    local upstream_empty_hook =
        "#define TARGET_END_CALL_ARGS wasm_end_call_args\n" ..
        "bool wasm_pass_by_reference (cumulative_args_t, const function_arg_info &arg);"
    local default_empty_hook =
        "#define TARGET_END_CALL_ARGS wasm_end_call_args\n" ..
        "#define TARGET_EMPTY_RECORD_P default_is_empty_record\n" ..
        "bool wasm_pass_by_reference (cumulative_args_t, const function_arg_info &arg);"
    if io.readfile(wasm_hooks):find(default_empty_hook, 1, true) then
        strict_replace(wasm_hooks, default_empty_hook, upstream_empty_hook,
            "GCC WebAssembly legacy empty aggregate hook migration")
    end
    strict_replace(wasm_hooks,
        upstream_empty_hook,
        "#define TARGET_END_CALL_ARGS wasm_end_call_args\n" ..
        "static bool\n" ..
        "wasm_empty_record_p (const_tree type)\n" ..
        "{\n" ..
        "  return type && type != error_mark_node\n" ..
        "    && RECORD_OR_UNION_TYPE_P (type)\n" ..
        "    && is_empty_type (TYPE_MAIN_VARIANT (type));\n" ..
        "}\n" ..
        "#define TARGET_EMPTY_RECORD_P wasm_empty_record_p\n" ..
        "bool wasm_pass_by_reference (cumulative_args_t, const function_arg_info &arg);",
        "GCC WebAssembly Basic C ABI empty aggregate classification")
    strict_replace(wasm_hooks,
        "#define TARGET_SCALAR_MODE_SUPPORTED_P [](scalar_mode m) \\\n" ..
        "  { return default_scalar_mode_supported_p (m) && m != TImode; }",
        "#define TARGET_SCALAR_MODE_SUPPORTED_P default_scalar_mode_supported_p",
        "GCC WebAssembly 128-bit integer scalar mode")
    strict_replace(wasm_hooks,
        [=[#define TARGET_OPTION_OVERRIDE wasm_option_override
static void
wasm_option_override (void)
{
  init_machine_status = wasm_init_machine_status;
}]=],
        [=[#define TARGET_OPTION_OVERRIDE wasm_option_override
static void
wasm_option_override (void)
{
  init_machine_status = wasm_init_machine_status;
}

/* GCC's experimental multi-value TImode ABI is intentionally distinct from
   the canonical Emscripten/Rust sret ABI carried by compiler_builtins.  Keep
   the internal libgcc calls in GCC's alternate namespace so both can coexist
   in one final Emscripten link without a same-name, different-type collision.  */
static void
wasm_init_libfuncs (void)
{
  set_optab_libfunc (smul_optab, TImode, "__gnu_multi3");
  set_optab_libfunc (sdiv_optab, TImode, "__gnu_divti3");
  set_optab_libfunc (udiv_optab, TImode, "__gnu_udivti3");
  set_optab_libfunc (smod_optab, TImode, "__gnu_modti3");
  set_optab_libfunc (umod_optab, TImode, "__gnu_umodti3");
}
#define TARGET_INIT_LIBFUNCS wasm_init_libfuncs]=],
        "GCC WebAssembly private multi-value int128 libcall namespace")

    local wasm_protos = path.join(src, "gcc", "config", "wasm", "wasm-protos.h")
    strict_replace(wasm_protos,
        "#ifdef RTX_CODE",
        "extern const_tree wasm_singleton_scalar_type (const_tree);\n\n#ifdef RTX_CODE",
        "GCC WebAssembly singleton aggregate ABI declaration")
    strict_replace(wasm_protos,
        "extern bool wasm_expand_mov (rtx, rtx, machine_mode);\n" ..
        "extern void wasm_expand_conv (rtx, rtx, rtx_code);",
        "extern bool wasm_expand_mov (rtx, rtx, machine_mode);\n" ..
        "extern void wasm_expand_int128_bitquery (rtx, rtx, rtx_code);\n" ..
        "extern void wasm_expand_conv (rtx, rtx, rtx_code);",
        "GCC WebAssembly 128-bit integer bit-query declaration")

    local wasm_codegen = path.join(src, "gcc", "config", "wasm", "wasm-cg.cc")
    strict_replace(wasm_header,
        [=[#ifndef USED_FOR_TARGET
struct GTY(()) machine_function]=],
        [=[#ifndef USED_FOR_TARGET
/* Libcall function types outlive the function that created them and must
   remain visible to GCC's garbage collector until assembly file finalization.  */
extern GTY(()) vec<tree, va_gc> *wasm_libcall_type_roots;

struct GTY(()) machine_function]=],
        "GCC WebAssembly libcall type GC root declaration")
    strict_replace(wasm_codegen,
        "hash_map<const_rtx, tree> external_libcalls;",
        [=[hash_map<const_rtx, tree> external_libcalls;
vec<tree, va_gc> *wasm_libcall_type_roots;]=],
        "GCC WebAssembly libcall type GC root definition")
    strict_replace(wasm_codegen,
        [=[  if (!existed)
    slot = ty;
  gcc_assert (slot == ty);]=],
        [=[  if (!existed)
    {
      slot = ty;
      vec_safe_push (wasm_libcall_type_roots, ty);
    }
  gcc_assert (slot == ty);]=],
        "GCC WebAssembly libcall type GC lifetime")
    local legacy_int128_return_offset =
        "gen_rtx_EXPR_LIST (VOIDmode, high, const8_rtx)"
    if io.readfile(wasm_codegen):find(legacy_int128_return_offset, 1, true) then
        strict_replace(wasm_codegen,
            legacy_int128_return_offset,
            "gen_rtx_EXPR_LIST (VOIDmode, high, GEN_INT (8))",
            "GCC WebAssembly legacy 128-bit return offset migration")
    end
    strict_replace(wasm_codegen,
        [=[machine_mode
wasm_real_register_mode (rtx reg)
{
  if (SUBREG_P (reg))
    reg = SUBREG_REG (reg);
  if (!REG_P (reg))
    return VOIDmode;
  machine_mode m = GET_MODE (reg);
  PROMOTE_MODE (m, 0, NULL_TREE);
  return m;
}]=],
        [=[machine_mode
wasm_real_register_mode (rtx reg)
{
  if (SUBREG_P (reg))
    {
      rtx inner = SUBREG_REG (reg);
      if (REG_P (inner) && GET_MODE (inner) == TImode
          && GET_MODE (reg) == DImode)
        return DImode;
      reg = inner;
    }
  if (!REG_P (reg))
    return VOIDmode;
  machine_mode m = GET_MODE (reg);
  PROMOTE_MODE (m, 0, NULL_TREE);
  return m;
}]=],
        "GCC WebAssembly split 128-bit integer register mode")
    strict_replace(wasm_codegen,
        [=[  if (GET_CODE (arg) == PARALLEL)
    {
      rtvec elts = XVEC (arg, 0);
      for (int i = 0; i != GET_NUM_ELEM (elts); ++i)
	wasm_call_args (args, XEXP (RTVEC_ELT (elts, i), 0), type);
      return;
    }]=],
        [=[  if (GET_CODE (arg) == PARALLEL)
    {
      rtvec elts = XVEC (arg, 0);
      /* Calls are accumulated in reverse argument order.  Reverse the pieces
	 of a multi-register value here as well, so the final WebAssembly
	 argument list retains the ABI's low-to-high order.  */
      for (int i = GET_NUM_ELEM (elts) - 1; i >= 0; --i)
	wasm_call_args (args, XEXP (RTVEC_ELT (elts, i), 0), type);
      return;
    }]=],
        "GCC WebAssembly outgoing multi-part argument order")

    strict_replace(wasm_codegen,
        [=[/* Implementation of TARGET_PASS_BY_REFERENCE.  */
bool
wasm_pass_by_reference (cumulative_args_t, const function_arg_info &arg)
{
  if (arg.type)
    {
      if (TREE_CODE (arg.type) == COMPLEX_TYPE)
	return true;
      if (TREE_CODE (arg.type) == VECTOR_TYPE)
	return true;
    }
  if (COMPLEX_MODE_P (arg.mode))
    return true;
  if (VECTOR_MODE_P (arg.mode))
    return true;
  if (arg.aggregate_type_p ())
    return true;
  return false;
}

/* Implementation of TARGET_RETURN_IN_MEMORY.  */
bool
wasm_return_in_memory (const_tree type, const_tree ARG_UNUSED (fntype))
{
  if (TREE_CODE (type) == COMPLEX_TYPE)
    return true;
  if (TREE_CODE (type) == VECTOR_TYPE)
    return true;
  if (VECTOR_MODE_P (TYPE_MODE (type)))
    return true;
  if (COMPLEX_MODE_P (TYPE_MODE (type)))
    return true;
  return false;
}]=],
        [=[/* Return the scalar carried by TYPE when TYPE is a Basic C ABI singleton
   aggregate.  Empty ABI-ignored fields and one-element arrays do not add an
   element.  Requiring identical aggregate and scalar sizes rejects tail
   padding and explicit over-alignment.  */
static const_tree
wasm_singleton_abi_element (const_tree type)
{
  if (!type || type == error_mark_node || TREE_ADDRESSABLE (type))
    return NULL_TREE;

  switch (TREE_CODE (type))
    {
    case NULLPTR_TYPE:
    case POINTER_TYPE:
    case REFERENCE_TYPE:
    case OFFSET_TYPE:
    case INTEGER_TYPE:
    case BOOLEAN_TYPE:
    case ENUMERAL_TYPE:
    case REAL_TYPE:
      return type;

    case ARRAY_TYPE:
      {
	tree nelts_minus_one = array_type_nelts_minus_one (type);
	if (!COMPLETE_TYPE_P (type) || !integer_zerop (nelts_minus_one))
	  return NULL_TREE;

	const_tree scalar = wasm_singleton_abi_element (TREE_TYPE (type));
	if (!scalar || !TYPE_SIZE (type) || !TYPE_SIZE (scalar)
	    || !tree_int_cst_equal (TYPE_SIZE (type), TYPE_SIZE (scalar))
	    || TYPE_ALIGN (type) > TYPE_ALIGN (scalar))
	  return NULL_TREE;
	return scalar;
      }

    case UNION_TYPE:
    case RECORD_TYPE:
      {
	if (flexible_array_type_p (type))
	  return NULL_TREE;

	const_tree scalar = NULL_TREE;
	for (tree field = TYPE_FIELDS (type); field; field = DECL_CHAIN (field))
	  {
	    if (TREE_CODE (field) != FIELD_DECL || DECL_PADDING_P (field)
		|| DECL_FIELD_ABI_IGNORED (field)
		|| (DECL_BIT_FIELD (field) && !DECL_NAME (field)))
	      continue;

	    const_tree candidate
	      = wasm_singleton_abi_element (TREE_TYPE (field));
	    if (!candidate || scalar)
	      return NULL_TREE;
	    scalar = candidate;
	  }

	if (!scalar || !TYPE_SIZE (type) || !TYPE_SIZE (scalar)
	    || !tree_int_cst_equal (TYPE_SIZE (type), TYPE_SIZE (scalar))
	    || TYPE_ALIGN (type) > TYPE_ALIGN (scalar))
	  return NULL_TREE;
	return scalar;
      }

    default:
      return NULL_TREE;
    }
}

const_tree
wasm_singleton_scalar_type (const_tree type)
{
  if (!type || !RECORD_OR_UNION_TYPE_P (type))
    return NULL_TREE;
  return wasm_singleton_abi_element (type);
}

/* Implementation of TARGET_PASS_BY_REFERENCE.  */
bool
wasm_pass_by_reference (cumulative_args_t, const function_arg_info &arg)
{
  if (arg.type)
    {
      if (TREE_CODE (arg.type) == COMPLEX_TYPE)
	return true;
      if (TREE_CODE (arg.type) == VECTOR_TYPE)
	return true;
    }
  if (COMPLEX_MODE_P (arg.mode))
    return true;
  if (VECTOR_MODE_P (arg.mode))
    return true;
  if (arg.aggregate_type_p ())
    {
	if (arg.type && TYPE_EMPTY_P (arg.type))
	  return false;
	return !arg.type || !wasm_singleton_scalar_type (arg.type);
    }
  return false;
}

/* Implementation of TARGET_RETURN_IN_MEMORY.  */
bool
wasm_return_in_memory (const_tree type, const_tree ARG_UNUSED (fntype))
{
  if (TREE_CODE (type) == COMPLEX_TYPE)
    return true;
  if (TREE_CODE (type) == VECTOR_TYPE)
    return true;
  if (VECTOR_MODE_P (TYPE_MODE (type)))
    return true;
  if (COMPLEX_MODE_P (TYPE_MODE (type)))
    return true;
  if (AGGREGATE_TYPE_P (type))
    return !TYPE_EMPTY_P (type) && !wasm_singleton_scalar_type (type);
  return false;
}]=],
        "GCC WebAssembly Basic C ABI singleton aggregate lowering")

    if not io.readfile(wasm_codegen):find(
        "Empty Basic C ABI arguments occupy no WebAssembly parameter.", 1, true) then
        strict_replace(wasm_codegen,
        [=[rtx
wasm_function_arg (cumulative_args_t, const function_arg_info &arg)
{
  if (arg.end_marker_p ())
    return NULL_RTX;

  if (!arg.named)
    return NULL_RTX;

  if (arg.mode == TImode)]=],
        [=[rtx
wasm_function_arg (cumulative_args_t, const function_arg_info &arg)
{
  if (arg.end_marker_p ())
    return NULL_RTX;

  /* Empty Basic C ABI arguments occupy no WebAssembly parameter.  Returning
     a stack location for their zero ABI size lets the middle end retain any
     language-level object semantics without manufacturing a value register.  */
  if (!arg.named || (arg.type && TYPE_EMPTY_P (arg.type)))
    return NULL_RTX;

  if (arg.mode == TImode)]=],
        "GCC WebAssembly ignored empty outgoing arguments")
    end

    if not io.readfile(wasm_codegen):find(
        "Empty Basic C ABI arguments do not have an incoming", 1, true) then
        strict_replace(wasm_codegen,
        [=[  if (!arg.named)
    return NULL_RTX;

  /* Int128 is passed as 2xint64_t, in LE order.  */
  if (arg.mode == TImode)]=],
        [=[  /* Empty Basic C ABI arguments do not have an incoming
     WebAssembly parameter.  Non-trivial C++ records have already been
     transformed into an invisible pointer before reaching this hook.  */
  if (!arg.named || (arg.type && TYPE_EMPTY_P (arg.type)))
    return NULL_RTX;

  /* Int128 is passed as 2xint64_t, in LE order.  */
  if (arg.mode == TImode)]=],
        "GCC WebAssembly ignored empty incoming arguments")
    end

    strict_replace(wasm_codegen,
        [=[      rtx lsb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const0_rtx);
      rtx msb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const8_rtx);
      maybe_push_arg (lsb);
      maybe_push_arg (msb);
      rtvec para = gen_rtvec (2, lsb, msb);]=],
        [=[      rtx lsb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const0_rtx);
      rtx msb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const8_rtx);
      maybe_push_arg (XEXP (lsb, 0));
      maybe_push_arg (XEXP (msb, 0));
      rtvec para = gen_rtvec (2, lsb, msb);]=],
        "GCC WebAssembly 128-bit incoming argument register tracking")

    if not io.readfile(wasm_codegen):find(
        "Describe a singleton aggregate as one scalar outgoing ABI piece.", 1, true) then
        strict_replace(wasm_codegen,
        [=[rtx
wasm_function_arg (cumulative_args_t, const function_arg_info &arg)
{
  if (arg.end_marker_p ())
    return NULL_RTX;

  /* Empty Basic C ABI arguments occupy no WebAssembly parameter.  Returning
     a stack location for their zero ABI size lets the middle end retain any
     language-level object semantics without manufacturing a value register.  */
  if (!arg.named || (arg.type && TYPE_EMPTY_P (arg.type)))
    return NULL_RTX;

  if (arg.mode == TImode)
    {
      rtx const8_rtx = gen_rtx_CONST_INT (VOIDmode, 8);
      rtvec para = gen_rtvec (2,
	gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const0_rtx),
	gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const8_rtx));
      return gen_rtx_PARALLEL (TImode, para);
    }
  return gen_reg_rtx (arg.mode);
}]=],
        [=[rtx
wasm_function_arg (cumulative_args_t, const function_arg_info &arg)
{
  if (arg.end_marker_p ())
    return NULL_RTX;

  /* Empty Basic C ABI arguments occupy no WebAssembly parameter.  Returning
     a stack location for their zero ABI size lets the middle end retain any
     language-level object semantics without manufacturing a value register.  */
  if (!arg.named || (arg.type && TYPE_EMPTY_P (arg.type)))
    return NULL_RTX;

  machine_mode mode = arg.mode;
  if (const_tree scalar = wasm_singleton_scalar_type (arg.type))
    mode = TYPE_MODE (scalar);

  if (mode == TImode)
    {
      rtx const8_rtx = gen_rtx_CONST_INT (VOIDmode, 8);
      rtvec para = gen_rtvec (2,
	gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const0_rtx),
	gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const8_rtx));
      return gen_rtx_PARALLEL (TImode, para);
    }
  return gen_reg_rtx (mode);
}]=],
        "GCC WebAssembly outgoing singleton aggregate register mode")
    end

    if not io.readfile(wasm_codegen):find(
        "Describe a singleton aggregate as one scalar incoming ABI piece.", 1, true) then
        strict_replace(wasm_codegen,
        [=[  /* Int128 is passed as 2xint64_t, in LE order.  */
  if (arg.mode == TImode)
    {
      rtx const8_rtx = gen_rtx_CONST_INT (VOIDmode, 8);

      rtx lsb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const0_rtx);
      rtx msb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const8_rtx);
      maybe_push_arg (XEXP (lsb, 0));
      maybe_push_arg (XEXP (msb, 0));
      rtvec para = gen_rtvec (2, lsb, msb);
      return gen_rtx_PARALLEL (TImode, para);
    }
  rtx reg = gen_reg_rtx (arg.mode);
  maybe_push_arg (reg);
  return reg;]=],
        [=[  machine_mode mode = arg.mode;
  if (const_tree scalar = wasm_singleton_scalar_type (arg.type))
    mode = TYPE_MODE (scalar);

  /* Int128 is passed as 2xint64_t, in LE order.  */
  if (mode == TImode)
    {
      rtx const8_rtx = gen_rtx_CONST_INT (VOIDmode, 8);

      rtx lsb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const0_rtx);
      rtx msb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const8_rtx);
      maybe_push_arg (XEXP (lsb, 0));
      maybe_push_arg (XEXP (msb, 0));
      rtvec para = gen_rtvec (2, lsb, msb);
      return gen_rtx_PARALLEL (TImode, para);
    }
  rtx reg = gen_reg_rtx (mode);
  maybe_push_arg (reg);
  return reg;]=],
        "GCC WebAssembly incoming singleton aggregate register mode")
    end

    strict_replace(wasm_codegen,
        [=[  machine_mode mode = arg.mode;
  if (const_tree scalar = wasm_singleton_scalar_type (arg.type))
    mode = TYPE_MODE (scalar);

  if (mode == TImode)
    {
      rtx const8_rtx = gen_rtx_CONST_INT (VOIDmode, 8);
      rtvec para = gen_rtvec (2,
	gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const0_rtx),
	gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const8_rtx));
      return gen_rtx_PARALLEL (TImode, para);
    }
  return gen_reg_rtx (mode);]=],
        [=[  const_tree scalar = wasm_singleton_scalar_type (arg.type);
  machine_mode mode = scalar ? TYPE_MODE (scalar) : arg.mode;

  if (mode == TImode)
    {
      rtx const8_rtx = gen_rtx_CONST_INT (VOIDmode, 8);
      rtvec para = gen_rtvec (2,
	gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const0_rtx),
	gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const8_rtx));
      return gen_rtx_PARALLEL (TImode, para);
    }

  /* Describe a singleton aggregate as one scalar outgoing ABI piece.  */
  rtx reg = gen_reg_rtx (mode);
  if (scalar)
    {
      rtx piece = gen_rtx_EXPR_LIST (VOIDmode, reg, const0_rtx);
      return gen_rtx_PARALLEL (arg.mode, gen_rtvec (1, piece));
    }
  return reg;]=],
        "GCC WebAssembly outgoing singleton aggregate piece description")

    strict_replace(wasm_codegen,
        [=[  machine_mode mode = arg.mode;
  if (const_tree scalar = wasm_singleton_scalar_type (arg.type))
    mode = TYPE_MODE (scalar);

  /* Int128 is passed as 2xint64_t, in LE order.  */
  if (mode == TImode)
    {
      rtx const8_rtx = gen_rtx_CONST_INT (VOIDmode, 8);

      rtx lsb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const0_rtx);
      rtx msb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const8_rtx);
      maybe_push_arg (XEXP (lsb, 0));
      maybe_push_arg (XEXP (msb, 0));
      rtvec para = gen_rtvec (2, lsb, msb);
      return gen_rtx_PARALLEL (TImode, para);
    }
  rtx reg = gen_reg_rtx (mode);
  maybe_push_arg (reg);
  return reg;]=],
        [=[  const_tree scalar = wasm_singleton_scalar_type (arg.type);
  machine_mode mode = scalar ? TYPE_MODE (scalar) : arg.mode;

  /* Int128 is passed as 2xint64_t, in LE order.  */
  if (mode == TImode)
    {
      rtx const8_rtx = gen_rtx_CONST_INT (VOIDmode, 8);

      rtx lsb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const0_rtx);
      rtx msb = gen_rtx_EXPR_LIST (DImode, gen_reg_rtx (DImode), const8_rtx);
      maybe_push_arg (XEXP (lsb, 0));
      maybe_push_arg (XEXP (msb, 0));
      rtvec para = gen_rtvec (2, lsb, msb);
      return gen_rtx_PARALLEL (TImode, para);
    }

  /* Describe a singleton aggregate as one scalar incoming ABI piece.  */
  rtx reg = gen_reg_rtx (mode);
  maybe_push_arg (reg);
  if (scalar)
    {
      rtx piece = gen_rtx_EXPR_LIST (VOIDmode, reg, const0_rtx);
      return gen_rtx_PARALLEL (arg.mode, gen_rtvec (1, piece));
    }
  return reg;]=],
        "GCC WebAssembly incoming singleton aggregate piece description")

    strict_replace(wasm_codegen,
        [=[/* Implementation of TARGET_FUNCTION_VALUE.  */
rtx
wasm_function_value (const_tree type, const_tree ARG_UNUSED (func),
		     bool outgoing)
{
  machine_mode mode = TYPE_MODE (type);
  if (!cfun)
    /* Fake the return regnum since none is actually available.  */
    return gen_rtx_REG (mode, WASM_RETURN_REGNUM);
  if (outgoing)
    {
      /* This is where we actually put the return value.  */
      cfun->machine->return_mode = mode;
      return gen_rtx_REG (mode, WASM_RETURN_REGNUM);
    }
  if (!cfun->machine->call)
    /* Fake the return regnum again, since we're not in a call.  */
    return gen_rtx_REG (mode, WASM_RETURN_REGNUM);

  /* Put the retval in a fresh reg, since its class may be different from actual
     retval, and we can't have that.  */
  return gen_reg_rtx (mode);
}]=],
        [=[static rtx
wasm_int128_function_value (bool hard_registers)
{
  rtx low = hard_registers
    ? gen_rtx_REG (DImode, WASM_RETURN_REGNUM)
    : gen_reg_rtx (DImode);
  rtx high = hard_registers
    ? gen_rtx_REG (DImode, WASM_RETURN_HIGH_REGNUM)
    : gen_reg_rtx (DImode);
  rtx parts[2] =
    {
      gen_rtx_EXPR_LIST (VOIDmode, low, const0_rtx),
      gen_rtx_EXPR_LIST (VOIDmode, high, GEN_INT (8))
    };
  return gen_rtx_PARALLEL (TImode, gen_rtvec_v (2, parts));
}

/* Implementation of TARGET_FUNCTION_VALUE.  */
rtx
wasm_function_value (const_tree type, const_tree ARG_UNUSED (func),
		     bool outgoing)
{
  machine_mode mode = TYPE_MODE (type);
  if (mode == TImode)
    {
      if (cfun && outgoing)
	cfun->machine->return_mode = mode;

      bool hard_registers = !cfun || outgoing || !cfun->machine->call;
      return wasm_int128_function_value (hard_registers);
    }
  if (!cfun)
    /* Fake the return regnum since none is actually available.  */
    return gen_rtx_REG (mode, WASM_RETURN_REGNUM);
  if (outgoing)
    {
      /* This is where we actually put the return value.  */
      cfun->machine->return_mode = mode;
      return gen_rtx_REG (mode, WASM_RETURN_REGNUM);
    }
  if (!cfun->machine->call)
    /* Fake the return regnum again, since we're not in a call.  */
    return gen_rtx_REG (mode, WASM_RETURN_REGNUM);

  /* Put the retval in a fresh reg, since its class may be different from actual
     retval, and we can't have that.  */
  return gen_reg_rtx (mode);
}]=],
        "GCC WebAssembly 128-bit integer multi-value return locations")

    strict_replace(wasm_codegen,
        [=[void
wasm_expand_call (rtx retval, rtx fn, rtx aux)
{
  bool vararg_p = false;
  bool has_proto = true;
  bool is_fn = true;
  bool need_chain = false;

  if (tree type = cfun->machine->call->type)
    {
      vararg_p = stdarg_p (type);
      has_proto = TYPE_ARG_TYPES (type) || vararg_p;
    }]=],
        [=[void
wasm_expand_call (rtx retval, rtx fn, rtx aux)
{
  bool vararg_p = false;
  bool has_proto = true;
  bool is_fn = true;
  bool need_chain = false;
  bool empty_result_p = false;

  if (tree type = cfun->machine->call->type)
    {
      vararg_p = stdarg_p (type);
      has_proto = TYPE_ARG_TYPES (type) || vararg_p;
      empty_result_p = retval && TYPE_EMPTY_P (TREE_TYPE (type));
    }]=],
        "GCC WebAssembly ignored empty call result classification")

    local upstream_call_result_lowering = [=[  rtx call = gen_rtx_CALL (VOIDmode, fn, aux);
  if (retval)
    call = gen_rtx_SET (retval, call);

  auto *args_rtx = cfun->machine->call->args;]=]
    local ignored_empty_call_result_lowering = [=[  rtx call = gen_rtx_CALL (VOIDmode, fn, aux);
  if (retval && !empty_result_p)
    call = gen_rtx_SET (retval, call);

  auto *args_rtx = cfun->machine->call->args;]=]
    local multi_call_result_lowering = [=[  rtx call = gen_rtx_CALL (VOIDmode, fn, aux);
  bool multi_result_p = retval && !empty_result_p
    && GET_CODE (retval) == PARALLEL;
  if (retval && !empty_result_p && !multi_result_p)
    call = gen_rtx_SET (retval, call);

  auto *args_rtx = cfun->machine->call->args;]=]
    strict_replace_migrated(wasm_codegen,
        upstream_call_result_lowering,
        ignored_empty_call_result_lowering,
        multi_call_result_lowering,
        "GCC WebAssembly multi-value call result classification")

    local upstream_call_emit = [=[  int argc = vec_safe_length (args_rtx);
  rtx res = gen_rtx_PARALLEL (VOIDmode, rtvec_alloc (argc + 1));
  XVECEXP (res, 0, 0) = call;
  for (int i = 0; i < argc; ++i)
    XVECEXP (res, 0, argc - i) = gen_rtx_USE (VOIDmode, (*args_rtx)[i]);
  emit_call_insn (res);
}]=]
    local ignored_empty_call_emit = [=[  int argc = vec_safe_length (args_rtx);
  rtx res = gen_rtx_PARALLEL (VOIDmode, rtvec_alloc (argc + 1));
  XVECEXP (res, 0, 0) = call;
  for (int i = 0; i < argc; ++i)
    XVECEXP (res, 0, argc - i) = gen_rtx_USE (VOIDmode, (*args_rtx)[i]);
  emit_call_insn (res);

  /* The language-level value of an empty aggregate still has a non-void RTL
     mode, while the Basic C ABI call returns no WebAssembly value.  Complete
     the RTL definition without manufacturing a result on the wasm stack.  */
  if (empty_result_p)
    emit_move_insn (retval, CONST0_RTX (GET_MODE (retval)));
}]=]
    local multi_call_emit = [=[  int argc = vec_safe_length (args_rtx);
  int result_count = multi_result_p ? 2 : 1;
  rtx res = gen_rtx_PARALLEL (VOIDmode,
			      rtvec_alloc (argc + result_count));
  if (multi_result_p)
    {
      gcc_assert (XVECLEN (retval, 0) == result_count);
      for (int i = 0; i < result_count; ++i)
	{
	  rtx result = XEXP (XVECEXP (retval, 0, i), 0);
	  XVECEXP (res, 0, i) = gen_rtx_SET (result, copy_rtx (call));
	}
    }
  else
    XVECEXP (res, 0, 0) = call;
  for (int i = 0; i < argc; ++i)
    XVECEXP (res, 0, result_count + argc - i - 1)
	= gen_rtx_USE (VOIDmode, (*args_rtx)[i]);
  emit_call_insn (res);

  /* The language-level value of an empty aggregate still has a non-void RTL
     mode, while the Basic C ABI call returns no WebAssembly value.  Complete
     the RTL definition without manufacturing a result on the wasm stack.  */
  if (empty_result_p)
    emit_move_insn (retval, CONST0_RTX (GET_MODE (retval)));
}]=]
    strict_replace_migrated(wasm_codegen,
        upstream_call_emit,
        ignored_empty_call_emit,
        multi_call_emit,
        "GCC WebAssembly multi-value call RTL lowering")

    strict_replace(wasm_codegen,
        [=[  dest = unify_mem (dest);
  src = unify_mem (src);
  if (register_operand (dest, mode) && immediate_operand (src, mode))]=],
        [=[  dest = unify_mem (dest);
  src = unify_mem (src);

  /* A TImode pseudo is represented by two i64 locals.  Materialize its low
     half as DImode before narrowing so the final RTL uses the ordinary
     i64-to-i32 conversion instead of an unrecognizable direct subreg move.  */
  if (SUBREG_P (src))
    {
      rtx inner = SUBREG_REG (src);
      if (REG_P (inner) && GET_MODE (inner) == TImode
	  && known_eq (SUBREG_BYTE (src), 0)
	  && (mode == QImode || mode == HImode || mode == SImode))
	{
	  rtx low_di = gen_reg_rtx (DImode);
	  rtx low_half = gen_rtx_SUBREG (DImode, inner, 0);
	  emit_move_insn (low_di, low_half);

	  rtx low_si = gen_reg_rtx (SImode);
	  emit_insn (gen_rtx_SET (low_si,
				  gen_rtx_TRUNCATE (SImode, low_di)));
	  rtx narrowed = mode == SImode
	    ? low_si
	    : simplify_gen_subreg (mode, low_si, SImode, 0);
	  gcc_assert (narrowed);
	  emit_move_insn (dest, narrowed);
	  return true;
	}
    }

  if (register_operand (dest, mode) && immediate_operand (src, mode))]=],
        "GCC WebAssembly 128-bit integer low-part truncation expansion")
    strict_replace(wasm_codegen,
        [=[  emit_insn (gen_rtx_SET (dest, src));
  return true;
}

void
wasm_expand_conv (rtx dest, rtx src, rtx_code code)]=],
        [=[  emit_insn (gen_rtx_SET (dest, src));
  return true;
}

/* WebAssembly has native 64-bit CLZ, CTZ, and POPCNT operations, while a
   TImode pseudo is represented by two i64 locals.  Open-code the 128-bit
   queries so generic C++ bit operations do not require nonexistent i128
   WebAssembly instructions or target libcalls.  */
void
wasm_expand_int128_bitquery (rtx dest, rtx src, rtx_code code)
{
  gcc_assert (REG_P (dest) && GET_MODE (dest) == TImode);
  gcc_assert ((REG_P (src) || MEM_P (src)) && GET_MODE (src) == TImode);

  auto materialize_part = [](rtx value, HOST_WIDE_INT offset)
    {
      rtx part = MEM_P (value)
	? adjust_address (value, DImode, offset)
	: gen_rtx_SUBREG (DImode, value, offset);
      return force_reg (DImode, part);
    };
  rtx low = materialize_part (src, 0);
  rtx high = materialize_part (src, 8);

  optab query_optab;
  switch (code)
    {
    case CLZ:
      query_optab = clz_optab;
      break;
    case CTZ:
      query_optab = ctz_optab;
      break;
    case POPCOUNT:
      query_optab = popcount_optab;
      break;
    default:
      gcc_unreachable ();
    }

  auto expand_part = [query_optab](rtx value)
    {
      rtx target = gen_reg_rtx (DImode);
      rtx result = expand_unop (DImode, query_optab, value, target, true);
      gcc_assert (result);
      if (result != target)
	emit_move_insn (target, result);
      return target;
    };

  rtx result = gen_reg_rtx (DImode);
  if (code == POPCOUNT)
    {
      rtx low_count = expand_part (low);
      rtx high_count = expand_part (high);
      rtx sum = expand_binop (DImode, add_optab, low_count, high_count,
			      result, true, OPTAB_DIRECT);
      gcc_assert (sum);
      if (sum != result)
	emit_move_insn (result, sum);
    }
  else
    {
      rtx primary = code == CLZ ? high : low;
      rtx secondary = code == CLZ ? low : high;
      rtx_code_label *primary_zero = gen_label_rtx ();
      rtx_code_label *done = gen_label_rtx ();

      emit_cmp_and_jump_insns (primary, CONST0_RTX (DImode), EQ,
			       NULL_RTX, DImode, true, primary_zero);
      emit_move_insn (result, expand_part (primary));
      emit_jump_insn (targetm.gen_jump (done));
      emit_barrier ();

      emit_label (primary_zero);
      rtx secondary_count = expand_part (secondary);
      rtx sum = expand_binop (DImode, add_optab, secondary_count,
			      GEN_INT (64), result, true, OPTAB_DIRECT);
      gcc_assert (sum);
      if (sum != result)
	emit_move_insn (result, sum);
      emit_label (done);
    }

  emit_move_insn (gen_rtx_SUBREG (DImode, dest, 0), result);
  emit_move_insn (gen_rtx_SUBREG (DImode, dest, 8), const0_rtx);
}

void
wasm_expand_conv (rtx dest, rtx src, rtx_code code)]=],
        "GCC WebAssembly 128-bit integer bit-query expansion")
    strict_replace(wasm_codegen,
        [=[void
wasm_expand_conv (rtx dest, rtx src, rtx_code code)
{
  if (code == TRUNCATE)]=],
        [=[void
wasm_expand_conv (rtx dest, rtx src, rtx_code code)
{
  /* The generic conversion expanders accept QI/HI/SI subregs, but a subreg
     of a TImode pseudo is backed by two i64 locals rather than an i32 local.
     Materialize the low half first so the existing i64-to-i32 conversion and
     i32 sign/zero-extension patterns see their expected register classes.  */
  if (SUBREG_P (src))
    {
      rtx inner = SUBREG_REG (src);
      machine_mode src_mode = GET_MODE (src);
      if (REG_P (inner) && GET_MODE (inner) == TImode
	  && known_eq (SUBREG_BYTE (src), 0)
	  && (src_mode == QImode || src_mode == HImode
	      || src_mode == SImode))
	{
	  rtx low_di = gen_reg_rtx (DImode);
	  emit_move_insn (low_di, gen_rtx_SUBREG (DImode, inner, 0));

	  rtx low_si = gen_reg_rtx (SImode);
	  emit_insn (gen_rtx_SET (low_si,
				  gen_rtx_TRUNCATE (SImode, low_di)));
	  src = src_mode == SImode
	    ? low_si
	    : simplify_gen_subreg (src_mode, low_si, SImode, 0);
	  gcc_assert (src);
	}
    }

  if (code == TRUNCATE)]=],
        "GCC WebAssembly 128-bit integer low-part conversion expansion")

    local wasm_constraints = path.join(src, "gcc", "config", "wasm", "constraints.md")
    remove_exact_patch(wasm_constraints,
        [=[(define_predicate "wasm_ti_lowpart_operand"
  (match_code "subreg")
  {
    rtx inner = SUBREG_REG (op);
    return REG_P (inner)
      && GET_MODE (inner) == TImode
      && known_eq (SUBREG_BYTE (op), 0);
  })

]=],
        "obsolete GCC WebAssembly 128-bit integer low-part predicate")
    strict_replace(wasm_constraints,
        [=[(define_predicate "call_operation"
  (match_code "parallel")
{
  int arg_end = XVECLEN (op, 0);

  for (int i = 1; i < arg_end; i++)
    {
      rtx elt = XVECEXP (op, 0, i);

      if (GET_CODE (elt) != USE || !REG_P (XEXP (elt, 0)))
	return false;
    }
  return true;
})]=],
        [=[(define_predicate "call_operation"
  (match_code "parallel")
{
  int arg_end = XVECLEN (op, 0);
  int arg_begin = arg_end > 1 && GET_CODE (XVECEXP (op, 0, 1)) == SET
    ? 2 : 1;

  for (int i = arg_begin; i < arg_end; i++)
    {
      rtx elt = XVECEXP (op, 0, i);

      if (GET_CODE (elt) != USE || !REG_P (XEXP (elt, 0)))
	return false;
    }
  return true;
})]=],
        "GCC WebAssembly multi-value call recognition")

    local wasm_machine = path.join(src, "gcc", "config", "wasm", "wasm.md")
    do
        local wasm_ti_lowpart_move_patch = [=[;; A TImode pseudo is represented by two i64 locals.  Narrowing its low
;; half therefore needs the same i64-to-i32 wrap as an ordinary DImode value.
(define_insn "*local_move_ti_lowpart<mode>"
  [(set (match_operand:SUBREGDI 0 "subregister_for_si_operand" "")
	(match_operand:SUBREGDI 1 "wasm_ti_lowpart_operand" ""))]
  ""
  "(%M0.set %0 (i32.wrap_i64 (%M1.get %1)))")

]=]
        local previous_wasm_ti_lowpart_move_patch = base.replace_plain(
            wasm_ti_lowpart_move_patch, "SUBREGDI", "QHSI")
        remove_exact_patch(wasm_machine, previous_wasm_ti_lowpart_move_patch,
            "obsolete GCC WebAssembly QHSI low-part move")
        remove_exact_patch(wasm_machine, wasm_ti_lowpart_move_patch,
            "obsolete GCC WebAssembly SUBREGDI low-part move")
    end
    strict_replace(wasm_machine,
        [=[(define_expand "call_value"
  [(set (match_operand 0 "register_operand" "=r")]=],
        [=[(define_expand "call_value"
  [(set (match_operand 0 "" "")]=],
        "GCC WebAssembly parallel call value expansion")
    strict_replace(wasm_machine,
        [=[(define_insn "*<opname_rt><mode>2"
  [(set (match_operand:REG 0 "wasm_register_operand")
	    (iunop:REG (match_operand:REG 1 "wasm_register_operand")))]
  ""
  "(%M0.set %0 (<types>.<iunop:opname> (%M1.get %1)))")

;; Binary float]=],
        [=[(define_insn "*<opname_rt><mode>2"
  [(set (match_operand:REG 0 "wasm_register_operand")
	    (iunop:REG (match_operand:REG 1 "wasm_register_operand")))]
  ""
  "(%M0.set %0 (<types>.<iunop:opname> (%M1.get %1)))")

;; A TImode pseudo is two i64 locals.  Expand the integer bit queries into
;; the corresponding native 64-bit operations.
(define_expand "clzti2"
  [(set (match_operand:TI 0 "register_operand")
	(clz:TI (match_operand:TI 1 "general_operand")))]
  ""
  {
    wasm_expand_int128_bitquery (operands[0], operands[1], CLZ);
    DONE;
  })

(define_expand "ctzti2"
  [(set (match_operand:TI 0 "register_operand")
	(ctz:TI (match_operand:TI 1 "general_operand")))]
  ""
  {
    wasm_expand_int128_bitquery (operands[0], operands[1], CTZ);
    DONE;
  })

(define_expand "popcountti2"
  [(set (match_operand:TI 0 "register_operand")
	(popcount:TI (match_operand:TI 1 "general_operand")))]
  ""
  {
    wasm_expand_int128_bitquery (operands[0], operands[1], POPCOUNT);
    DONE;
  })

;; Binary float]=],
        "GCC WebAssembly 128-bit integer bit-query expanders")
    strict_replace(wasm_machine,
        [=[(define_insn "*call_value_internal_indirect"
  [(match_parallel 3 "call_operation"
    [(set (match_operand 0 "wasm_register_operand" "")
	      (call (mem:SI (match_operand:P 1 "wasm_call_register_operand"))
			(match_operand 2)))])]
  ""
  "(%M0.set %0 (call_indirect (param%T3) (result%T0)%A3 (%M1.get %1)))")]=],
        [=[(define_insn "*call_value_multiple_internal_indirect"
  [(match_parallel 4 "call_operation"
    [(set (match_operand:DI 0 "wasm_register_operand" "")
	      (call (mem:SI (match_operand:P 2 "wasm_call_register_operand"))
			(match_operand 3)))
     (set (match_operand:DI 1 "wasm_register_operand" "")
	      (call (mem:SI (match_dup 2))
			(match_dup 3)))])]
  ""
  "(call_indirect (param%T4) (result%T0%T1)%A4 (%M2.get %2))\n\t(%M1.set %1)\n\t(%M0.set %0)")

(define_insn "*call_value_internal_indirect"
  [(match_parallel 3 "call_operation"
    [(set (match_operand 0 "wasm_register_operand" "")
	      (call (mem:SI (match_operand:P 1 "wasm_call_register_operand"))
			(match_operand 2)))])]
  ""
  "(%M0.set %0 (call_indirect (param%T3) (result%T0)%A3 (%M1.get %1)))")]=],
        "GCC WebAssembly indirect multi-value call instruction")
    strict_replace(wasm_machine,
        [=[(define_insn "*call_value_internal"
  [(match_parallel 3 "call_operation"
    [(set (match_operand 0 "wasm_register_operand" "")
	      (call (mem:SI (match_operand:P 1 "funcref_operand"))
			(match_operand 2)))])]
  ""
  "(%M0.set %0 (call %1%A3))")]=],
        [=[(define_insn "*call_value_multiple_internal"
  [(match_parallel 4 "call_operation"
    [(set (match_operand:DI 0 "wasm_register_operand" "")
	      (call (mem:SI (match_operand:P 2 "funcref_operand"))
			(match_operand 3)))
     (set (match_operand:DI 1 "wasm_register_operand" "")
	      (call (mem:SI (match_dup 2))
			(match_dup 3)))])]
  ""
  "(call %2%A4)\n\t(%M1.set %1)\n\t(%M0.set %0)")

(define_insn "*call_value_internal"
  [(match_parallel 3 "call_operation"
    [(set (match_operand 0 "wasm_register_operand" "")
	      (call (mem:SI (match_operand:P 1 "funcref_operand"))
			(match_operand 2)))])]
  ""
  "(%M0.set %0 (call %1%A3))")]=],
        "GCC WebAssembly direct multi-value call instruction")

    return wasm_header, wasm_hooks
end

function _apply_assembly(ctx, wasm_header, wasm_hooks)
    local src = ctx.src
    local function strict_replace(file, original, replacement, label)
        return shared.strict_replace(ctx, file, original, replacement, label)
    end
    local function strict_replace_migrated(file, original, previous, replacement, label)
        return shared.strict_replace_migrated(ctx, file, original, previous, replacement, label)
    end
    local function remove_exact_patch(file, patch, label)
        return shared.remove_exact_patch(ctx, file, patch, label)
    end

    local wasm_assembly = path.join(src, "gcc", "config", "wasm", "wasm-asm.cc")
    local wasm_passes = path.join(src, "gcc", "config", "wasm", "wasm-passes.cc")
    strict_replace(wasm_assembly,
        [=[  bool override_args = false;
  if (MAIN_NAME_P (DECL_NAME (decl)))
    {
      if (!cfun->machine->func_args)
	name = "__main_void";
      else
	name = "__main_argc_argv", override_args = true;
    }]=],
        [=[  bool override_args = false;
  if (MAIN_NAME_P (DECL_NAME (decl)))
    name = "__main_argc_argv", override_args = true;]=],
        "GCC WebAssembly Emscripten executable entry ABI")
    do
        local wasm_atomic_compare_exchange_import_anchor = [=[void
assemble_entity_import (FILE *stream, const char *name, const char *abi_name,
			const_tree decl)
{
  const_tree type = DECL_P (decl) ? TREE_TYPE (decl) : decl;]=]
        local wasm_atomic_compare_exchange_import_patch = [=[/* GCC's source-level fixed-width compare-exchange builtins have a
   boolean weak operand, but the libatomic ABI deliberately omits it.  Most
   assemblers do not encode function types, whereas WebAssembly imports must
   describe the lowered five-argument libcall exactly.  */
static bool
wasm_atomic_compare_exchange_libcall_p (const char *name)
{
  return strcmp (name, "__atomic_compare_exchange_1") == 0
    || strcmp (name, "__atomic_compare_exchange_2") == 0
    || strcmp (name, "__atomic_compare_exchange_4") == 0
    || strcmp (name, "__atomic_compare_exchange_8") == 0
    || strcmp (name, "__atomic_compare_exchange_16") == 0;
}

static const_tree
wasm_external_abi_type (const char *abi_name, const_tree decl)
{
  const_tree type = DECL_P (decl) ? TREE_TYPE (decl) : decl;
  if (!FUNC_OR_METHOD_TYPE_P (type)
      || !wasm_atomic_compare_exchange_libcall_p (abi_name))
    return type;

  auto_vec<tree, 5> args;
  function_args_iterator it;
  tree arg;
  unsigned int index = 0;
  FOREACH_FUNCTION_ARGS (type, arg, it)
    {
      if (arg == void_type_node)
	break;
      if (index != 3)
	args.safe_push (arg);
      ++index;
    }

  if (index != 6)
    return type;
  return build_function_type_array (TREE_TYPE (type), args.length (),
				    args.address ());
}

void
assemble_entity_import (FILE *stream, const char *name, const char *abi_name,
			const_tree decl)
{
  const_tree type = wasm_external_abi_type (abi_name, decl);]=]
        local previous_wasm_atomic_compare_exchange_import_patch = base.replace_plain(
            wasm_atomic_compare_exchange_import_patch,
            [=[    {
      if (arg == void_type_node)
	break;
      if (index != 3)]=],
            [=[    {
      if (index != 3)]=])
        strict_replace_migrated(wasm_assembly,
            wasm_atomic_compare_exchange_import_anchor,
            previous_wasm_atomic_compare_exchange_import_patch,
            wasm_atomic_compare_exchange_import_patch,
            "GCC WebAssembly fixed-width atomic compare-exchange libcall ABI")
    end
    remove_exact_patch(wasm_assembly,
        [=[  if (value && SUBREG_P (value))
    {
      rtx inner = SUBREG_REG (value);
      machine_mode value_mode = GET_MODE (value);
      if (REG_P (inner) && GET_MODE (inner) == TImode
	  && known_eq (SUBREG_BYTE (value), 0)
	  && (value_mode == SImode || value_mode == HImode
	      || value_mode == QImode)
	  && (mode == 0 || mode == 'i' || mode == 'o' || mode == 'M'))
	{
	  gcc_assert (!HARD_REGISTER_P (inner));
	  if (mode == 'i' || mode == 'o')
	    fprintf (stream, "%s%s.%s ", mode == 'o' ? "" : "(",
		     "local", mode == 'i' ? "get" : "set");
	  else if (mode == 'M')
	    {
	      fprintf (stream, "local");
	      return;
	    }

	  fprintf (stream, "$local_%d_0",
		   REGNO (inner) - FIRST_PSEUDO_REGISTER);
	  if (mode == 'i')
	    fprintf (stream, ")");
	  return;
	}
    }

]=],
        "obsolete GCC WebAssembly 128-bit integer low-part printing")
    strict_replace(wasm_header,
        "void wasm_generate_internal_label (char *buf, const char *pfx, size_t no);",
        "void wasm_generate_internal_label (char *buf, const char *pfx, unsigned long no);",
        "GCC WebAssembly portable generated-label number type")
    strict_replace(wasm_hooks,
        "void wasm_output_internal_label (FILE *stream, const char *pfx, size_t no);",
        "void wasm_output_internal_label (FILE *stream, const char *pfx, unsigned long no);",
        "GCC WebAssembly target internal-label hook signature")
    strict_replace(wasm_assembly,
        [=[char *fake_out_file_data;
size_t fake_out_file_length;
FILE *saved_asm_out_file;]=],
        [=[/* Assembly output is deferred until imports have been discovered.  */
FILE *saved_asm_out_file;]=],
        "GCC WebAssembly portable deferred assembly storage")
    strict_replace(wasm_assembly,
        "  asm_out_file = open_memstream (&fake_out_file_data, &fake_out_file_length);",
        [=[  asm_out_file = tmpfile ();
  if (!asm_out_file)
    fatal_error (UNKNOWN_LOCATION,
                 "cannot create temporary WebAssembly assembly output");]=],
        "GCC WebAssembly portable deferred assembly stream")
    strict_replace(wasm_assembly,
        [=[  fflush (asm_out_file);
  fwrite (fake_out_file_data, 1, fake_out_file_length, saved_asm_out_file);

  fprintf (saved_asm_out_file, ")\n");]=],
        [=[  if (fflush (asm_out_file) != 0
      || fseek (asm_out_file, 0, SEEK_SET) != 0)
    fatal_error (UNKNOWN_LOCATION,
                 "cannot rewind temporary WebAssembly assembly output");

  char buffer[BUFSIZ];
  size_t length;
  while ((length = fread (buffer, 1, sizeof buffer, asm_out_file)) != 0)
    if (fwrite (buffer, 1, length, saved_asm_out_file) != length)
      fatal_error (UNKNOWN_LOCATION,
                   "cannot write WebAssembly assembly output");
  if (ferror (asm_out_file))
    fatal_error (UNKNOWN_LOCATION,
                 "cannot read temporary WebAssembly assembly output");
  if (fclose (asm_out_file) != 0)
    fatal_error (UNKNOWN_LOCATION,
                 "cannot close temporary WebAssembly assembly output");
  asm_out_file = saved_asm_out_file;

  fprintf (asm_out_file, ")\n");]=],
        "GCC WebAssembly portable deferred assembly copy")
    strict_replace(wasm_assembly,
        "static int get_cf_label (size_t no)",
        "static int get_cf_label (unsigned long no)",
        "GCC WebAssembly portable control-flow label number type")
    strict_replace(wasm_assembly,
        "wasm_generate_internal_label (char *buf, const char *pfx, size_t no)",
        "wasm_generate_internal_label (char *buf, const char *pfx, unsigned long no)",
        "GCC WebAssembly portable generated-label definition")
    strict_replace(wasm_assembly,
        "    sprintf (buf, \"%s\" HOST_WIDE_INT_PRINT_DEC, pfx, no);",
        "    sprintf (buf, \"%s%lu\", pfx, no);",
        "GCC WebAssembly portable generated-label formatting")
    strict_replace(wasm_assembly,
        "wasm_output_internal_label (FILE *stream, const char *pfx, size_t no)",
        "wasm_output_internal_label (FILE *stream, const char *pfx, unsigned long no)",
        "GCC WebAssembly portable internal-label definition")
    strict_replace(wasm_assembly,
        "\tfprintf (stream, \" %+ld\", addend);",
        "\tfprintf (stream, \" %+\" HOST_WIDE_INT_PRINT \"d\", addend);",
        "GCC WebAssembly portable relocation addend formatting")
    strict_replace(wasm_assembly,
        "  fprintf (stream, \" (size %ld)\", size);",
        "  fprintf (stream, \" (size \" HOST_WIDE_INT_PRINT_DEC \")\", size);",
        "GCC WebAssembly portable data size formatting")
    strict_replace(wasm_assembly,
        "\t    fprintf (stream, \"offset=%lu \", UINTVAL (XEXP (addr, 1)));",
        "\t    fprintf (stream, \"offset=\" HOST_WIDE_INT_PRINT_UNSIGNED \" \",\n" ..
        "\t\t     UINTVAL (XEXP (addr, 1)));",
        "GCC WebAssembly portable memory offset formatting")
    strict_replace(wasm_assembly,
        "      fprintf (stream, \"%ld\", INTVAL (value));",
        "      fprintf (stream, HOST_WIDE_INT_PRINT_DEC, INTVAL (value));",
        "GCC WebAssembly portable integer operand formatting")
    strict_replace(wasm_assembly,
        "#include \"rtl.h\"\n#include \"tree.h\"",
        "#include \"rtl.h\"\n#include \"rtl-iter.h\"\n#include \"tree.h\"",
        "GCC WebAssembly final RTL operand scanning support")
    strict_replace(wasm_assembly,
        "#include \"tree-pass.h\"",
        "#include \"tree-pass.h\"\n#include \"cgraph.h\"",
        "GCC WebAssembly call graph access")
    strict_replace(wasm_assembly,
        [=[wasm_asm_start_function (FILE *stream, tree decl, const char *name)
{
  output_indent (stream);]=],
        [=[wasm_asm_start_function (FILE *stream, tree decl, const char *name)
{
  for (rtx_insn *insn = get_insns (); insn; insn = NEXT_INSN (insn))
    if (CALL_P (insn))
      if (tree callee_decl = get_call_fndecl (insn))
        {
          cgraph_node *callee_node = cgraph_node::get (callee_decl);
          if (!callee_node || !callee_node->definition)
            wasm_handle_import
              (stream,
               IDENTIFIER_POINTER (DECL_ASSEMBLER_NAME (callee_decl)),
               callee_decl);
        }

  output_indent (stream);]=],
        "GCC WebAssembly final direct-call imports")
    strict_replace(wasm_assembly,
        [=[  for (const auto &map_entry: import_map)
    {
      tree name = map_entry.second.first;
      const_tree decl = map_entry.second.second;
      assemble_import (saved_asm_out_file, IDENTIFIER_POINTER (name), decl);
    }
  for (auto sym: external_libcall_set)]=],
        [=[  hash_set<tree> external_libcall_names;
  for (auto sym: external_libcall_set)
    external_libcall_names.add
      (targetm.asm_out.mangle_assembler_name (XSTR (sym, 0)));

  for (const auto &map_entry: import_map)
    {
      if (external_libcall_names.contains (map_entry.first))
        continue;
      tree name = map_entry.second.first;
      const_tree decl = map_entry.second.second;
      assemble_import (saved_asm_out_file, IDENTIFIER_POINTER (name), decl);
    }
  for (auto sym: external_libcall_set)]=],
        "GCC WebAssembly specialized libcall import precedence")
    strict_replace(wasm_passes,
        [=[    df_clear_flags (DF_LR_RUN_DCE);
    df_set_flags (DF_NO_INSN_RESCAN | DF_NO_HARD_REGS);
    df_live_add_problem ();
    df_live_set_all_dirty ();
    df_analyze ();]=],
        [=[    df_clear_flags (DF_LR_RUN_DCE | DF_NO_INSN_RESCAN);
    df_set_flags (DF_NO_HARD_REGS);
    df_insn_rescan_all ();
    df_live_add_problem ();
    df_live_set_all_dirty ();
    df_analyze ();]=],
        "GCC WebAssembly final pseudo-register liveness rescan")
    strict_replace_migrated(wasm_assembly,
        [=[  int max = max_reg_num ();
  for (int r = FIRST_PSEUDO_REGISTER; r < max; r++)
    {
      reg = regno_reg_rtx[r];
      if (!reg)
	continue;
      if (reg == const0_rtx)
	continue;
      if (vec_safe_contains (cfun->machine->func_args, reg))
	continue;
      if (!bitmap_bit_p (cfun->machine->regs_ever_live, r))
	continue;
      print_local_decl (stream, reg);
    }]=],
        [=[  int max = max_reg_num ();
  for (int r = FIRST_PSEUDO_REGISTER; r < max; r++)
    {
      reg = regno_reg_rtx[r];
      if (!reg)
	continue;
      if (reg == const0_rtx)
	continue;
      if (vec_safe_contains (cfun->machine->func_args, reg))
	continue;
      /* Final target splitting can create pseudos after the
	 liveness snapshot.  Declaring every canonical non-argument pseudo is
	 conservative and prevents valid late registers from being omitted.  */
      print_local_decl (stream, reg);
    }]=],
        [=[  /* The final target split can create a scalar REG view whose canonical
     regno_reg_rtx entry still has an aggregate mode.  Scan the final
     instruction operands so every local is declared with the mode that the
     emitted instruction actually uses.  */
  auto_bitmap declared_pseudos;
  FOR_EACH_VEC_SAFE_ELT (cfun->machine->func_args, i, reg)
    {
      rtx argument_reg = SUBREG_P (reg) ? SUBREG_REG (reg) : reg;
      if (REG_P (argument_reg) && !HARD_REGISTER_P (argument_reg))
	bitmap_set_bit (declared_pseudos, REGNO (argument_reg));
    }

  for (rtx_insn *insn = get_insns (); insn; insn = NEXT_INSN (insn))
    if (INSN_P (insn))
      {
	subrtx_var_iterator::array_type array;
	FOR_EACH_SUBRTX_VAR (iter, array, PATTERN (insn), NONCONST)
	  {
	    rtx operand = *iter;
	    if (!REG_P (operand) || HARD_REGISTER_P (operand))
	      continue;
	    unsigned int regno = REGNO (operand);
	    if (bitmap_bit_p (declared_pseudos, regno))
	      continue;

	    machine_mode mode = GET_MODE (operand);
	    tree local_type = lang_hooks.types.type_for_mode (mode, 0);
	    if (mode != TImode && (!local_type || VOID_TYPE_P (local_type)))
	      continue;

	    print_local_decl (stream, operand);
	    bitmap_set_bit (declared_pseudos, regno);
	  }
      }]=],
        "GCC WebAssembly final operand pseudo-register declarations")
    local ignored_empty_local_decl = [=[void
print_local_decl (FILE *stream, rtx reg, bool param = false)
{
  tree param_type = lang_hooks.types.type_for_mode (GET_MODE (reg), 0);
  if (!param_type || VOID_TYPE_P (param_type))
    return;

  output_indent (stream);
  fprintf (stream, "(%s ", param ? "param" : "local");
  wasm_print_operand (stream, reg, 0);
  print_type (stream, param_type);
  fprintf (stream, ")\n");
}]=]
    local upstream_local_decl = [=[void
print_local_decl (FILE *stream, rtx reg, bool param = false)
{
  output_indent (stream);
  fprintf (stream, "(%s ", param ? "param" : "local");
  wasm_print_operand (stream, reg, 0);
  tree param_type = lang_hooks.types.type_for_mode (GET_MODE (reg), 0);
  print_type (stream, param_type);
  fprintf (stream, ")\n");
}]=]
    if io.readfile(wasm_assembly):find(ignored_empty_local_decl, 1, true) then
        strict_replace(wasm_assembly, ignored_empty_local_decl, upstream_local_decl,
            "GCC WebAssembly legacy empty local declaration migration")
    end
    strict_replace(wasm_assembly,
        [=[    case UNION_TYPE:
    case RECORD_TYPE:
      if (TYPE_EMPTY_P (type))
	break;
      if (TYPE_TRANSPARENT_AGGR (type))
	print_type (stream, TREE_TYPE (first_field (type)), first);
      else
	print_type (stream, ptr_type_node, first);
      break;]=],
        [=[    case UNION_TYPE:
    case RECORD_TYPE:
      if (TYPE_EMPTY_P (type))
	break;
      if (TYPE_TRANSPARENT_AGGR (type))
	print_type (stream, TREE_TYPE (first_field (type)), first);
      else if (const_tree scalar = wasm_singleton_scalar_type (type))
	print_type (stream, scalar, first);
      else
	print_type (stream, ptr_type_node, first);
      break;]=],
        "GCC WebAssembly Basic C ABI singleton WAT value type")
    strict_replace(wasm_assembly,
        [=[    case NULLPTR_TYPE:
    case POINTER_TYPE:
    case REFERENCE_TYPE:
    case OFFSET_TYPE:
    case INTEGER_TYPE:
    case BOOLEAN_TYPE:
    case ENUMERAL_TYPE:
      fprintf (stream, "%s%s", delim,
	       TYPE_PRECISION (type) > 32 ? "i64" : "i32");
      break;]=],
        [=[    case NULLPTR_TYPE:
    case POINTER_TYPE:
    case REFERENCE_TYPE:
    case OFFSET_TYPE:
    case INTEGER_TYPE:
    case BOOLEAN_TYPE:
    case ENUMERAL_TYPE:
      if (TYPE_MODE (type) == TImode)
	fprintf (stream, "%si64 i64", delim);
      else
	fprintf (stream, "%s%s", delim,
		 TYPE_PRECISION (type) > 32 ? "i64" : "i32");
      break;]=],
        "GCC WebAssembly 128-bit integer WAT value types")
    strict_replace(wasm_assembly,
        [=[void
print_local_decl (FILE *stream, rtx reg, bool param = false)
{
  output_indent (stream);
  fprintf (stream, "(%s ", param ? "param" : "local");
  wasm_print_operand (stream, reg, 0);
  tree param_type = lang_hooks.types.type_for_mode (GET_MODE (reg), 0);
  print_type (stream, param_type);
  fprintf (stream, ")\n");
}]=],
        [=[void
print_local_decl (FILE *stream, rtx reg, bool param = false)
{
  if (GET_MODE (reg) == TImode)
    {
      print_local_decl (stream, gen_rtx_SUBREG (DImode, reg, 0), param);
      print_local_decl (stream, gen_rtx_SUBREG (DImode, reg, 8), param);
      return;
    }

  tree param_type = lang_hooks.types.type_for_mode (GET_MODE (reg), 0);
  if (!param_type || VOID_TYPE_P (param_type))
    return;

  output_indent (stream);
  fprintf (stream, "(%s ", param ? "param" : "local");
  wasm_print_operand (stream, reg, 0);
  print_type (stream, param_type);
  fprintf (stream, ")\n");
}]=],
        "GCC WebAssembly split 128-bit integer local declarations")
    strict_replace(wasm_assembly,
        [=[    case SUBREG:
      gcc_assert (SUBREG_BYTE (value) == 0);
      wasm_print_operand (stream, SUBREG_REG (value), mode);
      break;]=],
        [=[    case SUBREG:
      {
        rtx inner = SUBREG_REG (value);
        if (REG_P (inner) && GET_MODE (inner) == TImode
            && GET_MODE (value) == DImode)
          {
            gcc_assert (!HARD_REGISTER_P (inner));
            if (mode == 'i' || mode == 'o')
              fprintf (stream, "%s%s.%s ", mode == 'o' ? "" : "(",
                       "local", mode == 'i' ? "get" : "set");
            else if (mode == 'M')
              {
                fprintf (stream, "local");
                break;
              }

            unsigned int part = known_eq (SUBREG_BYTE (value), 0) ? 0 : 1;
            gcc_assert (known_eq (SUBREG_BYTE (value), part * 8));
            fprintf (stream, "$local_%d_%u",
                     REGNO (inner) - FIRST_PSEUDO_REGISTER, part);
            if (mode == 'i')
              fprintf (stream, ")");
            break;
          }

        gcc_assert (SUBREG_BYTE (value) == 0);
        wasm_print_operand (stream, inner, mode);
        break;
      }]=],
        "GCC WebAssembly split 128-bit integer operand names")
    strict_replace_migrated(wasm_assembly,
        [=[  if (cfun->machine->return_mode != VOIDmode)
    print_local_decl (stream, gen_rtx_REG (cfun->machine->return_mode,
					   WASM_RETURN_REGNUM));]=],
        [=[  if (cfun->machine->return_mode == TImode)
    {
      print_local_decl (stream, gen_rtx_REG (DImode, WASM_RETURN_REGNUM));
      print_local_decl (stream, gen_rtx_REG (DImode,
					     WASM_RETURN_HIGH_REGNUM));
    }
  else if (cfun->machine->return_mode != VOIDmode)
    print_local_decl (stream, gen_rtx_REG (cfun->machine->return_mode,
					   WASM_RETURN_REGNUM));]=],
        [=[  auto hard_return_register_mode = [] (unsigned int regno)
    {
      machine_mode mode = VOIDmode;
      for (rtx_insn *insn = get_insns (); insn; insn = NEXT_INSN (insn))
	if (INSN_P (insn))
	  {
	    subrtx_var_iterator::array_type array;
	    FOR_EACH_SUBRTX_VAR (iter, array, PATTERN (insn), NONCONST)
	      {
		rtx operand = *iter;
		if (!REG_P (operand) || REGNO (operand) != regno
		    || GET_MODE (operand) == VOIDmode)
		  continue;

		if (mode == VOIDmode)
		  mode = GET_MODE (operand);
		else
		  gcc_assert (mode == GET_MODE (operand));
	      }
	  }
      return mode;
    };

  machine_mode return_register_mode = cfun->machine->return_mode;
  if (return_register_mode == TImode)
    return_register_mode = DImode;
  else if (return_register_mode == VOIDmode
	   && df_regs_ever_live_p (WASM_RETURN_REGNUM))
    return_register_mode = hard_return_register_mode (WASM_RETURN_REGNUM);
  if (return_register_mode != VOIDmode)
    print_local_decl (stream, gen_rtx_REG (return_register_mode,
					   WASM_RETURN_REGNUM));

  machine_mode return_high_register_mode
    = cfun->machine->return_mode == TImode ? DImode : VOIDmode;
  if (return_high_register_mode == VOIDmode
	&& df_regs_ever_live_p (WASM_RETURN_HIGH_REGNUM))
    return_high_register_mode
	= hard_return_register_mode (WASM_RETURN_HIGH_REGNUM);
  if (return_high_register_mode != VOIDmode)
    print_local_decl (stream, gen_rtx_REG (return_high_register_mode,
					   WASM_RETURN_HIGH_REGNUM));]=],
        "GCC WebAssembly live return hard-register declarations")
    strict_replace(wasm_assembly,
        [=[      if (r == WASM_RETURN_REGNUM)
	continue;]=],
        [=[      if (r == WASM_RETURN_REGNUM || r == WASM_RETURN_HIGH_REGNUM)
	continue;]=],
        "GCC WebAssembly return hard-register declaration exclusion")
    strict_replace(wasm_assembly,
        [=[    case FUNCTION_TYPE:
    case METHOD_TYPE:
      function_args_iterator it;
      tree *arg;
      fprintf (stream, "%s(param", delim);
      CUMULATIVE_ARGS args;
      INIT_CUMULATIVE_ARGS (args, type, nullptr, false, 0);
      FOREACH_FUNCTION_ARGS_PTR (type, arg, it)
      {
	function_arg_info info (*arg, stdarg_p (type));
	if (pass_by_reference (&args, info))
	  print_type (stream, intSI_type_node);
	else
	  print_type (stream, *arg);
      }
      fprintf (stream, ")");
      tree return_type = TREE_TYPE (type);
      fprintf (stream, " (result");
      if (return_type != void_type_node)
	{
	  print_type (stream, return_type);
	}
      fprintf (stream, ")");
      break;]=],
        [=[    case FUNCTION_TYPE:
    case METHOD_TYPE:
      function_args_iterator it;
      tree *arg;
      tree return_type = TREE_TYPE (type);
      bool return_by_ref = aggregate_value_p (return_type, type);
      fprintf (stream, "%s(param", delim);
      if (return_by_ref)
	print_type (stream, ptr_type_node);
      CUMULATIVE_ARGS args;
      INIT_CUMULATIVE_ARGS (args, type, nullptr, false, 0);
      FOREACH_FUNCTION_ARGS_PTR (type, arg, it)
      {
	function_arg_info info (*arg, stdarg_p (type));
	if (pass_by_reference (&args, info))
	  print_type (stream, intSI_type_node);
	else
	  print_type (stream, *arg);
      }
      fprintf (stream, ")");
      fprintf (stream, " (result");
      if (return_type != void_type_node && !return_by_ref)
	print_type (stream, return_type);
      fprintf (stream, ")");
      break;]=],
        "GCC WebAssembly Basic C ABI indirect function-type returns")
    local basic_abi_result_classification = [=[  tree type = TREE_TYPE (decl);
  tree return_type = TREE_TYPE (type);
  cfun->machine->wat_result_p
    = return_type != void_type_node
      && !TYPE_EMPTY_P (return_type)
      && !aggregate_value_p (return_type, type);
  fprintf (stream, "\n");
  int i;]=]
    local declared_result_classification = [=[  tree type = TREE_TYPE (decl);
  tree return_type = TREE_TYPE (type);
  bool return_by_ref = aggregate_value_p (return_type, type);

  machine_mode declared_return_mode = VOIDmode;
  if (return_type != void_type_node && !TYPE_EMPTY_P (return_type))
    {
      const_tree wasm_return_type = return_type;
      if (return_by_ref)
	declared_return_mode = Pmode;
      else
	{
	  if (RECORD_OR_UNION_TYPE_P (return_type)
	      && TYPE_TRANSPARENT_AGGR (return_type))
	    wasm_return_type = TREE_TYPE (first_field (return_type));
	  else if (const_tree scalar = wasm_singleton_scalar_type (return_type))
	    wasm_return_type = scalar;
	  declared_return_mode = TYPE_MODE (wasm_return_type);
	}
    }
  cfun->machine->return_mode = declared_return_mode;
  fprintf (stream, "\n");
  int i;]=]
    do
        local cached_result_classification = [=[  tree type = TREE_TYPE (decl);
  tree return_type = TREE_TYPE (type);
  bool return_by_ref = aggregate_value_p (return_type, type);
  cfun->machine->wat_result_p
    = return_type != void_type_node
      && !TYPE_EMPTY_P (return_type)
      && !return_by_ref;

  machine_mode declared_return_mode = VOIDmode;
  if (return_type != void_type_node && !TYPE_EMPTY_P (return_type))
    {
      const_tree wasm_return_type = return_type;
      if (return_by_ref)
	declared_return_mode = Pmode;
      else
	{
	  if (RECORD_OR_UNION_TYPE_P (return_type)
	      && TYPE_TRANSPARENT_AGGR (return_type))
	    wasm_return_type = TREE_TYPE (first_field (return_type));
	  else if (const_tree scalar = wasm_singleton_scalar_type (return_type))
	    wasm_return_type = scalar;
	  declared_return_mode = TYPE_MODE (wasm_return_type);
	}
    }
  cfun->machine->return_mode = declared_return_mode;
  fprintf (stream, "\n");
  int i;]=]
        if io.readfile(wasm_assembly):find(cached_result_classification, 1, true) then
            strict_replace(wasm_assembly,
                cached_result_classification,
                declared_result_classification,
                "GCC WebAssembly cached WAT result classification removal")
        end
    end
    strict_replace_migrated(wasm_assembly,
        [=[  tree type = TREE_TYPE (decl);
  fprintf (stream, "\n");
  int i;]=],
        basic_abi_result_classification,
        declared_result_classification,
        "GCC WebAssembly declared return mode classification")
    local upstream_return_instruction = [=[  if (mode == '#') /* Print the return insn.  */
    {
      if (TREE_TYPE (TREE_TYPE (cfun->decl)) != void_type_node)
	fprintf (stream, " (local.get $return)");
    }]=]
    local basic_abi_return_instruction = [=[  if (mode == '#') /* Print the return insn.  */
    {
      tree function_type = TREE_TYPE (cfun->decl);
      tree return_type = TREE_TYPE (function_type);
      if (return_type != void_type_node
	  && !TYPE_EMPTY_P (return_type)
	  && !aggregate_value_p (return_type, function_type))
	fprintf (stream, " (local.get $return)");
    }]=]
    local int128_return_instruction = [=[  if (mode == '#') /* Print the return insn.  */
    {
      tree function_type = TREE_TYPE (cfun->decl);
      tree return_type = TREE_TYPE (function_type);
      if (return_type != void_type_node
	  && !TYPE_EMPTY_P (return_type)
	  && !aggregate_value_p (return_type, function_type))
	{
	  fprintf (stream, " (local.get $return)");
	  if (TYPE_MODE (return_type) == TImode)
	    fprintf (stream, " (local.get $return_high)");
	}
    }]=]
    local lowered_return_instruction = [=[  if (mode == '#') /* Print the return insn.  */
    {
      machine_mode return_mode = cfun->machine->return_mode;
      if (return_mode != VOIDmode)
	{
	  fprintf (stream, " (local.get $return)");
	  if (return_mode == TImode)
	    fprintf (stream, " (local.get $return_high)");
	}
    }]=]
    local declared_return_instruction = [=[  if (mode == '#') /* Print the return insn.  */
    {
      tree function_type = TREE_TYPE (cfun->decl);
      tree return_type = TREE_TYPE (function_type);
      bool return_by_ref = aggregate_value_p (return_type, function_type);

      machine_mode return_mode = cfun->machine->return_mode;
      if (return_mode != VOIDmode
	  && return_type != void_type_node
	  && !TYPE_EMPTY_P (return_type)
	  && !return_by_ref)
	{
	  fprintf (stream, " (local.get $return)");
	  if (return_mode == TImode)
	    fprintf (stream, " (local.get $return_high)");
	}
    }]=]
    do
        local cached_return_instruction = [=[  if (mode == '#') /* Print the return insn.  */
    {
      machine_mode return_mode = cfun->machine->return_mode;
      if (cfun->machine->wat_result_p)
	{
	  fprintf (stream, " (local.get $return)");
	  if (return_mode == TImode)
	    fprintf (stream, " (local.get $return_high)");
	}
    }]=]
        if io.readfile(wasm_assembly):find(cached_return_instruction, 1, true) then
            strict_replace(wasm_assembly,
                cached_return_instruction,
                declared_return_instruction,
                "GCC WebAssembly cached WAT return decision removal")
        end
        cached_return_instruction = [=[  if (mode == '#') /* Print the return insn.  */
    {
      tree function_type = TREE_TYPE (cfun->decl);
      tree return_type = TREE_TYPE (function_type);
      bool return_by_ref = aggregate_value_p (return_type, function_type);
      if (return_type != void_type_node
	  && !TYPE_EMPTY_P (return_type)
	  && !return_by_ref)
	{
	  machine_mode return_mode = cfun->machine->return_mode;
	  fprintf (stream, " (local.get $return)");
	  if (return_mode == TImode)
	    fprintf (stream, " (local.get $return_high)");
	}
    }]=]
        if io.readfile(wasm_assembly):find(cached_return_instruction, 1, true) then
            strict_replace(wasm_assembly,
                cached_return_instruction,
                declared_return_instruction,
                "GCC WebAssembly undeclared return local guard")
        end
    end
    if io.readfile(wasm_assembly):find(basic_abi_return_instruction, 1, true) then
        strict_replace(wasm_assembly,
            basic_abi_return_instruction,
            declared_return_instruction,
            "GCC WebAssembly lowered return instruction migration")
    end
    if io.readfile(wasm_assembly):find(lowered_return_instruction, 1, true) then
        strict_replace(wasm_assembly,
            lowered_return_instruction,
            declared_return_instruction,
            "GCC WebAssembly declared return instruction migration")
    end
    strict_replace_migrated(wasm_assembly,
        upstream_return_instruction,
        int128_return_instruction,
        declared_return_instruction,
        "GCC WebAssembly machine-ABI return instruction")

    strict_replace(wasm_assembly,
        [=[  else if (mode == 'A') /* Print a call insn arglist.  */
    {
      gcc_assert (GET_CODE (value) == PARALLEL);
      int len = XVECLEN (value, 0);
      for (int i = 1; i < len; ++i)
	{
	  rtx arg = XVECEXP (value, 0, i);
	  gcc_assert (GET_CODE (arg) == USE);
	  rtx reg = XEXP (arg, 0);
	  gcc_assert (GET_CODE (reg) == REG);
	  fprintf (stream, " ");
	  wasm_print_operand (stream, reg, 'i');
	}
    }]=],
        [=[  else if (mode == 'A') /* Print a call insn arglist.  */
    {
      gcc_assert (GET_CODE (value) == PARALLEL);
      int len = XVECLEN (value, 0);
      int arg_begin = len > 1 && GET_CODE (XVECEXP (value, 0, 1)) == SET
	? 2 : 1;
      for (int i = arg_begin; i < len; ++i)
	{
	  rtx arg = XVECEXP (value, 0, i);
	  gcc_assert (GET_CODE (arg) == USE);
	  rtx reg = XEXP (arg, 0);
	  gcc_assert (GET_CODE (reg) == REG);
	  fprintf (stream, " ");
	  wasm_print_operand (stream, reg, 'i');
	}
    }]=],
        "GCC WebAssembly multi-value call argument printing")
    strict_replace(wasm_assembly,
        [=[  else if (mode == 'T') /* Print an arglist type.  */
    {
      if (GET_CODE (value) == PARALLEL)
	{
	  int len = XVECLEN (value, 0);
	  for (int i = 1; i < len; ++i)
	    {
	      rtx arg = XVECEXP (value, 0, i);
	      gcc_assert (GET_CODE (arg) == USE);
	      rtx reg = XEXP (arg, 0);
	      gcc_assert (GET_CODE (reg) == REG);
	      wasm_print_operand (stream, reg, mode);
	    }
	}
      else if (REG_P (value))
	print_type (stream,
		    lang_hooks.types.type_for_mode (GET_MODE (value), 0));
      else
	gcc_unreachable ();
    }]=],
        [=[  else if (mode == 'T') /* Print an arglist type.  */
    {
      if (GET_CODE (value) == PARALLEL)
	{
	  int len = XVECLEN (value, 0);
	  int arg_begin = len > 1 && GET_CODE (XVECEXP (value, 0, 1)) == SET
	    ? 2 : 1;
	  for (int i = arg_begin; i < len; ++i)
	    {
	      rtx arg = XVECEXP (value, 0, i);
	      gcc_assert (GET_CODE (arg) == USE);
	      rtx reg = XEXP (arg, 0);
	      gcc_assert (GET_CODE (reg) == REG);
	      wasm_print_operand (stream, reg, mode);
	    }
	}
      else if (REG_P (value))
	print_type (stream,
		    lang_hooks.types.type_for_mode (GET_MODE (value), 0));
      else
	gcc_unreachable ();
    }]=],
        "GCC WebAssembly multi-value call argument type printing")
end

function _apply_target_identity(ctx)
    local src = ctx.src
    local function strict_replace(file, original, replacement, label)
        return shared.strict_replace(ctx, file, original, replacement, label)
    end
    local function strict_replace_migrated(file, original, previous, replacement, label)
        return shared.strict_replace_migrated(ctx, file, original, previous, replacement, label)
    end
    local function strict_write_new(file, content, label)
        return shared.strict_write_new(ctx, file, content, label)
    end
    local function strict_write_owned(file, content, ownership_marker, label)
        return shared.strict_write_owned(ctx, file, content, ownership_marker, label)
    end

    do
    local config_gcc = path.join(src, "gcc", "config.gcc")
    local previous_wasm_os_dispatch =
        "wasm*-*-emscripten*)\n\ttm_file=\"${tm_file} wasm/wasm-emscripten.h\"\n\tuse_gcc_stdint=wrap\n\t;;\n" ..
        "wasm*-*-wasi*)\n\ttm_file=\"${tm_file} wasm/wasm-wasi.h\"\n\tuse_gcc_stdint=wrap\n\t;;\n" ..
        "wasm*-*-*)\n\tuse_gcc_stdint=wrap\n\t;;"
    local wasm_os_dispatch =
        "wasm*-*-emscripten*)\n\ttm_file=\"${tm_file} wasm/wasm-emscripten.h\"\n" ..
        "\textra_options=\"${extra_options} wasm/wasm-emscripten.opt\"\n" ..
        "\tuse_gcc_stdint=wrap\n\t;;\n" ..
        "wasm*-*-wasi*)\n\ttm_file=\"${tm_file} wasm/wasm-wasi.h\"\n\tuse_gcc_stdint=wrap\n\t;;\n" ..
        "wasm*-*-*)\n\tuse_gcc_stdint=wrap\n\t;;"
    strict_replace_migrated(config_gcc,
        "wasm*-*-*)\n\tuse_gcc_stdint=wrap\n\t;;",
        previous_wasm_os_dispatch,
        wasm_os_dispatch,
        "GCC WebAssembly Emscripten and WASI target identity dispatch")
    end

    strict_write_owned(path.join(src, "gcc", "config", "wasm", "wasm-emscripten.h"),
        "/* Target identity and Emscripten pthread ABI for WebAssembly.  */\n" ..
        "#ifndef GCC_WASM_EMSCRIPTEN_H\n" ..
        "#define GCC_WASM_EMSCRIPTEN_H\n\n" ..
        "#undef TARGET_OS_CPP_BUILTINS\n" ..
        "#define TARGET_OS_CPP_BUILTINS()             \\\n" ..
        "  do                                         \\\n" ..
        "    {                                        \\\n" ..
        "      builtin_define (\"__EMSCRIPTEN__\");    \\\n" ..
        "      if (c_dialect_cxx ())                  \\\n" ..
        "        builtin_define (\"_Noreturn=__attribute__((__noreturn__))\"); \\\n" ..
        "      builtin_assert (\"system=emscripten\"); \\\n" ..
        "    }                                        \\\n" ..
        "  while (0)\n\n" ..
        "#undef CPP_SPEC\n" ..
        "#define CPP_SPEC \"%{pthread:-D_REENTRANT -D__EMSCRIPTEN_PTHREADS__}\"\n" ..
        "#undef CPLUSPLUS_CPP_SPEC\n" ..
        "#define CPLUSPLUS_CPP_SPEC \"-D_GNU_SOURCE %(cpp)\"\n\n" ..
        "#undef INT_FAST16_TYPE\n" ..
        "#define INT_FAST16_TYPE \"int\"\n" ..
        "#undef UINT_FAST16_TYPE\n" ..
        "#define UINT_FAST16_TYPE \"unsigned int\"\n" ..
        "#undef WINT_TYPE\n" ..
        "#define WINT_TYPE \"int\"\n\n" ..
        "#undef STANDARD_STARTFILE_PREFIX_1\n" ..
        "#define STANDARD_STARTFILE_PREFIX_1 \"\"\n" ..
        "#undef STARTFILE_SPEC\n" ..
        "#define STARTFILE_SPEC \"\"\n" ..
        "#undef ENDFILE_SPEC\n" ..
        "#define ENDFILE_SPEC \"\"\n" ..
        "#undef LIB_SPEC\n" ..
        "#define LIB_SPEC \"\"\n" ..
        "#undef LINK_SPEC\n" ..
        "#define LINK_SPEC \"--no-entry %{!o:-o a.out}\"\n\n" ..
        "#endif /* GCC_WASM_EMSCRIPTEN_H */\n",
        "Target identity",
        "GCC WebAssembly Emscripten subtarget header")

    strict_write_owned(path.join(src, "gcc", "config", "wasm", "wasm-emscripten.opt"),
        "; Emscripten driver options for the experimental GCC WebAssembly target.\n\n" ..
        "pthread\n" ..
        "Driver\n" ..
        "Compile for the Emscripten pthread runtime.\n",
        "Emscripten driver options",
        "GCC WebAssembly Emscripten driver options")
    strict_write_owned(path.join(src, "gcc", "config", "wasm", "wasm-emscripten.opt.urls"),
        "; Companion URL metadata for wasm-emscripten.opt.\n\n" ..
        "; skipping UrlSuffix for 'pthread' because GCC documents it in both\n" ..
        "; the link-options and preprocessor-options sections.\n",
        "Companion URL metadata",
        "GCC WebAssembly Emscripten driver option URLs")

    do
    local contracts_source = path.join(src, "gcc", "cp", "contracts.cc")
    strict_replace(contracts_source,
        [=[  tree fnbody;
  if (TYPE_NOEXCEPT_P (TREE_TYPE (fndecl)))
    {
      tree m_n_t_expr = expr_first (DECL_SAVED_TREE (fndecl));
      gcc_checking_assert (TREE_CODE (m_n_t_expr) == MUST_NOT_THROW_EXPR);
      fnbody = TREE_OPERAND (m_n_t_expr, 0);
      TREE_OPERAND (m_n_t_expr, 0) = push_stmt_list ();
    }
  else
    {
      fnbody = DECL_SAVED_TREE (fndecl);
      DECL_SAVED_TREE (fndecl) = push_stmt_list ();
    }]=],
        [=[  tree fnbody;
  tree m_n_t_expr = NULL_TREE;
  if (TYPE_NOEXCEPT_P (TREE_TYPE (fndecl)))
    m_n_t_expr = expr_first (DECL_SAVED_TREE (fndecl));
  if (m_n_t_expr && TREE_CODE (m_n_t_expr) == MUST_NOT_THROW_EXPR)
    {
      fnbody = TREE_OPERAND (m_n_t_expr, 0);
      TREE_OPERAND (m_n_t_expr, 0) = push_stmt_list ();
    }
  else
    {
      fnbody = DECL_SAVED_TREE (fndecl);
      DECL_SAVED_TREE (fndecl) = push_stmt_list ();
    }]=],
        "GCC WebAssembly contracts noexcept body-shape tolerance")
    end

    strict_write_new(path.join(src, "gcc", "config", "wasm", "wasm-wasi.h"),
        "/* Target identity for the WASI form of the experimental backend.  */\n" ..
        "#ifndef GCC_WASM_WASI_H\n" ..
        "#define GCC_WASM_WASI_H\n\n" ..
        "#undef TARGET_OS_CPP_BUILTINS\n" ..
        "#define TARGET_OS_CPP_BUILTINS()       \\\n" ..
        "  do                                   \\\n" ..
        "    {                                  \\\n" ..
        "      builtin_define (\"__wasi__\");   \\\n" ..
        "      builtin_assert (\"system=wasi\"); \\\n" ..
        "    }                                  \\\n" ..
        "  while (0)\n\n" ..
        "#endif /* GCC_WASM_WASI_H */\n",
        "GCC WebAssembly WASI subtarget header")
end

function _apply_libgcc(ctx)
    local src = ctx.src
    local function strict_replace(file, original, replacement, label)
        return shared.strict_replace(ctx, file, original, replacement, label)
    end
    local function strict_write_owned(file, content, ownership_marker, label)
        return shared.strict_write_owned(ctx, file, content, ownership_marker, label)
    end

    local libgcc2 = path.join(src, "libgcc", "libgcc2.c")
    strict_replace(libgcc2,
        "/* Work out the largest \"word\" size that we can deal with on this target.  */\n" ..
        "#if MIN_UNITS_PER_WORD > 4\n" ..
        "# define LIBGCC2_MAX_UNITS_PER_WORD 8\n" ..
        "#elif (MIN_UNITS_PER_WORD > 2 \\\n" ..
        "       || (MIN_UNITS_PER_WORD > 1 && __SIZEOF_LONG_LONG__ > 4))\n" ..
        "# define LIBGCC2_MAX_UNITS_PER_WORD 4\n" ..
        "#else\n" ..
        "# define LIBGCC2_MAX_UNITS_PER_WORD MIN_UNITS_PER_WORD\n" ..
        "#endif",
        "/* Work out the largest \"word\" size that we can deal with on this target.\n" ..
        "   Target-owned supplementary sources may select a wider supported mode.  */\n" ..
        "#ifndef LIBGCC2_MAX_UNITS_PER_WORD\n" ..
        "# if MIN_UNITS_PER_WORD > 4\n" ..
        "#  define LIBGCC2_MAX_UNITS_PER_WORD 8\n" ..
        "# elif (MIN_UNITS_PER_WORD > 2 \\\n" ..
        "         || (MIN_UNITS_PER_WORD > 1 && __SIZEOF_LONG_LONG__ > 4))\n" ..
        "#  define LIBGCC2_MAX_UNITS_PER_WORD 4\n" ..
        "# else\n" ..
        "#  define LIBGCC2_MAX_UNITS_PER_WORD MIN_UNITS_PER_WORD\n" ..
        "# endif\n" ..
        "#endif",
        "GCC libgcc target-owned supplementary word size")

    local libgcc2_header = path.join(src, "libgcc", "libgcc2.h")
    strict_replace(libgcc2_header,
        "#if MIN_UNITS_PER_WORD > 4\n" ..
        "/* These typedefs are usually forbidden on archs with UNITS_PER_WORD 4.  */\n" ..
        "typedef\t\t int TItype\t__attribute__ ((mode (TI)));",
        "#if MIN_UNITS_PER_WORD > 4 || LIBGCC2_MAX_UNITS_PER_WORD > 4\n" ..
        "/* Supplementary target sources can explicitly select the supported TI mode.  */\n" ..
        "typedef\t\t int TItype\t__attribute__ ((mode (TI)));",
        "GCC libgcc supplementary 128-bit integer mode types")

    strict_write_owned(path.join(src, "libgcc", "config", "wasm", "int128.c"),
        "/* WebAssembly 128-bit integer libcalls selected from generic libgcc2.  */\n" ..
        "#define LIBGCC2_GNU_PREFIX 1\n" ..
        "#define LIBGCC2_MAX_UNITS_PER_WORD 8\n" ..
        "#define LIBGCC2_UNITS_PER_WORD 8\n" ..
        "#define L_clz\n" ..
        "#define L_muldi3\n" ..
        "#define L_divdi3\n" ..
        "#define L_udivdi3\n" ..
        "#define L_moddi3\n" ..
        "#define L_umoddi3\n" ..
        "#include \"../../libgcc2.c\"\n",
        "WebAssembly 128-bit integer libcalls selected from generic libgcc2.",
        "GCC WebAssembly 128-bit integer libgcc source")

    strict_write_owned(path.join(src, "libgcc", "config", "wasm", "memory.c"),
        gccwasmcompat.runtime_source(),
        "for the no-libc WebAssembly profile.",
        "GCC WebAssembly no-libc single-thread runtime source")

    strict_write_owned(path.join(src, "libgcc", "config", "wasm", "unwind-abort.c"),
        gccwasmcompat.unwind_abort_source(),
        "WebAssembly no-unwind runtime for hosted Emscripten links.",
        "GCC WebAssembly hosted no-unwind runtime source")

    strict_write_owned(path.join(src, "libstdc++-v3", "include", "bits",
            "wasm_freestanding_hosted_compat.h"),
        gccwasmcompat.hosted_compat_header(),
        "Experimental hosted-surface compatibility for freestanding WebAssembly.",
        "GCC WebAssembly extended freestanding hosted-surface header")

    local wasm_libgcc_make = path.join(src, "libgcc", "config", "wasm", "t-wasm")
    local wasm_libgcc_final =
        "LIB2ADDEH=\n" ..
        "LIB2ADD += $(srcdir)/config/wasm/int128.c\n" ..
        "LIB2ADD += $(srcdir)/config/wasm/unwind-abort.c\n" ..
        "LIBGCC2_CFLAGS += -fno-builtin\n\n" ..
        "# Debug information is not yet supported"
    if not io.readfile(wasm_libgcc_make):find(wasm_libgcc_final, 1, true) then
        local wasm_libgcc_current =
            "LIB2ADDEH=\n" ..
            "LIB2ADD += $(srcdir)/config/wasm/int128.c\n" ..
            "LIBGCC2_CFLAGS += -fno-builtin\n\n" ..
            "# Debug information is not yet supported"
        local wasm_libgcc_legacy =
            "LIB2ADDEH=\n" ..
            "LIB2ADD += $(srcdir)/config/wasm/int128.c\n" ..
            "LIB2ADD += $(srcdir)/config/wasm/memory.c\n" ..
            "LIBGCC2_CFLAGS += -fno-builtin\n\n" ..
            "# Debug information is not yet supported"
        local wasm_libgcc_content = io.readfile(wasm_libgcc_make)
        if wasm_libgcc_content:find(wasm_libgcc_current, 1, true) then
            strict_replace(wasm_libgcc_make, wasm_libgcc_current, wasm_libgcc_final,
                "GCC WebAssembly hosted no-unwind libgcc build fragment")
        elseif wasm_libgcc_content:find(wasm_libgcc_legacy, 1, true) then
            strict_replace(wasm_libgcc_make, wasm_libgcc_legacy, wasm_libgcc_final,
                "GCC WebAssembly hosted no-unwind libgcc build fragment migration")
        else
            strict_replace(wasm_libgcc_make,
                "LIB2ADDEH=\n\n" ..
                "# Debug information is not yet supported",
                wasm_libgcc_final,
                "GCC WebAssembly hosted no-unwind libgcc build fragment")
        end
    end

    strict_replace(path.join(src, "libgcc", "gthr.h"),
        [=[#ifdef __MINGW32__
#undef GTHREAD_USE_WEAK
#define GTHREAD_USE_WEAK 0
#endif]=],
        [=[#ifdef __MINGW32__
#undef GTHREAD_USE_WEAK
#define GTHREAD_USE_WEAK 0
#endif

/* The experimental WebAssembly assembler cannot represent weak imports.
   Emscripten pthread entry points are supplied by the final emcc link.  */
#ifdef __EMSCRIPTEN__
#undef GTHREAD_USE_WEAK
#define GTHREAD_USE_WEAK 0
#endif]=],
        "GCC WebAssembly Emscripten strong gthread imports")

    do
        local libgcc_config_host = path.join(src, "libgcc", "config.host")
        local generic_wasm_libgcc =
            "wasm*-*-*)\n" ..
            "\ttmake_file=\"$tmake_file wasm/t-wasm\"\n" ..
            "\t# unwind_header=config/no-unwind.h\n" ..
            "\t# extra_parts=\"crt0.o\"\n" ..
            "\t;;"
        local emscripten_wasm_libgcc =
            "wasm*-*-emscripten*)\n" ..
            "\ttmake_file=\"$tmake_file wasm/t-wasm t-gthr-noweak\"\n" ..
            "\t# Emscripten pthread symbols are mandatory under -pthread; weak\n" ..
            "\t# imports are not representable by the experimental WAT assembler.\n" ..
            "\t;;\n" ..
            generic_wasm_libgcc
        strict_replace(libgcc_config_host,
            generic_wasm_libgcc,
            emscripten_wasm_libgcc,
            "GCC WebAssembly Emscripten strong pthread imports")
    end
end

function _apply_libstdcxx_config(ctx)
    local src = ctx.src
    local function strict_replace(file, original, replacement, label)
        return shared.strict_replace(ctx, file, original, replacement, label)
    end
    local function strict_replace_migrated(file, original, previous, replacement, label)
        return shared.strict_replace_migrated(ctx, file, original, previous, replacement, label)
    end

    strict_replace(path.join(src, "libstdc++-v3", "configure.host"),
        "case \"${host}\" in\n" ..
        "  amdgcn-*-amdhsa \\\n" ..
        "  | nvptx-*-none )",
        "case \"${host}\" in\n" ..
        "  amdgcn-*-amdhsa \\\n" ..
        "  | nvptx-*-none \\\n" ..
        "  | wasm*-*-* )",
        "GCC WebAssembly freestanding libstdc++ exception and RTTI flags")

    strict_replace(path.join(src, "libstdc++-v3", "configure.host"),
        "  dragonfly*)\n" ..
        "    os_include_dir=\"os/bsd/dragonfly\"\n" ..
        "    ;;\n" ..
        "  freebsd*)",
        "  dragonfly*)\n" ..
        "    os_include_dir=\"os/bsd/dragonfly\"\n" ..
        "    ;;\n" ..
        "  emscripten*)\n" ..
        "    # GCC lowers these builtins to __atomic_* calls; the final emcc\n" ..
        "    # link resolves them to compiler-rt implementations using wasm atomics.\n" ..
        "    os_include_dir=\"os/generic\"\n" ..
        "    atomicity_dir=\"cpu/generic/atomicity_builtins\"\n" ..
        "    ;;\n" ..
        "  freebsd*)",
        "GCC WebAssembly Emscripten libstdc++ compiler-rt atomics")

    do
        local emscripten_c99_math_functions = {
            "acosf", "acosl", "asinf", "asinl", "atanf", "atanl", "atan2f", "atan2l",
            "ceilf", "ceill", "cosf", "cosl", "coshf", "coshl", "expf", "expl",
            "fabsf", "fabsl", "floorf", "floorl", "fmodf", "fmodl", "frexpf", "frexpl",
            "ldexpf", "ldexpl", "logf", "logl", "log10f", "log10l", "modff", "modfl",
            "powf", "powl", "sinf", "sinl", "sinhf", "sinhl", "sqrtf", "sqrtl",
            "tanf", "tanl", "tanhf", "tanhl"
        }
        local m4_math_definitions = {}
        local configure_math_definitions = {}
        for _, function_name in ipairs(emscripten_c99_math_functions) do
            local macro_name = "HAVE_" .. function_name:upper()
            table.insert(m4_math_definitions, "    AC_DEFINE(" .. macro_name .. ")\n")
            table.insert(configure_math_definitions,
                "    $as_echo \"#define " .. macro_name .. " 1\" >>confdefs.h\n\n")
        end

        local m4_fuchsia =
            "  *-fuchsia*)\n" ..
            "    SECTION_FLAGS='-ffunction-sections -fdata-sections'\n" ..
            "    AC_SUBST(SECTION_FLAGS)\n" ..
            "    ;;"
        local previous_m4_emscripten =
            "  wasm*-*-emscripten*)\n" ..
            "    SECTION_FLAGS='-ffunction-sections -fdata-sections'\n" ..
            "    AC_SUBST(SECTION_FLAGS)\n" ..
            "    AC_DEFINE(HAVE_TLS, 1,\n" ..
            "      [Define to 1 because GCC uses libgcc emutls for this target.])\n" ..
            "    ;;"
        local m4_emscripten =
            "  wasm*-*-emscripten*)\n" ..
            "    SECTION_FLAGS='-ffunction-sections -fdata-sections'\n" ..
            "    AC_SUBST(SECTION_FLAGS)\n" ..
            "    # Emscripten's musl headers and final emcc runtime provide the C99\n" ..
            "    # float and long double math entry points. Target links are not\n" ..
            "    # available during this GCC cross configure, so record them here.\n" ..
            table.concat(m4_math_definitions) ..
            "    AC_DEFINE(HAVE_TLS, 1,\n" ..
            "      [Define to 1 because GCC uses libgcc emutls for this target.])\n" ..
            "    ;;"
        strict_replace_migrated(path.join(src, "libstdc++-v3", "crossconfig.m4"),
            m4_fuchsia,
            previous_m4_emscripten .. "\n\n" .. m4_fuchsia,
            m4_emscripten .. "\n\n" .. m4_fuchsia,
            "GCC WebAssembly Emscripten hosted libstdc++ cross configuration")

        local configure_fuchsia =
            "  *-fuchsia*)\n" ..
            "    SECTION_FLAGS='-ffunction-sections -fdata-sections'\n\n" ..
            "    ;;"
        local previous_configure_emscripten =
            "  wasm*-*-emscripten*)\n" ..
            "    SECTION_FLAGS='-ffunction-sections -fdata-sections'\n" ..
            "    $as_echo \"#define HAVE_TLS 1\" >>confdefs.h\n\n" ..
            "    ;;"
        local configure_emscripten =
            "  wasm*-*-emscripten*)\n" ..
            "    SECTION_FLAGS='-ffunction-sections -fdata-sections'\n" ..
            "    # Emscripten's musl headers and final emcc runtime provide the C99\n" ..
            "    # float and long double math entry points. Target links are not\n" ..
            "    # available during this GCC cross configure, so record them here.\n" ..
            table.concat(configure_math_definitions) ..
            "    $as_echo \"#define HAVE_TLS 1\" >>confdefs.h\n\n" ..
            "    ;;"
        strict_replace_migrated(path.join(src, "libstdc++-v3", "configure"),
            configure_fuchsia,
            previous_configure_emscripten .. "\n\n" .. configure_fuchsia,
            configure_emscripten .. "\n\n" .. configure_fuchsia,
            "GCC WebAssembly generated Emscripten hosted libstdc++ cross configuration")
    end

    strict_replace(path.join(src, "libstdc++-v3", "acinclude.m4"),
        "      darwin*)\n" ..
        "        ac_has_nanosleep=yes\n" ..
        "        ac_has_sched_yield=yes\n" ..
        "        ;;",
        "      darwin*)\n" ..
        "        ac_has_nanosleep=yes\n" ..
        "        ac_has_sched_yield=yes\n" ..
        "        ;;\n" ..
        "      emscripten*)\n" ..
        "        ac_has_clock_monotonic=yes\n" ..
        "        ac_has_clock_realtime=yes\n" ..
        "        ac_has_nanosleep=yes\n" ..
        "        ac_has_sched_yield=yes\n" ..
        "        ;;",
        "GCC WebAssembly Emscripten libstdc++ time support")
    strict_replace(path.join(src, "libstdc++-v3", "configure"),
        "      darwin*)\n" ..
        "        ac_has_nanosleep=yes\n" ..
        "        ac_has_sched_yield=yes\n" ..
        "        ;;",
        "      darwin*)\n" ..
        "        ac_has_nanosleep=yes\n" ..
        "        ac_has_sched_yield=yes\n" ..
        "        ;;\n" ..
        "      emscripten*)\n" ..
        "        ac_has_clock_monotonic=yes\n" ..
        "        ac_has_clock_realtime=yes\n" ..
        "        ac_has_nanosleep=yes\n" ..
        "        ac_has_sched_yield=yes\n" ..
        "        ;;",
        "GCC WebAssembly generated Emscripten libstdc++ time support")

    -- The WAT backend does not implement assembler aliases. Preserve the
    -- libsupc++ ABI entry point as a real forwarding function instead.
    local libstdcxx_tinfo = path.join(src, "libstdc++-v3", "libsupc++", "tinfo.cc")
    strict_replace(libstdcxx_tinfo,
        [=[bool
std::type_info::__equal (const std::type_info& arg) const _GLIBCXX_NOEXCEPT
__attribute__((alias("_ZNKSt9type_infoeqERKS_")));]=],
        [=[bool
std::type_info::__equal (const std::type_info& arg) const _GLIBCXX_NOEXCEPT
{
  return *this == arg;
}]=],
        "GCC WebAssembly libsupc++ type_info alias fallback")
end

function _apply_freestanding_headers(ctx)
    local src = ctx.src
    local function strict_replace(file, original, replacement, label)
        return shared.strict_replace(ctx, file, original, replacement, label)
    end
    local function strict_replace_migrated(file, original, previous, replacement, label)
        return shared.strict_replace_migrated(ctx, file, original, previous, replacement, label)
    end
    local wasm_freestanding_include_headers_changed = false

    -- C++26 exposes std::function_ref for freestanding implementations,
    -- and <functional> includes these two implementation headers whenever
    -- that feature is enabled. The experimental branch still classifies
    -- them as hosted-only, so its freestanding install is internally
    -- inconsistent even though the implementation itself is feature-
    -- guarded. Move them into bits_freestanding; hosted installs already
    -- include that complete list and therefore keep the same header set.
    local libstdcxx_include_make_am = path.join(src, "libstdc++-v3", "include", "Makefile.am")
    local libstdcxx_include_make_in = path.join(src, "libstdc++-v3", "include", "Makefile.in")
    local cxx26_wrapper_make_am_before = io.readfile(libstdcxx_include_make_am)
    local cxx26_wrapper_make_in_before = io.readfile(libstdcxx_include_make_in)
    local original_freestanding_wrapper_headers =
        "\t${bits_srcdir}/functional_hash.h \\\n" ..
        "\t${bits_srcdir}/intcmp.h \\\n"
    local previous_freestanding_wrapper_headers =
        "\t${bits_srcdir}/functional_hash.h \\\n" ..
        "\t${bits_srcdir}/funcref_impl.h \\\n" ..
        "\t${bits_srcdir}/funcwrap.h \\\n" ..
        "\t${bits_srcdir}/intcmp.h \\\n"
    local freestanding_wrapper_headers =
        "\t${bits_srcdir}/functional_hash.h \\\n" ..
        "\t${bits_srcdir}/funcref_impl.h \\\n" ..
        "\t${bits_srcdir}/funcwrap.h \\\n" ..
        "\t${bits_srcdir}/indirect.h \\\n" ..
        "\t${bits_srcdir}/intcmp.h \\\n"
    local freestanding_wrapper_headers_with_hosted_compat =
        "\t${bits_srcdir}/functional_hash.h \\\n" ..
        "\t${bits_srcdir}/funcref_impl.h \\\n" ..
        "\t${bits_srcdir}/funcwrap.h \\\n" ..
        "\t${bits_srcdir}/wasm_freestanding_hosted_compat.h \\\n" ..
        "\t${bits_srcdir}/indirect.h \\\n" ..
        "\t${bits_srcdir}/intcmp.h \\\n"
    local freestanding_wrapper_headers_with_hosted_compat_and_hash =
        "\t${bits_srcdir}/functional_hash.h \\\n" ..
        "\t${bits_srcdir}/hashtable.h \\\n" ..
        "\t${bits_srcdir}/hashtable_policy.h \\\n" ..
        "\t${bits_srcdir}/funcref_impl.h \\\n" ..
        "\t${bits_srcdir}/funcwrap.h \\\n" ..
        "\t${bits_srcdir}/wasm_freestanding_hosted_compat.h \\\n" ..
        "\t${bits_srcdir}/indirect.h \\\n" ..
        "\t${bits_srcdir}/intcmp.h \\\n"
    for _, makefile in ipairs({libstdcxx_include_make_am, libstdcxx_include_make_in}) do
        local makefile_content = io.readfile(makefile)
        if not makefile_content:find(
                freestanding_wrapper_headers_with_hosted_compat, 1, true)
            and not makefile_content:find(
                freestanding_wrapper_headers_with_hosted_compat_and_hash, 1, true) then
            strict_replace_migrated(makefile,
                original_freestanding_wrapper_headers,
                previous_freestanding_wrapper_headers,
                freestanding_wrapper_headers,
                "GCC WebAssembly freestanding libstdc++ C++26 wrapper headers")
        end
    end
    strict_replace(libstdcxx_include_make_am,
        "\t${bits_srcdir}/fstream.tcc \\\n" ..
        "\t${bits_srcdir}/funcref_impl.h \\\n" ..
        "\t${bits_srcdir}/funcwrap.h \\\n" ..
        "\t${bits_srcdir}/gslice.h \\\n",
        "\t${bits_srcdir}/fstream.tcc \\\n" ..
        "\t${bits_srcdir}/gslice.h \\\n",
        "GCC WebAssembly hosted libstdc++ function_ref header deduplication")
    strict_replace(libstdcxx_include_make_in,
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/fstream.tcc \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/funcref_impl.h \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/funcwrap.h \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/gslice.h \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/fstream.tcc \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/gslice.h \\\n",
        "GCC WebAssembly configured hosted libstdc++ function_ref header deduplication")
    -- <memory> includes bits/indirect.h unconditionally in C++26, even
    -- though that header keeps std::indirect and std::polymorphic disabled
    -- for non-hosted implementations. Install the feature-dispatch wrapper
    -- itself for freestanding profiles; its hosted dependencies remain
    -- behind the inactive feature macros.
    local function remove_hosted_cxx26_memory_wrapper(makefile, prefix, label)
        local hash_deduplicated =
            prefix .. "\t${bits_srcdir}/gslice_array.h \\\n" ..
            prefix .. "\t${bits_srcdir}/indirect_array.h \\\n"
        if not io.readfile(makefile):find(hash_deduplicated, 1, true) then
            strict_replace(makefile,
                prefix .. "\t${bits_srcdir}/hashtable_policy.h \\\n" ..
                prefix .. "\t${bits_srcdir}/indirect.h \\\n" ..
                prefix .. "\t${bits_srcdir}/indirect_array.h \\\n",
                prefix .. "\t${bits_srcdir}/hashtable_policy.h \\\n" ..
                prefix .. "\t${bits_srcdir}/indirect_array.h \\\n",
                label)
        end
    end
    remove_hosted_cxx26_memory_wrapper(libstdcxx_include_make_am, "",
        "GCC WebAssembly hosted libstdc++ C++26 memory wrapper deduplication")
    remove_hosted_cxx26_memory_wrapper(libstdcxx_include_make_in, "@GLIBCXX_HOSTED_TRUE@",
        "GCC WebAssembly configured hosted libstdc++ C++26 memory wrapper deduplication")
    for _, makefile in ipairs({libstdcxx_include_make_am, libstdcxx_include_make_in}) do
        strict_replace(makefile,
            "\t${std_srcdir}/string_view \\\n" ..
            "\t${std_srcdir}/tuple \\\n",
            "\t${std_srcdir}/string_view \\\n" ..
            "\t${std_srcdir}/stdexcept \\\n" ..
            "\t${std_srcdir}/tuple \\\n",
            "GCC WebAssembly freestanding stdexcept header")
    end
    strict_replace(libstdcxx_include_make_am,
        "\t${std_srcdir}/stacktrace \\\n" ..
        "\t${std_srcdir}/stdexcept \\\n" ..
        "\t${std_srcdir}/stdfloat \\\n",
        "\t${std_srcdir}/stacktrace \\\n" ..
        "\t${std_srcdir}/stdfloat \\\n",
        "GCC WebAssembly hosted stdexcept header deduplication")
    strict_replace(libstdcxx_include_make_in,
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/stacktrace \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/stdexcept \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/stdfloat \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/stacktrace \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/stdfloat \\\n",
        "GCC WebAssembly configured hosted stdexcept header deduplication")
    local freestanding_cxx26_wrapper_headers_changed = cxx26_wrapper_make_am_before
        ~= io.readfile(libstdcxx_include_make_am)
        or cxx26_wrapper_make_in_before ~= io.readfile(libstdcxx_include_make_in)

    do
        -- The Engine only needs the single-thread ownership core of
        -- shared_ptr. Its implementation is libc-independent, but the
        -- upstream freestanding profile neither installs the supporting
        -- headers nor includes them from <memory>. Keep atomic<shared_ptr>
        -- hosted-only because that layer depends on the thread runtime.
        local libstdcxx_memory = path.join(src, "libstdc++-v3", "include", "std", "memory")
        local libstdcxx_iosfwd = path.join(src, "libstdc++-v3", "include", "bits", "iosfwd.h")
        local libstdcxx_shared_ptr = path.join(src, "libstdc++-v3", "include", "bits", "shared_ptr.h")
        local shared_ptr_memory_before = io.readfile(libstdcxx_memory)
        local shared_ptr_iosfwd_before = io.readfile(libstdcxx_iosfwd)
        local shared_ptr_header_before = io.readfile(libstdcxx_shared_ptr)
        local shared_ptr_make_am_before = io.readfile(libstdcxx_include_make_am)
        local shared_ptr_make_in_before = io.readfile(libstdcxx_include_make_in)
        strict_replace(libstdcxx_memory,
            "# if _GLIBCXX_HOSTED\n" ..
            "#  include <bits/shared_ptr.h>\n" ..
            "#  include <bits/shared_ptr_atomic.h>\n" ..
            "# endif",
            "# if _GLIBCXX_HOSTED || defined(__wasm32__)\n" ..
            "#  include <bits/shared_ptr.h>\n" ..
            "# endif\n" ..
            "# if _GLIBCXX_HOSTED\n" ..
            "#  include <bits/shared_ptr_atomic.h>\n" ..
            "# endif",
            "GCC WebAssembly freestanding shared pointer availability")
        local wasm_iosfwd_hosted_guard =
            "#if !defined(__wasm32__)\n" ..
            "#include <bits/requires_hosted.h> // iostreams\n" ..
            "#endif"
        if io.readfile(libstdcxx_iosfwd):find(wasm_iosfwd_hosted_guard, 1, true) then
            strict_replace(libstdcxx_iosfwd,
                wasm_iosfwd_hosted_guard,
                "#include <bits/requires_hosted.h> // iostreams",
                "GCC WebAssembly stream forward declaration guard migration")
        end
        strict_replace(libstdcxx_shared_ptr,
            "#include <bits/iosfwd.h>",
            [=[#if defined(__wasm32__)
#include <bits/c++config.h>
namespace std _GLIBCXX_VISIBILITY(default)
{
_GLIBCXX_BEGIN_NAMESPACE_VERSION
  template<typename _CharT, typename _Traits>
    class basic_ostream;
_GLIBCXX_END_NAMESPACE_VERSION
}
#else
#include <bits/iosfwd.h>
#endif]=],
            "GCC WebAssembly freestanding shared pointer stream declaration")
        for _, makefile in ipairs({libstdcxx_include_make_am, libstdcxx_include_make_in}) do
            strict_replace(makefile,
                "\t${bits_srcdir}/align.h \\\n" ..
                "\t${bits_srcdir}/allocator.h \\\n",
                "\t${bits_srcdir}/align.h \\\n" ..
                "\t${bits_srcdir}/allocated_ptr.h \\\n" ..
                "\t${bits_srcdir}/allocator.h \\\n",
                "GCC WebAssembly freestanding allocated pointer header")
            local conflicting_shared_ptr_headers =
                "\t${bits_srcdir}/sat_arith.h \\\n" ..
                "\t${bits_srcdir}/shared_ptr.h \\\n" ..
                "\t${bits_srcdir}/shared_ptr_base.h \\\n" ..
                "\t${bits_srcdir}/std_function.h \\\n"
            if io.readfile(makefile):find(conflicting_shared_ptr_headers, 1, true) then
                strict_replace(makefile,
                    conflicting_shared_ptr_headers,
                    "\t${bits_srcdir}/sat_arith.h \\\n" ..
                    "\t${bits_srcdir}/std_function.h \\\n",
                    "GCC WebAssembly freestanding shared pointer header anchor migration")
            end
            strict_replace(makefile,
                "\t${bits_srcdir}/refwrap.h \\\n" ..
                "\t${bits_srcdir}/sat_arith.h \\\n",
                "\t${bits_srcdir}/refwrap.h \\\n" ..
                "\t${bits_srcdir}/shared_ptr.h \\\n" ..
                "\t${bits_srcdir}/shared_ptr_base.h \\\n" ..
                "\t${bits_srcdir}/sat_arith.h \\\n",
                "GCC WebAssembly freestanding shared pointer headers")
        end
        local function remove_hosted_shared_ptr_headers(makefile, prefix, label)
            strict_replace(makefile,
                prefix .. "\t${bits_freestanding} \\\n" ..
                prefix .. "\t${bits_srcdir}/allocated_ptr.h \\\n" ..
                prefix .. "\t${bits_srcdir}/atomic_futex.h \\\n",
                prefix .. "\t${bits_freestanding} \\\n" ..
                prefix .. "\t${bits_srcdir}/atomic_futex.h \\\n",
                label .. " allocated pointer header deduplication")
            strict_replace(makefile,
                prefix .. "\t${bits_srcdir}/semaphore_base.h \\\n" ..
                prefix .. "\t${bits_srcdir}/shared_ptr.h \\\n" ..
                prefix .. "\t${bits_srcdir}/shared_ptr_atomic.h \\\n" ..
                prefix .. "\t${bits_srcdir}/shared_ptr_base.h \\\n" ..
                prefix .. "\t${bits_srcdir}/simd_alg.h \\\n",
                prefix .. "\t${bits_srcdir}/semaphore_base.h \\\n" ..
                prefix .. "\t${bits_srcdir}/shared_ptr_atomic.h \\\n" ..
                prefix .. "\t${bits_srcdir}/simd_alg.h \\\n",
                label .. " shared pointer header deduplication")
        end
        remove_hosted_shared_ptr_headers(libstdcxx_include_make_am, "",
            "GCC WebAssembly hosted libstdc++")
        remove_hosted_shared_ptr_headers(libstdcxx_include_make_in, "@GLIBCXX_HOSTED_TRUE@",
            "GCC WebAssembly configured hosted libstdc++")
        wasm_freestanding_include_headers_changed =
            wasm_freestanding_include_headers_changed
            or shared_ptr_memory_before ~= io.readfile(libstdcxx_memory)
            or shared_ptr_iosfwd_before ~= io.readfile(libstdcxx_iosfwd)
            or shared_ptr_header_before ~= io.readfile(libstdcxx_shared_ptr)
            or shared_ptr_make_am_before ~= io.readfile(libstdcxx_include_make_am)
            or shared_ptr_make_in_before ~= io.readfile(libstdcxx_include_make_in)
    end

    -- make_unique only needs the already-supported unique_ptr and allocation
    -- primitives. Keep the upstream hosted classification for every other
    -- freestanding target, while enabling the implementation for wasm32.
    -- Patch both the AutoGen definition and its checked-in output so a later
    -- regeneration preserves the target-specific extension.
    do
        local libstdcxx_version_def = path.join(src, "libstdc++-v3", "include", "bits",
            "version.def")
        local libstdcxx_version_header = path.join(src, "libstdc++-v3", "include", "bits",
            "version.h")
        local make_unique_version_def_before = io.readfile(libstdcxx_version_def)
        local make_unique_version_header_before = io.readfile(libstdcxx_version_header)
        strict_replace(libstdcxx_version_def,
            [=[ftms = {
  name = make_unique;
  values = {
    v = 201304;
    cxxmin = 14;
    hosted = yes;
  };
};]=],
            [=[ftms = {
  name = make_unique;
  values = {
    v = 201304;
    cxxmin = 14;
    extra_cond = "_GLIBCXX_HOSTED || defined(__wasm32__)";
  };
};]=],
            "GCC WebAssembly freestanding make_unique feature definition")
        strict_replace(libstdcxx_version_header,
            "#if !defined(__cpp_lib_make_unique)\n" ..
            "# if (__cplusplus >= 201402L) && _GLIBCXX_HOSTED\n" ..
            "#  define __glibcxx_make_unique 201304L",
            "#if !defined(__cpp_lib_make_unique)\n" ..
            "# if (__cplusplus >= 201402L) && (_GLIBCXX_HOSTED || defined(__wasm32__))\n" ..
            "#  define __glibcxx_make_unique 201304L",
            "GCC WebAssembly freestanding make_unique feature macro")
        wasm_freestanding_include_headers_changed =
            make_unique_version_def_before ~= io.readfile(libstdcxx_version_def)
            or make_unique_version_header_before ~= io.readfile(libstdcxx_version_header)
    end

    do
        -- ranges::to is header-only and can populate the already-enabled
        -- freestanding vector through its iterator or incremental insert
        -- paths. Preserve the hosted classification on other targets,
        -- while keeping both the feature-definition source and generated
        -- header in sync for wasm32.
        local libstdcxx_version_def = path.join(src, "libstdc++-v3", "include", "bits",
            "version.def")
        local libstdcxx_version_header = path.join(src, "libstdc++-v3", "include", "bits",
            "version.h")
        local ranges_to_version_def_before = io.readfile(libstdcxx_version_def)
        local ranges_to_version_header_before = io.readfile(libstdcxx_version_header)
        strict_replace(libstdcxx_version_def,
            [=[ftms = {
  name = ranges_to_container;
  values = {
    v = 202202;
    cxxmin = 23;
    hosted = yes;
  };
};]=],
            [=[ftms = {
  name = ranges_to_container;
  values = {
    v = 202202;
    cxxmin = 23;
    extra_cond = "_GLIBCXX_HOSTED || defined(__wasm32__)";
  };
};]=],
            "GCC WebAssembly freestanding ranges-to-container feature definition")
        strict_replace(libstdcxx_version_header,
            "#if !defined(__cpp_lib_ranges_to_container)\n" ..
            "# if (__cplusplus >= 202100L) && _GLIBCXX_HOSTED\n" ..
            "#  define __glibcxx_ranges_to_container 202202L",
            "#if !defined(__cpp_lib_ranges_to_container)\n" ..
            "# if (__cplusplus >= 202100L) && (_GLIBCXX_HOSTED || defined(__wasm32__))\n" ..
            "#  define __glibcxx_ranges_to_container 202202L",
            "GCC WebAssembly freestanding ranges-to-container feature macro")
        wasm_freestanding_include_headers_changed =
            wasm_freestanding_include_headers_changed
            or ranges_to_version_def_before ~= io.readfile(libstdcxx_version_def)
            or ranges_to_version_header_before ~= io.readfile(libstdcxx_version_header)
    end

    do
        -- P3391R2 constexpr std::format ships in the vendored mainline <format>
        -- written above, but the pinned wasm PR's version.def/version.h predate
        -- the feature. Add mainline's exact entry so __cpp_lib_constexpr_format
        -- is defined and the header's _GLIBCXX_CONSTEXPR_FORMAT expands to
        -- constexpr. No wasm32 promotion is needed: the Engine's WebAssembly
        -- libstdc++ is configured hosted (--enable-hosted-libstdcxx), so the
        -- stock _GLIBCXX_HOSTED gate already applies. The feature stays gated on
        -- the already-present __cpp_lib_constexpr_exceptions, so it self-disables
        -- if the toolchain ever loses constexpr exception support.
        local libstdcxx_version_def = path.join(src, "libstdc++-v3", "include", "bits",
            "version.def")
        local libstdcxx_version_header = path.join(src, "libstdc++-v3", "include", "bits",
            "version.h")
        local constexpr_format_version_def_before = io.readfile(libstdcxx_version_def)
        local constexpr_format_version_header_before = io.readfile(libstdcxx_version_header)
        strict_replace(libstdcxx_version_def,
            [=[  name = constexpr_exceptions;
  values = {
    v = 202502;
    cxxmin = 26;
    extra_cond = "__cpp_constexpr_exceptions >= 202411L";
    cxx11abi = yes;
  };
};]=],
            [=[  name = constexpr_exceptions;
  values = {
    v = 202502;
    cxxmin = 26;
    extra_cond = "__cpp_constexpr_exceptions >= 202411L";
    cxx11abi = yes;
  };
};

ftms = {
  name = constexpr_format;
  values = {
    v = 202511;
    cxxmin = 26;
    hosted = yes;
    extra_cond = "__cpp_lib_constexpr_exceptions >= 202502L";
    cxx11abi = yes;
  };
};]=],
            "GCC WebAssembly hosted constexpr std::format feature definition")
        strict_replace(libstdcxx_version_header,
            [=[#  define __glibcxx_constexpr_exceptions 202502L
#  if defined(__glibcxx_want_all) || defined(__glibcxx_want_constexpr_exceptions)
#   define __cpp_lib_constexpr_exceptions 202502L
#  endif
# endif
#endif /* !defined(__cpp_lib_constexpr_exceptions) */
#undef __glibcxx_want_constexpr_exceptions]=],
            [=[#  define __glibcxx_constexpr_exceptions 202502L
#  if defined(__glibcxx_want_all) || defined(__glibcxx_want_constexpr_exceptions)
#   define __cpp_lib_constexpr_exceptions 202502L
#  endif
# endif
#endif /* !defined(__cpp_lib_constexpr_exceptions) */
#undef __glibcxx_want_constexpr_exceptions

#if !defined(__cpp_lib_constexpr_format)
# if (__cplusplus >  202302L) && _GLIBCXX_USE_CXX11_ABI && _GLIBCXX_HOSTED && (__cpp_lib_constexpr_exceptions >= 202502L)
#  define __glibcxx_constexpr_format 202511L
#  if defined(__glibcxx_want_all) || defined(__glibcxx_want_constexpr_format)
#   define __cpp_lib_constexpr_format 202511L
#  endif
# endif
#endif /* !defined(__cpp_lib_constexpr_format) */
#undef __glibcxx_want_constexpr_format]=],
            "GCC WebAssembly hosted constexpr std::format feature macro")
        wasm_freestanding_include_headers_changed =
            wasm_freestanding_include_headers_changed
            or constexpr_format_version_def_before ~= io.readfile(libstdcxx_version_def)
            or constexpr_format_version_header_before ~= io.readfile(libstdcxx_version_header)
    end

    -- Ordered associative containers only need the red-black tree runtime,
    -- allocation primitives, and headers that are already usable without a
    -- libc. Keep the target configured as freestanding, but install this
    -- deliberately small hosted extension instead of enabling all of
    -- libstdc++ (which would pull in unsupported locale, I/O, and threading
    -- dependencies).
    local ordered_map_make_am_before = io.readfile(libstdcxx_include_make_am)
    local ordered_map_make_in_before = io.readfile(libstdcxx_include_make_in)
    for _, makefile in ipairs({libstdcxx_include_make_am, libstdcxx_include_make_in}) do
        strict_replace(makefile,
            "\t${std_srcdir}/limits \\\n" ..
            "\t${std_srcdir}/mdspan \\\n",
            "\t${std_srcdir}/limits \\\n" ..
            "\t${std_srcdir}/map \\\n" ..
            "\t${std_srcdir}/mdspan \\\n",
            "GCC WebAssembly extended freestanding map header")
        strict_replace(makefile,
            "\t${bits_srcdir}/enable_special_members.h \\\n" ..
            "\t${bits_srcdir}/functexcept.h \\\n",
            "\t${bits_srcdir}/enable_special_members.h \\\n" ..
            "\t${bits_srcdir}/erase_if.h \\\n" ..
            "\t${bits_srcdir}/functexcept.h \\\n",
            "GCC WebAssembly extended freestanding erase_if header")
        strict_replace(makefile,
            "\t${bits_srcdir}/memoryfwd.h \\\n" ..
            "\t${bits_srcdir}/monostate.h \\\n",
            "\t${bits_srcdir}/memoryfwd.h \\\n" ..
            "\t${bits_srcdir}/memory_resource.h \\\n" ..
            "\t${bits_srcdir}/monostate.h \\\n",
            "GCC WebAssembly extended freestanding memory resource header")
        strict_replace(makefile,
            "\t${bits_srcdir}/iterator_concepts.h \\\n" ..
            "\t${bits_srcdir}/new_except.h \\\n",
            "\t${bits_srcdir}/iterator_concepts.h \\\n" ..
            "\t${bits_srcdir}/new_allocator.h \\\n" ..
            "\t${bits_srcdir}/new_except.h \\\n",
            "GCC WebAssembly extended freestanding default allocator header")
        strict_replace(makefile,
            "\t${bits_srcdir}/new_throw.h \\\n" ..
            "\t${bits_srcdir}/max_size_type.h \\\n",
            "\t${bits_srcdir}/new_throw.h \\\n" ..
            "\t${bits_srcdir}/node_handle.h \\\n" ..
            "\t${bits_srcdir}/max_size_type.h \\\n",
            "GCC WebAssembly extended freestanding node handle header")
        strict_replace(makefile,
            "\t${bits_srcdir}/stl_heap.h \\\n" ..
            "\t${bits_srcdir}/stl_pair.h \\\n",
            "\t${bits_srcdir}/stl_heap.h \\\n" ..
            "\t${bits_srcdir}/stl_map.h \\\n" ..
            "\t${bits_srcdir}/stl_multimap.h \\\n" ..
            "\t${bits_srcdir}/stl_pair.h \\\n",
            "GCC WebAssembly extended freestanding map implementation headers")
        strict_replace(makefile,
            "\t${bits_srcdir}/stl_relops.h \\\n" ..
            "\t${bits_srcdir}/stl_uninitialized.h \\\n",
            "\t${bits_srcdir}/stl_relops.h \\\n" ..
            "\t${bits_srcdir}/stl_tree.h \\\n" ..
            "\t${bits_srcdir}/stl_uninitialized.h \\\n",
            "GCC WebAssembly extended freestanding tree implementation header")
    end
    strict_replace(libstdcxx_include_make_am,
        "\t${std_srcdir}/locale \\\n" ..
        "\t${std_srcdir}/map \\\n" ..
        "\t${std_srcdir}/memory_resource \\\n",
        "\t${std_srcdir}/locale \\\n" ..
        "\t${std_srcdir}/memory_resource \\\n",
        "GCC WebAssembly hosted map header deduplication")
    strict_replace(libstdcxx_include_make_in,
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/locale \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/map \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/memory_resource \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/locale \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/memory_resource \\\n",
        "GCC WebAssembly configured hosted map header deduplication")
    local function remove_ordered_map_hosted_bits(makefile, prefix, label)
        strict_replace(makefile,
            prefix .. "\t${bits_srcdir}/deque.tcc \\\n" ..
            prefix .. "\t${bits_srcdir}/erase_if.h \\\n" ..
            prefix .. "\t${bits_srcdir}/formatfwd.h \\\n",
            prefix .. "\t${bits_srcdir}/deque.tcc \\\n" ..
            prefix .. "\t${bits_srcdir}/formatfwd.h \\\n",
            label .. " erase_if header deduplication")
        strict_replace(makefile,
            prefix .. "\t${bits_srcdir}/mask_array.h \\\n" ..
            prefix .. "\t${bits_srcdir}/memory_resource.h \\\n" ..
            prefix .. "\t${bits_srcdir}/mofunc_impl.h \\\n",
            prefix .. "\t${bits_srcdir}/mask_array.h \\\n" ..
            prefix .. "\t${bits_srcdir}/mofunc_impl.h \\\n",
            label .. " memory resource header deduplication")
        strict_replace_migrated(makefile,
            prefix .. "\t${bits_srcdir}/mofunc_impl.h \\\n" ..
            prefix .. "\t${bits_srcdir}/new_allocator.h \\\n" ..
            prefix .. "\t${bits_srcdir}/node_handle.h \\\n" ..
            prefix .. "\t${bits_srcdir}/ostream.tcc \\\n",
            prefix .. "\t${bits_srcdir}/mofunc_impl.h \\\n" ..
            prefix .. "\t${bits_srcdir}/new_allocator.h \\\n" ..
            prefix .. "\t${bits_srcdir}/ostream.tcc \\\n",
            prefix .. "\t${bits_srcdir}/mofunc_impl.h \\\n" ..
            prefix .. "\t${bits_srcdir}/ostream.tcc \\\n",
            label .. " default allocator and node handle header deduplication")
        strict_replace(makefile,
            prefix .. "\t${bits_srcdir}/stl_list.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stl_map.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stl_multimap.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stl_multiset.h \\\n",
            prefix .. "\t${bits_srcdir}/stl_list.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stl_multiset.h \\\n",
            label .. " map implementation header deduplication")
        strict_replace_migrated(makefile,
            prefix .. "\t${bits_srcdir}/stl_tempbuf.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stl_tree.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stl_vector.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stream_iterator.h \\\n",
            prefix .. "\t${bits_srcdir}/stl_tempbuf.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stl_vector.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stream_iterator.h \\\n",
            prefix .. "\t${bits_srcdir}/stl_tempbuf.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stream_iterator.h \\\n",
            label .. " tree and vector implementation header deduplication")
    end
    remove_ordered_map_hosted_bits(libstdcxx_include_make_am, "",
        "GCC WebAssembly hosted ordered map")
    remove_ordered_map_hosted_bits(libstdcxx_include_make_in, "@GLIBCXX_HOSTED_TRUE@",
        "GCC WebAssembly configured hosted ordered map")
    local ordered_map_install_headers_changed = ordered_map_make_am_before
        ~= io.readfile(libstdcxx_include_make_am)
        or ordered_map_make_in_before ~= io.readfile(libstdcxx_include_make_in)

    -- std::function and unordered_map are implemented independently of
    -- pthreads and a target libc. Move their existing headers into this
    -- target's extended freestanding set; an empty function terminates
    -- because this profile still has no unwinding runtime.
    local callable_hash_make_am_before = io.readfile(libstdcxx_include_make_am)
    local callable_hash_make_in_before = io.readfile(libstdcxx_include_make_in)
    for _, makefile in ipairs({libstdcxx_include_make_am, libstdcxx_include_make_in}) do
        strict_replace(makefile,
            "\t${std_srcdir}/typeindex \\\n" ..
            "\t${std_srcdir}/utility \\\n",
            "\t${std_srcdir}/typeindex \\\n" ..
            "\t${std_srcdir}/unordered_map \\\n" ..
            "\t${std_srcdir}/utility \\\n",
            "GCC WebAssembly extended freestanding unordered map header")
        strict_replace(makefile,
            "\t${bits_srcdir}/functional_hash.h \\\n" ..
            "\t${bits_srcdir}/funcref_impl.h \\\n",
            "\t${bits_srcdir}/functional_hash.h \\\n" ..
            "\t${bits_srcdir}/hashtable.h \\\n" ..
            "\t${bits_srcdir}/hashtable_policy.h \\\n" ..
            "\t${bits_srcdir}/funcref_impl.h \\\n",
            "GCC WebAssembly extended freestanding hash table implementation headers")
        strict_replace(makefile,
            "\t${bits_srcdir}/sat_arith.h \\\n" ..
            "\t${bits_srcdir}/stdexcept_except.h \\\n",
            "\t${bits_srcdir}/sat_arith.h \\\n" ..
            "\t${bits_srcdir}/std_function.h \\\n" ..
            "\t${bits_srcdir}/stdexcept_except.h \\\n",
            "GCC WebAssembly extended freestanding function implementation header")
        strict_replace(makefile,
            "\t${bits_srcdir}/unique_ptr.h \\\n" ..
            "\t${bits_srcdir}/uses_allocator.h \\\n",
            "\t${bits_srcdir}/unique_ptr.h \\\n" ..
            "\t${bits_srcdir}/unordered_map.h \\\n" ..
            "\t${bits_srcdir}/uses_allocator.h \\\n",
            "GCC WebAssembly extended freestanding unordered map implementation header")
    end
    local function remove_callable_hash_hosted_headers(makefile, prefix, label)
        strict_replace(makefile,
            prefix .. "\t${std_srcdir}/thread \\\n" ..
            prefix .. "\t${std_srcdir}/unordered_map \\\n" ..
            prefix .. "\t${std_srcdir}/unordered_set \\\n",
            prefix .. "\t${std_srcdir}/thread \\\n" ..
            prefix .. "\t${std_srcdir}/unordered_set \\\n",
            label .. " public unordered map header deduplication")
        strict_replace(makefile,
            prefix .. "\t${bits_srcdir}/gslice_array.h \\\n" ..
            prefix .. "\t${bits_srcdir}/hashtable.h \\\n" ..
            prefix .. "\t${bits_srcdir}/hashtable_policy.h \\\n" ..
            prefix .. "\t${bits_srcdir}/indirect_array.h \\\n",
            prefix .. "\t${bits_srcdir}/gslice_array.h \\\n" ..
            prefix .. "\t${bits_srcdir}/indirect_array.h \\\n",
            label .. " hash table implementation header deduplication")
        strict_replace(makefile,
            prefix .. "\t${bits_srcdir}/std_abs.h \\\n" ..
            prefix .. "\t${bits_srcdir}/std_function.h \\\n" ..
            prefix .. "\t${bits_srcdir}/std_mutex.h \\\n",
            prefix .. "\t${bits_srcdir}/std_abs.h \\\n" ..
            prefix .. "\t${bits_srcdir}/std_mutex.h \\\n",
            label .. " function implementation header deduplication")
        strict_replace(makefile,
            prefix .. "\t${bits_srcdir}/unique_lock.h \\\n" ..
            prefix .. "\t${bits_srcdir}/unordered_map.h \\\n" ..
            prefix .. "\t${bits_srcdir}/unordered_set.h \\\n",
            prefix .. "\t${bits_srcdir}/unique_lock.h \\\n" ..
            prefix .. "\t${bits_srcdir}/unordered_set.h \\\n",
            label .. " unordered map implementation header deduplication")
    end
    remove_callable_hash_hosted_headers(libstdcxx_include_make_am, "",
        "GCC WebAssembly hosted callable and unordered map")
    remove_callable_hash_hosted_headers(libstdcxx_include_make_in, "@GLIBCXX_HOSTED_TRUE@",
        "GCC WebAssembly configured hosted callable and unordered map")
    local callable_hash_install_headers_changed = callable_hash_make_am_before
        ~= io.readfile(libstdcxx_include_make_am)
        or callable_hash_make_in_before ~= io.readfile(libstdcxx_include_make_in)

    local libstdcxx_functional = path.join(src, "libstdc++-v3", "include", "std", "functional")
    local functional_header_before = io.readfile(libstdcxx_functional)
    strict_replace(libstdcxx_functional,
        "#if _GLIBCXX_HOSTED\n" ..
        "# include <bits/std_function.h>\t// std::function\n" ..
        "#endif",
        "// xmake: std::function is target-libc independent.\n" ..
        "#include <bits/std_function.h>\t// std::function",
        "GCC WebAssembly extended freestanding function availability")
    local functional_header_changed = functional_header_before ~= io.readfile(libstdcxx_functional)

    local libstdcxx_std_function = path.join(src,
        "libstdc++-v3", "include", "bits", "std_function.h")
    local std_function_header_before = io.readfile(libstdcxx_std_function)
    strict_replace(libstdcxx_std_function,
        "  class bad_function_call : public std::exception\n" ..
        "  {\n" ..
        "  public:\n" ..
        "    virtual ~bad_function_call() noexcept;\n\n" ..
        "    const char* what() const noexcept;\n" ..
        "  };",
        "  class bad_function_call : public std::exception\n" ..
        "  {\n" ..
        "  public:\n" ..
        "#if _GLIBCXX_HOSTED\n" ..
        "    virtual ~bad_function_call() noexcept;\n\n" ..
        "    const char* what() const noexcept;\n" ..
        "#else\n" ..
        "    ~bad_function_call() noexcept override = default;\n\n" ..
        "    const char* what() const noexcept override\n" ..
        "    { return \"bad_function_call\"; }\n" ..
        "#endif\n" ..
        "  };",
        "GCC WebAssembly freestanding bad function call definition")
    strict_replace(libstdcxx_std_function,
        "\tif (_M_empty())\n" ..
        "\t  __throw_bad_function_call();\n" ..
        "\treturn _M_invoker(_M_functor, std::forward<_ArgTypes>(__args)...);",
        "\tif (_M_empty())\n" ..
        "\t  {\n" ..
        "#if _GLIBCXX_HOSTED\n" ..
        "\t    __throw_bad_function_call();\n" ..
        "#else\n" ..
        "\t    std::__terminate();\n" ..
        "#endif\n" ..
        "\t  }\n" ..
        "\treturn _M_invoker(_M_functor, std::forward<_ArgTypes>(__args)...);",
        "GCC WebAssembly freestanding empty function handling")
    local std_function_header_changed = std_function_header_before
        ~= io.readfile(libstdcxx_std_function)

    local libstdcxx_unordered_map = path.join(src,
        "libstdc++-v3", "include", "std", "unordered_map")
    local unordered_map_header_before = io.readfile(libstdcxx_unordered_map)
    strict_replace(libstdcxx_unordered_map,
        "#include <bits/requires_hosted.h> // container",
        "#if _GLIBCXX_HOSTED\n" ..
        "#include <bits/requires_hosted.h> // container\n" ..
        "#endif",
        "GCC WebAssembly extended freestanding unordered map availability")
    local unordered_map_header_changed = unordered_map_header_before
        ~= io.readfile(libstdcxx_unordered_map)

    local libstdcxx_unordered_version = path.join(
        src, "libstdc++-v3", "include", "bits", "version.h")
    local unordered_map_feature_before = io.readfile(libstdcxx_unordered_version)
    strict_replace(libstdcxx_unordered_version,
        "#if !defined(__cpp_lib_generic_unordered_lookup)\n" ..
        "# if (__cplusplus >= 202002L) && _GLIBCXX_HOSTED",
        "#if !defined(__cpp_lib_generic_unordered_lookup)\n" ..
        "# if (__cplusplus >= 202002L)\n" ..
        "// xmake: GCC WebAssembly extended freestanding generic unordered lookup.",
        "GCC WebAssembly extended freestanding generic unordered lookup")
    local unordered_map_feature_changed = unordered_map_feature_before
        ~= io.readfile(libstdcxx_unordered_version)

    local libstdcxx_cxx11_make_am = path.join(src,
        "libstdc++-v3", "src", "c++11", "Makefile.am")
    local libstdcxx_cxx11_make_in = path.join(src,
        "libstdc++-v3", "src", "c++11", "Makefile.in")
    local unordered_map_runtime_make_am_before = io.readfile(libstdcxx_cxx11_make_am)
    local unordered_map_runtime_make_in_before = io.readfile(libstdcxx_cxx11_make_in)
    strict_replace_migrated(libstdcxx_cxx11_make_am,
        "sources_freestanding = \\\n" ..
        "\tlimits.cc \\\n" ..
        "\tplaceholders.cc",
        "sources_freestanding = \\\n" ..
        "\thashtable_c++0x.cc \\\n" ..
        "\tlimits.cc \\\n" ..
        "\tplaceholders.cc",
        "sources_freestanding = \\\n" ..
        "\thashtable_c++0x.cc \\\n" ..
        "\tlimits.cc \\\n" ..
        "\tplaceholders.cc \\\n" ..
        "\tshared_ptr.cc",
        "GCC WebAssembly extended freestanding unordered map and shared pointer runtime")
    strict_replace_migrated(libstdcxx_cxx11_make_in,
        "am__objects_1 = limits.lo placeholders.lo",
        "am__objects_1 = hashtable_c++0x.lo limits.lo placeholders.lo",
        "am__objects_1 = hashtable_c++0x.lo limits.lo placeholders.lo shared_ptr.lo",
        "GCC WebAssembly configured extended freestanding unordered map and shared pointer runtime objects")
    strict_replace_migrated(libstdcxx_cxx11_make_in,
        "sources_freestanding = \\\n" ..
        "\tlimits.cc \\\n" ..
        "\tplaceholders.cc",
        "sources_freestanding = \\\n" ..
        "\thashtable_c++0x.cc \\\n" ..
        "\tlimits.cc \\\n" ..
        "\tplaceholders.cc",
        "sources_freestanding = \\\n" ..
        "\thashtable_c++0x.cc \\\n" ..
        "\tlimits.cc \\\n" ..
        "\tplaceholders.cc \\\n" ..
        "\tshared_ptr.cc",
        "GCC WebAssembly configured extended freestanding unordered map and shared pointer runtime")
    local unordered_map_runtime_changed = unordered_map_runtime_make_am_before
        ~= io.readfile(libstdcxx_cxx11_make_am)
        or unordered_map_runtime_make_in_before ~= io.readfile(libstdcxx_cxx11_make_in)

    -- The prime rehash policy only rounds non-negative bucket counts down,
    -- but GCC lowers __builtin_floor to a libm call for this target. Use
    -- the equivalent unsigned conversion so the freestanding runtime does
    -- not acquire a hidden hosted-math dependency.
    local libstdcxx_hashtable_runtime = path.join(
        src, "libstdc++-v3", "src", "c++11", "hashtable_c++0x.cc")
    local unordered_map_runtime_source_before = io.readfile(libstdcxx_hashtable_runtime)
    strict_replace(libstdcxx_hashtable_runtime,
        "__builtin_floor(__fast_bkt[__n] * (double)_M_max_load_factor)",
        "static_cast<std::size_t>(__fast_bkt[__n] * (double)_M_max_load_factor)",
        "GCC WebAssembly freestanding unordered map fast-bucket rounding")
    strict_replace(libstdcxx_hashtable_runtime,
        "__builtin_floor(*__next_bkt * (double)_M_max_load_factor)",
        "static_cast<std::size_t>(*__next_bkt * (double)_M_max_load_factor)",
        "GCC WebAssembly freestanding unordered map resize rounding")
    strict_replace(libstdcxx_hashtable_runtime,
        "__builtin_floor(__min_bkts) + 1",
        "static_cast<std::size_t>(__min_bkts) + 1",
        "GCC WebAssembly freestanding unordered map minimum-bucket rounding")
    strict_replace(libstdcxx_hashtable_runtime,
        "__builtin_floor(__n_bkt * (double)_M_max_load_factor)",
        "static_cast<std::size_t>(__n_bkt * (double)_M_max_load_factor)",
        "GCC WebAssembly freestanding unordered map threshold rounding")
    unordered_map_runtime_changed = unordered_map_runtime_changed
        or unordered_map_runtime_source_before ~= io.readfile(libstdcxx_hashtable_runtime)

    -- GCC still classifies <string> as hosted even though the core
    -- basic_string implementation only needs allocation and the
    -- freestanding character/memory primitives. Install that core and the
    -- header-only integral to_string overloads while keeping stream I/O,
    -- numeric parsing, and floating-point conversions unavailable.
    local string_make_am_before = io.readfile(libstdcxx_include_make_am)
    local string_make_in_before = io.readfile(libstdcxx_include_make_in)
    for _, makefile in ipairs({libstdcxx_include_make_am, libstdcxx_include_make_in}) do
        strict_replace(makefile,
            "\t${std_srcdir}/span \\\n" ..
            "\t${std_srcdir}/string_view \\\n",
            "\t${std_srcdir}/span \\\n" ..
            "\t${std_srcdir}/string \\\n" ..
            "\t${std_srcdir}/string_view \\\n",
            "GCC WebAssembly extended freestanding string header")
        strict_replace_migrated(makefile,
            "\t${bits_srcdir}/atomic_base.h \\\n" ..
            "\t${bits_srcdir}/c++0x_warning.h \\\n",
            "\t${bits_srcdir}/atomic_base.h \\\n" ..
            "\t${bits_srcdir}/basic_string.h \\\n" ..
            "\t${bits_srcdir}/basic_string.tcc \\\n" ..
            "\t${bits_srcdir}/c++0x_warning.h \\\n",
            "\t${bits_srcdir}/atomic_base.h \\\n" ..
            "\t${bits_srcdir}/basic_string.h \\\n" ..
            "\t${bits_srcdir}/basic_string.tcc \\\n" ..
            "\t${bits_srcdir}/charconv.h \\\n" ..
            "\t${bits_srcdir}/c++0x_warning.h \\\n",
            "GCC WebAssembly extended freestanding basic string conversion headers")
        strict_replace(makefile,
            "\t${bits_srcdir}/version.h \\\n" ..
            "\t${bits_srcdir}/string_view.tcc \\\n",
            "\t${bits_srcdir}/version.h \\\n" ..
            "\t${bits_srcdir}/stringfwd.h \\\n" ..
            "\t${bits_srcdir}/string_view.tcc \\\n",
            "GCC WebAssembly extended freestanding string forward declarations")
    end
    strict_replace(libstdcxx_include_make_am,
        "\t${std_srcdir}/streambuf \\\n" ..
        "\t${std_srcdir}/string \\\n" ..
        "\t${std_srcdir}/system_error \\\n",
        "\t${std_srcdir}/streambuf \\\n" ..
        "\t${std_srcdir}/system_error \\\n",
        "GCC WebAssembly hosted string header deduplication")
    strict_replace(libstdcxx_include_make_in,
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/streambuf \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/string \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/system_error \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/streambuf \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/system_error \\\n",
        "GCC WebAssembly configured hosted string header deduplication")
    if not io.readfile(libstdcxx_include_make_am):find(
            "\t${bits_srcdir}/basic_ios.h \\\n" ..
            "\t${bits_srcdir}/basic_ios.tcc \\\n" ..
            "\t${bits_srcdir}/chrono_io.h \\\n", 1, true) then
        strict_replace(libstdcxx_include_make_am,
            "\t${bits_srcdir}/basic_ios.h \\\n" ..
            "\t${bits_srcdir}/basic_ios.tcc \\\n" ..
            "\t${bits_srcdir}/basic_string.h \\\n" ..
            "\t${bits_srcdir}/basic_string.tcc \\\n" ..
            "\t${bits_srcdir}/charconv.h \\\n",
            "\t${bits_srcdir}/basic_ios.h \\\n" ..
            "\t${bits_srcdir}/basic_ios.tcc \\\n" ..
            "\t${bits_srcdir}/charconv.h \\\n",
            "GCC WebAssembly hosted basic string implementation header deduplication")
    end
    if not io.readfile(libstdcxx_include_make_in):find(
            "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.h \\\n" ..
            "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.tcc \\\n" ..
            "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/chrono_io.h \\\n", 1, true) then
        strict_replace(libstdcxx_include_make_in,
            "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.h \\\n" ..
            "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.tcc \\\n" ..
            "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_string.h \\\n" ..
            "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_string.tcc \\\n" ..
            "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/charconv.h \\\n",
            "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.h \\\n" ..
            "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.tcc \\\n" ..
            "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/charconv.h \\\n",
            "GCC WebAssembly configured hosted basic string implementation header deduplication")
    end
    strict_replace(libstdcxx_include_make_am,
        "\t${bits_srcdir}/streambuf.tcc \\\n" ..
        "\t${bits_srcdir}/stringfwd.h \\\n" ..
        "\t${bits_srcdir}/this_thread_sleep.h \\\n",
        "\t${bits_srcdir}/streambuf.tcc \\\n" ..
        "\t${bits_srcdir}/this_thread_sleep.h \\\n",
        "GCC WebAssembly hosted string forward declaration header deduplication")
    strict_replace(libstdcxx_include_make_in,
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/streambuf.tcc \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/stringfwd.h \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/this_thread_sleep.h \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/streambuf.tcc \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/this_thread_sleep.h \\\n",
        "GCC WebAssembly configured hosted string forward declaration header deduplication")
    local string_install_headers_changed = string_make_am_before
        ~= io.readfile(libstdcxx_include_make_am)
        or string_make_in_before ~= io.readfile(libstdcxx_include_make_in)

    -- std::vector's primary implementation is header-only and uses the
    -- same allocator and terminate-backed failure surface already needed
    -- by the extended freestanding map and string cores. Install only the
    -- vector headers; debug mode and hosted formatting remain unavailable.
    local vector_make_am_before = io.readfile(libstdcxx_include_make_am)
    local vector_make_in_before = io.readfile(libstdcxx_include_make_in)
    for _, makefile in ipairs({libstdcxx_include_make_am, libstdcxx_include_make_in}) do
        strict_replace(makefile,
            "\t${std_srcdir}/variant \\\n" ..
            "\t${std_srcdir}/version",
            "\t${std_srcdir}/variant \\\n" ..
            "\t${std_srcdir}/vector \\\n" ..
            "\t${std_srcdir}/version",
            "GCC WebAssembly extended freestanding vector header")
        strict_replace(makefile,
            "\t${bits_srcdir}/stl_algobase.h \\\n" ..
            "\t${bits_srcdir}/stl_construct.h \\\n",
            "\t${bits_srcdir}/stl_algobase.h \\\n" ..
            "\t${bits_srcdir}/stl_bvector.h \\\n" ..
            "\t${bits_srcdir}/stl_construct.h \\\n",
            "GCC WebAssembly extended freestanding vector bool implementation header")
        strict_replace(makefile,
            "\t${bits_srcdir}/stl_uninitialized.h \\\n" ..
            "\t${bits_srcdir}/text_encoding-data.h \\\n",
            "\t${bits_srcdir}/stl_uninitialized.h \\\n" ..
            "\t${bits_srcdir}/stl_vector.h \\\n" ..
            "\t${bits_srcdir}/text_encoding-data.h \\\n",
            "GCC WebAssembly extended freestanding vector implementation header")
        strict_replace(makefile,
            "\t${bits_srcdir}/uses_allocator_args.h \\\n" ..
            "\t${bits_srcdir}/utility.h",
            "\t${bits_srcdir}/uses_allocator_args.h \\\n" ..
            "\t${bits_srcdir}/utility.h \\\n" ..
            "\t${bits_srcdir}/vector.tcc",
            "GCC WebAssembly extended freestanding vector template definitions")
    end
    local function remove_vector_hosted_headers(makefile, prefix, label)
        strict_replace(makefile,
            prefix .. "\t${std_srcdir}/unordered_set \\\n" ..
            prefix .. "\t${std_srcdir}/valarray \\\n" ..
            prefix .. "\t${std_srcdir}/vector",
            prefix .. "\t${std_srcdir}/unordered_set \\\n" ..
            prefix .. "\t${std_srcdir}/valarray",
            label .. " public header deduplication")
        strict_replace(makefile,
            prefix .. "\t${bits_srcdir}/std_thread.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stl_bvector.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stl_deque.h \\\n",
            prefix .. "\t${bits_srcdir}/std_thread.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stl_deque.h \\\n",
            label .. " vector bool implementation header deduplication")
        strict_replace(makefile,
            prefix .. "\t${bits_srcdir}/stl_tempbuf.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stl_vector.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stream_iterator.h \\\n",
            prefix .. "\t${bits_srcdir}/stl_tempbuf.h \\\n" ..
            prefix .. "\t${bits_srcdir}/stream_iterator.h \\\n",
            label .. " vector implementation header deduplication")
        strict_replace(makefile,
            prefix .. "\t${bits_srcdir}/valarray_after.h \\\n" ..
            prefix .. "\t${bits_srcdir}/vec_ops.h \\\n" ..
            prefix .. "\t${bits_srcdir}/vector.tcc",
            prefix .. "\t${bits_srcdir}/valarray_after.h \\\n" ..
            prefix .. "\t${bits_srcdir}/vec_ops.h",
            label .. " vector template definition header deduplication")
    end
    remove_vector_hosted_headers(libstdcxx_include_make_am, "",
        "GCC WebAssembly hosted vector")
    remove_vector_hosted_headers(libstdcxx_include_make_in, "@GLIBCXX_HOSTED_TRUE@",
        "GCC WebAssembly configured hosted vector")
    local vector_install_headers_changed = vector_make_am_before
        ~= io.readfile(libstdcxx_include_make_am)
        or vector_make_in_before ~= io.readfile(libstdcxx_include_make_in)

    -- GCC already implements duration, time_point, and the duration
    -- literals without a target libc, but still installs <chrono> and its
    -- implementation header only for hosted profiles. Move that existing
    -- core into the freestanding header set while leaving clocks, time
    -- zones, stream I/O, and formatting in their upstream hosted guards.
    local chrono_make_am_before = io.readfile(libstdcxx_include_make_am)
    local chrono_make_in_before = io.readfile(libstdcxx_include_make_in)
    for _, makefile in ipairs({libstdcxx_include_make_am, libstdcxx_include_make_in}) do
        strict_replace(makefile,
            "\t${std_srcdir}/bitset \\\n" ..
            "\t${std_srcdir}/concepts \\\n",
            "\t${std_srcdir}/bitset \\\n" ..
            "\t${std_srcdir}/chrono \\\n" ..
            "\t${std_srcdir}/concepts \\\n",
            "GCC WebAssembly freestanding chrono duration header")
        strict_replace(makefile,
            "\t${bits_srcdir}/char_traits.h \\\n" ..
            "\t${bits_srcdir}/cpp_type_traits.h \\\n",
            "\t${bits_srcdir}/char_traits.h \\\n" ..
            "\t${bits_srcdir}/chrono.h \\\n" ..
            "\t${bits_srcdir}/cpp_type_traits.h \\\n",
            "GCC WebAssembly freestanding chrono duration implementation header")
    end
    strict_replace(libstdcxx_include_make_am,
        "\t${std_srcdir}/charconv \\\n" ..
        "\t${std_srcdir}/chrono \\\n" ..
        "\t${std_srcdir}/codecvt \\\n",
        "\t${std_srcdir}/charconv \\\n" ..
        "\t${std_srcdir}/codecvt \\\n",
        "GCC WebAssembly hosted chrono header deduplication")
    strict_replace(libstdcxx_include_make_in,
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/charconv \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/chrono \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/codecvt \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/charconv \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/codecvt \\\n",
        "GCC WebAssembly configured hosted chrono header deduplication")
    strict_replace_migrated(libstdcxx_include_make_am,
        "\t${bits_srcdir}/basic_ios.h \\\n" ..
        "\t${bits_srcdir}/basic_ios.tcc \\\n" ..
        "\t${bits_srcdir}/charconv.h \\\n" ..
        "\t${bits_srcdir}/chrono.h \\\n" ..
        "\t${bits_srcdir}/chrono_io.h \\\n",
        "\t${bits_srcdir}/basic_ios.h \\\n" ..
        "\t${bits_srcdir}/basic_ios.tcc \\\n" ..
        "\t${bits_srcdir}/charconv.h \\\n" ..
        "\t${bits_srcdir}/chrono_io.h \\\n",
        "\t${bits_srcdir}/basic_ios.h \\\n" ..
        "\t${bits_srcdir}/basic_ios.tcc \\\n" ..
        "\t${bits_srcdir}/chrono_io.h \\\n",
        "GCC WebAssembly hosted string and chrono implementation header migration")
    strict_replace_migrated(libstdcxx_include_make_in,
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.h \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.tcc \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/charconv.h \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/chrono.h \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/chrono_io.h \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.h \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.tcc \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/charconv.h \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/chrono_io.h \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.h \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/basic_ios.tcc \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${bits_srcdir}/chrono_io.h \\\n",
        "GCC WebAssembly configured hosted string and chrono implementation header migration")
    local chrono_install_headers_changed = chrono_make_am_before
        ~= io.readfile(libstdcxx_include_make_am)
        or chrono_make_in_before ~= io.readfile(libstdcxx_include_make_in)

    do
        -- Freestanding libstdc++ deliberately exposes sys_time through an
        -- anonymous fake clock, which makes system_clock::duration
        -- impossible to name. Keep the hosted clock implementation and
        -- C time conversions untouched, but expose the standard clock
        -- type and ABI declaration so a WebAssembly runtime can provide
        -- now() at the final link/import boundary.
        local libstdcxx_chrono_core = path.join(src,
            "libstdc++-v3", "include", "bits", "chrono.h")
        local chrono_core_before = io.readfile(libstdcxx_chrono_core)
        strict_replace(libstdcxx_chrono_core,
            [=[#elif __cplusplus >= 202002L
    // Define a fake clock like chrono::local_t so that sys_time etc.
    // can be used for freestanding.
    struct __sys_t;
    template<typename _Duration>
      using sys_time = time_point<__sys_t, _Duration>;
    using sys_seconds = sys_time<seconds>;
    using sys_days = sys_time<days>;]=],
            [=[#elif __cplusplus >= 202002L
    // xmake: source-compatible clock surface for the no-libc WebAssembly
    // profile. The final runtime supplies system_clock::now().
_GLIBCXX_BEGIN_INLINE_ABI_NAMESPACE(_V2)
    struct system_clock
    {
      typedef chrono::nanoseconds                              duration;
      typedef duration::rep                                    rep;
      typedef duration::period                                 period;
      typedef chrono::time_point<system_clock, duration>       time_point;

      static constexpr bool is_steady = false;

      static time_point
      now() noexcept;
    };

    using high_resolution_clock = system_clock;
_GLIBCXX_END_INLINE_ABI_NAMESPACE(_V2)

    template<typename _Duration>
      using sys_time = time_point<system_clock, _Duration>;
    using sys_seconds = sys_time<seconds>;
    using sys_days = sys_time<days>;]=],
            "GCC WebAssembly freestanding system clock type surface")
        wasm_freestanding_include_headers_changed =
            wasm_freestanding_include_headers_changed
            or chrono_core_before ~= io.readfile(libstdcxx_chrono_core)
    end

    local cstring_make_am_before = io.readfile(libstdcxx_include_make_am)
    local cstring_make_in_before = io.readfile(libstdcxx_include_make_in)
    for _, makefile in ipairs({libstdcxx_include_make_am, libstdcxx_include_make_in}) do
        strict_replace(makefile,
            "\t${c_base_srcdir}/cstdint \\\n" ..
            "\t${c_base_srcdir}/cstdlib",
            "\t${c_base_srcdir}/cstdint \\\n" ..
            "\t${c_base_srcdir}/cstdlib \\\n" ..
            "\t${c_base_srcdir}/cstring",
            "GCC WebAssembly freestanding cstring header")
    end
    strict_replace(libstdcxx_include_make_am,
        "\t${c_base_srcdir}/cstdio \\\n" ..
        "\t${c_base_srcdir}/cstring \\\n" ..
        "\t${c_base_srcdir}/ctgmath \\\n",
        "\t${c_base_srcdir}/cstdio \\\n" ..
        "\t${c_base_srcdir}/ctgmath \\\n",
        "GCC WebAssembly hosted cstring header deduplication")
    strict_replace(libstdcxx_include_make_in,
        "@GLIBCXX_HOSTED_TRUE@\t${c_base_srcdir}/cstdio \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${c_base_srcdir}/cstring \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${c_base_srcdir}/ctgmath \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${c_base_srcdir}/cstdio \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${c_base_srcdir}/ctgmath \\\n",
        "GCC WebAssembly configured hosted cstring header deduplication")
    local cstring_install_headers_changed = cstring_make_am_before
        ~= io.readfile(libstdcxx_include_make_am)
        or cstring_make_in_before ~= io.readfile(libstdcxx_include_make_in)

    do
        local libstdcxx_cstdlib = path.join(src,
            "libstdc++-v3", "include", "c_global", "cstdlib")
        local cstdlib_header_before = io.readfile(libstdcxx_cstdlib)
        strict_replace(libstdcxx_cstdlib,
            "  extern \"C\" void exit(int) _GLIBCXX_NOTHROW _GLIBCXX_NORETURN;\n" ..
            "#if __cplusplus >= 201103L",
            "  extern \"C\" void exit(int) _GLIBCXX_NOTHROW _GLIBCXX_NORETURN;\n\n" ..
            "  inline _GLIBCXX_CONSTEXPR int\n" ..
            "  abs(int __x) { return __builtin_abs(__x); }\n\n" ..
            "  inline _GLIBCXX_CONSTEXPR long\n" ..
            "  abs(long __x) { return __builtin_labs(__x); }\n\n" ..
            "#ifdef _GLIBCXX_USE_LONG_LONG\n" ..
            "  inline _GLIBCXX_CONSTEXPR long long\n" ..
            "  abs(long long __x) { return __builtin_llabs(__x); }\n" ..
            "#endif\n\n" ..
            "#if __cplusplus >= 201103L",
            "GCC WebAssembly freestanding cstdlib integral abs")
        wasm_freestanding_include_headers_changed = wasm_freestanding_include_headers_changed
            or cstdlib_header_before ~= io.readfile(libstdcxx_cstdlib)
    end

    local libstdcxx_cstring = path.join(src, "libstdc++-v3", "include", "c_global", "cstring")
    local cstring_header_before = io.readfile(libstdcxx_cstring)
    strict_replace(libstdcxx_cstring,
        "#define __glibcxx_want_freestanding_cstring\n" ..
        "#include <bits/version.h>\n" ..
        "#include <string.h>",
        "#define __glibcxx_want_freestanding_cstring\n" ..
        "#include <bits/version.h>\n" ..
        "#if _GLIBCXX_HOSTED\n" ..
        "#include <string.h>\n" ..
        "#else\n" ..
        "#include <cstddef>\n" ..
        "extern \"C\"\n" ..
        "{\n" ..
        "  void* memchr(const void*, int, __SIZE_TYPE__) noexcept;\n" ..
        "  int memcmp(const void*, const void*, __SIZE_TYPE__) noexcept;\n" ..
        "  void* memcpy(void*, const void*, __SIZE_TYPE__) noexcept;\n" ..
        "  void* memmove(void*, const void*, __SIZE_TYPE__) noexcept;\n" ..
        "  void* memset(void*, int, __SIZE_TYPE__) noexcept;\n" ..
        "}\n" ..
        "#endif",
        "GCC WebAssembly freestanding cstring runtime declarations")
    strict_replace(libstdcxx_cstring,
        "  using ::memchr;\n" ..
        "  using ::memcmp;",
        "#if _GLIBCXX_HOSTED\n" ..
        "  using ::memchr;\n" ..
        "  using ::memcmp;",
        "GCC WebAssembly hosted cstring namespace imports")
    strict_replace(libstdcxx_cstring,
        [=[#endif

_GLIBCXX_END_NAMESPACE_VERSION
} // namespace]=],
        [=[#endif
#else
  inline void*
  memchr(void* __s, int __c, size_t __n) noexcept
  { return ::memchr(__s, __c, __n); }

  inline const void*
  memchr(const void* __s, int __c, size_t __n) noexcept
  { return ::memchr(__s, __c, __n); }

  using ::memcmp;
  using ::memcpy;
  using ::memmove;
  using ::memset;
#endif

_GLIBCXX_END_NAMESPACE_VERSION
} // namespace]=],
        "GCC WebAssembly freestanding cstring namespace imports")
    local cstring_header_changed = cstring_header_before ~= io.readfile(libstdcxx_cstring)

    -- The Engine consumes formatting through import std, but the target
    -- deliberately remains no-libc and cannot enable all hosted
    -- libstdc++. Install a target-owned, executable formatting subset and
    -- stream type compatibility surface. print/println retain an explicit
    -- external console hook instead of silently discarding output.
    local hosted_compat_make_am_before = io.readfile(libstdcxx_include_make_am)
    local hosted_compat_make_in_before = io.readfile(libstdcxx_include_make_in)
    for _, makefile in ipairs({libstdcxx_include_make_am, libstdcxx_include_make_in}) do
        strict_replace(makefile,
            "\t${std_srcdir}/expected \\\n" ..
            "\t${std_srcdir}/functional \\\n",
            "\t${std_srcdir}/expected \\\n" ..
            "\t${std_srcdir}/format \\\n" ..
            "\t${std_srcdir}/functional \\\n",
            "GCC WebAssembly extended freestanding format header")
        strict_replace(makefile,
            "\t${std_srcdir}/generator \\\n" ..
            "\t${std_srcdir}/iterator \\\n",
            "\t${std_srcdir}/generator \\\n" ..
            "\t${std_srcdir}/istream \\\n" ..
            "\t${std_srcdir}/iterator \\\n",
            "GCC WebAssembly extended freestanding input stream header")
        strict_replace(makefile,
            "\t${std_srcdir}/optional \\\n" ..
            "\t${std_srcdir}/ranges \\\n",
            "\t${std_srcdir}/optional \\\n" ..
            "\t${std_srcdir}/ostream \\\n" ..
            "\t${std_srcdir}/print \\\n" ..
            "\t${std_srcdir}/ranges \\\n",
            "GCC WebAssembly extended freestanding output and print headers")
        strict_replace(makefile,
            "\t${bits_srcdir}/funcwrap.h \\\n" ..
            "\t${bits_srcdir}/indirect.h \\\n",
            "\t${bits_srcdir}/funcwrap.h \\\n" ..
            "\t${bits_srcdir}/wasm_freestanding_hosted_compat.h \\\n" ..
            "\t${bits_srcdir}/indirect.h \\\n",
            "GCC WebAssembly extended freestanding hosted-surface implementation header")
    end
    strict_replace(libstdcxx_include_make_am,
        "\t${std_srcdir}/flat_set \\\n" ..
        "\t${std_srcdir}/format \\\n" ..
        "\t${std_srcdir}/forward_list \\\n",
        "\t${std_srcdir}/flat_set \\\n" ..
        "\t${std_srcdir}/forward_list \\\n",
        "GCC WebAssembly hosted format header deduplication")
    strict_replace(libstdcxx_include_make_am,
        "\t${std_srcdir}/iostream \\\n" ..
        "\t${std_srcdir}/istream \\\n" ..
        "\t${std_srcdir}/latch \\\n",
        "\t${std_srcdir}/iostream \\\n" ..
        "\t${std_srcdir}/latch \\\n",
        "GCC WebAssembly hosted input stream header deduplication")
    strict_replace(libstdcxx_include_make_am,
        "\t${std_srcdir}/mutex \\\n" ..
        "\t${std_srcdir}/ostream \\\n" ..
        "\t${std_srcdir}/print \\\n" ..
        "\t${std_srcdir}/queue \\\n",
        "\t${std_srcdir}/mutex \\\n" ..
        "\t${std_srcdir}/queue \\\n",
        "GCC WebAssembly hosted output and print header deduplication")
    strict_replace(libstdcxx_include_make_in,
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/flat_set \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/format \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/forward_list \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/flat_set \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/forward_list \\\n",
        "GCC WebAssembly configured hosted format header deduplication")
    strict_replace(libstdcxx_include_make_in,
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/iostream \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/istream \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/latch \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/iostream \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/latch \\\n",
        "GCC WebAssembly configured hosted input stream header deduplication")
    strict_replace(libstdcxx_include_make_in,
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/mutex \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/ostream \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/print \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/queue \\\n",
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/mutex \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t${std_srcdir}/queue \\\n",
        "GCC WebAssembly configured hosted output and print header deduplication")
    local hosted_compat_install_headers_changed = hosted_compat_make_am_before
        ~= io.readfile(libstdcxx_include_make_am)
        or hosted_compat_make_in_before ~= io.readfile(libstdcxx_include_make_in)

    local hosted_compat_header_changed = false
    local function wrap_freestanding_hosted_header(name, define_line, end_line)
        local file = path.join(src, "libstdc++-v3", "include", "std", name)
        local before = io.readfile(file)
        strict_replace(file,
            define_line,
            define_line .. "\n\n" ..
            "#include <bits/c++config.h>\n" ..
            "#if !_GLIBCXX_HOSTED\n" ..
            "#include <bits/wasm_freestanding_hosted_compat.h>\n" ..
            "#else",
            "GCC WebAssembly extended freestanding " .. name .. " dispatch")
        strict_replace(file,
            end_line,
            "#endif // _GLIBCXX_HOSTED\n" .. end_line,
            "GCC WebAssembly extended freestanding " .. name .. " dispatch close")
        hosted_compat_header_changed = hosted_compat_header_changed
            or before ~= io.readfile(file)
    end
    -- Vendor mainline's P3391R2 constexpr <format> over the pinned upstream
    -- wasm PR's older copy so hosted WebAssembly gets a genuinely constexpr
    -- std::format; the freestanding dispatch wrapper below re-applies on the
    -- unchanged include guards. istream/ostream/print keep the fork's copies.
    -- The constexpr_format feature macro is enabled in version.def/version.h
    -- below (the build is hosted, so mainline's stock _GLIBCXX_HOSTED gate fits).
    local vendored_format = gccwasmcompat.constexpr_format_source()
    if not vendored_format then
        errors.fail("vendored mainline <format> source (patches/wasm_sources/std_format) is missing")
    end
    io.writefile(path.join(src, "libstdc++-v3", "include", "std", "format"), vendored_format)
    hosted_compat_header_changed = true
    wrap_freestanding_hosted_header(
        "format", "#define _GLIBCXX_FORMAT 1", "#endif // _GLIBCXX_FORMAT")
    wrap_freestanding_hosted_header(
        "istream", "#define _GLIBCXX_ISTREAM 1", "#endif\t/* _GLIBCXX_ISTREAM */")
    wrap_freestanding_hosted_header(
        "ostream", "#define _GLIBCXX_OSTREAM 1", "#endif\t/* _GLIBCXX_OSTREAM */")
    wrap_freestanding_hosted_header(
        "print", "#define _GLIBCXX_PRINT 1", "#endif // _GLIBCXX_PRINT")

    local libstdcxx_map = path.join(src, "libstdc++-v3", "include", "std", "map")
    local ordered_map_header_before = io.readfile(libstdcxx_map)
    strict_replace(libstdcxx_map,
        "#include <bits/requires_hosted.h> // containers",
        "#if _GLIBCXX_HOSTED\n" ..
        "#include <bits/requires_hosted.h> // containers\n" ..
        "#endif",
        "GCC WebAssembly extended freestanding map availability")
    local ordered_map_header_changed = ordered_map_header_before ~= io.readfile(libstdcxx_map)

    local libstdcxx_version = path.join(src, "libstdc++-v3", "include", "bits", "version.h")
    local ordered_map_feature_before = io.readfile(libstdcxx_version)
    strict_replace(libstdcxx_version,
        "#if !defined(__cpp_lib_generic_associative_lookup)\n" ..
        "# if (__cplusplus >= 201402L) && _GLIBCXX_HOSTED",
        "#if !defined(__cpp_lib_generic_associative_lookup)\n" ..
        "# if (__cplusplus >= 201402L)\n" ..
        "// xmake: GCC WebAssembly extended freestanding ordered map.",
        "GCC WebAssembly extended freestanding generic associative lookup")
    strict_replace(libstdcxx_version,
        "#if !defined(__cpp_lib_erase_if)\n" ..
        "# if (__cplusplus >= 202002L) && _GLIBCXX_HOSTED",
        "#if !defined(__cpp_lib_erase_if)\n" ..
        "# if (__cplusplus >= 202002L)\n" ..
        "// xmake: GCC WebAssembly extended freestanding ordered map erase_if.",
        "GCC WebAssembly extended freestanding ordered map erase_if")
    strict_replace(libstdcxx_version,
        "#if !defined(__cpp_lib_string_udls)\n" ..
        "# if (__cplusplus >= 201402L) && _GLIBCXX_HOSTED",
        "#if !defined(__cpp_lib_string_udls)\n" ..
        "# if (__cplusplus >= 201402L)\n" ..
        "// xmake: GCC WebAssembly extended freestanding string literals.",
        "GCC WebAssembly extended freestanding string literals")
    strict_replace(libstdcxx_version,
        "#if !defined(__cpp_lib_string_view)\n" ..
        "# if (__cplusplus >  202302L) && _GLIBCXX_HOSTED",
        "#if !defined(__cpp_lib_string_view)\n" ..
        "# if (__cplusplus >  202302L)\n" ..
        "// xmake: GCC WebAssembly freestanding string_view feature level.",
        "GCC WebAssembly freestanding C++26 string view feature")
    strict_replace(libstdcxx_version,
        "# elif (__cplusplus >= 201703L) && _GLIBCXX_HOSTED\n" ..
        "#  define __glibcxx_string_view 201803L",
        "# elif (__cplusplus >= 201703L)\n" ..
        "// xmake: GCC WebAssembly freestanding string_view fallback feature level.\n" ..
        "#  define __glibcxx_string_view 201803L",
        "GCC WebAssembly freestanding string view fallback feature")
    strict_replace(libstdcxx_version,
        "#if !defined(__cpp_lib_constexpr_string)\n" ..
        "# if (__cplusplus >= 202002L) && _GLIBCXX_USE_CXX11_ABI && _GLIBCXX_HOSTED && (defined(__glibcxx_is_constant_evaluated))",
        "#if !defined(__cpp_lib_constexpr_string)\n" ..
        "# if (__cplusplus >= 202002L) && _GLIBCXX_USE_CXX11_ABI && (defined(__glibcxx_is_constant_evaluated))\n" ..
        "// xmake: GCC WebAssembly extended freestanding constexpr string.",
        "GCC WebAssembly extended freestanding constexpr string")
    strict_replace(libstdcxx_version,
        "#if !defined(__cpp_lib_incomplete_container_elements)\n" ..
        "# if _GLIBCXX_HOSTED",
        "#if !defined(__cpp_lib_incomplete_container_elements)\n" ..
        "# if 1\n" ..
        "// xmake: GCC WebAssembly extended freestanding vector incomplete elements.",
        "GCC WebAssembly extended freestanding vector incomplete elements")
    strict_replace(libstdcxx_version,
        "#if !defined(__cpp_lib_constexpr_vector)\n" ..
        "# if (__cplusplus >= 202002L) && _GLIBCXX_HOSTED",
        "#if !defined(__cpp_lib_constexpr_vector)\n" ..
        "# if (__cplusplus >= 202002L)\n" ..
        "// xmake: GCC WebAssembly extended freestanding constexpr vector.",
        "GCC WebAssembly extended freestanding constexpr vector")
    local ordered_map_feature_changed = ordered_map_feature_before ~= io.readfile(libstdcxx_version)

    -- GCC's freestanding error helpers call this internal function, whose
    -- upstream implementation enters std::terminate and ultimately needs
    -- a target libc abort(). This profile deliberately has no target libc,
    -- so keep hosted semantics unchanged and lower only freestanding fatal
    -- paths to the WebAssembly trap instruction.
    local libstdcxx_cxxconfig = path.join(src, "libstdc++-v3", "include", "bits", "c++config")
    local freestanding_terminate_before = io.readfile(libstdcxx_cxxconfig)
    strict_replace(libstdcxx_cxxconfig,
        [=[  inline void __terminate() _GLIBCXX_USE_NOEXCEPT
  {
    void terminate() _GLIBCXX_USE_NOEXCEPT __attribute__ ((__noreturn__,__cold__));
    terminate();
  }]=],
        [=[  inline void __terminate() _GLIBCXX_USE_NOEXCEPT
  {
#if _GLIBCXX_HOSTED
    void terminate() _GLIBCXX_USE_NOEXCEPT __attribute__ ((__noreturn__,__cold__));
    terminate();
#else
    // xmake: the no-libc WebAssembly profile terminates through a trap.
    __builtin_trap();
#endif
  }]=],
        "GCC WebAssembly no-libc freestanding termination")
    local freestanding_terminate_changed = freestanding_terminate_before
        ~= io.readfile(libstdcxx_cxxconfig)

    local libstdcxx_string = path.join(src, "libstdc++-v3", "include", "std", "string")
    local string_header_before = io.readfile(libstdcxx_string)
    strict_replace(libstdcxx_string,
        "#include <bits/requires_hosted.h> // containers",
        "#if _GLIBCXX_HOSTED\n" ..
        "#include <bits/requires_hosted.h> // containers\n" ..
        "#endif",
        "GCC WebAssembly extended freestanding string availability")
    strict_replace(libstdcxx_string,
        "#include <bits/cpp_type_traits.h>\n" ..
        "#include <bits/localefwd.h>    // For operators >>, <<, and getline.\n" ..
        "#include <bits/ostream_insert.h>\n" ..
        "#include <bits/stl_iterator_base_funcs.h>",
        "#include <bits/cpp_type_traits.h>\n" ..
        "#if _GLIBCXX_HOSTED\n" ..
        "#include <bits/localefwd.h>    // For operators >>, <<, and getline.\n" ..
        "#include <bits/ostream_insert.h>\n" ..
        "#endif\n" ..
        "#include <bits/stl_iterator_base_funcs.h>",
        "GCC WebAssembly extended freestanding string stream dependencies")
    local string_header_changed = string_header_before ~= io.readfile(libstdcxx_string)

    local libstdcxx_vector = path.join(src, "libstdc++-v3", "include", "std", "vector")
    local vector_header_before = io.readfile(libstdcxx_vector)
    strict_replace(libstdcxx_vector,
        "#include <bits/requires_hosted.h> // container",
        "#if _GLIBCXX_HOSTED\n" ..
        "#include <bits/requires_hosted.h> // container\n" ..
        "#endif",
        "GCC WebAssembly extended freestanding vector availability")
    local vector_header_changed = vector_header_before ~= io.readfile(libstdcxx_vector)

    local libstdcxx_char_traits = path.join(src,
        "libstdc++-v3", "include", "bits", "char_traits.h")
    local char_traits_before = io.readfile(libstdcxx_char_traits)
    strict_replace(libstdcxx_char_traits,
        [=[      static _GLIBCXX17_CONSTEXPR size_t
      length(const char_type* __s)
      {
#if __cplusplus >= 201703L
	if (std::__is_constant_evaluated())
	  return __gnu_cxx::char_traits<char_type>::length(__s);
#endif
	return __builtin_strlen(__s);
      }

      static _GLIBCXX17_CONSTEXPR const char_type*
      find(const char_type* __s, size_t __n, const char_type& __a)
      {
	if (__n == 0)
	  return 0;
#if __cplusplus >= 201703L
	if (std::__is_constant_evaluated())
	  return __gnu_cxx::char_traits<char_type>::find(__s, __n, __a);
#endif
	return static_cast<const char_type*>(__builtin_memchr(__s, __a, __n));
      }]=],
        [=[      static _GLIBCXX17_CONSTEXPR size_t
      length(const char_type* __s)
      {
#if __cplusplus >= 201703L
	if (std::__is_constant_evaluated())
	  return __gnu_cxx::char_traits<char_type>::length(__s);
#endif
	return __builtin_strlen(__s);
      }

      static _GLIBCXX17_CONSTEXPR const char_type*
      find(const char_type* __s, size_t __n, const char_type& __a)
      {
	if (__n == 0)
	  return 0;
#if __cplusplus >= 201703L
	if (std::__is_constant_evaluated())
	  return __gnu_cxx::char_traits<char_type>::find(__s, __n, __a);
#endif
#if _GLIBCXX_HOSTED
	return static_cast<const char_type*>(__builtin_memchr(__s, __a, __n));
#else
	return __gnu_cxx::char_traits<char_type>::find(__s, __n, __a);
#endif
      }]=],
        "GCC WebAssembly freestanding char_traits character search")
    local char_traits_changed = char_traits_before ~= io.readfile(libstdcxx_char_traits)

    local libstdcxx_basic_string = path.join(src, "libstdc++-v3", "include", "bits", "basic_string.h")
    local basic_string_before = io.readfile(libstdcxx_basic_string)
    strict_replace(libstdcxx_basic_string,
        "    { __lhs.swap(__rhs); }\n\n\n" ..
        "  /**\n" ..
        "   *  @brief  Read stream into a string.",
        "    { __lhs.swap(__rhs); }\n\n" ..
        "#if _GLIBCXX_HOSTED\n" ..
        "  /**\n" ..
        "   *  @brief  Read stream into a string.",
        "GCC WebAssembly extended freestanding basic string stream declarations")
    strict_replace_migrated(libstdcxx_basic_string,
        "#endif\n\n" ..
        "_GLIBCXX_END_NAMESPACE_VERSION\n" ..
        "} // namespace\n\n" ..
        "#if __cplusplus >= 201103L\n\n" ..
        "#include <ext/string_conversions.h>",
        "#endif\n\n" ..
        "#endif // _GLIBCXX_HOSTED\n\n" ..
        "_GLIBCXX_END_NAMESPACE_VERSION\n" ..
        "} // namespace\n\n" ..
        "#if __cplusplus >= 201103L && _GLIBCXX_HOSTED\n\n" ..
        "#include <ext/string_conversions.h>",
        "#endif\n\n" ..
        "#endif // _GLIBCXX_HOSTED\n\n" ..
        "_GLIBCXX_END_NAMESPACE_VERSION\n" ..
        "} // namespace\n\n" ..
        "#if __cplusplus >= 201103L && (_GLIBCXX_HOSTED || defined(__wasm32__))\n\n" ..
        "#if _GLIBCXX_HOSTED\n" ..
        "#include <ext/string_conversions.h>\n" ..
        "#endif",
        "GCC WebAssembly extended freestanding basic string integral conversions")
    strict_replace(libstdcxx_basic_string,
        "_GLIBCXX_BEGIN_NAMESPACE_CXX11\n\n" ..
        "  // 21.4 Numeric Conversions [string.conversions].",
        "_GLIBCXX_BEGIN_NAMESPACE_CXX11\n\n" ..
        "#if _GLIBCXX_HOSTED\n" ..
        "  // 21.4 Numeric Conversions [string.conversions].",
        "GCC WebAssembly hosted basic string parsing conversions")
    strict_replace(libstdcxx_basic_string,
        "#endif\n\n" ..
        "  // _GLIBCXX_RESOLVE_LIB_DEFECTS\n" ..
        "  // DR 1261. Insufficent overloads for to_string / to_wstring",
        "#endif\n" ..
        "#endif // _GLIBCXX_HOSTED\n\n" ..
        "  // _GLIBCXX_RESOLVE_LIB_DEFECTS\n" ..
        "  // DR 1261. Insufficent overloads for to_string / to_wstring",
        "GCC WebAssembly hosted basic string parsing conversion boundary")
    strict_replace(libstdcxx_basic_string,
        "    return __str;\n" ..
        "  }\n\n" ..
        "#if __glibcxx_to_string >= 202306L // C++ >= 26",
        "    return __str;\n" ..
        "  }\n\n" ..
        "#if _GLIBCXX_HOSTED\n" ..
        "#if __glibcxx_to_string >= 202306L // C++ >= 26",
        "GCC WebAssembly hosted basic string floating conversions")
    strict_replace(libstdcxx_basic_string,
        "#endif // _GLIBCXX_USE_WCHAR_T\n\n" ..
        "_GLIBCXX_END_NAMESPACE_CXX11",
        "#endif // _GLIBCXX_USE_WCHAR_T\n" ..
        "#endif // _GLIBCXX_HOSTED\n\n" ..
        "_GLIBCXX_END_NAMESPACE_CXX11",
        "GCC WebAssembly hosted basic string floating conversion boundary")
    local basic_string_changed = basic_string_before ~= io.readfile(libstdcxx_basic_string)

    local libstdcxx_basic_string_tcc = path.join(src,
        "libstdc++-v3", "include", "bits", "basic_string.tcc")
    local basic_string_tcc_before = io.readfile(libstdcxx_basic_string_tcc)
    strict_replace(libstdcxx_basic_string_tcc,
        "  // 21.3.7.9 basic_string::getline and operators",
        "#if _GLIBCXX_HOSTED\n" ..
        "  // 21.3.7.9 basic_string::getline and operators",
        "GCC WebAssembly extended freestanding basic string stream definitions")
    strict_replace(libstdcxx_basic_string_tcc,
        "      return __in;\n" ..
        "    }\n\n" ..
        "  // Inhibit implicit instantiations for required instantiations,",
        "      return __in;\n" ..
        "    }\n" ..
        "#endif // _GLIBCXX_HOSTED\n\n" ..
        "  // Inhibit implicit instantiations for required instantiations,",
        "GCC WebAssembly extended freestanding basic string stream definition boundary")
    strict_replace(libstdcxx_basic_string_tcc,
        "#if _GLIBCXX_EXTERN_TEMPLATE\n" ..
        "  // The explicit instantiation definitions in src/c++11/string-inst.cc,",
        "#if _GLIBCXX_EXTERN_TEMPLATE && _GLIBCXX_HOSTED\n" ..
        "  // xmake: freestanding basic_string remains implicitly instantiated.\n" ..
        "  // The explicit instantiation definitions in src/c++11/string-inst.cc,",
        "GCC WebAssembly extended freestanding basic string implicit instantiation")
    local basic_string_tcc_changed = basic_string_tcc_before
        ~= io.readfile(libstdcxx_basic_string_tcc)

    local libstdcxx_new_throw = path.join(src, "libstdc++-v3", "include", "bits", "new_throw.h")
    local new_throw_before = io.readfile(libstdcxx_new_throw)
    strict_replace(libstdcxx_new_throw,
        "#endif\n" ..
        "#endif // HOSTED\n\n" ..
        "_GLIBCXX_END_NAMESPACE_VERSION",
        "#endif\n" ..
        "#else // ! HOSTED\n\n" ..
        "  __attribute__((__noreturn__)) inline void\n" ..
        "  __throw_bad_alloc(void)\n" ..
        "  { std::__terminate(); }\n\n" ..
        "  __attribute__((__noreturn__)) inline void\n" ..
        "  __throw_bad_array_new_length(void)\n" ..
        "  { std::__terminate(); }\n\n" ..
        "#endif // HOSTED\n\n" ..
        "_GLIBCXX_END_NAMESPACE_VERSION",
        "GCC WebAssembly freestanding allocator failure helpers")
    local freestanding_new_throw_changed = new_throw_before ~= io.readfile(libstdcxx_new_throw)

    local libstdcxx_cxx98_make_am = path.join(src, "libstdc++-v3", "src", "c++98", "Makefile.am")
    local libstdcxx_cxx98_make_in = path.join(src, "libstdc++-v3", "src", "c++98", "Makefile.in")
    local ordered_map_runtime_make_am_before = io.readfile(libstdcxx_cxx98_make_am)
    local ordered_map_runtime_make_in_before = io.readfile(libstdcxx_cxx98_make_in)
    strict_replace(libstdcxx_cxx98_make_am,
        "else\n" ..
        "libc__98convenience_la_SOURCES =\n" ..
        "endif",
        "else\n" ..
        "libc__98convenience_la_SOURCES = tree.cc\n" ..
        "endif",
        "GCC WebAssembly extended freestanding ordered map runtime")
    strict_replace(libstdcxx_cxx98_make_in,
        "@GLIBCXX_HOSTED_FALSE@libc__98convenience_la_SOURCES = ",
        "@GLIBCXX_HOSTED_FALSE@libc__98convenience_la_SOURCES = tree.cc",
        "GCC WebAssembly configured extended freestanding ordered map runtime")
    strict_replace(libstdcxx_cxx98_make_in,
        "@GLIBCXX_HOSTED_TRUE@am_libc__98convenience_la_OBJECTS =  \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t$(am__objects_7)",
        "@GLIBCXX_HOSTED_FALSE@am_libc__98convenience_la_OBJECTS = tree.lo\n" ..
        "@GLIBCXX_HOSTED_TRUE@am_libc__98convenience_la_OBJECTS =  \\\n" ..
        "@GLIBCXX_HOSTED_TRUE@\t$(am__objects_7)",
        "GCC WebAssembly configured extended freestanding ordered map runtime object")
    local ordered_map_runtime_changed = ordered_map_runtime_make_am_before
        ~= io.readfile(libstdcxx_cxx98_make_am)
        or ordered_map_runtime_make_in_before ~= io.readfile(libstdcxx_cxx98_make_in)
    wasm_freestanding_include_headers_changed = wasm_freestanding_include_headers_changed
        or freestanding_cxx26_wrapper_headers_changed
        or ordered_map_install_headers_changed
        or callable_hash_install_headers_changed
        or string_install_headers_changed
        or vector_install_headers_changed
        or chrono_install_headers_changed
        or cstring_install_headers_changed
        or functional_header_changed
        or std_function_header_changed
        or unordered_map_header_changed
        or unordered_map_feature_changed
        or cstring_header_changed
        or freestanding_terminate_changed

    -- <generator> is installed as part of libstdc++'s freestanding
    -- header set. Its <cstring> include is unused by the implementation
    -- and that hosted C wrapper is intentionally absent without a libc.
    local libstdcxx_generator = path.join(src, "libstdc++-v3", "include", "std", "generator")
    local generator_before = io.readfile(libstdcxx_generator)
    strict_replace(libstdcxx_generator,
        "#include <cstdint>\n#include <cstring>\n#include <coroutine>",
        "#include <cstdint>\n" ..
        "#if _GLIBCXX_HOSTED\n" ..
        "#include <cstring>\n" ..
        "#endif\n" ..
        "#include <coroutine>",
        "GCC WebAssembly freestanding libstdc++ generator header")
    strict_replace(libstdcxx_generator,
        "#include <bits/elements_of.h>\n#include <bits/uses_allocator.h>",
        "#include <bits/elements_of.h>\n" ..
        "#include <bits/alloc_traits.h>\n" ..
        "#include <bits/uses_allocator.h>",
        "GCC WebAssembly freestanding libstdc++ generator allocator traits")
    local generator_header_changed = generator_before ~= io.readfile(libstdcxx_generator)

    -- Freestanding containers diagnose invalid input through the same
    -- helper surface as hosted <stdexcept>. Keep those failure paths
    -- terminate-backed without introducing the hosted exception runtime.
    local libstdcxx_stdexcept_throwfwd = path.join(src,
        "libstdc++-v3", "include", "bits", "stdexcept_throwfwd.h")
    local stdexcept_throwfwd_before = io.readfile(libstdcxx_stdexcept_throwfwd)
    strict_replace(libstdcxx_stdexcept_throwfwd,
        [=[#else // ! HOSTED

  __attribute__((__noreturn__)) inline void
  __throw_invalid_argument(const char*)]=],
        [=[#else // ! HOSTED

  __attribute__((__noreturn__)) inline void
  __throw_logic_error(const char*)
  { std::__terminate(); }

  __attribute__((__noreturn__)) inline void
  __throw_length_error(const char*)
  { std::__terminate(); }

  __attribute__((__noreturn__)) inline void
  __throw_invalid_argument(const char*)]=],
        "GCC WebAssembly freestanding libstdc++ logic and length error helpers")
    local freestanding_exception_helper_changed = stdexcept_throwfwd_before
        ~= io.readfile(libstdcxx_stdexcept_throwfwd)

    ctx.flags.wasm_freestanding_include_headers_changed = wasm_freestanding_include_headers_changed
    return {
        include_headers_changed = wasm_freestanding_include_headers_changed,
        sources_changed_any = freestanding_cxx26_wrapper_headers_changed
            or ordered_map_install_headers_changed
            or callable_hash_install_headers_changed
            or string_install_headers_changed
            or vector_install_headers_changed
            or chrono_install_headers_changed
            or cstring_install_headers_changed
            or hosted_compat_install_headers_changed
            or ordered_map_header_changed
            or ordered_map_feature_changed
            or ordered_map_runtime_changed
            or unordered_map_runtime_changed
            or functional_header_changed
            or std_function_header_changed
            or unordered_map_header_changed
            or unordered_map_feature_changed
            or freestanding_terminate_changed
            or string_header_changed
            or vector_header_changed
            or cstring_header_changed
            or hosted_compat_header_changed
            or char_traits_changed
            or basic_string_changed
            or basic_string_tcc_changed
            or freestanding_new_throw_changed
            or generator_header_changed
            or freestanding_exception_helper_changed
    }
end

function _apply_std_module(ctx, headers_flags)
    local src = ctx.src
    local function strict_replace(file, original, replacement, label)
        return shared.strict_replace(ctx, file, original, replacement, label)
    end
    local function strict_replace_migrated(file, original, previous, replacement, label)
        return shared.strict_replace_migrated(ctx, file, original, previous, replacement, label)
    end

    -- libstdc++ installs a deliberately reduced header set when configured
    -- with --disable-hosted-libstdcxx, but its std module template still
    -- includes bits/stdc++.h and exports every hosted header. Generate the
    -- module from libstdc++'s own freestanding header set instead. The
    -- hosted branch remains byte-for-byte equivalent to upstream behavior.
    local libstdcxx_std = path.join(src, "libstdc++-v3", "src", "c++23", "std.cc.in")
    local hosted_std_preamble = [=[module;

#include <bits/stdc++.h>

// stdc++.h doesn't include <execution> because of TBB issues;
// FIXME for now let's avoid the problem by suppressing TBB.
#ifdef _PSTL_PAR_BACKEND_TBB
#undef _PSTL_PAR_BACKEND_TBB
#define _PSTL_PAR_BACKEND_SERIAL
#endif
#include <execution>

// Module std does include deprecated library interfaces.
#undef __DEPRECATED
#include <strstream>]=]
    local previous_freestanding_std_preamble = [=[module;

#include <bits/c++config.h>

#if _GLIBCXX_HOSTED
#include <bits/stdc++.h>

// stdc++.h doesn't include <execution> because of TBB issues;
// FIXME for now let's avoid the problem by suppressing TBB.
#ifdef _PSTL_PAR_BACKEND_TBB
#undef _PSTL_PAR_BACKEND_TBB
#define _PSTL_PAR_BACKEND_SERIAL
#endif
#include <execution>

// Module std does include deprecated library interfaces.
#undef __DEPRECATED
#include <strstream>
#else
// xmake: GCC WebAssembly freestanding std-module headers.
#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <bitset>
#include <compare>
#include <concepts>
#include <contracts>
#include <coroutine>
#include <cfloat>
#include <climits>
#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <expected>
#include <functional>
#include <generator>
#include <initializer_list>
#include <iterator>
#include <limits>
#include <mdspan>
#include <memory>
#include <new>
#include <numbers>
#include <numeric>
#include <optional>
#include <ranges>
#include <ratio>
#include <scoped_allocator>
#include <source_location>
#include <span>
#include <string_view>
#include <tuple>
#include <type_traits>
#include <typeindex>
#include <typeinfo>
#include <utility>
#include <variant>
#include <version>
#endif]=]
    local ordered_map_freestanding_std_preamble = base.replace_plain(
        previous_freestanding_std_preamble,
        "#include <limits>\n" ..
        "#include <mdspan>",
        "#include <limits>\n" ..
        "#include <map>\n" ..
        "#include <mdspan>")
    local string_freestanding_std_preamble = base.replace_plain(
        ordered_map_freestanding_std_preamble,
        "#include <span>\n" ..
        "#include <string_view>",
        "#include <span>\n" ..
        "#include <string>\n" ..
        "#include <string_view>")
    local vector_freestanding_std_preamble = base.replace_plain(
        string_freestanding_std_preamble,
        "#include <variant>\n" ..
        "#include <version>",
        "#include <variant>\n" ..
        "#include <vector>\n" ..
        "#include <version>")
    local chrono_freestanding_std_preamble = base.replace_plain(
        vector_freestanding_std_preamble,
        "#include <bitset>\n" ..
        "#include <compare>",
        "#include <bitset>\n" ..
        "#include <chrono>\n" ..
        "#include <compare>")
    local cstring_freestanding_std_preamble = base.replace_plain(
        chrono_freestanding_std_preamble,
        "#include <cstdint>\n" ..
        "#include <cstdlib>",
        "#include <cstdint>\n" ..
        "#include <cstdlib>\n" ..
        "#include <cstring>")
    local format_freestanding_std_preamble = base.replace_plain(
        cstring_freestanding_std_preamble,
        "#include <expected>\n" ..
        "#include <functional>",
        "#include <expected>\n" ..
        "#include <format>\n" ..
        "#include <functional>")
    local istream_freestanding_std_preamble = base.replace_plain(
        format_freestanding_std_preamble,
        "#include <generator>\n" ..
        "#include <initializer_list>",
        "#include <generator>\n" ..
        "#include <initializer_list>\n" ..
        "#include <istream>")
    local format_stream_freestanding_std_preamble = base.replace_plain(
        istream_freestanding_std_preamble,
        "#include <optional>\n" ..
        "#include <ranges>",
        "#include <optional>\n" ..
        "#include <ostream>\n" ..
        "#include <print>\n" ..
        "#include <ranges>")
    local freestanding_std_preamble = base.replace_plain(
        format_stream_freestanding_std_preamble,
        "#include <typeindex>\n" ..
        "#include <typeinfo>\n" ..
        "#include <utility>",
        "#include <typeindex>\n" ..
        "#include <typeinfo>\n" ..
        "#include <unordered_map>\n" ..
        "#include <utility>")
    freestanding_std_preamble = base.replace_plain(
        freestanding_std_preamble,
        "#include <string_view>\n" ..
        "#include <tuple>",
        "#include <string_view>\n" ..
        "#include <stdexcept>\n" ..
        "#include <tuple>")
    local legacy_freestanding_std_preamble = base.replace_plain(
        previous_freestanding_std_preamble,
        "#include <climits>\n" ..
        "#include <cstdarg>\n" ..
        "#include <cstddef>",
        "#include <climits>\n" ..
        "#include <cstdalign>\n" ..
        "#include <cstdarg>\n" ..
        "#include <cstdbool>\n" ..
        "#include <cstddef>")
    local std_before = io.readfile(libstdcxx_std)
    if not std_before:find(freestanding_std_preamble, 1, true) then
        if std_before:find(base.replace_plain(freestanding_std_preamble,
                "#include <stdexcept>\n", ""), 1, true) then
            strict_replace(libstdcxx_std,
                base.replace_plain(freestanding_std_preamble,
                    "#include <stdexcept>\n", ""),
                freestanding_std_preamble,
                "GCC WebAssembly freestanding stdexcept std module header migration")
        elseif std_before:find(format_stream_freestanding_std_preamble, 1, true) then
            strict_replace(libstdcxx_std, format_stream_freestanding_std_preamble,
                freestanding_std_preamble,
                "GCC WebAssembly extended freestanding unordered map std module header migration")
        elseif std_before:find(cstring_freestanding_std_preamble, 1, true) then
            strict_replace(libstdcxx_std, cstring_freestanding_std_preamble,
                freestanding_std_preamble,
                "GCC WebAssembly extended freestanding format, stream, and unordered map std module header migration")
        elseif std_before:find(chrono_freestanding_std_preamble, 1, true) then
            strict_replace(libstdcxx_std, chrono_freestanding_std_preamble,
                freestanding_std_preamble,
                "GCC WebAssembly freestanding libstdc++ cstring, format, and stream std module header migration")
        elseif std_before:find(vector_freestanding_std_preamble, 1, true) then
            strict_replace(libstdcxx_std, vector_freestanding_std_preamble,
                freestanding_std_preamble,
                "GCC WebAssembly freestanding libstdc++ chrono and cstring std module header migration")
        elseif std_before:find(string_freestanding_std_preamble, 1, true) then
            strict_replace(libstdcxx_std, string_freestanding_std_preamble,
                freestanding_std_preamble,
                "GCC WebAssembly extended freestanding libstdc++ vector and chrono std module header migration")
        elseif std_before:find(ordered_map_freestanding_std_preamble, 1, true) then
            strict_replace(libstdcxx_std, ordered_map_freestanding_std_preamble,
                freestanding_std_preamble,
                "GCC WebAssembly extended freestanding libstdc++ string, vector, and chrono std module header migration")
        elseif std_before:find(previous_freestanding_std_preamble, 1, true) then
            strict_replace(libstdcxx_std, previous_freestanding_std_preamble,
                freestanding_std_preamble,
                "GCC WebAssembly extended freestanding libstdc++ std module header migration")
        elseif std_before:find(legacy_freestanding_std_preamble, 1, true) then
            strict_replace(libstdcxx_std, legacy_freestanding_std_preamble,
                freestanding_std_preamble,
                "GCC WebAssembly extended freestanding libstdc++ legacy std module header migration")
        else
            strict_replace(libstdcxx_std, hosted_std_preamble,
                freestanding_std_preamble,
                "GCC WebAssembly freestanding libstdc++ std module headers")
        end
    end
    local std_headers_changed = std_before ~= io.readfile(libstdcxx_std)

    local freestanding_cpp_headers = {
        algorithm = true,
        array = true,
        atomic = true,
        bit = true,
        bitset = true,
        compare = true,
        concepts = true,
        contracts = true,
        coroutine = true,
        exception = true,
        expected = true,
        functional = true,
        generator = true,
        initializer_list = true,
        iterator = true,
        limits = true,
        map = true,
        mdspan = true,
        memory = true,
        new = true,
        numbers = true,
        numeric = true,
        optional = true,
        ranges = true,
        ratio = true,
        scoped_allocator = true,
        source_location = true,
        span = true,
        string_view = true,
        tuple = true,
        type_traits = true,
        typeindex = true,
        typeinfo = true,
        utility = true,
        variant = true,
        vector = true
    }
    local freestanding_c_headers = {
        cfloat = true,
        climits = true,
        cstdarg = true,
        cstddef = true,
        cstdint = true
    }
    local freestanding_cstdlib_exports = {
        "#else",
        "export C_LIB_NAMESPACE",
        "{",
        "  using std::abort;",
        "  using std::abs;",
        "  using std::atexit;",
        "  using std::exit;",
        "#ifdef _GLIBCXX_HAVE_AT_QUICK_EXIT",
        "  using std::at_quick_exit;",
        "#endif",
        "#ifdef _GLIBCXX_HAVE_QUICK_EXIT",
        "  using std::quick_exit;",
        "#endif",
        "}"
    }

    local function patch_freestanding_module_exports(file, export_anchor, allowed_headers,
            cstdlib_fallback, label)
        local marker = "// xmake: GCC WebAssembly freestanding-aware module exports."
        local content = io.readfile(file)
        if content:find(marker, 1, true) then
            return false
        end

        local lines = {}
        local line_begin = 1
        while true do
            local line_end = content:find("\n", line_begin, true)
            if not line_end then
                table.insert(lines, content:sub(line_begin))
                break
            end
            table.insert(lines, content:sub(line_begin, line_end - 1))
            line_begin = line_end + 1
        end
        local patched = {}
        local after_export = false
        local hosted_block = false
        local block_header
        local header_count = 0
        local hosted_count = 0

        local function close_block()
            if not hosted_block then
                return
            end
            if block_header == "cstdlib" and cstdlib_fallback then
                for _, line in ipairs(cstdlib_fallback) do
                    table.insert(patched, line)
                end
            end
            table.insert(patched, "#endif // _GLIBCXX_HOSTED")
            hosted_block = false
            block_header = nil
        end

        for _, line in ipairs(lines) do
            if line == export_anchor then
                after_export = true
                table.insert(patched, line)
                table.insert(patched, marker)
            elseif after_export then
                local header = line:match("^//.*<([%w_%.]+)>")
                if header then
                    close_block()
                    header_count = header_count + 1
                    block_header = header
                    if not allowed_headers[header] then
                        table.insert(patched, "#if _GLIBCXX_HOSTED")
                        hosted_block = true
                        hosted_count = hosted_count + 1
                    end
                end
                table.insert(patched, line)
            else
                table.insert(patched, line)
            end
        end
        close_block()

        if not after_export or header_count == 0 or hosted_count == 0 then
            errors.fail("cannot apply %s: the pinned upstream module export layout drifted in %s", label, file)
        end

        local replacement = table.concat(patched, "\n")
        if content:sub(-1) == "\n" and replacement:sub(-1) ~= "\n" then
            replacement = replacement .. "\n"
        end
        print("patching " .. label .. ": " .. path.relative(file, src))
        base.writefile_bytes(file, replacement)
        return true
    end

    local std_exports_changed = patch_freestanding_module_exports(
        libstdcxx_std, "export module std;", freestanding_cpp_headers, nil,
        "GCC WebAssembly freestanding libstdc++ std module exports")

    local previous_freestanding_hosted_compat_exports = [=[#if !_GLIBCXX_HOSTED
// xmake: GCC WebAssembly extended freestanding hosted-surface exports.
export namespace std
{
  using std::basic_format_context;
  using std::basic_format_parse_context;
  using std::basic_format_string;
  using std::format;
  using std::format_context;
  using std::format_error;
  using std::format_kind;
  using std::format_parse_context;
  using std::format_string;
  using std::format_to;
  using std::formattable;
  using std::formatter;
  using std::range_format;
  using std::basic_istream;
  using std::basic_ostream;
  using std::istream;
  using std::ostream;
#ifdef _GLIBCXX_USE_WCHAR_T
  using std::wistream;
  using std::wostream;
#endif
  using std::print;
  using std::println;
}
#endif // !_GLIBCXX_HOSTED

]=]
    local single_thread_freestanding_hosted_compat_exports = [=[#if !_GLIBCXX_HOSTED
// xmake: GCC WebAssembly extended freestanding hosted-surface exports.
export namespace std
{
  using std::basic_format_context;
  using std::basic_format_parse_context;
  using std::basic_format_string;
  using std::format;
  using std::format_context;
  using std::format_error;
  using std::format_kind;
  using std::format_parse_context;
  using std::format_string;
  using std::format_to;
  using std::formattable;
  using std::formatter;
  using std::range_format;
  using std::basic_istream;
  using std::basic_ostream;
  using std::istream;
  using std::ostream;
#ifdef _GLIBCXX_USE_WCHAR_T
  using std::wistream;
  using std::wostream;
#endif
  using std::print;
  using std::println;
  using std::adopt_lock;
  using std::adopt_lock_t;
  using std::condition_variable;
  using std::condition_variable_any;
  using std::cv_status;
  using std::defer_lock;
  using std::defer_lock_t;
  using std::jthread;
  using std::latch;
  using std::lock_guard;
  using std::mutex;
  using std::nostopstate;
  using std::nostopstate_t;
  using std::recursive_mutex;
  using std::recursive_timed_mutex;
  using std::scoped_lock;
  using std::shared_lock;
  using std::shared_mutex;
  using std::shared_timed_mutex;
  using std::stop_source;
  using std::stop_token;
  using std::thread;
  using std::timed_mutex;
  using std::try_to_lock;
  using std::try_to_lock_t;
  using std::unique_lock;
  namespace this_thread
  {
    using std::this_thread::get_id;
    using std::this_thread::sleep_for;
    using std::this_thread::sleep_until;
    using std::this_thread::yield;
  }
}
#endif // !_GLIBCXX_HOSTED

]=]
    local freestanding_hosted_compat_exports = base.replace_plain(
        single_thread_freestanding_hosted_compat_exports,
        "  using std::print;\n" ..
        "  using std::println;\n" ..
        "  using std::adopt_lock;",
        "  using std::print;\n" ..
        "  using std::println;\n" ..
        "  using std::bad_function_call;\n" ..
        "  using std::function;\n" ..
        "  using std::unordered_map;\n" ..
        "  using std::unordered_multimap;\n" ..
        "  using std::adopt_lock;")
    freestanding_hosted_compat_exports = base.replace_plain(
        freestanding_hosted_compat_exports,
        "  using std::thread;\n" ..
        "  using std::timed_mutex;",
        "  using std::thread;\n" ..
        "  using std::hash;\n" ..
        "  using std::timed_mutex;")
    local hosted_compat_export_anchor = "#if _GLIBCXX_HOSTED\n// <format>"
    local hosted_compat_exports_before = io.readfile(libstdcxx_std)
    local hosted_compat_exports_content = hosted_compat_exports_before
    if not hosted_compat_exports_content:find(
            freestanding_hosted_compat_exports .. hosted_compat_export_anchor, 1, true) then
        if hosted_compat_exports_content:find(base.replace_plain(
                freestanding_hosted_compat_exports,
                "  using std::thread;\n" ..
                "  using std::hash;\n" ..
                "  using std::timed_mutex;",
                "  using std::thread;\n" ..
                "  using std::timed_mutex;") .. hosted_compat_export_anchor, 1, true) then
            strict_replace(libstdcxx_std,
                base.replace_plain(
                    freestanding_hosted_compat_exports,
                    "  using std::thread;\n" ..
                    "  using std::hash;\n" ..
                    "  using std::timed_mutex;",
                    "  using std::thread;\n" ..
                    "  using std::timed_mutex;") .. hosted_compat_export_anchor,
                freestanding_hosted_compat_exports .. hosted_compat_export_anchor,
                "GCC WebAssembly freestanding thread hash module export migration")
        elseif hosted_compat_exports_content:find(
                single_thread_freestanding_hosted_compat_exports
                    .. hosted_compat_export_anchor, 1, true) then
            strict_replace(libstdcxx_std,
                single_thread_freestanding_hosted_compat_exports
                    .. hosted_compat_export_anchor,
                freestanding_hosted_compat_exports .. hosted_compat_export_anchor,
                "GCC WebAssembly extended freestanding callable and unordered map module exports migration")
        elseif hosted_compat_exports_content:find(
                previous_freestanding_hosted_compat_exports
                    .. hosted_compat_export_anchor, 1, true) then
            strict_replace(libstdcxx_std,
                previous_freestanding_hosted_compat_exports
                    .. hosted_compat_export_anchor,
                freestanding_hosted_compat_exports .. hosted_compat_export_anchor,
                "GCC WebAssembly extended freestanding hosted-surface module exports migration")
        else
            strict_replace(libstdcxx_std,
                hosted_compat_export_anchor,
                freestanding_hosted_compat_exports .. hosted_compat_export_anchor,
                "GCC WebAssembly extended freestanding hosted-surface module exports")
        end
    end
    local hosted_compat_exports_changed = hosted_compat_exports_before
        ~= io.readfile(libstdcxx_std)

    local ordered_map_export_block = [=[// <map>
export namespace std
{
  using std::map;
  using std::operator==;
  using std::operator<=>;
  using std::erase_if;
  using std::multimap;
  using std::swap;
  namespace pmr
  {
    using std::pmr::map;
    using std::pmr::multimap;
  }
}]=]
    local ordered_map_wrapped_export_block =
        "#if _GLIBCXX_HOSTED\n" .. ordered_map_export_block ..
        "\n\n#endif // _GLIBCXX_HOSTED"
    local ordered_map_exports_changed = false
    local ordered_map_exports_content = io.readfile(libstdcxx_std)
    if ordered_map_exports_content:find(ordered_map_wrapped_export_block, 1, true) then
        print("patching GCC WebAssembly extended freestanding ordered map module exports: " ..
            path.relative(libstdcxx_std, src))
        base.writefile_bytes(libstdcxx_std, base.replace_plain(
            ordered_map_exports_content, ordered_map_wrapped_export_block,
            ordered_map_export_block))
        ordered_map_exports_changed = true
    elseif not ordered_map_exports_content:find(ordered_map_export_block, 1, true) then
        errors.fail("cannot apply GCC WebAssembly extended freestanding ordered map module exports: " ..
            "the pinned upstream anchor drifted in %s", libstdcxx_std)
    end

    local vector_export_block = [=[// <vector>
export namespace std
{
  using std::vector;
  using std::operator==;
  using std::operator<=>;
  using std::erase;
  using std::erase_if;
  using std::swap;
  namespace pmr
  {
    using std::pmr::vector;
  }
  using std::hash;
}]=]
    local vector_wrapped_export_block =
        "#if _GLIBCXX_HOSTED\n" .. vector_export_block ..
        "\n\n#endif // _GLIBCXX_HOSTED"
    local vector_exports_changed = false
    local vector_exports_content = io.readfile(libstdcxx_std)
    if vector_exports_content:find(vector_wrapped_export_block, 1, true) then
        print("patching GCC WebAssembly extended freestanding vector module exports: " ..
            path.relative(libstdcxx_std, src))
        base.writefile_bytes(libstdcxx_std, base.replace_plain(
            vector_exports_content, vector_wrapped_export_block,
            vector_export_block))
        vector_exports_changed = true
    elseif not vector_exports_content:find(vector_export_block, 1, true) then
        errors.fail("cannot apply GCC WebAssembly extended freestanding vector module exports: " ..
            "the pinned upstream anchor drifted in %s", libstdcxx_std)
    end

    local freestanding_chrono_export_block = [=[#if !_GLIBCXX_HOSTED
// xmake: GCC WebAssembly freestanding chrono core module exports.
// <chrono>
export namespace std
{
  namespace chrono
  {
    using std::chrono::duration;
    using std::chrono::time_point;
    using std::chrono::duration_values;
    using std::chrono::treat_as_floating_point;
    using std::chrono::treat_as_floating_point_v;
    using std::chrono::operator+;
    using std::chrono::operator-;
    using std::chrono::operator*;
    using std::chrono::operator/;
    using std::chrono::operator%;
    using std::chrono::operator==;
    using std::chrono::operator<=>;
    using std::chrono::ceil;
    using std::chrono::duration_cast;
    using std::chrono::floor;
    using std::chrono::round;
    using std::chrono::abs;
    using std::chrono::day;
    using std::chrono::days;
    using std::chrono::hh_mm_ss;
    using std::chrono::high_resolution_clock;
    using std::chrono::hours;
    using std::chrono::is_am;
    using std::chrono::is_pm;
    using std::chrono::last_spec;
    using std::chrono::make12;
    using std::chrono::make24;
    using std::chrono::microseconds;
    using std::chrono::milliseconds;
    using std::chrono::minutes;
    using std::chrono::month;
    using std::chrono::month_day;
    using std::chrono::month_day_last;
    using std::chrono::month_weekday;
    using std::chrono::month_weekday_last;
    using std::chrono::months;
    using std::chrono::nanoseconds;
    using std::chrono::seconds;
    using std::chrono::sys_days;
    using std::chrono::sys_seconds;
    using std::chrono::sys_time;
    using std::chrono::system_clock;
    using std::chrono::time_point_cast;
    using std::chrono::weekday;
    using std::chrono::weekday_indexed;
    using std::chrono::weekday_last;
    using std::chrono::weeks;
    using std::chrono::year;
    using std::chrono::year_month;
    using std::chrono::year_month_day;
    using std::chrono::year_month_day_last;
    using std::chrono::year_month_weekday;
    using std::chrono::year_month_weekday_last;
    using std::chrono::years;
    using std::chrono::local_days;
    using std::chrono::local_seconds;
    using std::chrono::local_t;
    using std::chrono::local_time;
    using std::chrono::April;
    using std::chrono::August;
    using std::chrono::December;
    using std::chrono::February;
    using std::chrono::Friday;
    using std::chrono::January;
    using std::chrono::July;
    using std::chrono::June;
    using std::chrono::last;
    using std::chrono::March;
    using std::chrono::May;
    using std::chrono::Monday;
    using std::chrono::November;
    using std::chrono::October;
    using std::chrono::Saturday;
    using std::chrono::September;
    using std::chrono::Sunday;
    using std::chrono::Thursday;
    using std::chrono::Tuesday;
    using std::chrono::Wednesday;
  }
}
export namespace std::inline literals::inline chrono_literals
{
  using std::literals::chrono_literals::operator""h;
  using std::literals::chrono_literals::operator""min;
  using std::literals::chrono_literals::operator""s;
  using std::literals::chrono_literals::operator""ms;
  using std::literals::chrono_literals::operator""us;
  using std::literals::chrono_literals::operator""ns;
  using std::literals::chrono_literals::operator""d;
  using std::literals::chrono_literals::operator""y;
}
export namespace std::chrono
{
  using namespace literals::chrono_literals;
}
#endif // !_GLIBCXX_HOSTED]=]
    local chrono_export_anchor = [=[export namespace std::chrono {
  using namespace literals::chrono_literals;
}

#endif // _GLIBCXX_HOSTED]=]
    local chrono_exports_before = io.readfile(libstdcxx_std)
    strict_replace(libstdcxx_std, chrono_export_anchor,
        chrono_export_anchor .. "\n" .. freestanding_chrono_export_block,
        "GCC WebAssembly freestanding chrono core module exports")
    local chrono_exports_changed = chrono_exports_before ~= io.readfile(libstdcxx_std)

    local hosted_string_export_block = [=[#if _GLIBCXX_HOSTED
// <string>
export namespace std
{
  using std::basic_string;
  using std::char_traits;
  using std::operator+;
  using std::operator==;
  using std::operator<=>;
  using std::swap;
  using std::operator>>;
  using std::operator<<;
  using std::erase;
  using std::erase_if;
  using std::getline;
  using std::stod;
  using std::stof;
  using std::stoi;
  using std::stol;
  using std::stold;
  using std::stoll;
  using std::stoul;
  using std::stoull;
  using std::string;
  using std::to_string;
  using std::to_wstring;
  using std::u16string;
  using std::u32string;
  using std::u8string;
  using std::wstring;
  namespace pmr
  {
#if _GLIBCXX_USE_CXX11_ABI
    using std::pmr::basic_string;
    using std::pmr::string;
    using std::pmr::u16string;
    using std::pmr::u32string;
    using std::pmr::u8string;
    using std::pmr::wstring;
#endif
  }
  using std::hash;
}
export namespace std::inline literals::inline string_literals
{
  using std::operator""s;
}

#endif // _GLIBCXX_HOSTED]=]
    local freestanding_string_export_block = [=[#if !_GLIBCXX_HOSTED
// xmake: GCC WebAssembly extended freestanding string module exports.
// <string>
export namespace std
{
  using std::basic_string;
  using std::char_traits;
  using std::operator+;
  using std::operator==;
  using std::operator<=>;
  using std::swap;
  using std::erase;
  using std::erase_if;
  using std::string;
  using std::to_string;
  using std::u16string;
  using std::u32string;
  using std::u8string;
  using std::wstring;
  namespace pmr
  {
#if _GLIBCXX_USE_CXX11_ABI
    using std::pmr::basic_string;
    using std::pmr::string;
    using std::pmr::u16string;
    using std::pmr::u32string;
    using std::pmr::u8string;
    using std::pmr::wstring;
#endif
  }
  using std::hash;
}
export namespace std::inline literals::inline string_literals
{
  using std::operator""s;
}
#endif // !_GLIBCXX_HOSTED]=]
    local string_exports_changed = false
    local string_exports_content = io.readfile(libstdcxx_std)
    if not string_exports_content:find(
            "// xmake: GCC WebAssembly extended freestanding string module exports.",
            1, true) then
        local patched_string_exports = base.replace_plain(string_exports_content,
            hosted_string_export_block,
            hosted_string_export_block .. "\n" .. freestanding_string_export_block)
        if patched_string_exports == string_exports_content then
            errors.fail("cannot apply GCC WebAssembly extended freestanding string module exports: " ..
                "the pinned upstream anchor drifted in %s", libstdcxx_std)
        end
        print("patching GCC WebAssembly extended freestanding string module exports: " ..
            path.relative(libstdcxx_std, src))
        base.writefile_bytes(libstdcxx_std, patched_string_exports)
        string_exports_changed = true
    end
    string_exports_content = io.readfile(libstdcxx_std)
    strict_replace(libstdcxx_std,
        "  using std::string;\n" ..
        "  using std::u16string;",
        "  using std::string;\n" ..
        "  using std::to_string;\n" ..
        "  using std::u16string;",
        "GCC WebAssembly freestanding integral to_string module export")
    string_exports_changed = string_exports_changed
        or string_exports_content ~= io.readfile(libstdcxx_std)

    -- Several headers are only partially freestanding. Mirror the guards
    -- already used by those headers so the module does not try to export
    -- declarations that were intentionally omitted by the header itself.
    local partial_exports_before = io.readfile(libstdcxx_std)
    strict_replace(libstdcxx_std,
        [=[  using std::stable_partition;
  namespace ranges
  {
    using std::ranges::stable_partition;
  }]=],
        [=[#if _GLIBCXX_HOSTED
  using std::stable_partition;
  namespace ranges
  {
    using std::ranges::stable_partition;
  }
#endif]=],
        "GCC WebAssembly freestanding std module algorithm exports")
    strict_replace(libstdcxx_std,
        [=[  using std::atomic_int16_t;
  using std::atomic_int32_t;
  using std::atomic_int64_t;
  using std::atomic_int8_t;]=],
        [=[#ifdef _GLIBCXX_USE_C99_STDINT
  using std::atomic_int16_t;
  using std::atomic_int32_t;
  using std::atomic_int64_t;
  using std::atomic_int8_t;
#endif]=],
        "GCC WebAssembly freestanding std module signed exact-width atomic exports")
    strict_replace(libstdcxx_std,
        [=[  using std::atomic_uint16_t;
  using std::atomic_uint32_t;
  using std::atomic_uint64_t;
  using std::atomic_uint8_t;]=],
        [=[#ifdef _GLIBCXX_USE_C99_STDINT
  using std::atomic_uint16_t;
  using std::atomic_uint32_t;
  using std::atomic_uint64_t;
  using std::atomic_uint8_t;
#endif]=],
        "GCC WebAssembly freestanding std module unsigned exact-width atomic exports")
    strict_replace(libstdcxx_std,
        [=[  using std::bad_function_call;
  using std::function;
  using std::mem_fn;]=],
        [=[#if _GLIBCXX_HOSTED
  using std::bad_function_call;
  using std::function;
#endif
  using std::mem_fn;]=],
        "GCC WebAssembly freestanding std module function exports")
    strict_replace(libstdcxx_std,
        [=[  using std::boyer_moore_horspool_searcher;
  using std::boyer_moore_searcher;]=],
        [=[#if _GLIBCXX_HOSTED
  using std::boyer_moore_horspool_searcher;
  using std::boyer_moore_searcher;
#endif]=],
        "GCC WebAssembly freestanding std module searcher exports")
    strict_replace(libstdcxx_std,
        [=[  using std::istream_iterator;
  using std::istreambuf_iterator;]=],
        [=[#if _GLIBCXX_HOSTED
  using std::istream_iterator;
  using std::istreambuf_iterator;
#endif]=],
        "GCC WebAssembly freestanding std module input stream iterator exports")
    strict_replace(libstdcxx_std,
        [=[  using std::ostream_iterator;
  using std::ostreambuf_iterator;]=],
        [=[#if _GLIBCXX_HOSTED
  using std::ostream_iterator;
  using std::ostreambuf_iterator;
#endif]=],
        "GCC WebAssembly freestanding std module output stream iterator exports")
    strict_replace_migrated(libstdcxx_std,
        [=[  using std::make_unique;
  using std::make_unique_for_overwrite;]=],
        [=[#if _GLIBCXX_HOSTED
  using std::make_unique;
  using std::make_unique_for_overwrite;
#endif]=],
        [=[#ifdef __glibcxx_make_unique
  using std::make_unique;
  using std::make_unique_for_overwrite;
#endif]=],
        "GCC WebAssembly freestanding std module make_unique exports")
    strict_replace_migrated(libstdcxx_std,
        [=[// 19.2 <stdexcept>
export namespace std
{
  using std::domain_error;
  using std::invalid_argument;
  using std::length_error;
  using std::logic_error;
  using std::out_of_range;
  using std::overflow_error;
  using std::range_error;
  using std::runtime_error;
  using std::underflow_error;
}]=],
        [=[#if _GLIBCXX_HOSTED
// 19.2 <stdexcept>
export namespace std
{
  using std::domain_error;
  using std::invalid_argument;
  using std::length_error;
  using std::logic_error;
  using std::out_of_range;
  using std::overflow_error;
  using std::range_error;
  using std::runtime_error;
  using std::underflow_error;
}

#endif // _GLIBCXX_HOSTED]=],
        [=[#if _GLIBCXX_HOSTED || defined(__wasm32__)
// 19.2 <stdexcept>
export namespace std
{
  using std::domain_error;
  using std::invalid_argument;
  using std::length_error;
  using std::logic_error;
  using std::out_of_range;
  using std::overflow_error;
  using std::range_error;
  using std::runtime_error;
  using std::underflow_error;
}

#endif // _GLIBCXX_HOSTED || defined(__wasm32__)]=],
        "GCC WebAssembly freestanding std module stdexcept exports")
    do
        local shared_pointer_exports = [=[#if _GLIBCXX_HOSTED || defined(__wasm32__)
  using std::allocate_shared;
  using std::bad_weak_ptr;
  using std::const_pointer_cast;
  using std::dynamic_pointer_cast;
  using std::make_shared;
  using std::reinterpret_pointer_cast;
  using std::shared_ptr;
  using std::static_pointer_cast;
  using std::swap;
  using std::get_deleter;
  using std::enable_shared_from_this;
  using std::hash;
  using std::owner_less;
  using std::weak_ptr;
#endif
#if _GLIBCXX_HOSTED
  using std::allocate_shared_for_overwrite;
  using std::make_shared_for_overwrite;
  using std::atomic_compare_exchange_strong;
  using std::atomic_compare_exchange_strong_explicit;
  using std::atomic_compare_exchange_weak;
  using std::atomic_compare_exchange_weak_explicit;
  using std::atomic_exchange;
  using std::atomic_exchange_explicit;
  using std::atomic_is_lock_free;
  using std::atomic_load;
  using std::atomic_load_explicit;
  using std::atomic_store;
  using std::atomic_store_explicit;
#endif]=]
        local previous_shared_pointer_exports =
            "#if _GLIBCXX_HOSTED\n" .. shared_pointer_exports .. "\n#endif"
        local shared_pointer_content = io.readfile(libstdcxx_std)
        if shared_pointer_content:find(previous_shared_pointer_exports, 1, true) then
            print("patching GCC WebAssembly freestanding std module shared pointer exports migration: " ..
                path.relative(libstdcxx_std, src))
            base.writefile_bytes(libstdcxx_std, base.replace_plain(
                shared_pointer_content, previous_shared_pointer_exports, shared_pointer_exports))
        else
            strict_replace(libstdcxx_std,
                [=[  using std::allocate_shared;
  using std::allocate_shared_for_overwrite;
  using std::bad_weak_ptr;
  using std::const_pointer_cast;
  using std::dynamic_pointer_cast;
  using std::make_shared;
  using std::make_shared_for_overwrite;
  using std::reinterpret_pointer_cast;
  using std::shared_ptr;
  using std::static_pointer_cast;
  using std::swap;
  using std::get_deleter;
  using std::atomic_compare_exchange_strong;
  using std::atomic_compare_exchange_strong_explicit;
  using std::atomic_compare_exchange_weak;
  using std::atomic_compare_exchange_weak_explicit;
  using std::atomic_exchange;
  using std::atomic_exchange_explicit;
  using std::atomic_is_lock_free;
  using std::atomic_load;
  using std::atomic_load_explicit;
  using std::atomic_store;
  using std::atomic_store_explicit;
  using std::enable_shared_from_this;
  using std::hash;
  using std::owner_less;
  using std::weak_ptr;]=],
                shared_pointer_exports,
                "GCC WebAssembly freestanding std module shared pointer exports")
        end
    end
    strict_replace(libstdcxx_std,
        [=[    using std::ranges::basic_istream_view;
    using std::ranges::istream_view;
    using std::ranges::wistream_view;
    namespace views
    {
      using std::ranges::views::istream;
    }]=],
        [=[#if _GLIBCXX_HOSTED
    using std::ranges::basic_istream_view;
    using std::ranges::istream_view;
    using std::ranges::wistream_view;
    namespace views
    {
      using std::ranges::views::istream;
    }
#endif]=],
        "GCC WebAssembly freestanding std module input range exports")
    local partial_exports_changed = partial_exports_before ~= io.readfile(libstdcxx_std)

    local libstdcxx_std_compat = path.join(src, "libstdc++-v3", "src", "c++23", "std.compat.cc.in")
    local hosted_compat_preamble = [=[module;

#include <stdbit.h>
#include <stdckdint.h>]=]
    local freestanding_compat_preamble = [=[module;

#include <bits/c++config.h>

#if _GLIBCXX_HOSTED
#include <stdbit.h>
#include <stdckdint.h>
#endif]=]
    local compat_before = io.readfile(libstdcxx_std_compat)
    strict_replace(libstdcxx_std_compat, hosted_compat_preamble, freestanding_compat_preamble,
        "GCC WebAssembly freestanding libstdc++ std.compat module headers")
    local compat_headers_changed = compat_before ~= io.readfile(libstdcxx_std_compat)

    local libstdcxx_std_clib = path.join(src, "libstdc++-v3", "src", "c++23", "std-clib.cc.in")
    local clib_exports_changed = patch_freestanding_module_exports(
        libstdcxx_std_clib, "// C standard library headers [tab:headers.cpp.c]",
        freestanding_c_headers, freestanding_cstdlib_exports,
        "GCC WebAssembly freestanding libstdc++ C library module exports")
    do
        local clib_exports_before = io.readfile(libstdcxx_std_clib)
        strict_replace(libstdcxx_std_clib,
            "  using std::abort;\n" ..
            "  using std::atexit;",
            "  using std::abort;\n" ..
            "  using std::abs;\n" ..
            "  using std::atexit;",
            "GCC WebAssembly freestanding integral abs module export")
        clib_exports_changed = clib_exports_changed
            or clib_exports_before ~= io.readfile(libstdcxx_std_clib)
    end
    local freestanding_cstring_export_block = [=[#if !_GLIBCXX_HOSTED
// xmake: GCC WebAssembly freestanding cstring memory module exports.
// 23.5.3 <cstring>
export C_LIB_NAMESPACE
{
  using std::memchr;
  using std::memcmp;
  using std::memcpy;
  using std::memmove;
  using std::memset;
  using std::size_t;
}
#endif // !_GLIBCXX_HOSTED]=]
    local cstring_export_anchor = [=[  using std::strxfrm;
}

#endif // _GLIBCXX_HOSTED]=]
    local cstring_exports_before = io.readfile(libstdcxx_std_clib)
    strict_replace(libstdcxx_std_clib,
        [=[#endif // _GLIBCXX_HOSTED
#if _GLIBCXX_HOSTED
// 17.2.2 <cstdlib> [cstdlib.syn]]=],
        [=[#endif // _GLIBCXX_HOSTED
#if !_GLIBCXX_HOSTED
// xmake: GCC WebAssembly freestanding opaque C stream type export.
// 31.13.1 <cstdio>
export C_LIB_NAMESPACE
{
  using std::FILE;
}
#endif // !_GLIBCXX_HOSTED
#if _GLIBCXX_HOSTED
// 17.2.2 <cstdlib> [cstdlib.syn]]=],
        "GCC WebAssembly freestanding FILE module export")
    strict_replace(libstdcxx_std_clib, cstring_export_anchor,
        cstring_export_anchor .. "\n" .. freestanding_cstring_export_block,
        "GCC WebAssembly freestanding cstring memory module exports")
    local cstring_exports_changed = cstring_exports_before ~= io.readfile(libstdcxx_std_clib)

    -- Same aggregate as before the profile split: headers_flags carries the
    -- OR of every *_changed flag from _apply_freestanding_headers.
    local wasm_freestanding_std_module_changed = headers_flags.sources_changed_any
        or headers_flags.include_headers_changed
        or std_headers_changed
        or std_exports_changed
        or ordered_map_exports_changed
        or vector_exports_changed
        or chrono_exports_changed
        or string_exports_changed
        or hosted_compat_exports_changed
        or partial_exports_changed
        or compat_headers_changed
        or clib_exports_changed
        or cstring_exports_changed
    ctx.flags.wasm_freestanding_std_module_changed = wasm_freestanding_std_module_changed
end
