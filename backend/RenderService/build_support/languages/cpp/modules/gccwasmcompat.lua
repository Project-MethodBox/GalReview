-- Generated runtime and libstdc++ compatibility sources for the experimental
-- WebAssembly profiles. Keep target source in one place so
-- gccpatches.lua can focus on applying and invalidating source-tree changes.

function runtime_source()
    return [=[/* Minimal single-thread runtime for the no-libc WebAssembly profile.  */
typedef __SIZE_TYPE__ size_type;
typedef __UINTPTR_TYPE__ uintptr_type;

#define WASM_RUNTIME \
  __attribute__ ((noinline, used, visibility ("default"), \
                  optimize ("no-tree-loop-distribute-patterns")))

WASM_RUNTIME void *
memcpy (void *destination, const void *source, size_type size)
{
  unsigned char *to = (unsigned char *) destination;
  const unsigned char *from = (const unsigned char *) source;
  for (size_type index = 0; index < size; ++index)
    to[index] = from[index];
  return destination;
}

WASM_RUNTIME void *
memmove (void *destination, const void *source, size_type size)
{
  unsigned char *to = (unsigned char *) destination;
  const unsigned char *from = (const unsigned char *) source;
  uintptr_type to_address = (uintptr_type) destination;
  uintptr_type from_address = (uintptr_type) source;
  if (to_address < from_address || to_address - from_address >= size)
    for (size_type index = 0; index < size; ++index)
      to[index] = from[index];
  else
    while (size != 0)
      {
        --size;
        to[size] = from[size];
      }
  return destination;
}

WASM_RUNTIME void *
memset (void *destination, int value, size_type size)
{
  unsigned char *to = (unsigned char *) destination;
  for (size_type index = 0; index < size; ++index)
    to[index] = (unsigned char) value;
  return destination;
}

WASM_RUNTIME int
memcmp (const void *left, const void *right, size_type size)
{
  const unsigned char *left_bytes = (const unsigned char *) left;
  const unsigned char *right_bytes = (const unsigned char *) right;
  for (size_type index = 0; index < size; ++index)
    if (left_bytes[index] != right_bytes[index])
      return (int) left_bytes[index] - (int) right_bytes[index];
  return 0;
}

WASM_RUNTIME void *
memchr (const void *memory, int value, size_type size)
{
  const unsigned char *bytes = (const unsigned char *) memory;
  for (size_type index = 0; index < size; ++index)
    if (bytes[index] == (unsigned char) value)
      return (void *) (bytes + index);
  return (void *) 0;
}

WASM_RUNTIME size_type
strlen (const char *text)
{
  const char *end = text;
  while (*end != '\0')
    ++end;
  return (size_type) (end - text);
}

#define WASM_HEAP_ALIGNMENT 16
#define WASM_HEAP_CAPACITY (16 * 1024 * 1024)

typedef struct wasm_heap_block
{
  size_type size;
  struct wasm_heap_block *next;
  uintptr_type alignment_padding[2];
} wasm_heap_block;

typedef char wasm_heap_block_must_preserve_alignment[
  sizeof (wasm_heap_block) % WASM_HEAP_ALIGNMENT == 0 ? 1 : -1];

static unsigned char wasm_heap[WASM_HEAP_CAPACITY]
  __attribute__ ((aligned (WASM_HEAP_ALIGNMENT)));
static size_type wasm_heap_used;
static wasm_heap_block *wasm_free_blocks;

WASM_RUNTIME void *
malloc (size_type size)
{
  wasm_heap_block **link = &wasm_free_blocks;
  if (size == 0)
    size = 1;
  if (size > (size_type) -1 - (WASM_HEAP_ALIGNMENT - 1))
    return (void *) 0;
  size = (size + WASM_HEAP_ALIGNMENT - 1)
    & ~((size_type) WASM_HEAP_ALIGNMENT - 1);
  while (*link != (void *) 0)
    {
      wasm_heap_block *block = *link;
      if (block->size >= size)
        {
          *link = block->next;
          block->next = (void *) 0;
          return block + 1;
        }
      link = &block->next;
    }
  if (size > WASM_HEAP_CAPACITY - wasm_heap_used
      || sizeof (wasm_heap_block) > WASM_HEAP_CAPACITY - wasm_heap_used - size)
    return (void *) 0;
  wasm_heap_block *block = (wasm_heap_block *) (wasm_heap + wasm_heap_used);
  block->size = size;
  block->next = (void *) 0;
  wasm_heap_used += sizeof (wasm_heap_block) + size;
  return block + 1;
}

WASM_RUNTIME void
free (void *memory)
{
  if (memory == (void *) 0)
    return;
  wasm_heap_block *block = (wasm_heap_block *) memory - 1;
  block->next = wasm_free_blocks;
  wasm_free_blocks = block;
}

WASM_RUNTIME void *
calloc (size_type count, size_type size)
{
  if (size != 0 && count > (size_type) -1 / size)
    return (void *) 0;
  size_type total = count * size;
  void *memory = malloc (total);
  if (memory != (void *) 0)
    memset (memory, 0, total);
  return memory;
}

WASM_RUNTIME void *
realloc (void *memory, size_type size)
{
  if (memory == (void *) 0)
    return malloc (size);
  if (size == 0)
    {
      free (memory);
      return (void *) 0;
    }
  wasm_heap_block *block = (wasm_heap_block *) memory - 1;
  if (block->size >= size)
    return memory;
  void *replacement = malloc (size);
  if (replacement == (void *) 0)
    return (void *) 0;
  memcpy (replacement, memory, block->size);
  free (memory);
  return replacement;
}

typedef void (*wasm_atexit_callback) (void);
static wasm_atexit_callback wasm_atexit_callbacks[64];
static size_type wasm_atexit_callback_count;

WASM_RUNTIME int
atexit (wasm_atexit_callback callback)
{
  if (callback == 0 || wasm_atexit_callback_count == 64)
    return -1;
  wasm_atexit_callbacks[wasm_atexit_callback_count++] = callback;
  return 0;
}

WASM_RUNTIME void
__gcc_wasm_run_atexit (void)
{
  while (wasm_atexit_callback_count != 0)
    wasm_atexit_callbacks[--wasm_atexit_callback_count] ();
}

void abort (void) __attribute__ ((noreturn));
WASM_RUNTIME void
abort (void)
{
  __builtin_trap ();
}

void _Unwind_Resume (void *) __attribute__ ((noreturn));
WASM_RUNTIME void
_Unwind_Resume (void *exception_object)
{
  (void) exception_object;
  __builtin_trap ();
}

WASM_RUNTIME int
_Unwind_Resume_or_Rethrow (void *exception_object)
{
  (void) exception_object;
  __builtin_trap ();
}

WASM_RUNTIME void
_Unwind_DeleteException (void *exception_object)
{
  (void) exception_object;
  __builtin_trap ();
}
]=]
end

function unwind_abort_source()
    return [=[/* WebAssembly no-unwind runtime for hosted Emscripten links.
   GCC owns the C++ ABI while Emscripten supplies the process runtime.  */

#include "unwind.h"

_Unwind_Reason_Code
_Unwind_RaiseException (struct _Unwind_Exception *exception_object
                        __attribute__ ((__unused__)))
{
  __builtin_trap ();
  return _URC_FATAL_PHASE1_ERROR;
}

void
_Unwind_DeleteException (struct _Unwind_Exception *exception_object)
{
  if (exception_object->exception_cleanup)
    (*exception_object->exception_cleanup) (_URC_FOREIGN_EXCEPTION_CAUGHT,
                                            exception_object);
}

void
_Unwind_Resume (struct _Unwind_Exception *exception_object
                __attribute__ ((__unused__)))
{
  __builtin_trap ();
}

_Unwind_Reason_Code
_Unwind_Resume_or_Rethrow (struct _Unwind_Exception *exception_object
                           __attribute__ ((__unused__)))
{
  __builtin_trap ();
  return _URC_FATAL_PHASE2_ERROR;
}

_Unwind_Reason_Code
_Unwind_Backtrace (_Unwind_Trace_Fn trace __attribute__ ((__unused__)),
                   void *trace_argument __attribute__ ((__unused__)))
{
  return _URC_END_OF_STACK;
}

_Unwind_Ptr
_Unwind_GetIPInfo (struct _Unwind_Context *context __attribute__ ((__unused__)),
                   int *ip_before_instruction)
{
  if (ip_before_instruction)
    *ip_before_instruction = 0;
  return 0;
}
]=]
end

function hosted_compat_header()
    return [=[/* Experimental hosted-surface compatibility for freestanding WebAssembly.
   This is intentionally smaller than a hosted libstdc++ implementation.  */

#ifndef _GLIBCXX_WASM_FREESTANDING_HOSTED_COMPAT_H
#define _GLIBCXX_WASM_FREESTANDING_HOSTED_COMPAT_H 1

#include <bits/c++config.h>
#include <bits/functional_hash.h>
#include <concepts>
#include <cstdint>
#include <exception>
#include <iterator>
#include <limits>
#include <string>
#include <string_view>
#include <tuple>
#include <type_traits>
#include <utility>

#if !_GLIBCXX_HOSTED
struct __wasm_freestanding_FILE;
#endif

namespace std _GLIBCXX_VISIBILITY(default)
{
_GLIBCXX_BEGIN_NAMESPACE_VERSION

#if !_GLIBCXX_HOSTED
  using FILE = ::__wasm_freestanding_FILE;
#endif

  template<typename _Tp, typename _CharT = char>
    struct formatter;

  template<typename _Out, typename _CharT>
    class basic_format_context;

  template<typename _CharT>
    class basic_format_parse_context
    {
    public:
      using char_type = _CharT;
      using const_iterator = const _CharT*;
      using iterator = const_iterator;

      constexpr explicit
      basic_format_parse_context(basic_string_view<_CharT> __spec) noexcept
      : _M_begin(__spec.data()), _M_end(__spec.data() + __spec.size())
      { }

      constexpr iterator begin() const noexcept { return _M_begin; }
      constexpr iterator end() const noexcept { return _M_end; }
      constexpr void advance_to(iterator __it) noexcept { _M_begin = __it; }

    private:
      iterator _M_begin;
      iterator _M_end;
    };

  using format_parse_context = basic_format_parse_context<char>;

  template<typename _Out, typename _CharT>
    class basic_format_context
    {
    public:
      using iterator = _Out;
      using char_type = _CharT;

      template<typename _Tp>
        using formatter_type = formatter<remove_const_t<_Tp>, _CharT>;

      constexpr explicit basic_format_context(_Out __out)
      : _M_out(__out)
      { }

      constexpr iterator out() { return _M_out; }
      constexpr void advance_to(iterator __it) { _M_out = __it; }

    private:
      iterator _M_out;
    };

  using format_context = basic_format_context<back_insert_iterator<string>, char>;

  class format_error : public exception
  {
  public:
    explicit format_error(const char* __message) noexcept
    : _M_message(__message)
    { }

    const char* what() const noexcept override { return _M_message; }

  private:
    const char* _M_message;
  };

  enum class range_format
  {
    disabled,
    map,
    set,
    sequence,
    string,
    debug_string
  };

  template<typename _Range>
    inline constexpr auto format_kind = range_format::disabled;

namespace __wasm_format
{
  struct _Spec
  {
    unsigned int _M_width = 0;
    bool _M_zero = false;
    bool _M_alternate = false;
    char _M_presentation = 0;
  };

  template<typename _Iterator>
    constexpr _Spec
    __parse_spec(_Iterator __first, _Iterator __last)
    {
      _Spec __spec;
      if (__first != __last && *__first == '#')
        {
          __spec._M_alternate = true;
          ++__first;
        }
      if (__first != __last && *__first == '0')
        {
          __spec._M_zero = true;
          ++__first;
        }
      while (__first != __last && *__first >= '0' && *__first <= '9')
        {
          __spec._M_width = __spec._M_width * 10u
            + static_cast<unsigned int>(*__first - '0');
          ++__first;
        }
      if (__first != __last)
        __spec._M_presentation = static_cast<char>(*__first);
      return __spec;
    }

  template<typename _Out, typename _CharT>
    constexpr _Out
    __put(_Out __out, _CharT __value)
    {
      *__out = __value;
      ++__out;
      return __out;
    }

  template<typename _Out, typename _CharT>
    constexpr _Out
    __write(_Out __out, basic_string_view<_CharT> __value)
    {
      for (_CharT __character : __value)
        __out = __put(__out, __character);
      return __out;
    }

  template<typename _Out, typename _CharT>
    constexpr _Out
    __repeat(_Out __out, _CharT __value, unsigned int __count)
    {
      while (__count != 0)
        {
          __out = __put(__out, __value);
          --__count;
        }
      return __out;
    }

  template<typename _CharT, typename _Out, typename _Integer>
    constexpr _Out
    __write_integer(_Out __out, _Integer __value, const _Spec& __spec)
    {
      using _Value = remove_cv_t<_Integer>;
      using _Unsigned = make_unsigned_t<_Value>;
      unsigned int __base = 10;
      if (__spec._M_presentation == 'x' || __spec._M_presentation == 'X')
        __base = 16;
      else if (__spec._M_presentation == 'o')
        __base = 8;
      else if (__spec._M_presentation == 'b' || __spec._M_presentation == 'B')
        __base = 2;

      bool __negative = false;
      _Unsigned __magnitude;
      if constexpr (is_signed_v<_Value>)
        {
          if (__value < 0)
            {
              __negative = true;
              __magnitude = _Unsigned(0) - static_cast<_Unsigned>(__value);
            }
          else
            __magnitude = static_cast<_Unsigned>(__value);
        }
      else
        __magnitude = __value;

      _CharT __digits[sizeof(_Unsigned) * 8u + 1u];
      unsigned int __count = 0;
      do
        {
          const unsigned int __digit
            = static_cast<unsigned int>(__magnitude % __base);
          const char __alpha = __spec._M_presentation == 'X' ? 'A' : 'a';
          __digits[__count++] = static_cast<_CharT>(
            __digit < 10 ? '0' + __digit : __alpha + (__digit - 10));
          __magnitude /= __base;
        }
      while (__magnitude != 0);

      unsigned int __prefix = __negative ? 1u : 0u;
      if (__spec._M_alternate && __base != 10)
        __prefix += __base == 8 ? 1u : 2u;
      const unsigned int __padding = __spec._M_width > __prefix + __count
        ? __spec._M_width - __prefix - __count : 0u;
      if (!__spec._M_zero)
        __out = __repeat(__out, static_cast<_CharT>(' '), __padding);
      if (__negative)
        __out = __put(__out, static_cast<_CharT>('-'));
      if (__spec._M_alternate)
        {
          if (__base == 8)
            __out = __put(__out, static_cast<_CharT>('0'));
          else if (__base == 16 || __base == 2)
            {
              __out = __put(__out, static_cast<_CharT>('0'));
              const char __prefix_character = __base == 16
                ? (__spec._M_presentation == 'X' ? 'X' : 'x')
                : (__spec._M_presentation == 'B' ? 'B' : 'b');
              __out = __put(__out, static_cast<_CharT>(__prefix_character));
            }
        }
      if (__spec._M_zero)
        __out = __repeat(__out, static_cast<_CharT>('0'), __padding);
      while (__count != 0)
        __out = __put(__out, __digits[--__count]);
      return __out;
    }

  template<typename _CharT, typename _Out, typename _Float>
    constexpr _Out
    __write_float(_Out __out, _Float __value, const _Spec& __spec)
    {
      if (__value != __value)
        return __write(__out, basic_string_view<_CharT>{
          reinterpret_cast<const _CharT*>("nan"), 3});
      bool __negative = __value < 0;
      if (__negative)
        __value = -__value;
      if (__value > static_cast<_Float>(18446744073709551615.0L))
        return __write(__out, basic_string_view<_CharT>{
          reinterpret_cast<const _CharT*>("inf"), 3});

      const unsigned long long __whole
        = static_cast<unsigned long long>(__value);
      unsigned long long __fraction = static_cast<unsigned long long>(
        (__value - static_cast<_Float>(__whole)) * 1000000 + 0.5);
      if (__negative)
        __out = __put(__out, static_cast<_CharT>('-'));
      _Spec __whole_spec = __spec;
      __whole_spec._M_width = 0;
      __whole_spec._M_zero = false;
      __whole_spec._M_alternate = false;
      __whole_spec._M_presentation = 0;
      __out = __write_integer<_CharT>(__out, __whole, __whole_spec);
      if (__fraction == 0)
        return __out;
      __out = __put(__out, static_cast<_CharT>('.'));
      _CharT __digits[6];
      for (int __index = 5; __index >= 0; --__index)
        {
          __digits[__index] = static_cast<_CharT>('0' + __fraction % 10);
          __fraction /= 10;
        }
      unsigned int __count = 6;
      while (__count > 1 && __digits[__count - 1] == '0')
        --__count;
      for (unsigned int __index = 0; __index < __count; ++__index)
        __out = __put(__out, __digits[__index]);
      return __out;
    }

  template<typename _CharT, typename _Out, typename _Tp>
    constexpr _Out
    __write_value(_Out __out, const _Tp& __value, const _Spec& __spec)
    {
      using _Value = remove_cvref_t<_Tp>;
      if constexpr (is_same_v<_Value, _CharT>)
        return __put(__out, __value);
      else if constexpr (is_same_v<_Value, bool>)
        return __value
          ? __write(__out, basic_string_view<_CharT>{
              reinterpret_cast<const _CharT*>("true"), 4})
          : __write(__out, basic_string_view<_CharT>{
              reinterpret_cast<const _CharT*>("false"), 5});
      else if constexpr (is_convertible_v<const _Tp&, basic_string_view<_CharT>>)
        return __write(__out, basic_string_view<_CharT>{__value});
      else if constexpr (is_integral_v<_Value>)
        return __write_integer<_CharT>(__out, __value, __spec);
      else if constexpr (is_enum_v<_Value>)
        return __write_integer<_CharT>(
          __out, static_cast<underlying_type_t<_Value>>(__value), __spec);
      else if constexpr (is_floating_point_v<_Value>)
        return __write_float<_CharT>(__out, __value, __spec);
      else if constexpr (is_null_pointer_v<_Value>)
        return __write(__out, basic_string_view<_CharT>{
          reinterpret_cast<const _CharT*>("0x0"), 3});
      else if constexpr (is_pointer_v<_Value>)
        {
          _Spec __pointer_spec = __spec;
          __pointer_spec._M_alternate = true;
          __pointer_spec._M_presentation = 'x';
          return __write_integer<_CharT>(__out,
            reinterpret_cast<uintptr_t>(__value), __pointer_spec);
        }
      else
        return __write(__out, basic_string_view<_CharT>{
          reinterpret_cast<const _CharT*>("<?>"), 3});
    }
} // namespace __wasm_format

  template<typename _Tp, typename _CharT>
    struct formatter
    {
      constexpr auto
      parse(basic_format_parse_context<_CharT>& __context)
      {
        _M_spec = __wasm_format::__parse_spec(
          __context.begin(), __context.end());
        return __context.end();
      }

      template<typename _Context>
        constexpr auto
        format(const _Tp& __value, _Context& __context) const
        {
          return __wasm_format::__write_value<_CharT>(
            __context.out(), __value, _M_spec);
        }

    private:
      __wasm_format::_Spec _M_spec;
    };

  template<typename _Tp, typename _CharT>
    concept formattable = requires(formatter<remove_cvref_t<_Tp>, _CharT> __formatter,
      const remove_cvref_t<_Tp>& __value,
      basic_format_parse_context<_CharT>& __parse_context,
      basic_format_context<back_insert_iterator<basic_string<_CharT>>, _CharT>& __context)
    {
      __formatter.parse(__parse_context);
      __formatter.format(__value, __context);
    };

  template<typename _CharT, typename... _Args>
    class basic_format_string
    {
    public:
      template<typename _Source>
        consteval basic_format_string(const _Source& __source)
        : _M_value(__source)
        { }

      constexpr basic_string_view<_CharT> get() const noexcept
      { return _M_value; }

    private:
      basic_string_view<_CharT> _M_value;
    };

  template<typename... _Args>
    using format_string = basic_format_string<char, type_identity_t<_Args>...>;

namespace __wasm_format
{
  template<size_t _Index = 0, typename _Out, typename _Tuple>
    constexpr _Out
    __format_argument(size_t __selected, _Out __out, string_view __spec,
      _Tuple& __arguments)
    {
      if constexpr (_Index < tuple_size_v<remove_reference_t<_Tuple>>)
        {
          if (__selected == _Index)
            {
              using _Argument = remove_cvref_t<decltype(get<_Index>(__arguments))>;
              formatter<_Argument, char> __formatter;
              format_parse_context __parse_context(__spec);
              (void) __formatter.parse(__parse_context);
              basic_format_context<_Out, char> __context(__out);
              return __formatter.format(get<_Index>(__arguments), __context);
            }
          return __format_argument<_Index + 1>(
            __selected, __out, __spec, __arguments);
        }
      return __out;
    }

  template<typename _Out, typename _Tuple>
    constexpr _Out
    __format_to(_Out __out, string_view __format, _Tuple& __arguments)
    {
      size_t __next_argument = 0;
      for (size_t __index = 0; __index < __format.size(); ++__index)
        {
          const char __character = __format[__index];
          if (__character == '{' && __index + 1 < __format.size()
              && __format[__index + 1] == '{')
            {
              __out = __put(__out, '{');
              ++__index;
              continue;
            }
          if (__character == '}' && __index + 1 < __format.size()
              && __format[__index + 1] == '}')
            {
              __out = __put(__out, '}');
              ++__index;
              continue;
            }
          if (__character != '{')
            {
              __out = __put(__out, __character);
              continue;
            }

          size_t __close = __index + 1;
          while (__close < __format.size() && __format[__close] != '}')
            ++__close;
          if (__close == __format.size())
            return __put(__out, '{');

          size_t __cursor = __index + 1;
          size_t __selected = __next_argument++;
          if (__cursor < __close && __format[__cursor] >= '0'
              && __format[__cursor] <= '9')
            {
              __selected = 0;
              while (__cursor < __close && __format[__cursor] >= '0'
                  && __format[__cursor] <= '9')
                {
                  __selected = __selected * 10
                    + static_cast<size_t>(__format[__cursor] - '0');
                  ++__cursor;
                }
            }
          string_view __spec;
          if (__cursor < __close && __format[__cursor] == ':')
            __spec = __format.substr(__cursor + 1, __close - __cursor - 1);
          __out = __format_argument(
            __selected, __out, __spec, __arguments);
          __index = __close;
        }
      return __out;
    }
} // namespace __wasm_format

  template<typename _Out, typename... _Args>
    constexpr _Out
    format_to(_Out __out, format_string<_Args...> __format, _Args&&... __args)
    {
      auto __arguments = forward_as_tuple(forward<_Args>(__args)...);
      return __wasm_format::__format_to(
        __out, __format.get(), __arguments);
    }

  template<typename... _Args>
    string
    format(format_string<_Args...> __format, _Args&&... __args)
    {
      string __result;
      format_to(back_inserter(__result), __format,
        forward<_Args>(__args)...);
      return __result;
    }

  extern "C" void
  __gcc_wasm_console_write(const char*, size_t);

  template<typename... _Args>
    void
    print(format_string<_Args...> __format, _Args&&... __args)
    {
      const string __output = format(
        __format, forward<_Args>(__args)...);
      __gcc_wasm_console_write(__output.data(), __output.size());
    }

  template<typename... _Args>
    void
    println(format_string<_Args...> __format, _Args&&... __args)
    {
      string __output = format(__format, forward<_Args>(__args)...);
      __output.push_back('\n');
      __gcc_wasm_console_write(__output.data(), __output.size());
    }

  // This target has no pthread runtime. These synchronization types provide
  // the standard single-thread surface used by the Engine while making the
  // absence of workers observable through hardware_concurrency() == 0.
  struct defer_lock_t
  {
    explicit defer_lock_t() = default;
  };

  struct try_to_lock_t
  {
    explicit try_to_lock_t() = default;
  };

  struct adopt_lock_t
  {
    explicit adopt_lock_t() = default;
  };

  inline constexpr defer_lock_t defer_lock{};
  inline constexpr try_to_lock_t try_to_lock{};
  inline constexpr adopt_lock_t adopt_lock{};

  class mutex
  {
  public:
    using native_handle_type = void*;

    constexpr mutex() noexcept = default;
    mutex(const mutex&) = delete;
    mutex& operator=(const mutex&) = delete;

    constexpr void lock() noexcept { }
    constexpr bool try_lock() noexcept { return true; }
    constexpr void unlock() noexcept { }
    constexpr native_handle_type native_handle() noexcept { return nullptr; }
  };

  class recursive_mutex : public mutex
  { };

  class timed_mutex : public mutex
  {
  public:
    template<typename _Duration>
      constexpr bool try_lock_for(const _Duration&) noexcept { return true; }

    template<typename _TimePoint>
      constexpr bool try_lock_until(const _TimePoint&) noexcept { return true; }
  };

  class recursive_timed_mutex : public timed_mutex
  { };

  class shared_mutex
  {
  public:
    using native_handle_type = void*;

    constexpr shared_mutex() noexcept = default;
    shared_mutex(const shared_mutex&) = delete;
    shared_mutex& operator=(const shared_mutex&) = delete;

    constexpr void lock() noexcept { }
    constexpr bool try_lock() noexcept { return true; }
    constexpr void unlock() noexcept { }
    constexpr void lock_shared() noexcept { }
    constexpr bool try_lock_shared() noexcept { return true; }
    constexpr void unlock_shared() noexcept { }
    constexpr native_handle_type native_handle() noexcept { return nullptr; }
  };

  class shared_timed_mutex : public shared_mutex
  {
  public:
    template<typename _Duration>
      constexpr bool try_lock_for(const _Duration&) noexcept { return true; }

    template<typename _TimePoint>
      constexpr bool try_lock_until(const _TimePoint&) noexcept { return true; }

    template<typename _Duration>
      constexpr bool try_lock_shared_for(const _Duration&) noexcept { return true; }

    template<typename _TimePoint>
      constexpr bool try_lock_shared_until(const _TimePoint&) noexcept { return true; }
  };

  template<typename _Mutex>
    class lock_guard
    {
    public:
      using mutex_type = _Mutex;

      explicit constexpr lock_guard(mutex_type& __mutex)
      : _M_mutex(__mutex)
      { _M_mutex.lock(); }

      constexpr lock_guard(mutex_type& __mutex, adopt_lock_t) noexcept
      : _M_mutex(__mutex)
      { }

      ~lock_guard() { _M_mutex.unlock(); }

      lock_guard(const lock_guard&) = delete;
      lock_guard& operator=(const lock_guard&) = delete;

    private:
      mutex_type& _M_mutex;
    };

  template<typename _Mutex>
    class unique_lock
    {
    public:
      using mutex_type = _Mutex;

      constexpr unique_lock() noexcept = default;

      explicit constexpr unique_lock(mutex_type& __mutex)
      : _M_mutex(addressof(__mutex)), _M_owns(true)
      { _M_mutex->lock(); }

      constexpr unique_lock(mutex_type& __mutex, defer_lock_t) noexcept
      : _M_mutex(addressof(__mutex))
      { }

      constexpr unique_lock(mutex_type& __mutex, try_to_lock_t)
      : _M_mutex(addressof(__mutex)), _M_owns(_M_mutex->try_lock())
      { }

      constexpr unique_lock(mutex_type& __mutex, adopt_lock_t) noexcept
      : _M_mutex(addressof(__mutex)), _M_owns(true)
      { }

      unique_lock(const unique_lock&) = delete;
      unique_lock& operator=(const unique_lock&) = delete;

      constexpr unique_lock(unique_lock&& __other) noexcept
      : _M_mutex(__other._M_mutex), _M_owns(__other._M_owns)
      {
        __other._M_mutex = nullptr;
        __other._M_owns = false;
      }

      constexpr unique_lock& operator=(unique_lock&& __other) noexcept
      {
        if (this != addressof(__other))
          {
            if (_M_owns)
              _M_mutex->unlock();
            _M_mutex = __other._M_mutex;
            _M_owns = __other._M_owns;
            __other._M_mutex = nullptr;
            __other._M_owns = false;
          }
        return *this;
      }

      ~unique_lock()
      {
        if (_M_owns)
          _M_mutex->unlock();
      }

      constexpr void lock()
      {
        _M_mutex->lock();
        _M_owns = true;
      }

      constexpr bool try_lock()
      {
        return _M_owns = _M_mutex->try_lock();
      }

      constexpr void unlock()
      {
        _M_mutex->unlock();
        _M_owns = false;
      }

      constexpr void swap(unique_lock& __other) noexcept
      {
        std::swap(_M_mutex, __other._M_mutex);
        std::swap(_M_owns, __other._M_owns);
      }

      constexpr mutex_type* release() noexcept
      {
        mutex_type* __result = _M_mutex;
        _M_mutex = nullptr;
        _M_owns = false;
        return __result;
      }

      constexpr bool owns_lock() const noexcept { return _M_owns; }
      explicit constexpr operator bool() const noexcept { return _M_owns; }
      constexpr mutex_type* mutex() const noexcept { return _M_mutex; }

    private:
      mutex_type* _M_mutex = nullptr;
      bool _M_owns = false;
    };

  template<typename _Mutex>
    constexpr void
    swap(unique_lock<_Mutex>& __left, unique_lock<_Mutex>& __right) noexcept
    { __left.swap(__right); }

  template<typename... _MutexTypes>
    class scoped_lock
    {
    public:
      using mutex_type = conditional_t<sizeof...(_MutexTypes) == 1,
        tuple_element_t<0, tuple<_MutexTypes...>>, void>;

      explicit scoped_lock(_MutexTypes&... __mutexes)
      : _M_mutexes(__mutexes...)
      { apply([](auto&... __mutex) { (__mutex.lock(), ...); }, _M_mutexes); }

      scoped_lock(adopt_lock_t, _MutexTypes&... __mutexes) noexcept
      : _M_mutexes(__mutexes...)
      { }

      ~scoped_lock()
      { apply([](auto&... __mutex) { (__mutex.unlock(), ...); }, _M_mutexes); }

      scoped_lock(const scoped_lock&) = delete;
      scoped_lock& operator=(const scoped_lock&) = delete;

    private:
      tuple<_MutexTypes&...> _M_mutexes;
    };

  template<>
    class scoped_lock<>
    {
    public:
      explicit scoped_lock() = default;
      explicit scoped_lock(adopt_lock_t) noexcept { }
    };

  template<typename _Mutex>
    class shared_lock
    {
    public:
      using mutex_type = _Mutex;

      constexpr shared_lock() noexcept = default;

      explicit shared_lock(mutex_type& __mutex)
      : _M_mutex(addressof(__mutex)), _M_owns(true)
      { _M_mutex->lock_shared(); }

      shared_lock(mutex_type& __mutex, defer_lock_t) noexcept
      : _M_mutex(addressof(__mutex))
      { }

      shared_lock(mutex_type& __mutex, try_to_lock_t)
      : _M_mutex(addressof(__mutex)), _M_owns(_M_mutex->try_lock_shared())
      { }

      shared_lock(mutex_type& __mutex, adopt_lock_t) noexcept
      : _M_mutex(addressof(__mutex)), _M_owns(true)
      { }

      shared_lock(const shared_lock&) = delete;
      shared_lock& operator=(const shared_lock&) = delete;
      shared_lock(shared_lock&&) noexcept = default;
      shared_lock& operator=(shared_lock&&) noexcept = default;

      ~shared_lock()
      {
        if (_M_owns)
          _M_mutex->unlock_shared();
      }

      void lock()
      {
        _M_mutex->lock_shared();
        _M_owns = true;
      }

      bool try_lock()
      { return _M_owns = _M_mutex->try_lock_shared(); }

      void unlock()
      {
        _M_mutex->unlock_shared();
        _M_owns = false;
      }

      constexpr bool owns_lock() const noexcept { return _M_owns; }
      explicit constexpr operator bool() const noexcept { return _M_owns; }
      constexpr mutex_type* mutex() const noexcept { return _M_mutex; }

    private:
      mutex_type* _M_mutex = nullptr;
      bool _M_owns = false;
    };

  enum class cv_status
  {
    no_timeout,
    timeout
  };

  class condition_variable
  {
  public:
    using native_handle_type = void*;

    constexpr condition_variable() noexcept = default;
    condition_variable(const condition_variable&) = delete;
    condition_variable& operator=(const condition_variable&) = delete;

    constexpr void notify_one() noexcept { }
    constexpr void notify_all() noexcept { }
    constexpr void wait(unique_lock<mutex>&) noexcept { }

    template<typename _Predicate>
      constexpr void wait(unique_lock<mutex>&, _Predicate __predicate)
      { (void) __predicate(); }

    template<typename _TimePoint>
      constexpr cv_status wait_until(unique_lock<mutex>&, const _TimePoint&)
      { return cv_status::no_timeout; }

    template<typename _TimePoint, typename _Predicate>
      constexpr bool wait_until(unique_lock<mutex>&, const _TimePoint&,
        _Predicate __predicate)
      { return __predicate(); }

    template<typename _Duration>
      constexpr cv_status wait_for(unique_lock<mutex>&, const _Duration&)
      { return cv_status::no_timeout; }

    template<typename _Duration, typename _Predicate>
      constexpr bool wait_for(unique_lock<mutex>&, const _Duration&,
        _Predicate __predicate)
      { return __predicate(); }

    constexpr native_handle_type native_handle() noexcept { return nullptr; }
  };

  class condition_variable_any
  {
  public:
    constexpr condition_variable_any() noexcept = default;
    condition_variable_any(const condition_variable_any&) = delete;
    condition_variable_any& operator=(const condition_variable_any&) = delete;

    constexpr void notify_one() noexcept { }
    constexpr void notify_all() noexcept { }

    template<typename _Lock>
      constexpr void wait(_Lock&) noexcept { }

    template<typename _Lock, typename _Predicate>
      constexpr void wait(_Lock&, _Predicate __predicate)
      { (void) __predicate(); }

    template<typename _Lock, typename _TimePoint>
      constexpr cv_status wait_until(_Lock&, const _TimePoint&)
      { return cv_status::no_timeout; }

    template<typename _Lock, typename _TimePoint, typename _Predicate>
      constexpr bool wait_until(_Lock&, const _TimePoint&,
        _Predicate __predicate)
      { return __predicate(); }

    template<typename _Lock, typename _Duration>
      constexpr cv_status wait_for(_Lock&, const _Duration&)
      { return cv_status::no_timeout; }

    template<typename _Lock, typename _Duration, typename _Predicate>
      constexpr bool wait_for(_Lock&, const _Duration&,
        _Predicate __predicate)
      { return __predicate(); }
  };

  class latch
  {
  public:
    static constexpr ptrdiff_t max() noexcept
    { return numeric_limits<ptrdiff_t>::max(); }

    constexpr explicit latch(ptrdiff_t __expected)
    : _M_expected(__expected)
    { }

    latch(const latch&) = delete;
    latch& operator=(const latch&) = delete;

    constexpr void count_down(ptrdiff_t __update = 1)
    { _M_expected = __update < _M_expected ? _M_expected - __update : 0; }

    constexpr bool try_wait() const noexcept { return _M_expected == 0; }
    constexpr void wait() const noexcept { }

    constexpr void arrive_and_wait(ptrdiff_t __update = 1)
    { count_down(__update); }

  private:
    ptrdiff_t _M_expected;
  };

  class thread
  {
  public:
    using native_handle_type = uintptr_t;

    class id
    {
    public:
      constexpr id() noexcept = default;
      friend constexpr bool operator==(id, id) noexcept = default;
    };

    constexpr thread() noexcept = default;

    template<typename _Callable, typename... _Args>
      requires (!same_as<remove_cvref_t<_Callable>, thread>)
      explicit constexpr thread(_Callable&&, _Args&&...) noexcept
      { }

    thread(const thread&) = delete;
    thread& operator=(const thread&) = delete;
    constexpr thread(thread&&) noexcept = default;
    constexpr thread& operator=(thread&&) noexcept = default;

    constexpr bool joinable() const noexcept { return false; }
    constexpr void join() noexcept { }
    constexpr void detach() noexcept { }
    constexpr id get_id() const noexcept { return {}; }
    constexpr native_handle_type native_handle() noexcept { return 0; }
    static constexpr unsigned int hardware_concurrency() noexcept { return 0; }
    constexpr void swap(thread&) noexcept { }
  };

  constexpr void swap(thread& __left, thread& __right) noexcept
  { __left.swap(__right); }

  template<>
    struct hash<thread::id>
    {
      constexpr size_t operator()(const thread::id&) const noexcept
      { return 0; }
    };

namespace this_thread
{
  constexpr thread::id get_id() noexcept { return {}; }
  constexpr void yield() noexcept { }

  template<typename _Duration>
    constexpr void sleep_for(const _Duration&) noexcept { }

  template<typename _TimePoint>
    constexpr void sleep_until(const _TimePoint&) noexcept { }
}

  struct nostopstate_t
  {
    explicit nostopstate_t() = default;
  };

  inline constexpr nostopstate_t nostopstate{};

  class stop_token
  {
  public:
    constexpr stop_token() noexcept = default;
    constexpr bool stop_requested() const noexcept
    { return _M_state && *_M_state; }
    constexpr bool stop_possible() const noexcept
    { return _M_state != nullptr; }

    friend constexpr bool operator==(stop_token, stop_token) noexcept = default;

  private:
    friend class stop_source;
    explicit constexpr stop_token(const bool* __state) noexcept
    : _M_state(__state)
    { }

    const bool* _M_state = nullptr;
  };

  class stop_source
  {
  public:
    constexpr stop_source() noexcept = default;
    explicit constexpr stop_source(nostopstate_t) noexcept
    : _M_possible(false)
    { }

    constexpr stop_token get_token() const noexcept
    { return _M_possible ? stop_token{addressof(_M_requested)} : stop_token{}; }

    constexpr bool stop_possible() const noexcept { return _M_possible; }
    constexpr bool stop_requested() const noexcept { return _M_requested; }

    constexpr bool request_stop() noexcept
    {
      if (!_M_possible || _M_requested)
        return false;
      _M_requested = true;
      return true;
    }

  private:
    bool _M_requested = false;
    bool _M_possible = true;
  };

  class jthread
  {
  public:
    using id = thread::id;
    using native_handle_type = thread::native_handle_type;

    constexpr jthread() noexcept = default;

    template<typename _Callable, typename... _Args>
      requires (!same_as<remove_cvref_t<_Callable>, jthread>)
      explicit constexpr jthread(_Callable&&, _Args&&...) noexcept
      { }

    jthread(const jthread&) = delete;
    jthread& operator=(const jthread&) = delete;
    constexpr jthread(jthread&&) noexcept = default;
    constexpr jthread& operator=(jthread&&) noexcept = default;

    constexpr bool joinable() const noexcept { return false; }
    constexpr void join() noexcept { }
    constexpr void detach() noexcept { }
    constexpr id get_id() const noexcept { return {}; }
    constexpr native_handle_type native_handle() noexcept { return 0; }
    static constexpr unsigned int hardware_concurrency() noexcept { return 0; }
    constexpr stop_source get_stop_source() noexcept { return _M_stop_source; }
    constexpr stop_token get_stop_token() const noexcept
    { return _M_stop_source.get_token(); }
    constexpr bool request_stop() noexcept
    { return _M_stop_source.request_stop(); }
    constexpr void swap(jthread&) noexcept { }

  private:
    stop_source _M_stop_source;
  };

  constexpr void swap(jthread& __left, jthread& __right) noexcept
  { __left.swap(__right); }

  template<typename _CharT, typename _Traits = char_traits<_CharT>>
    class basic_ostream
    {
    public:
      template<typename _Tp>
        basic_ostream& operator<<(const _Tp&) noexcept { return *this; }
    };

  template<typename _CharT, typename _Traits = char_traits<_CharT>>
    class basic_istream
    {
    public:
      template<typename _Tp>
        basic_istream& operator>>(_Tp&) noexcept { return *this; }
    };

  using ostream = basic_ostream<char>;
  using istream = basic_istream<char>;
#ifdef _GLIBCXX_USE_WCHAR_T
  using wostream = basic_ostream<wchar_t>;
  using wistream = basic_istream<wchar_t>;
#endif

_GLIBCXX_END_NAMESPACE_VERSION
} // namespace std

#endif // _GLIBCXX_WASM_FREESTANDING_HOSTED_COMPAT_H
]=]
end

-- The full mainline <format> header, vendored so the hosted WebAssembly
-- libstdc++ gets P3391R2 constexpr std::format even though the pinned upstream
-- wasm PR predates it. wasm.lua writes this over the fork's older copy before
-- re-applying the freestanding dispatch wrapper (the include guards it anchors
-- on are unchanged by the constexpr backport). Provenance/refresh notes live in
-- the sidecar patches/wasm_sources/std_format.PROVENANCE.
function constexpr_format_source()
    -- Returns nil when the sidecar is missing; the caller (wasm.lua, which owns
    -- the strict error helpers) turns that into a hard failure.
    return io.readfile(path.join(os.scriptdir(), "patches", "wasm_sources", "std_format"))
end
