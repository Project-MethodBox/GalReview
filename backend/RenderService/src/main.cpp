// Native entry point for the RenderService runtime core.
//
//   (no arguments)        run the self-test suite; exit 0 only when green.
//   --validate <file>     validate a game package JSON file through the same
//                         §8.3 ABI the browser WASM uses; prints the
//                         ValidationResult JSON. Exit codes: 0 valid,
//                         2 invalid, 1 usage or I/O failure.
//
// The WASM reactor build excludes this file (src/core + src/abi only).
#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>

#include "core/json.hpp"

extern "C"
{
std::int32_t initialize(const char* configJson);
const char* loadPackage(const char* packageJson);
}

namespace rt::tests
{
int runAll();
}

namespace
{

bool readFile(const char* path, std::string& out)
{
    std::FILE* file = std::fopen(path, "rb");
    if (file == nullptr)
    {
        return false;
    }
    char buffer[8192];
    std::size_t bytes = 0;
    while ((bytes = std::fread(buffer, 1, sizeof(buffer), file)) > 0)
    {
        out.append(buffer, bytes);
    }
    const bool ok = std::ferror(file) == 0;
    std::fclose(file);
    return ok;
}

int validateFile(const char* path)
{
    std::string text;
    if (!readFile(path, text))
    {
        std::fprintf(stderr, "unable to read %s\n", path);
        return 1;
    }
    if (initialize("{}") != 0)
    {
        std::fprintf(stderr, "runtime initialization failed\n");
        return 1;
    }
    const char* resultJson = loadPackage(text.c_str());
    std::printf("%s\n", resultJson);

    const rt::json::ParseResult parsed = rt::json::parse(std::string_view(resultJson));
    const rt::json::Value* valid = parsed.value.find("valid");
    const bool isValid =
        parsed.ok && valid != nullptr && valid->isBoolean() && valid->asBoolean();
    return isValid ? 0 : 2;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc >= 3 && std::string_view(argv[1]) == "--validate")
    {
        return validateFile(argv[2]);
    }
    if (argc >= 2)
    {
        std::fprintf(stderr, "usage: %s [--validate <game-package.json>]\n", argv[0]);
        return 1;
    }
    return rt::tests::runAll();
}
