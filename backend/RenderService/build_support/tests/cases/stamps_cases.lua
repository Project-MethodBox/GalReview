-- Fixture regression for the outer install gate (provider installed_extra):
-- corrupted, stale, and pre-key install stamps. The replica redirects the
-- whole .toolchains tree into the sandbox (layout self-roots at the nearest
-- build_support folder), so the fake stamps never touch the real cache.
-- Scenario anchors are the drift classes seen live: a gnu install passing
-- the gate under a musl configuration (2026-07-17) and iOS SDK/deployment
-- drift silently reusing an old install (robustness review, 2026-07-17).

local REPLICA_SUBDIRS = {
    "core/modules",
    "languages/cpp/modules",
    "languages/cpp/modules/targets",
    "languages/cpp/modules/patches"
}

local function fresh(t)
    local replica = t.replicate_build_support(REPLICA_SUBDIRS, "stamps-sandbox")
    local tgtdir = path.join(replica, "languages", "cpp", "modules", "targets")
    local settings = import("settings",
        {rootdir = path.join(replica, "core", "modules"), anonymous = true})
    return replica, tgtdir, settings
end

local function write_stamp(settings, target_os, extra_lines)
    local stamp = settings.stamp_file(target_os)
    os.mkdir(path.directory(stamp))
    io.writefile(stamp, "host=test\ntarget_os=" .. target_os .. "\n"
        .. table.concat(extra_lines, "\n") .. (#extra_lines > 0 and "\n" or "")
        .. "installed_at=today\n")
    return stamp
end

function run(t)
    os.setenv("TOOLCHAINS_TARGET", "")
    os.setenv("IOS_SDK", "")
    os.setenv("LINUX_LIBC", "")

    t.case("stamps: a missing ios stamp does not trip the gate", function ()
        local _, tgtdir = fresh(t)
        local ios = import("ios", {rootdir = tgtdir, anonymous = true})
        t.assert_true(ios.installed_extra("ios"), "no stamp means nothing to invalidate")
    end)

    t.case("stamps: a matching ios stamp passes the gate", function ()
        local replica, tgtdir, settings = fresh(t)
        local defaults = import("defaults",
            {rootdir = path.join(replica, "core", "modules"), anonymous = true}).values()
        local deployment = tostring(settings.value_or("ios_deployment_target", defaults.ios_deployment_target))
        write_stamp(settings, "ios", {
            "ios_sdk=", "ios_sdk_version=", "ios_deployment_target=" .. deployment})
        local ios = import("ios", {rootdir = tgtdir, anonymous = true})
        t.assert_true(ios.installed_extra("ios"), "matching keys must pass")
    end)

    t.case("stamps: ios deployment-target drift trips the gate", function ()
        local _, tgtdir, settings = fresh(t)
        write_stamp(settings, "ios", {
            "ios_sdk=", "ios_sdk_version=", "ios_deployment_target=1.0-stale"})
        local ios = import("ios", {rootdir = tgtdir, anonymous = true})
        t.assert_true(not ios.installed_extra("ios"), "stale deployment target must invalidate")
    end)

    t.case("stamps: ios SDK drift trips the gate", function ()
        local _, tgtdir, settings = fresh(t)
        write_stamp(settings, "ios", {
            "ios_sdk=C:/stale/iPhoneOS.sdk", "ios_sdk_version=9.9", "ios_deployment_target=15.0"})
        local ios = import("ios", {rootdir = tgtdir, anonymous = true})
        t.assert_true(not ios.installed_extra("ios"), "stale SDK identity must invalidate")
    end)

    t.case("stamps: a pre-key ios stamp is grandfathered", function ()
        local _, tgtdir, settings = fresh(t)
        write_stamp(settings, "ios", {})
        local ios = import("ios", {rootdir = tgtdir, anonymous = true})
        t.assert_true(ios.installed_extra("ios"), "stamps written before the keys existed must pass")
    end)

    t.case("stamps: linux libc-flavor drift trips the gate", function ()
        local _, tgtdir, settings = fresh(t)
        -- on every host this fixture runs, the default cross linux flavor is
        -- deterministic through linux_libc auto; record the OPPOSITE flavor
        local linux = import("linux", {rootdir = tgtdir, anonymous = true})
        local current = linux.linux_target_libc("linux")
        local opposite = current == "musl" and "gnu" or "musl"
        write_stamp(settings, "linux", {"linux_libc=" .. opposite})
        t.assert_true(not linux.installed_extra("linux"),
            "recorded " .. opposite .. " must not pass a " .. current .. " configuration")
    end)

    t.case("stamps: a matching musl flavor passes the gate exactly", function ()
        -- musl is pinned explicitly: the earlier form asserted
        -- `installed_extra == true or linux_glibc_managed(...)`, which
        -- degenerates to a vacuous pass whenever the managed-glibc branch
        -- is active (review 2026-07-18). musl keeps that branch
        -- deterministically off, so the gate answer must be exactly true.
        os.setenv("LINUX_LIBC", "musl")
        local _, tgtdir, settings = fresh(t)
        local linux = import("linux", {rootdir = tgtdir, anonymous = true})
        write_stamp(settings, "linux", {"linux_libc=musl"})
        t.assert_eq(linux.installed_extra("linux"), true, "matching musl flavor must pass exactly")
        os.setenv("LINUX_LIBC", "")
    end)

    t.case("stamps: a matching managed-glibc stamp passes the gate exactly", function ()
        os.setenv("LINUX_LIBC", "gnu")
        local replica, tgtdir, settings = fresh(t)
        local linux = import("linux", {rootdir = tgtdir, anonymous = true})
        if not linux.linux_glibc_managed("linux") then
            os.setenv("LINUX_LIBC", "")
            t.skip("stamps: a matching managed-glibc stamp passes the gate exactly",
                "managed-glibc branch is not active in this configuration")
            return
        end
        local gccglibc = import("gccglibc",
            {rootdir = path.join(replica, "languages", "cpp", "modules"), anonymous = true})
        local version = tostring(gccglibc.resolve_version("linux").version or "")
        write_stamp(settings, "linux", {"linux_libc=gnu", "linux_glibc_version=" .. version})
        t.assert_eq(linux.installed_extra("linux"), true,
            "matching gnu flavor plus glibc version must pass exactly")
        os.setenv("LINUX_LIBC", "")
    end)

    t.case("stamps: managed-glibc version drift trips the gate", function ()
        os.setenv("LINUX_LIBC", "gnu")
        local _, tgtdir, settings = fresh(t)
        local linux = import("linux", {rootdir = tgtdir, anonymous = true})
        if not linux.linux_glibc_managed("linux") then
            os.setenv("LINUX_LIBC", "")
            t.skip("stamps: managed-glibc version drift trips the gate",
                "managed-glibc branch is not active in this configuration")
            return
        end
        write_stamp(settings, "linux", {"linux_libc=gnu", "linux_glibc_version=0.0-stale"})
        t.assert_true(not linux.installed_extra("linux"), "stale glibc version must invalidate")
        os.setenv("LINUX_LIBC", "")
    end)

    -- install-state transitions at the gccbuild layer: the recorded
    -- build-config signature block and the finalize-path stamp-extra
    -- migration (real modules from the replica, sandboxed .toolchains)
    local function fresh_gccbuild(t)
        local replica = t.replicate_build_support(REPLICA_SUBDIRS, "stamps-sandbox")
        local moddir = path.join(replica, "languages", "cpp", "modules")
        local settings = import("settings",
            {rootdir = path.join(replica, "core", "modules"), anonymous = true})
        local gccbuild = import("gccbuild", {rootdir = moddir, anonymous = true})
        local gccpatches = import("gccpatches", {rootdir = moddir, anonymous = true})
        return settings, gccbuild, gccpatches
    end

    local function write_signature_stamp(settings, target_os, signature_body, extra_lines)
        local stamp = settings.stamp_file(target_os)
        os.mkdir(path.directory(stamp))
        io.writefile(stamp, "host=test\ntarget_os=" .. target_os .. "\n"
            .. table.concat(extra_lines or {}, "\n") .. (extra_lines and #extra_lines > 0 and "\n" or "")
            .. "installed_at=today\n"
            .. "build_config_signature_begin\n" .. signature_body .. "\nbuild_config_signature_end\n")
        return stamp
    end

    -- Source identity lines matching the current profile (compared for
    -- EVERY profile since 2026-07-18; mainline was historically exempt and
    -- a gcc_ref change silently reused the old compiler). The revision is
    -- any non-empty value: with no synced source tree in the sandbox the
    -- current-revision probe returns "" and the equality arm is skipped.
    local function source_identity_lines(settings, target_os, patch_version)
        local source = settings.gcc_source_profile(target_os)
        return {
            "source_profile=" .. source.name,
            "source_url=" .. source.url,
            "source_ref=" .. source.ref,
            "source_revision=fixture-revision",
            "source_patch_version=" .. tostring(patch_version)
        }
    end

    t.case("stamps: a matching signature and source identity pass", function ()
        local settings, gccbuild, gccpatches = fresh_gccbuild(t)
        write_signature_stamp(settings, "windows",
            (settings.build_config_signature("windows"):gsub("%s+$", "")),
            source_identity_lines(settings, "windows", gccpatches.source_patch_stamp_version("windows")))
        t.assert_eq(gccbuild.managed_toolchains_installed_config_matches("windows"), true,
            "recorded signature and source identity identical to the current ones must match")
    end)

    t.case("stamps: a signature-only stamp without source identity is a mismatch", function ()
        -- the exact shape found live on the dev machine (2026-07-18): a
        -- pre-pinning-era stamp whose signature still matches but which
        -- recorded no source identity at all
        local settings, gccbuild = fresh_gccbuild(t)
        write_signature_stamp(settings, "windows",
            (settings.build_config_signature("windows"):gsub("%s+$", "")))
        t.assert_true(not gccbuild.managed_toolchains_installed_config_matches("windows"),
            "an unverifiable source identity means one rebuild to establish it")
    end)

    t.case("stamps: a stale mainline source_ref is a mismatch", function ()
        local settings, gccbuild, gccpatches = fresh_gccbuild(t)
        local lines = source_identity_lines(settings, "windows", gccpatches.source_patch_stamp_version("windows"))
        lines[3] = "source_ref=stale-ref"
        write_signature_stamp(settings, "windows",
            (settings.build_config_signature("windows"):gsub("%s+$", "")), lines)
        t.assert_true(not gccbuild.managed_toolchains_installed_config_matches("windows"),
            "changing gcc_ref must invalidate a mainline install instead of reusing the old compiler")
    end)

    t.case("stamps: a stale source patch version is a mismatch", function ()
        -- editing a local GCC source patch bumps source_patch_stamp_version
        -- while the upstream revision stays put, so ONLY this field catches the
        -- staleness (external review, 2026-07-20). Without it the auto-install
        -- path reuses a compiler built from the old patch set.
        local settings, gccbuild, gccpatches = fresh_gccbuild(t)
        local lines = source_identity_lines(settings, "windows", gccpatches.source_patch_stamp_version("windows"))
        lines[5] = "source_patch_version=0"
        write_signature_stamp(settings, "windows",
            (settings.build_config_signature("windows"):gsub("%s+$", "")), lines)
        t.assert_true(not gccbuild.managed_toolchains_installed_config_matches("windows"),
            "a bumped patch version must invalidate an install built from the old patches")
    end)

    t.case("stamps: the patch stamp is keyed per source profile", function ()
        -- A single global stamp forced every toolchain to rebuild on any patch
        -- edit. Keyed per source profile, a patch touching only one tree bumps
        -- only that profile's number: windows/linux/android share the mainline
        -- tree, macOS/iOS share darwin, and emscripten is its own wasm tree.
        local _, _, gccpatches = fresh_gccbuild(t)
        t.assert_eq(gccpatches.source_patch_stamp_version("linux"),
            gccpatches.source_patch_stamp_version("windows"),
            "windows and linux resolve to the same mainline stamp")
        t.assert_eq(gccpatches.source_patch_stamp_version("ios"),
            gccpatches.source_patch_stamp_version("macosx"),
            "iOS and macOS resolve to the same darwin stamp")
        local wasm = gccpatches.source_patch_stamp_version("emscripten")
        t.assert_true(gccpatches.source_patch_stamp_max_version() >= wasm,
            "the cleanup superset covers the highest profile stamp")
        -- the marker embeds the profile's own version, so a bump renames only
        -- that profile tree's marker and forces only that tree to re-patch
        t.assert_true(gccpatches.source_patch_marker_name("emscripten"):find(
            "-v" .. wasm, 1, true) ~= nil,
            "the marker carries the profile's own stamp version")
    end)

    t.case("stamps: a stamp without a source patch version is a mismatch", function ()
        -- a pre-field stamp cannot prove which patch set built it, so it gets
        -- the same one-honest-rebuild treatment as a pre-key source stamp
        local settings, gccbuild = fresh_gccbuild(t)
        local source = settings.gcc_source_profile("windows")
        write_signature_stamp(settings, "windows",
            (settings.build_config_signature("windows"):gsub("%s+$", "")),
            {"source_profile=" .. source.name, "source_url=" .. source.url,
                "source_ref=" .. source.ref, "source_revision=fixture-revision"})
        t.assert_true(not gccbuild.managed_toolchains_installed_config_matches("windows"),
            "a missing patch version means one rebuild to establish it, not a silent pass")
    end)

    t.case("stamps: a tampered build-config signature is a mismatch", function ()
        local settings, gccbuild = fresh_gccbuild(t)
        write_signature_stamp(settings, "windows",
            settings.build_config_signature("windows"):gsub("%s+$", "") .. "\ntampered=yes")
        t.assert_true(not gccbuild.managed_toolchains_installed_config_matches("windows"),
            "a signature with foreign content must not match")
    end)

    t.case("stamps: a legacy stamp without a signature block is a mismatch", function ()
        local settings, gccbuild = fresh_gccbuild(t)
        write_stamp(settings, "windows", {})
        t.assert_true(not gccbuild.managed_toolchains_installed_config_matches("windows"),
            "no recorded signature means one rebuild to establish it, not a silent pass")
    end)

    t.case("stamps: finalize migrates a gate-passing pre-key stamp and keeps its provenance", function ()
        -- The production entry runs the install gate BEFORE finalize, and
        -- the gate rejects stamps without a signature block -- so the
        -- migrated shape must be a REACHABLE one: valid signature block,
        -- matching source identity, and only the provider key missing
        -- (external review, 2026-07-18). linux_libc is top-level-only
        -- (linux signature_extra carries no libc line outside managed-glibc
        -- keys), so it cannot be masked by an identical line inside the
        -- signature block the way the ios keys can. Compiler presence is
        -- host state outside this sandbox; the layers exercised here are
        -- exactly the ones the earlier, unreachable-shape test bypassed.
        os.setenv("LINUX_LIBC", "gnu")
        local settings, gccbuild, gccpatches = fresh_gccbuild(t)
        local stamp = write_signature_stamp(settings, "linux",
            (settings.build_config_signature("linux"):gsub("%s+$", "")),
            source_identity_lines(settings, "linux", gccpatches.source_patch_stamp_version("linux")))
        t.assert_eq(gccbuild.managed_toolchains_installed_config_matches("linux"), true,
            "precondition: the pre-key stamp must pass the config gate")
        t.assert_true(not (io.readfile(stamp) or ""):find("linux_libc=", 1, true),
            "precondition: the seeded stamp must lack the provider key")
        gccbuild.finalize_existing_toolchain_install("linux")
        local content = io.readfile(stamp) or ""
        t.assert_match(content, "linux_libc=", "migration must adopt the provider identity keys")
        t.assert_match(content, "build_config_signature_begin", "migrated stamp carries a signature block")
        local source = settings.gcc_source_profile("linux")
        t.assert_match(content, "source_ref=" .. source.ref,
            "migration must not rewrite the recorded source provenance")
        -- the decisive provenance assertion (external review, 2026-07-18):
        -- the sandbox has NO source cache, exactly like a host whose source
        -- tree was cleaned after install; a rewrite-based migration would
        -- blank this recorded revision and the next gate run would force a
        -- pointless full rebuild
        t.assert_match(content, "source_revision=fixture-revision",
            "migration must preserve a recorded revision it cannot re-derive")
        t.assert_eq(gccbuild.managed_toolchains_installed_config_matches("linux"), true,
            "the migrated stamp must still pass the install gate")
        os.setenv("LINUX_LIBC", "")
    end)

    os.setenv("TOOLCHAINS_TARGET", "")
    os.setenv("IOS_SDK", "")
    os.setenv("LINUX_LIBC", "")
end
