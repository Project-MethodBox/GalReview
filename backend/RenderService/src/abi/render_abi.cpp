// RenderService §8.3 ABI - the frozen JavaScript <-> WASM boundary.
//
// Memory ownership (RenderService runtime-abi v1, resolves contract.md §8.5):
//   * Input strings are caller-owned UTF-8, NUL-terminated. The wasm caller
//     allocates with rtAlloc, writes the bytes, calls the entry point, then
//     releases with rtFree. The runtime copies what it needs before returning.
//   * Returned const char* values are runtime-owned and stay valid only
//     until the next ABI call that returns a string, or dispose(). Callers
//     must copy immediately and must never rtFree a returned pointer.
//   * int32 entry points return 0 on success and non-zero on failure;
//     string entry points never return nullptr. Details: getLastError().
//   * The runtime is single-threaded; concurrent calls are undefined.
#include <cstdint>
#include <cstdlib>
#include <string>

#include "../core/runtime.hpp"

namespace
{

// Function-local statics keep the wasm reactor independent from static
// constructor ordering (the crt `_initialize` export stays optional).
rt::Runtime& runtime()
{
    static rt::Runtime instance;
    return instance;
}

std::string& returnBuffer()
{
    static std::string buffer;
    return buffer;
}

const char* stash(std::string value)
{
    returnBuffer() = std::move(value);
    return returnBuffer().c_str();
}

std::string_view view(const char* text)
{
    return text == nullptr ? std::string_view() : std::string_view(text);
}

} // namespace

extern "C"
{

std::int32_t initialize(const char* configJson)
{
    return runtime().initialize(view(configJson)) ? 0 : 1;
}

const char* loadPackage(const char* packageJson)
{
    return stash(runtime().loadPackage(view(packageJson)));
}

std::int32_t startSession(const char* sessionJson)
{
    return runtime().startSession(view(sessionJson)) ? 0 : 1;
}

const char* dispatchInput(const char* inputJson)
{
    return stash(runtime().dispatchInput(view(inputJson)));
}

void renderFrame(double deltaMs)
{
    runtime().renderFrame(deltaMs);
}

const char* serializeState()
{
    return stash(runtime().serializeState());
}

const char* getLastError()
{
    return stash(runtime().lastErrorJson());
}

void dispose()
{
    runtime().dispose();
    returnBuffer().clear();
    returnBuffer().shrink_to_fit();
}

std::uint32_t rtAbiVersion()
{
    return rt::kAbiVersion;
}

const char* rtVersion()
{
    return rt::kRuntimeVersion;
}

void* rtAlloc(std::uint32_t size)
{
    return std::malloc(size == 0 ? 1 : size);
}

void rtFree(void* pointer)
{
    std::free(pointer);
}

} // extern "C"
