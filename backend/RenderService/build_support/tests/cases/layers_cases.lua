-- Fixture regression for core/modules/layers.lua (the general C++ module
-- dependency-layerer): the manual "<level>:<name>" resolver's validation and
-- the automatic module-graph derivation under both grouping strategies (the
-- general "module" default and "partition-prefix"). Both entry points are pure
-- over their inputs (a string list / a { [file]=content } table), so no
-- target/config is needed.

local layers = import("layers", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules"), anonymous = true})

function run(t)
    t.case("layers: from_manual ranks branches and respects same-level siblings", function ()
        local m = layers.from_manual({"1:ExceptionEngine", "4:OSCallEngine", "4:AudioEngine", "7:WindowEngine"})
        t.assert_eq(m.level_of("ExceptionEngine"), 1, "lowest level")
        t.assert_eq(m.level_of("WindowEngine"), 7, "highest level")
        t.assert_true(m.may_depend("WindowEngine", "ExceptionEngine"), "top may depend on bottom")
        t.assert_true(not m.may_depend("OSCallEngine", "AudioEngine"), "same-level siblings must not depend")
        t.assert_eq(#m.known_names(), 4, "all four ranked")
    end)

    t.case("layers: from_manual tolerates a repeated branch at the SAME level", function ()
        local m = layers.from_manual({"3:DataProcessEngine", "3:DataProcessEngine"})
        t.assert_eq(m.level_of("DataProcessEngine"), 3, "same-level duplicate is harmless")
    end)

    t.case("layers: from_manual rejects a branch declared at two DIFFERENT levels", function ()
        t.expect_raise(function ()
            layers.from_manual({"4:OSCallEngine", "3:OSCallEngine"})
        end, "two different layers", "conflicting duplicate branch")
    end)

    t.case("layers: from_manual rejects level 0 (reserved for the runtime)", function ()
        t.expect_raise(function ()
            layers.from_manual({"0:ExceptionEngine"})
        end, "levels must be >= 1", "level zero")
    end)

    t.case("layers: from_manual rejects a negative level", function ()
        t.expect_raise(function ()
            layers.from_manual({"-1:ExceptionEngine"})
        end, "levels must be >= 1", "negative level")
    end)

    t.case("layers: from_manual rejects a malformed entry", function ()
        t.expect_raise(function ()
            layers.from_manual({"OSCallEngine"})
        end, "malformed layer entry", "missing level")
    end)

    t.case("layers: from_module_graph derives an acyclic layering with the expected order", function ()
        local files = {
            ["/p/A/A.cpp"] = "export module WhiteHopeEngine:A;\nexport import :A.base;\n",
            ["/p/A/base.cpp"] = "export module WhiteHopeEngine:A.base;\nimport std;\n",
            ["/p/B/B.cpp"] = "export module WhiteHopeEngine:B;\nexport import :B.core;\n",
            ["/p/B/core.cpp"] = "export module WhiteHopeEngine:B.core;\nimport :A.base;\nimport :A.impl;\n",
            ["/p/A/impl.cpp"] = "export module WhiteHopeEngine:A.impl;\nimport :A.base;\n"
        }
        local g = layers.from_module_graph(files, {grouping = "partition-prefix"})
        t.assert_true(g.cycle == nil, "acyclic tree yields no cycle")
        -- B.core imports A.impl (a non-leaf, so a real edge), so B sits above A
        t.assert_true(g.may_depend("B", "A"), "B depends on A")
        t.assert_true(not g.may_depend("A", "B"), "A does not depend on B")
    end)

    t.case("layers: from_module_graph excludes a root-level single-file partition (Version)", function ()
        -- A dot-free partition at the source root (Version.cpp, parent dir != name)
        -- is a root leaf, not an Engine branch, so it must not enter known_names
        -- (else a rust rs/Version/ crate would be wrongly accepted). A dot-free
        -- aggregate at <Branch>/<Branch>.cpp IS a branch.
        local files = {
            ["/p/cpp/Version.cpp"] = "export module WhiteHopeEngine:Version;\nimport std;\n",
            ["/p/cpp/AlgorithmEngine/AlgorithmEngine.cpp"] = "export module WhiteHopeEngine:AlgorithmEngine;\nexport import :AlgorithmEngine.sort;\n",
            ["/p/cpp/AlgorithmEngine/sort.cpp"] = "export module WhiteHopeEngine:AlgorithmEngine.sort;\nimport std;\n"
        }
        local g = layers.from_module_graph(files, {grouping = "partition-prefix"})
        t.assert_true(g.level_of("Version") == nil, "Version is not a branch")
        t.assert_true(g.level_of("AlgorithmEngine") ~= nil, "a real branch aggregate is ranked")
        local names = g.known_names()
        t.assert_eq(#names, 1, "only the real branch is known (got: " .. table.concat(names, ",") .. ")")
    end)

    t.case("layers: from_module_graph counts an impl-partition unit's cross-branch import", function ()
        -- `module M:P;` (no export) is importable, so its cross-branch import must
        -- participate in the graph. Here an OSCall impl partition imports a
        -- non-leaf Lib partition -> OSCall depends on Lib.
        local files = {
            ["/p/Lib/Lib.cpp"] = "export module WhiteHopeEngine:Lib;\nexport import :Lib.api;\n",
            ["/p/Lib/api.cpp"] = "export module WhiteHopeEngine:Lib.api;\nimport :Base.leaf;\n",
            ["/p/Base/Base.cpp"] = "export module WhiteHopeEngine:Base;\nexport import :Base.leaf;\n",
            ["/p/Base/leaf.cpp"] = "export module WhiteHopeEngine:Base.leaf;\nimport std;\n",
            ["/p/OSCall/detail.cpp"] = "module WhiteHopeEngine:OSCall.detail;\nimport :Lib.api;\n"
        }
        local g = layers.from_module_graph(files, {grouping = "partition-prefix"})
        t.assert_true(g.cycle == nil, "no cycle")
        t.assert_true(g.may_depend("OSCall", "Lib"), "impl-partition edge OSCall->Lib is counted")
    end)

    t.case("layers: from_module_graph default groups by named module (ordinary multi-module project)", function ()
        -- No project convention assumed: one node per named module, `import X;`
        -- an edge. An imported module is genuinely below you (no leaf exemption).
        local files = {
            ["/p/app.cpp"] = "export module app;\nimport core;\nimport util;\n",
            ["/p/core.cpp"] = "export module core;\nimport util;\n",
            ["/p/util.cpp"] = "export module util;\nimport std;\n",
            ["/p/core_impl.cpp"] = "module core;\nimport util;\n"
        }
        local g = layers.from_module_graph(files)  -- default grouping = "module"
        t.assert_true(g.cycle == nil, "acyclic")
        t.assert_eq(#g.known_names(), 3, "three modules are nodes")
        t.assert_true(g.may_depend("core", "util"), "core imports util -> util is below core")
        t.assert_true(g.may_depend("app", "core"), "app imports core")
        t.assert_true(not g.may_depend("util", "app"), "util does not depend on app")
    end)

    t.case("layers: from_module_graph default detects a cross-module cycle", function ()
        local files = {
            ["/p/a.cpp"] = "export module a;\nimport b;\n",
            ["/p/b.cpp"] = "export module b;\nimport a;\n"
        }
        local g = layers.from_module_graph(files)
        t.assert_true(g.cycle ~= nil, "a<->b cycle is reported")
    end)

    t.case("layers: from_module_graph rejects an unknown grouping name", function ()
        t.expect_raise(function ()
            layers.from_module_graph({}, {grouping = "nonsense"})
        end, "unknown layer grouping", "bad strategy name")
    end)

    t.case("layers: grouping auto-detects (single module with partitions -> partition-prefix)", function ()
        -- No grouping passed: a single named module that has partitions is the
        -- single-module-with-partitions shape, so branches come from partition
        -- prefixes (grouping by named module would collapse to one node).
        local files = {
            ["/p/cpp/A/A.cpp"] = "export module Engine:A;\nexport import :A.leaf;\n",
            ["/p/cpp/A/leaf.cpp"] = "export module Engine:A.leaf;\nimport std;\n",
            ["/p/cpp/B/B.cpp"] = "export module Engine:B;\nexport import :B.leaf;\n",
            ["/p/cpp/B/leaf.cpp"] = "export module Engine:B.leaf;\nimport :A.leaf;\n"
        }
        local g = layers.from_module_graph(files)  -- auto-detect
        t.assert_true(g.level_of("A") ~= nil and g.level_of("B") ~= nil, "A and B are nodes")
        t.assert_true(g.level_of("Engine") == nil, "the single module is not a node")
    end)

    t.case("layers: grouping auto-detects (multiple named modules -> module)", function ()
        local files = {
            ["/p/foo.cpp"] = "export module foo;\nimport bar;\n",
            ["/p/bar.cpp"] = "export module bar;\nimport std;\n"
        }
        local g = layers.from_module_graph(files)  -- auto-detect
        t.assert_true(g.level_of("foo") ~= nil and g.level_of("bar") ~= nil, "foo and bar are nodes")
        t.assert_true(g.may_depend("foo", "bar"), "foo imports bar")
    end)

    t.case("layers: direction_violations catches an upward MODULE import (multi-module manual)", function ()
        -- app at level 1 illegally imports core at level 2 (upward). The general
        -- direction check must catch this even though there are no partitions.
        local files = {
            ["/p/app.cpp"] = "export module app;\nimport core;\n",
            ["/p/core.cpp"] = "export module core;\nimport std;\n"
        }
        local level = function (n) return ({app = 1, core = 2})[n] end
        local v = layers.direction_violations(files, level)  -- auto-detect -> module
        t.assert_eq(#v, 1, "one upward import")
        t.assert_eq(v[1].importer_group, "app", "importer named")
        t.assert_eq(v[1].imported_group, "core", "imported named")
    end)

    t.case("layers: direction_violations is clean for a legal downward MODULE import", function ()
        local files = {
            ["/p/app.cpp"] = "export module app;\nimport core;\n",
            ["/p/core.cpp"] = "export module core;\nimport std;\n"
        }
        local level = function (n) return ({app = 2, core = 1})[n] end
        t.assert_eq(#layers.direction_violations(files, level), 0, "downward import is legal")
    end)

    t.case("layers: direction_violations honours the partition-prefix leaf exemption", function ()
        -- OSCall imports a pure-leaf mirror that nominally sits in Lib (upward),
        -- but the leaf exemption means it is not a violation.
        local files = {
            ["/p/cpp/OSCall/OSCall.cpp"] = "export module M:OSCall;\nexport import :OSCall.use;\n",
            ["/p/cpp/OSCall/use.cpp"] = "export module M:OSCall.use;\nimport :Lib.mirror;\n",
            ["/p/cpp/Lib/Lib.cpp"] = "export module M:Lib;\nexport import :Lib.mirror;\n",
            ["/p/cpp/Lib/mirror.cpp"] = "export module M:Lib.mirror;\nimport std;\n"
        }
        local level = function (n) return ({OSCall = 4, Lib = 6})[n] end  -- OSCall below Lib
        local v = layers.direction_violations(files, level, {grouping = "partition-prefix"})
        t.assert_eq(#v, 0, "importing a pure-leaf mirror is exempt (got: " .. #v .. ")")
    end)
end
