-- Fixture regression for the WABT build directory's staleness check in
-- languages/cpp/modules/gccwasm.lua.
--
-- The defect it guards (hit live, 2026-08-11): CMake records its generator's
-- build tool as an absolute path in CMAKE_MAKE_PROGRAM, and on Windows that
-- can be the ninja inside the project's PRIVATE bootstrap toolchain -- a tree
-- deliberately deleted again once the build that provisioned it finishes. The
-- configure signature sees unchanged arguments and keeps the cache, so the
-- next build dies inside CMake with a bare "no such file or directory" that
-- names no tool at all. The build directory is therefore also discarded when
-- the tool CMake recorded has gone missing, which needs this parse to be
-- exact: a wrong read either discards a healthy tree every time or never
-- notices the broken one.

local gccwasm = import("gccwasm",
    {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "cpp", "modules"), anonymous = true})

function run(t)
    local function cache_file(leaf, lines)
        local file = path.join(t.tmpdir(leaf), "CMakeCache.txt")
        io.writefile(file, table.concat(lines, "\n") .. "\n")
        return file
    end

    t.case("gccwasm: the recorded build tool is read out of the CMake cache", function ()
        local file = cache_file("cmake-cache-ninja", {
            "# This is the CMakeCache file.",
            "CMAKE_BUILD_TYPE:STRING=Release",
            "CMAKE_MAKE_PROGRAM:FILEPATH=E:/checkout/.toolchains/.cache/bootstrap/bin/ninja.exe",
            "CMAKE_GENERATOR:INTERNAL=Ninja"
        })
        t.assert_eq(gccwasm.cmake_cached_make_program(file),
            "E:/checkout/.toolchains/.cache/bootstrap/bin/ninja.exe", "recorded build tool")
    end)

    t.case("gccwasm: the -ADVANCED companion entry is not mistaken for the tool", function ()
        -- a real cache carries both the comment line naming the variable and
        -- the CMAKE_MAKE_PROGRAM-ADVANCED:INTERNAL=1 entry; neither is a path
        local file = cache_file("cmake-cache-advanced", {
            "//ADVANCED property for variable: CMAKE_MAKE_PROGRAM",
            "CMAKE_MAKE_PROGRAM-ADVANCED:INTERNAL=1",
            "CMAKE_MAKE_PROGRAM:FILEPATH=C:/tools/ninja.exe"
        })
        t.assert_eq(gccwasm.cmake_cached_make_program(file), "C:/tools/ninja.exe", "recorded build tool")
    end)

    t.case("gccwasm: a cache without the entry reports no tool instead of guessing", function ()
        -- generators that need no external build tool record nothing; that is
        -- not a broken cache, so the build directory must survive
        local file = cache_file("cmake-cache-none", {
            "CMAKE_BUILD_TYPE:STRING=Release",
            "//ADVANCED property for variable: CMAKE_MAKE_PROGRAM"
        })
        t.assert_true(gccwasm.cmake_cached_make_program(file) == nil, "no entry means no tool")
        t.assert_true(gccwasm.cmake_cached_make_program(path.join(t.tmpdir("cmake-cache-missing"),
            "CMakeCache.txt")) == nil, "a missing cache file must not raise")
    end)
end
