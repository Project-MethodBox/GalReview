-- Fixture regression for languages/cpp/modules/gccmodulecheck.lua.
-- collect_problems/scan_units are pure over a { [sourcefile] = content }
-- table plus opts (projectdir, level_of), so every case here feeds an
-- in-memory fake partition tree -- no file on disk, no target, no config.

import("gccmodulecheck", {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "cpp", "modules")})

-- fixture-local layer table standing in for a project's manual declaration
-- (the direction-check cases feed it as opts.level_of; the auto-mode cases
-- below omit it and exercise graph-derived branch-cycle detection instead)
local LEVELS = {
    ExceptionEngine = 1,
    AlgorithmEngine = 2,
    DataProcessEngine = 3,
    OSCallEngine = 4,
    AudioEngine = 4
}

local function level_of(name)
    return LEVELS[name]
end

-- Baseline healthy tree: primary interface, one root leaf, two branches
-- (one with an internal partition and an implementation unit), plus a
-- legal downward cross-branch import (DataProcessEngine -> AlgorithmEngine).
local function fixture(projdir)
    local cpp = path.join(projdir, "WhiteHopeEngine", "cpp")
    local files = {}
    files[path.join(cpp, "WhiteHopeEngine.cpp")] = [[
export module WhiteHopeEngine;
import std;
export import :Version;
export import :AlgorithmEngine;
export import :DataProcessEngine;
]]
    files[path.join(cpp, "Version.cpp")] = [[
export module WhiteHopeEngine:Version;
import std;
]]
    files[path.join(cpp, "AlgorithmEngine", "AlgorithmEngine.cpp")] = [[
export module WhiteHopeEngine:AlgorithmEngine;
export import :AlgorithmEngine.sort;
export import :AlgorithmEngine.search;
]]
    files[path.join(cpp, "AlgorithmEngine", "sort.cpp")] = [[
export module WhiteHopeEngine:AlgorithmEngine.sort;
import std;
]]
    files[path.join(cpp, "AlgorithmEngine", "search.cpp")] = [[
export module WhiteHopeEngine:AlgorithmEngine.search;
import std;
import :AlgorithmEngine.sort;
]]
    files[path.join(cpp, "AlgorithmEngine", "detail.cpp")] = [[
// gcc.modules: internal
export module WhiteHopeEngine:AlgorithmEngine.detail;
]]
    files[path.join(cpp, "AlgorithmEngine", "sort_impl.cpp")] = [[
module WhiteHopeEngine;
]]
    files[path.join(cpp, "DataProcessEngine", "DataProcessEngine.cpp")] = [[
export module WhiteHopeEngine:DataProcessEngine;
export import :DataProcessEngine.option;
]]
    files[path.join(cpp, "DataProcessEngine", "option.cpp")] = [[
export module WhiteHopeEngine:DataProcessEngine.option;
import :AlgorithmEngine.sort;
]]
    return files, cpp
end

-- Adds a complete extra branch (aggregate + one leaf) and re-exports it
-- from the primary interface, keeping the tree otherwise healthy.
local function add_branch(files, cpp, branch, leafname, leafbody)
    local part = branch .. "." .. leafname
    files[path.join(cpp, branch, branch .. ".cpp")] =
        "export module WhiteHopeEngine:" .. branch .. ";\n"
        .. "export import :" .. part .. ";\n"
    files[path.join(cpp, branch, leafname .. ".cpp")] =
        "export module WhiteHopeEngine:" .. part .. ";\n" .. (leafbody or "")
    local primary = path.join(cpp, "WhiteHopeEngine.cpp")
    files[primary] = files[primary] .. "export import :" .. branch .. ";\n"
end

-- Adds a branch with several leaves (each {name=, body=}), re-exporting them
-- all from the aggregate and the aggregate from the primary -- for building
-- multi-partition branch graphs (the auto-mode branch-cycle cases need more
-- than one partition per branch).
local function add_multi_branch(files, cpp, branch, leaves)
    local agg = "export module WhiteHopeEngine:" .. branch .. ";\n"
    for _, leaf in ipairs(leaves) do
        agg = agg .. "export import :" .. branch .. "." .. leaf.name .. ";\n"
        files[path.join(cpp, branch, leaf.name .. ".cpp")] =
            "export module WhiteHopeEngine:" .. branch .. "." .. leaf.name .. ";\n" .. (leaf.body or "")
    end
    files[path.join(cpp, branch, branch .. ".cpp")] = agg
    local primary = path.join(cpp, "WhiteHopeEngine.cpp")
    files[primary] = files[primary] .. "export import :" .. branch .. ";\n"
end

local function copy_of(files)
    local copy = {}
    for file, content in pairs(files) do
        copy[file] = content
    end
    return copy
end

local function problems_of(files, projdir)
    return gccmodulecheck.collect_problems(files, {projectdir = projdir, level_of = level_of})
end

local function assert_clean(t, problems, label)
    t.assert_eq(#problems, 0, label .. " problem count (got: "
        .. table.concat(problems, " | ") .. ")")
end

function run(t)
    local projdir = t.tmpdir("gccmodulecheck-proj")
    local files, cpp = fixture(projdir)
    local aggregate = path.join(cpp, "AlgorithmEngine", "AlgorithmEngine.cpp")
    local sort_leaf = path.join(cpp, "AlgorithmEngine", "sort.cpp")
    local option_leaf = path.join(cpp, "DataProcessEngine", "option.cpp")

    t.case("gccmodulecheck: clean fixture tree yields zero problems", function ()
        assert_clean(t, problems_of(files, projdir), "clean tree")
    end)

    t.case("gccmodulecheck: leaf missing from its branch aggregate is flagged", function ()
        local mutated = copy_of(files)
        mutated[aggregate] = [[
export module WhiteHopeEngine:AlgorithmEngine;
export import :AlgorithmEngine.sort;
]]
        local problems = problems_of(mutated, projdir)
        t.assert_eq(#problems, 1, "missing re-export problem count")
        t.assert_match(problems[1], "missing re-export", "missing re-export text")
        t.assert_match(problems[1], "export import :AlgorithmEngine.search;", "exact line to add")
    end)

    t.case("gccmodulecheck: stale re-export of an undeclared partition is flagged", function ()
        local mutated = copy_of(files)
        mutated[aggregate] = mutated[aggregate] .. "export import :AlgorithmEngine.ghost;\n"
        local problems = problems_of(mutated, projdir)
        t.assert_eq(#problems, 1, "stale re-export problem count")
        t.assert_match(problems[1], "stale re-export", "stale re-export text")
        t.assert_match(problems[1], "AlgorithmEngine.ghost", "stale partition named")
    end)

    t.case("gccmodulecheck: re-exporting an internal partition is flagged", function ()
        local mutated = copy_of(files)
        mutated[aggregate] = mutated[aggregate] .. "export import :AlgorithmEngine.detail;\n"
        local problems = problems_of(mutated, projdir)
        t.assert_eq(#problems, 1, "internal re-export problem count")
        t.assert_match(problems[1], "gcc.modules: internal", "internal marker named")
        t.assert_match(problems[1], "still re-exported", "internal re-export text")
    end)

    t.case("gccmodulecheck: partition name diverging from its file path is flagged", function ()
        local mutated = copy_of(files)
        mutated[sort_leaf] = [[
export module WhiteHopeEngine:AlgorithmEngine.sorting;
import std;
]]
        mutated[aggregate] = [[
export module WhiteHopeEngine:AlgorithmEngine;
export import :AlgorithmEngine.sorting;
export import :AlgorithmEngine.search;
]]
        local problems = problems_of(mutated, projdir)
        t.assert_eq(#problems, 1, "name/path mismatch problem count")
        t.assert_match(problems[1], "partition name does not match its file path", "mismatch text")
        t.assert_match(problems[1], ":AlgorithmEngine.sorting", "declared name shown")
        t.assert_match(problems[1], ":AlgorithmEngine.sort", "derived name shown")
    end)

    t.case("gccmodulecheck: branch aggregate outside <Branch>/<Branch>.cpp is flagged", function ()
        local mutated = copy_of(files)
        mutated[path.join(cpp, "AlgorithmEngine", "agg.cpp")] = mutated[aggregate]
        mutated[aggregate] = nil
        local problems = problems_of(mutated, projdir)
        t.assert_eq(#problems, 1, "aggregate location problem count")
        t.assert_match(problems[1], "must be declared in", "aggregate location text")
        t.assert_match(problems[1], "AlgorithmEngine/AlgorithmEngine.cpp", "expected location named")
    end)

    t.case("gccmodulecheck: unconditional partition import cycle is reported", function ()
        local mutated = copy_of(files)
        mutated[sort_leaf] = [[
export module WhiteHopeEngine:AlgorithmEngine.sort;
import :AlgorithmEngine.search;
]]
        local problems = problems_of(mutated, projdir)
        t.assert_eq(#problems, 1, "cycle problem count")
        t.assert_match(problems[1], "partition import cycle among unconditional imports", "cycle text")
        t.assert_match(problems[1], "AlgorithmEngine.sort", "cycle names sort")
        t.assert_match(problems[1], "AlgorithmEngine.search", "cycle names search")
    end)

    t.case("gccmodulecheck: #if-gated imports are excluded from cycle detection", function ()
        local mutated = copy_of(files)
        mutated[sort_leaf] = [[
export module WhiteHopeEngine:AlgorithmEngine.sort;
#if CONFIG_TEST_GATE
import :AlgorithmEngine.search;
#endif
]]
        assert_clean(t, problems_of(mutated, projdir), "gated-import tree")
    end)

    t.case("gccmodulecheck: upward cross-branch import violates the layer order", function ()
        local mutated = copy_of(files)
        -- drop the legal downward import first so the upward edge does not
        -- also close a cycle (the cycle check would otherwise fire too);
        -- keep it importing something (AlgorithmEngine.detail, itself a
        -- leaf, safely reachable and not looping back) rather than nothing,
        -- so option itself is not a leaf -- otherwise the leaf exemption
        -- would swallow this violation instead of the direction check
        mutated[option_leaf] = [[
export module WhiteHopeEngine:DataProcessEngine.option;
import :AlgorithmEngine.detail;
]]
        mutated[sort_leaf] = [[
export module WhiteHopeEngine:AlgorithmEngine.sort;
import :DataProcessEngine.option;
]]
        local problems = problems_of(mutated, projdir)
        t.assert_eq(#problems, 1, "upward layer violation problem count")
        t.assert_match(problems[1], "layer violation", "layer violation text")
        t.assert_match(problems[1], "strictly lower layer", "direction rule named")
    end)

    t.case("gccmodulecheck: same-level sibling branch import violates the layer order", function ()
        local mutated = copy_of(files)
        -- OSCallEngine.file must not be a leaf itself (see the leaf-exemption
        -- cases below) or the exemption would swallow this violation too
        add_branch(mutated, cpp, "OSCallEngine", "file", "import std;\nimport :AlgorithmEngine.detail;\n")
        add_branch(mutated, cpp, "AudioEngine", "mixer", "import :OSCallEngine.file;\n")
        local problems = problems_of(mutated, projdir)
        t.assert_eq(#problems, 1, "same-level violation problem count")
        t.assert_match(problems[1], "layer violation", "layer violation text")
        t.assert_match(problems[1], "AudioEngine", "importer branch named")
        t.assert_match(problems[1], "OSCallEngine", "imported branch named")
    end)

    t.case("gccmodulecheck: a leaf partition (no unconditional imports of its own) is exempt from the layer-direction check even when nominally upward", function ()
        local mutated = copy_of(files)
        add_branch(mutated, cpp, "OSCallEngine", "abi_mirror", "import std;\n")
        mutated[sort_leaf] = [[
export module WhiteHopeEngine:AlgorithmEngine.sort;
import std;
import :OSCallEngine.abi_mirror;
]]
        assert_clean(t, problems_of(mutated, projdir), "leaf-exempt upward import tree")
    end)

    t.case("gccmodulecheck: a non-leaf partition still violates the layer order even sitting next to an exempt leaf", function ()
        local mutated = copy_of(files)
        add_branch(mutated, cpp, "OSCallEngine", "abi_mirror", "import std;\nimport :AlgorithmEngine.detail;\n")
        mutated[sort_leaf] = [[
export module WhiteHopeEngine:AlgorithmEngine.sort;
import std;
import :OSCallEngine.abi_mirror;
]]
        local problems = problems_of(mutated, projdir)
        t.assert_eq(#problems, 1, "non-leaf upward violation problem count")
        t.assert_match(problems[1], "layer violation", "layer violation text")
    end)

    t.case("gccmodulecheck: branches absent from the layer table are unconstrained", function ()
        local mutated = copy_of(files)
        add_branch(mutated, cpp, "ZzzUnrankedEngine", "thing", "import :DataProcessEngine.option;\n")
        assert_clean(t, problems_of(mutated, projdir), "unranked-branch tree")
    end)

    -- Auto mode: no declared layer order, so collect_problems is called without
    -- level_of and the branch check derives the layering from the graph itself,
    -- degrading to branch-cycle detection.
    local function auto_problems(files)
        -- no grouping passed: the fixture trees are single-module-with-partitions,
        -- which layers auto-detects as partition-prefix
        return gccmodulecheck.collect_problems(files, {projectdir = projdir})
    end
    local function has_problem(problems, needle)
        for _, problem in ipairs(problems) do
            if problem:find(needle, 1, true) then
                return true
            end
        end
        return false
    end

    t.case("gccmodulecheck: auto mode leaves an acyclic tree clean", function ()
        assert_clean(t, auto_problems(files), "auto-mode clean tree")
    end)

    t.case("gccmodulecheck: auto mode catches a branch cycle the partition-cycle check misses", function ()
        -- OSCallEngine.caller -> LibraryEngine.api and LibraryEngine.hook ->
        -- OSCallEngine.base: distinct partitions, so no PARTITION cycle, but the
        -- two branches import each other. api/base import a downward leaf so
        -- neither is a leaf (the edges survive the exemption).
        local mutated = copy_of(files)
        add_multi_branch(mutated, cpp, "OSCallEngine", {
            {name = "caller", body = "import :LibraryEngine.api;\n"},
            {name = "base", body = "import :AlgorithmEngine.sort;\n"}
        })
        add_multi_branch(mutated, cpp, "LibraryEngine", {
            {name = "api", body = "import :AlgorithmEngine.sort;\n"},
            {name = "hook", body = "import :OSCallEngine.base;\n"}
        })
        local problems = auto_problems(mutated)
        t.assert_true(has_problem(problems, "branch dependency cycle"),
            "branch cycle reported (got: " .. table.concat(problems, " | ") .. ")")
        t.assert_true(not has_problem(problems, "partition import cycle"),
            "no partition cycle should fire for distinct partitions")
    end)

    t.case("gccmodulecheck: auto mode leaf exemption -- importing a relocated pure-leaf mirror does not fabricate a branch cycle", function ()
        -- Mirrors the real jni relocation: OSCallEngine imports a pure-leaf ABI
        -- mirror that physically lives in LibraryEngine, while LibraryEngine
        -- imports a real OSCallEngine partition. Only the non-leaf edge counts,
        -- so there is no branch cycle.
        local mutated = copy_of(files)
        add_multi_branch(mutated, cpp, "OSCallEngine", {
            {name = "user", body = "import :LibraryEngine.mirror;\n"},
            {name = "base", body = "import :AlgorithmEngine.sort;\n"}
        })
        add_multi_branch(mutated, cpp, "LibraryEngine", {
            {name = "mirror", body = "import std;\n"},
            {name = "hook", body = "import :OSCallEngine.base;\n"}
        })
        assert_clean(t, auto_problems(mutated), "auto leaf-exempt tree")
    end)

    t.case("gccmodulecheck: run() raises one aggregated report", function ()
        local mutated = copy_of(files)
        mutated[aggregate] = [[
export module WhiteHopeEngine:AlgorithmEngine;
export import :AlgorithmEngine.sort;
]]
        local message = t.expect_raise(function ()
            gccmodulecheck.run(mutated, {projectdir = projdir, level_of = level_of})
        end, "module aggregate validation failed", "run() raise")
        t.assert_match(message, "AlgorithmEngine.search", "raise carries the problem detail")
    end)

    t.case("gccmodulecheck: is_interface_unit classifies unit kinds", function ()
        t.assert_eq(gccmodulecheck.is_interface_unit(
            "export module WhiteHopeEngine:AlgorithmEngine.sort;\n"), true, "interface partition")
        t.assert_eq(gccmodulecheck.is_interface_unit(
            "module WhiteHopeEngine;\n"), false, "implementation unit")
        t.assert_eq(gccmodulecheck.is_interface_unit(
            "module;\n#include <assert.h>\nexport module WhiteHopeEngine:X;\n"),
            true, "interface with global module fragment")
    end)

    t.case("gccmodulecheck: the cross-plat cache sentinel self-heals the referenced pair", function ()
        -- the wasm<->windows switch shape found live: a foreign-plat BMI
        -- tree plus a localcache file referencing it. The sentinel must
        -- remove exactly that pair and leave everything else alone
        -- (opt.builddir/opt.cachefile keep this off the real project state).
        -- opt.host="windows" forces the platform gate open regardless of
        -- which OS actually runs this test process -- the sentinel's real
        -- guard (os.host()=="windows") is exercised separately below; this
        -- case is about the self-healing core, which must be testable on
        -- every CI runner (Linux/macOS/Windows alike), not just on Windows.
        local root = t.tmpdir("plat-cache-sandbox")
        local builddir = path.join(root, "build")
        local fake_target = {
            name = function () return "WhiteHopeEngine" end,
            plat = function () return "windows" end,
            arch = function () return "x64" end
        }
        local gens = path.join(builddir, ".gens", "WhiteHopeEngine")
        local current = path.join(gens, "windows", "x64", "deadbeef", "rules", "bmi")
        local referenced = path.join(gens, "wasm", "wasm32")
        local unreferenced = path.join(gens, "linux", "x86_64")
        os.mkdir(current)
        os.mkdir(path.join(referenced, "cafef00d", "rules", "bmi"))
        os.mkdir(path.join(unreferenced, "0ddba11", "rules", "bmi"))
        local cachefile = path.join(root, "cache", "cxxmodules")
        os.mkdir(path.directory(cachefile))
        io.writefile(cachefile, "entry = " .. path.absolute(referenced):gsub("\\", "\\\\") .. "\\\\module.gcm\n")
        gccmodulecheck.warn_foreign_plat_cache(fake_target,
            {builddir = builddir, cachefile = cachefile, host = "windows"})
        t.assert_true(not os.isdir(referenced), "the referenced foreign tree must be removed")
        t.assert_true(not os.isdir(path.join(gens, "wasm")),
            "the emptied foreign plat shell must not linger")
        t.assert_true(not os.isfile(cachefile), "the referencing localcache file must be removed")
        t.assert_true(os.isdir(unreferenced), "an unreferenced foreign tree must survive (sibling coexistence)")
        t.assert_true(os.isdir(current), "the current-plat tree must survive")
        -- second run on the healed state must be a silent no-op
        gccmodulecheck.warn_foreign_plat_cache(fake_target,
            {builddir = builddir, cachefile = cachefile, host = "windows"})
        t.assert_true(os.isdir(unreferenced), "the no-op pass must not grow teeth")
    end)

    t.case("gccmodulecheck: the cache sentinel is a no-op on non-Windows hosts", function ()
        -- the MAX_PATH defect this sentinel guards against is Windows-only
        -- (see the function's header comment); on every other host it must
        -- do nothing at all, even when a foreign-plat tree plus a
        -- referencing localcache entry are genuinely present. Without this
        -- case, fixing the case above to inject host="windows" would leave
        -- the real production gate (opt.host defaulting to os.host()) with
        -- zero coverage.
        local root = t.tmpdir("plat-cache-sandbox-nonwindows")
        local builddir = path.join(root, "build")
        local fake_target = {
            name = function () return "WhiteHopeEngine" end,
            plat = function () return "linux" end,
            arch = function () return "x86_64" end
        }
        local gens = path.join(builddir, ".gens", "WhiteHopeEngine")
        local referenced = path.join(gens, "wasm", "wasm32")
        os.mkdir(path.join(referenced, "cafef00d", "rules", "bmi"))
        local cachefile = path.join(root, "cache", "cxxmodules")
        os.mkdir(path.directory(cachefile))
        io.writefile(cachefile, "entry = " .. path.absolute(referenced):gsub("\\", "\\\\") .. "\\\\module.gcm\n")
        for _, host in ipairs({"linux", "macosx", "bsd"}) do
            gccmodulecheck.warn_foreign_plat_cache(fake_target,
                {builddir = builddir, cachefile = cachefile, host = host})
        end
        t.assert_true(os.isdir(referenced), "a non-Windows host must leave the foreign tree untouched")
        t.assert_true(os.isfile(cachefile), "a non-Windows host must leave the localcache file untouched")
    end)

    t.case("gccmodulecheck: importable-unit classification covers partition implementation units", function ()
        t.assert_true(gccmodulecheck.is_importable_unit("export module WhiteHopeEngine:X.y;\n"),
            "interface partitions are importable")
        t.assert_true(gccmodulecheck.is_importable_unit("// gcc.modules: internal\nmodule WhiteHopeEngine:X.y;\n"),
            "partition implementation units are importable and must propagate")
        t.assert_true(not gccmodulecheck.is_importable_unit("module WhiteHopeEngine;\nimport std;\n"),
            "plain implementation units stay target-private")
        t.assert_true(not gccmodulecheck.is_interface_unit("module WhiteHopeEngine:X.y;\n"),
            "is_interface_unit keeps its narrow meaning for aggregate checks")
    end)
end
