-- Fixture regression for core/modules/settings.lua triplet policy.
-- The anchor scenario is the config-residue trap: a leftover project arch
-- (x64 checkouts, reused matrix trees) used to flow into the macosx/ios
-- default triplets and silently select the mainline source profile, which
-- carries no Darwin support at all (bit the C3 chain live, 2026-07-17).
-- The Darwin triplets are aarch64-only by policy now; the explicit
-- --toolchains_target override remains the escape hatch and is asserted
-- here so the clamp can never quietly eat it.

local settings = import("settings",
    {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules"), anonymous = true})

function run(t)
    t.case("settings: the macosx default triplet is aarch64-only", function ()
        os.setenv("TOOLCHAINS_TARGET", "")
        local triplet = settings.default_triplet("macosx")
        t.assert_true(triplet:match("^aarch64%-apple%-darwin%d+$") ~= nil,
            "unexpected macosx triplet: " .. tostring(triplet))
    end)

    t.case("settings: a residual x86_64 arch cannot reach the macosx triplet", function ()
        os.setenv("TOOLCHAINS_TARGET", "")
        local triplet = settings.default_triplet("macosx", "x86_64")
        t.assert_true(triplet:match("^aarch64%-apple%-darwin%d+$") ~= nil,
            "arch residue leaked into the macosx triplet: " .. tostring(triplet))
    end)

    t.case("settings: the ios default triplet is aarch64-only and unversioned", function ()
        os.setenv("TOOLCHAINS_TARGET", "")
        t.assert_eq(settings.default_triplet("ios"), "aarch64-apple-ios", "ios triplet")
        t.assert_eq(settings.default_triplet("ios", "x86_64"), "aarch64-apple-ios",
            "arch residue leaked into the ios triplet")
    end)

    t.case("settings: emscripten stays wasm32 regardless of the configured arch", function ()
        os.setenv("TOOLCHAINS_TARGET", "")
        t.assert_eq(settings.default_triplet("emscripten", "x86_64"),
            "wasm32-unknown-emscripten", "emscripten triplet")
    end)

    t.case("settings: 32-bit ARM Android uses the eabi triplet, not armv7a-linux-android", function ()
        os.setenv("TOOLCHAINS_TARGET", "")
        -- The NDK names its sysroot include/lib dirs and GCC's config.gcc case
        -- arm-linux-androideabi; a naive armv7a-linux-android would resolve no
        -- dirs and have no GCC target case.
        t.assert_eq(settings.default_triplet("android", "armeabi-v7a"),
            "arm-linux-androideabi", "armeabi-v7a triplet")
        t.assert_eq(settings.default_triplet("android", "arm64-v8a"),
            "aarch64-linux-android", "64-bit ARM stays -linux-android")
    end)

    t.case("settings: an explicit toolchains_target override outranks the clamp", function ()
        os.setenv("TOOLCHAINS_TARGET", "x86_64-apple-darwin20")
        local triplet = settings.managed_target("macosx")
        local arch = settings.target_arch("macosx")
        local darwin_profile = settings.uses_darwin_arm64_gcc("macosx")
        os.setenv("TOOLCHAINS_TARGET", "")
        t.assert_eq(triplet, "x86_64-apple-darwin20", "override honored")
        t.assert_eq(arch, "x86_64", "target_arch follows the overridden triplet")
        -- the override drops out of the darwin-arm64 profile; the macosx
        -- preflight aarch64-only warning is what flags it to the operator
        t.assert_true(not darwin_profile, "overridden arch must not claim the darwin-arm64 profile")
    end)

    t.case("settings: darwin profile selection follows the clamped triplet", function ()
        os.setenv("TOOLCHAINS_TARGET", "")
        t.assert_true(settings.uses_darwin_arm64_gcc("macosx"),
            "macosx must select the darwin-arm64 profile")
        t.assert_true(settings.uses_darwin_arm64_gcc("ios"),
            "ios must select the darwin-arm64 profile")
    end)

    -- leave the process environment clean for later suites
    os.setenv("TOOLCHAINS_TARGET", "")
end
