#include <cstdint>

// The deployable HTTP service currently exposes a JS adapter state machine.
// These symbols reserve the frozen §8.3 ABI for the future Emscripten build,
// but deliberately report that package validation is not implemented here.
namespace
{
constexpr const char* not_ready =
    R"({"valid":false,"errors":[{"path":"$","code":"WASM_ABI_NOT_READY","message":"C++ WASM package validation is not implemented"}]})";
constexpr const char* empty_events = "[]";
constexpr const char* empty_state = "{}";
}

extern "C"
{
std::int32_t initialize(const char*) { return 1; }
const char* loadPackage(const char*) { return not_ready; }
std::int32_t startSession(const char*) { return 1; }
const char* dispatchInput(const char*) { return empty_events; }
void renderFrame(double) {}
const char* serializeState() { return empty_state; }
const char* getLastError() { return not_ready; }
void dispose() {}
}

int main() { return 0; }
