-- Fixture regression for languages/cpp/modules/gccfeatures.lua
-- toolchain_of(): the gcc.features toolchain-identity resolution. The
-- anchor scenario is consumer-wiring audit defect G4: a target explicitly
-- declaring a non-GCC toolchain used to fall through to the managed-GCC
-- default and receive force-injected GCC flags (LNK1104 on msvc).
--
-- The module is pure (no imports, no ambient reads), so the suite imports
-- it straight from the live tree and drives everything through fake target
-- tables and explicit context.

local gccfeatures = import("gccfeatures",
    {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "cpp", "modules"), anonymous = true})

-- Minimal stand-in for the target surface toolchain_of() touches:
-- target:get(key) reads spec[key], target:data(key) reads spec.data[key]
-- (absent entirely when spec.data is nil, mirroring pre-load targets).
local function fake_target(spec)
    local target = {
        get = function (_, key)
            return spec[key]
        end
    }
    if spec.data then
        target.data = function (_, key)
            return spec.data[key]
        end
    end
    return target
end

local MANAGED_DEFAULT = {default_toolchain = "gcc"}

function run(t)
    t.case("gccfeatures: an explicit msvc toolchain never resolves as GCC (G4)", function ()
        local resolved = gccfeatures.toolchain_of(
            fake_target({toolchains = {"msvc"}}), MANAGED_DEFAULT)
        t.assert_eq(resolved, "msvc", "explicit declaration honored")
        t.assert_true(not gccfeatures.is_gcc_toolchain(resolved),
            "msvc target must not receive managed GCC flags")
    end)

    t.case("gccfeatures: an explicit clang toolchain is not the managed GCC", function ()
        local resolved = gccfeatures.toolchain_of(
            fake_target({toolchains = {"clang"}}), MANAGED_DEFAULT)
        t.assert_eq(resolved, "clang", "explicit declaration honored")
        t.assert_true(not gccfeatures.is_gcc_toolchain(resolved), "clang is not gcc/mingw")
    end)

    t.case("gccfeatures: an explicit external beside envs still outranks the default", function ()
        local resolved = gccfeatures.toolchain_of(
            fake_target({toolchains = {"envs", "msvc"}}), MANAGED_DEFAULT)
        t.assert_eq(resolved, "msvc", "non-envs explicit name wins")
    end)

    t.case("gccfeatures: a non-GCC toolset compiler resolves as external", function ()
        local resolved = gccfeatures.toolchain_of(
            fake_target({["toolset.cxx"] = "cl.exe"}), MANAGED_DEFAULT)
        t.assert_eq(resolved, "external", "explicit toolset must not fall to the default")
        t.assert_true(not gccfeatures.is_gcc_toolchain(resolved), "cl.exe is not gcc/mingw")
    end)

    t.case("gccfeatures: toolchains.auto declared identity wins", function ()
        local resolved = gccfeatures.toolchain_of(
            fake_target({data = {["toolchains.auto.declared"] = "mingw"},
                toolchains = {"msvc"}}), MANAGED_DEFAULT)
        t.assert_eq(resolved, "mingw", "declared identity outranks everything")
        t.assert_true(gccfeatures.is_gcc_toolchain(resolved), "mingw is a GCC identity")
    end)

    t.case("gccfeatures: a g++ toolset resolves as gcc", function ()
        local resolved = gccfeatures.toolchain_of(
            fake_target({["toolset.cxx"] = "C:/tools/bin/x86_64-w64-mingw32-g++.exe"}),
            MANAGED_DEFAULT)
        t.assert_eq(resolved, "gcc", "g++ toolset recognized")
    end)

    t.case("gccfeatures: the gcc toolset check dominates an envs declaration", function ()
        local resolved = gccfeatures.toolchain_of(
            fake_target({toolchains = {"envs"}, ["toolset.cxx"] = "aarch64-linux-gnu-g++"}),
            MANAGED_DEFAULT)
        t.assert_eq(resolved, "gcc", "envs + gcc compiler recognized via the toolset check")
    end)

    t.case("gccfeatures: an envs declaration alone falls to the managed default", function ()
        local resolved = gccfeatures.toolchain_of(
            fake_target({toolchains = {"envs"}}), MANAGED_DEFAULT)
        t.assert_eq(resolved, "gcc", "envs is not an identity and must not read as explicit")
    end)

    t.case("gccfeatures: project_gcc alias resolves as gcc", function ()
        local resolved = gccfeatures.toolchain_of(
            fake_target({toolchains = {"project_gcc"}}), MANAGED_DEFAULT)
        t.assert_eq(resolved, "gcc", "managed alias recognized")
    end)

    t.case("gccfeatures: undeclared targets keep the managed default", function ()
        local resolved = gccfeatures.toolchain_of(fake_target({}), MANAGED_DEFAULT)
        t.assert_eq(resolved, "gcc", "fallback preserved for auto-managed consumers")
    end)

    t.case("gccfeatures: global toolchain config outranks the managed default", function ()
        local resolved = gccfeatures.toolchain_of(fake_target({}),
            {global_toolchain = "Clang", default_toolchain = "gcc"})
        t.assert_eq(resolved, "clang", "global config honored (lowercased)")
        t.assert_true(not gccfeatures.is_gcc_toolchain(resolved), "clang is not gcc/mingw")
    end)

    t.case("gccfeatures: mingw platform fallback stays mingw", function ()
        local resolved = gccfeatures.toolchain_of(fake_target({}),
            {mingw_plat = true, default_toolchain = "gcc"})
        t.assert_eq(resolved, "mingw", "platform fallback preserved")
    end)

    t.case("gccfeatures: disabled toolchains_auto yields no identity", function ()
        local resolved = gccfeatures.toolchain_of(fake_target({}), {default_toolchain = ""})
        t.assert_eq(resolved, "", "empty managed default passes through unchanged")
        t.assert_true(not gccfeatures.is_gcc_toolchain(resolved), "no identity, no injection")
    end)
end
