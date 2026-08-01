-- Fixture regression for wasm_runtime.find_rlibs, the build-std artifact
-- locator. Anchor scenario: nightly-2026-08-01's Cargo build-dir split moved
-- intermediate rlibs from `release/deps` into per-crate
-- `release/build/<crate>/<hash>/out` folders and left `deps` empty, so the
-- deps-only glob found 0 rlibs and the fresh toolchain install died right
-- after a successful `cargo build` (observed on the RenderService checkout,
-- 2026-08-01). These cases pin all three accepted layout shapes and the
-- exactly-one contract.

local wasm_runtime = import("wasm_runtime",
    {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "rust", "modules"), anonymous = true})

local CRATES = {"core", "compiler_builtins", "alloc"}

local function fresh_root(label)
    local root = path.join(os.tmpdir(), "wasm-runtime-cases", label)
    os.tryrm(root)
    os.mkdir(root)
    return root
end

local function touch(file)
    os.mkdir(path.directory(file))
    io.writefile(file, "stub")
end

function run(t)
    t.case("find_rlibs: the flat cache layout resolves (our own output dir)", function ()
        local root = fresh_root("flat")
        for _, name in ipairs(CRATES) do
            touch(path.join(root, "lib" .. name .. "-0123abcd.rlib"))
        end
        local rlibs = wasm_runtime.find_rlibs(root, {}, true)
        t.assert_eq(#rlibs, 3, "all three crates found")
        t.assert_eq(rlibs[1].name, "core", "order follows the expected crate list")
    end)

    t.case("find_rlibs: the pre-2026-08 deps layout resolves", function ()
        local root = fresh_root("deps")
        for _, name in ipairs(CRATES) do
            touch(path.join(root, "deps", "lib" .. name .. "-0123abcd.rlib"))
        end
        local rlibs = wasm_runtime.find_rlibs(root, {}, true)
        t.assert_eq(#rlibs, 3, "all three crates found under deps")
    end)

    t.case("find_rlibs: the 2026 build-dir split layout resolves (deps left empty)", function ()
        local root = fresh_root("builddir")
        os.mkdir(path.join(root, "deps"))
        for _, name in ipairs(CRATES) do
            touch(path.join(root, "build", name, "0123abcd", "out", "lib" .. name .. "-0123abcd.rlib"))
        end
        local rlibs = wasm_runtime.find_rlibs(root, {}, true)
        t.assert_eq(#rlibs, 3, "all three crates found under build/<crate>/<hash>/out")
        t.assert_true(rlibs[1].path:find("out", 1, true) ~= nil, "path points into the out folder")
    end)

    t.case("find_rlibs: zero matches fail loudly in strict mode", function ()
        local root = fresh_root("empty")
        t.expect_raise(function () wasm_runtime.find_rlibs(root, {}, true) end,
            "expected one libcore rlib", "empty tree must not pass")
    end)

    t.case("find_rlibs: duplicates across layouts fail loudly (no silent pick)", function ()
        local root = fresh_root("dup")
        for _, name in ipairs(CRATES) do
            touch(path.join(root, "deps", "lib" .. name .. "-aaaa.rlib"))
            touch(path.join(root, "build", name, "bbbb", "out", "lib" .. name .. "-bbbb.rlib"))
        end
        t.expect_raise(function () wasm_runtime.find_rlibs(root, {}, true) end,
            "found 2", "ambiguous artifacts must raise, never pick one")
    end)

    t.case("find_rlibs: non-strict mode returns nil instead of raising", function ()
        local root = fresh_root("lenient")
        t.assert_true(wasm_runtime.find_rlibs(root, {}, false) == nil,
            "cache-miss probing must stay quiet")
    end)
end
