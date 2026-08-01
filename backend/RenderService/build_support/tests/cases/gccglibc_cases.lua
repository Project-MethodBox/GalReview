-- Fixture regression for languages/cpp/modules/gccglibc.lua
-- resolve_version(): auto host-follow (which on non-Linux hosts is the
-- default-version branch), explicit supported versions, and the two
-- misconfiguration shapes (non-version text, unsupported version).
--
-- resolve_version() caches per process, so every scenario imports a fresh
-- module instance from its own build_support replica; the configured value
-- is driven through the LINUX_GLIBC_VERSION env fallback of
-- settings.value_or(). Assertions compare against the LIVE defaults.lua
-- (glibc_default_version / glibc_versions), so version-set bumps do not
-- break this suite.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})

local REPLICA_SUBDIRS = {"core/modules", "languages/cpp/modules", "languages/cpp/modules/patches"}

local function fresh_module(t)
    local replica = t.replicate_build_support(REPLICA_SUBDIRS, "gccglibc-sandbox")
    local gccglibc = import("gccglibc",
        {rootdir = path.join(replica, "languages", "cpp", "modules"), anonymous = true})
    local defaults = import("defaults",
        {rootdir = path.join(replica, "core", "modules"), anonymous = true}).values()
    return gccglibc, defaults
end

local function set_glibc_env(version)
    os.setenv("LINUX_GLIBC_VERSION", version or "")
    os.setenv("GLIBC_SNAPSHOT_URL", "")
end

function run(t)
    t.case("gccglibc: auto resolves to a supported version with no problems", function ()
        set_glibc_env(nil)
        local gccglibc, defaults = fresh_module(t)
        local resolved = gccglibc.resolve_version("linux")
        t.assert_eq(#resolved.problems, 0, "problem count")
        t.assert_true(defaults.glibc_versions[resolved.version],
            "resolved version must be in the managed set: " .. tostring(resolved.version))
        if base.host_os() == "linux" then
            -- host-follow branch: source is host / host-nearest / host-oldest,
            -- or default when the probe fails
            t.assert_true(tostring(resolved.source):find("host", 1, true) ~= nil
                or tostring(resolved.source):find("default", 1, true) ~= nil,
                "unexpected auto source on a Linux host: " .. tostring(resolved.source))
        else
            -- non-Linux hosts (the Windows CI/dev case) take the default branch
            t.assert_eq(resolved.source, "default", "auto source on a non-Linux host")
            t.assert_eq(resolved.version, defaults.glibc_default_version, "default version honored")
        end
        t.assert_eq(resolved.url, defaults.glibc_versions[resolved.version].url, "pinned glibc url")
        t.assert_eq(resolved.kernel_url,
            defaults.glibc_versions[resolved.version].kernel_headers_url, "pinned kernel url")
        t.assert_eq(#resolved.supported, (function ()
            local count = 0
            for _ in pairs(defaults.glibc_versions) do
                count = count + 1
            end
            return count
        end)(), "supported set size mirrors defaults.lua")
    end)

    t.case("gccglibc: an explicit supported version resolves as source=option", function ()
        local probe_gccglibc, probe_defaults = fresh_module(t)
        local supported = probe_gccglibc.supported_versions()
        t.assert_true(#supported > 0, "managed set must not be empty")
        -- prefer a non-default member so this case cannot silently pass
        -- through the default branch
        local choice = supported[1]
        for _, version in ipairs(supported) do
            if version ~= probe_defaults.glibc_default_version then
                choice = version
                break
            end
        end
        set_glibc_env(choice)
        local gccglibc, defaults = fresh_module(t)
        local resolved = gccglibc.resolve_version("linux")
        t.assert_eq(#resolved.problems, 0, "problem count")
        t.assert_eq(resolved.source, "option", "source attribution")
        t.assert_eq(resolved.version, choice, "configured version honored")
        t.assert_eq(resolved.url, defaults.glibc_versions[choice].url, "pinned url for the choice")
    end)

    t.case("gccglibc: non-version text is a problem, not a guess", function ()
        set_glibc_env("not-a-version")
        local gccglibc = fresh_module(t)
        local resolved = gccglibc.resolve_version("linux")
        t.assert_eq(resolved.version, nil, "no version invented")
        t.assert_eq(#resolved.problems, 1, "problem count")
        t.assert_match(resolved.problems[1], "is not a glibc version", "problem text")
    end)

    t.case("gccglibc: a version outside the managed set is a problem", function ()
        set_glibc_env("9.99")
        local gccglibc = fresh_module(t)
        local resolved = gccglibc.resolve_version("linux")
        t.assert_eq(resolved.version, nil, "no version invented")
        t.assert_eq(#resolved.problems, 1, "problem count")
        t.assert_match(resolved.problems[1], "not in the supported managed set", "problem text")
        t.assert_match(resolved.problems[1], "9.99", "offending value named")
    end)

    t.case("gccglibc: supported_versions() is sorted oldest to newest", function ()
        local gccglibc = fresh_module(t)
        local supported = gccglibc.supported_versions()
        for index = 2, #supported do
            local previous_major, previous_minor =
                supported[index - 1]:match("^(%d+)%.(%d+)")
            local current_major, current_minor =
                supported[index]:match("^(%d+)%.(%d+)")
            local previous = tonumber(previous_major) * 10000 + tonumber(previous_minor)
            local current = tonumber(current_major) * 10000 + tonumber(current_minor)
            t.assert_true(previous < current, "unsorted supported set: "
                .. table.concat(supported, ", "))
        end
    end)

    t.case("gccglibc: glibc_snapshot_url override replaces the pinned url", function ()
        local probe_gccglibc = fresh_module(t)
        local supported = probe_gccglibc.supported_versions()
        os.setenv("LINUX_GLIBC_VERSION", supported[1])
        os.setenv("GLIBC_SNAPSHOT_URL", "https://example.invalid/glibc-override.tar.xz")
        local gccglibc = fresh_module(t)
        local resolved = gccglibc.resolve_version("linux")
        t.assert_eq(resolved.url, "https://example.invalid/glibc-override.tar.xz", "override honored")
        t.assert_eq(#resolved.problems, 0, "problem count")
    end)

    -- leave the process environment clean for later suites
    set_glibc_env(nil)
end
