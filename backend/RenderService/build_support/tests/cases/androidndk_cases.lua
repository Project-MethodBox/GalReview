-- Fixture regression for core/modules/androidndk.lua resolve(): the
-- documented resolution chain option > env(ANDROID_NDK_HOME >
-- ANDROID_NDK_ROOT > NDK_HOME) > SDK ndk/<version match> > newest SDK ndk/.
--
-- resolve() caches its result for the process lifetime, so every scenario
-- imports a FRESH module instance from its own build_support replica
-- (fresh instance = fresh cache). The chain is driven purely through
-- environment variables: settings.value_or() falls back to the upper-cased
-- env name, which is also the documented ANDROID_NDK env behavior; every
-- scenario pins ALL chain-relevant variables so the host machine's real
-- SDK/NDK can never leak in (no scenario ever reaches the LOCALAPPDATA/HOME
-- fallback of sdk_root()).

-- every env var the resolution chain can read, reset around each scenario
local ENV_KEYS = {
    "ANDROID_NDK", "ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "NDK_HOME",
    "ANDROID_SDK", "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_NDK_VERSION"
}

local function set_chain_env(overrides)
    for _, key in ipairs(ENV_KEYS) do
        os.setenv(key, overrides[key] or "")
    end
end

local function fresh_module(t)
    local replica = t.replicate_build_support({"core/modules"}, "androidndk-sandbox")
    return import("androidndk", {rootdir = path.join(replica, "core", "modules"), anonymous = true})
end

local function make_ndk(t, label, revision)
    local dir = path.join(t.tmpdir("ndk-" .. label), "ndk-root")
    t.write(path.join(dir, "source.properties"),
        "Pkg.Desc = Android NDK\nPkg.Revision = " .. revision .. "\n")
    return dir
end

local function make_sdk(t, versions)
    local sdk = path.join(t.tmpdir("android-sdk"), "Sdk")
    for _, version in ipairs(versions) do
        t.write(path.join(sdk, "ndk", version, "source.properties"),
            "Pkg.Desc = Android NDK\nPkg.Revision = " .. version .. "\n")
    end
    return sdk
end

local function normalized(value)
    return (tostring(value):gsub("\\", "/")):lower()
end

function run(t)
    t.case("androidndk: the android_ndk option outranks env and SDK", function ()
        local option_ndk = make_ndk(t, "option", "27.1.111")
        local env_ndk = make_ndk(t, "env", "26.0.222")
        set_chain_env({ANDROID_NDK = option_ndk, ANDROID_NDK_HOME = env_ndk,
            ANDROID_HOME = make_sdk(t, {"25.0.1"})})
        local resolved = fresh_module(t).resolve()
        t.assert_eq(resolved.source, "option", "winning source")
        t.assert_eq(normalized(resolved.root), normalized(option_ndk), "resolved root")
        t.assert_eq(resolved.version, "27.1.111", "version from source.properties")
        t.assert_eq(#resolved.problems, 0, "problem count")
    end)

    t.case("androidndk: android_ndk pointing nowhere is a problem, not a fallthrough", function ()
        local missing = path.join(t.tmpdir("ndk-missing"), "nope")
        set_chain_env({ANDROID_NDK = missing, ANDROID_NDK_HOME = make_ndk(t, "shadowed", "26.0.1")})
        local ndk = fresh_module(t)
        local resolved = ndk.resolve()
        t.assert_eq(resolved.source, "option", "misconfigured source still attributed")
        t.assert_eq(resolved.root, nil, "no invented root")
        t.assert_eq(#resolved.problems, 1, "problem count")
        t.assert_match(ndk.problem_text(resolved.problems[1]), "nope", "problem names the bad path")
        t.expect_raise(function ()
            ndk.root_or_fail()
        end, "not a directory", "root_or_fail loud path")
    end)

    t.case("androidndk: env order ANDROID_NDK_ROOT beats NDK_HOME and the SDK", function ()
        local root_ndk = make_ndk(t, "root-env", "27.2.333")
        set_chain_env({ANDROID_NDK_ROOT = root_ndk, NDK_HOME = make_ndk(t, "home-env", "26.1.444"),
            ANDROID_HOME = make_sdk(t, {"25.0.1"})})
        local resolved = fresh_module(t).resolve()
        t.assert_eq(resolved.source, "env:ANDROID_NDK_ROOT", "winning source")
        t.assert_eq(normalized(resolved.root), normalized(root_ndk), "resolved root")
        t.assert_eq(resolved.version, "27.2.333", "version from source.properties")
    end)

    t.case("androidndk: android_ndk_version picks the matching SDK ndk/ folder (loose prefix)", function ()
        set_chain_env({ANDROID_HOME = make_sdk(t, {"27.0.1", "28.0.2"}),
            ANDROID_NDK_VERSION = "27"})
        local resolved = fresh_module(t).resolve()
        t.assert_eq(resolved.source, "sdk:version", "winning source")
        t.assert_match(normalized(resolved.root), "/ndk/27.0.1", "matched folder")
        t.assert_eq(resolved.version, "27.0.1", "version from source.properties")
        t.assert_eq(#resolved.problems, 0, "problem count")
    end)

    t.case("androidndk: a requested version that is not installed is a problem", function ()
        set_chain_env({ANDROID_HOME = make_sdk(t, {"27.0.1", "28.0.2"}),
            ANDROID_NDK_VERSION = "29"})
        local ndk = fresh_module(t)
        local resolved = ndk.resolve()
        t.assert_eq(resolved.source, "sdk:version", "source attribution")
        t.assert_eq(resolved.root, nil, "no invented root")
        t.assert_eq(#resolved.problems, 1, "problem count")
        local text = ndk.problem_text(resolved.problems[1])
        t.assert_match(text, "is not installed", "problem text")
        t.assert_match(text, "27.0.1", "installed versions listed")
    end)

    t.case("androidndk: without a version request the newest SDK ndk/ wins", function ()
        set_chain_env({ANDROID_HOME = make_sdk(t, {"27.0.1", "28.0.2"})})
        local resolved = fresh_module(t).resolve()
        t.assert_eq(resolved.source, "sdk:newest", "winning source")
        t.assert_match(normalized(resolved.root), "/ndk/28.0.2", "newest folder")
        t.assert_eq(resolved.version, "28.0.2", "version from source.properties")
    end)

    -- leave the process environment clean for later suites
    set_chain_env({})
end
