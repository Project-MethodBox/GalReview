-- Fixture regression for the GCC-triplet -> rustc-target mapping in
-- languages/rust/modules/toolchain.lua (rust_target_for). Anchor scenario:
-- the iOS device triplet (aarch64-apple-ios) had no table entry and does
-- NOT match the version-suffixed *-apple-darwin fallback, so every iOS
-- project build died at the rust.crates stage with "no rustc target
-- mapping" (2026-07-22). These cases pin the ios mapping, keep the darwin
-- fallback covered, and assert that simulator/catalyst and unknown triplets
-- still fail loudly rather than silently resolving to the device target.

local toolchain = import("toolchain",
    {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "rust", "modules"), anonymous = true})

function run(t)
    t.case("rust_target: the ios device triplet maps to the rustc ios target", function ()
        t.assert_eq(toolchain.rust_target_for("aarch64-apple-ios"), "aarch64-apple-ios",
            "ios rustc target")
    end)

    t.case("rust_target: a table triplet resolves (android sanity)", function ()
        t.assert_eq(toolchain.rust_target_for("aarch64-linux-android"), "aarch64-linux-android",
            "android rustc target")
    end)

    t.case("rust_target: the version-suffixed darwin triplet still falls back", function ()
        t.assert_eq(toolchain.rust_target_for("aarch64-apple-darwin20"), "aarch64-apple-darwin",
            "darwin fallback")
        t.assert_eq(toolchain.rust_target_for("x86_64-apple-darwin21"), "x86_64-apple-darwin",
            "darwin fallback keeps the arch")
    end)

    t.case("rust_target: an unmapped apple triplet fails loudly (no device mis-map)", function ()
        -- iOS simulator/catalyst are distinct rustc targets and unsupported
        -- yet; they must raise, never silently resolve to the device target
        t.expect_raise(function () toolchain.rust_target_for("aarch64-apple-ios-sim") end,
            "no rustc target mapping", "ios simulator must not mis-map")
    end)

    t.case("rust_target: an entirely unknown triplet fails loudly", function ()
        t.expect_raise(function () toolchain.rust_target_for("sparc-unknown-frobozz") end,
            "no rustc target mapping", "unknown triplet")
    end)

    -- host_objcopy_path pins the completeness sentinel that lets an incomplete
    -- rustc install self-heal (2026-07-22: a macOS prefix had rustc but no
    -- rust-objcopy, so cargo build-std of compiler_builtins died at build
    -- time). The path must resolve to the host rustlib's self-contained bin so
    -- a re-overlay of the rustc component restores it.
    t.case("rust_toolchain: rust-objcopy resolves under the host rustlib bin inside the prefix", function ()
        local objcopy = toolchain.host_objcopy_path()
        local prefix = toolchain.rust_prefix()
        t.assert_eq(objcopy:sub(1, #prefix), prefix, "rust-objcopy must live inside the pinned Rust prefix")
        t.assert_true(objcopy:find("rustlib", 1, true) ~= nil, "rust-objcopy must live under lib/rustlib")
        t.assert_true(objcopy:find(toolchain.host_rust_target(), 1, true) ~= nil,
            "rust-objcopy must live under the host rust target")
        t.assert_true(path.filename(objcopy):match("^rust%-objcopy") ~= nil,
            "the sentinel leaf must be the rust-objcopy tool")
    end)

    -- First-install freshness (2026-07-25): a fresh checkout used to install
    -- the aging built-in default nightly; the first install now resolves the
    -- newest published date via the channel manifest and writes the pin file.
    -- These cases pin the manifest parser feeding resolve_newest_nightly()
    -- and `xmake toolchains update rust`.
    t.case("rust_toolchain: the channel manifest date line parses", function ()
        t.assert_eq(toolchain.parse_nightly_date('date = "2026-07-24"'), "2026-07-24",
            "plain date line")
        t.assert_eq(toolchain.parse_nightly_date('manifest-version = "2"\ndate="2026-01-02"\n[pkg.cargo]'),
            "2026-01-02", "embedded line without spaces still parses")
    end)

    t.case("rust_toolchain: a manifest without a usable date yields nil (resolution fails loudly)", function ()
        t.assert_true(toolchain.parse_nightly_date("no date here") == nil,
            "missing date line must not parse")
        t.assert_true(toolchain.parse_nightly_date('date = "26-07-24"') == nil,
            "malformed date must not parse")
        t.assert_true(toolchain.parse_nightly_date(nil) == nil, "nil manifest must not parse")
    end)
end
