-- Fixture regression for core/modules/checksums.lua (repo-resident form of
-- the original one-off recheck.lua verification). checksums writes
-- trust-on-first-use records through layout.toolchains_cache_dir(), so the
-- module under test is imported from a sandbox REPLICA of build_support:
-- layout self-bootstraps its owner root from its own script location, which
-- redirects every cache write into the fixture sandbox. The real download
-- cache is only ever READ (pinned-positive case), and one case explicitly
-- asserts the real cache gained no TOFU record.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})

-- the pinned-URL keys of core/modules/defaults.lua whose leaf names must
-- stay registered (a bump that forgets checksums.lua must fail here)
local PINNED_URL_KEYS = {
    "binutils_snapshot_url",
    "mingw_w64_snapshot_url",
    "musl_snapshot_url",
    "m4_url",
    "flex_url",
    "winflexbison_url",
    "windows_bootstrap_fallback_url_x64",
    "windows_bootstrap_fallback_url_x86"
}

local function url_leaf(url)
    return (tostring(url):gsub("[#%?].*$", "")):match("[^/\\]+$")
end

function run(t)
    -- anonymous imports: a plain import() would rebind the module-scope
    -- `layout` name above to the sandbox instance, silently breaking the
    -- real-cache assertions below
    local replica = t.replicate_build_support({"core/modules"}, "checksums-sandbox")
    local coredir = path.join(replica, "core", "modules")
    local checksums = import("checksums", {rootdir = coredir, anonymous = true})
    local sandbox_layout = import("layout", {rootdir = coredir, anonymous = true})
    local sandbox_defaults = import("defaults", {rootdir = coredir, anonymous = true}).values()
    local sandbox_root = path.directory(replica)

    t.case("checksums: module imports clean and the registry is populated", function ()
        local registry = checksums.registry()
        local count = 0
        for _ in pairs(registry) do
            count = count + 1
        end
        t.assert_true(count > 0, "registry must not be empty")
    end)

    t.case("checksums: sandbox layout resolves into the fixture tree, not the real cache", function ()
        t.assert_eq(sandbox_layout.toolchains_home(),
            path.join(sandbox_root, ".toolchains"), "sandboxed toolchains home")
    end)

    t.case("checksums: every pinned defaults.lua URL leaf is registered", function ()
        local registry = checksums.registry()
        local missing = {}
        for _, key in ipairs(PINNED_URL_KEYS) do
            local url = sandbox_defaults[key]
            if type(url) ~= "string" or url == "" then
                table.insert(missing, key .. " (key absent from defaults.lua -- renamed? update PINNED_URL_KEYS)")
            elseif not registry[url_leaf(url)] then
                table.insert(missing, key .. " -> " .. tostring(url_leaf(url)))
            end
        end
        for version, entry in pairs(sandbox_defaults.glibc_versions or {}) do
            for _, field in ipairs({"url", "kernel_headers_url"}) do
                local leaf = url_leaf(entry[field] or "")
                if not (leaf and registry[leaf]) then
                    table.insert(missing, "glibc_versions[" .. version .. "]." .. field)
                end
            end
        end
        t.assert_true(#missing == 0, "unregistered pinned leaves: " .. table.concat(missing, ", "))
    end)

    t.case("checksums: tampered bytes under a pinned sha256 leaf are rejected", function ()
        local dir = t.tmpdir("pinned-sha256")
        local fake = path.join(dir, "musl-1.2.5.tar.gz")
        io.writefile(fake, "definitely not the pinned musl archive\n")
        local message = t.expect_raise(function ()
            checksums.verify(fake)
        end, "musl-1.2.5.tar.gz", "pinned sha256 mismatch")
        t.assert_match(message, "integrity", "mismatch is an integrity failure")
    end)

    local hosttools = import("hosttools", {rootdir = coredir, anonymous = true})
    local sha512_tool = hosttools.find_tool_path("sha512sum")
        or (base.is_windows_host() and hosttools.find_tool_path("certutil"))
    if sha512_tool then
        t.case("checksums: tampered bytes under a pinned sha512 leaf are rejected", function ()
            local dir = t.tmpdir("pinned-sha512")
            local fake = path.join(dir, "binutils-2.45.tar.xz")
            io.writefile(fake, "definitely not the pinned binutils archive\n")
            local message = t.expect_raise(function ()
                checksums.verify(fake)
            end, "binutils-2.45.tar.xz", "pinned sha512 mismatch")
            t.assert_match(message, "integrity", "mismatch is an integrity failure")
        end)
    else
        t.skip("checksums: tampered bytes under a pinned sha512 leaf are rejected",
            "no sha512sum/certutil on this host")
    end

    -- TOFU three-state walk over one unpinned leaf: record, reuse, reject.
    local leaf = string.format("tofu-fixture-%s-%s.zip",
        tostring(os.time()), tostring(os.getpid and os.getpid() or 0))
    local tofu_dir = t.tmpdir("tofu")
    local tofu_file = path.join(tofu_dir, leaf)
    local record = path.join(sandbox_layout.toolchains_cache_dir(base.host_os()),
        "checksums", "tofu", leaf .. ".sha256")

    t.case("checksums: TOFU first sight records a digest in the sandbox cache", function ()
        io.writefile(tofu_file, "unpinned fixture archive body\n")
        checksums.verify(tofu_file)
        t.assert_true(os.isfile(record), "TOFU record missing: " .. record)
        local content = io.readfile(record) or ""
        t.assert_match(content, "format:tofu-v1", "record format tag")
        t.assert_match(content, "sha256:" .. hash.sha256(tofu_file), "recorded digest matches the bytes")
    end)

    t.case("checksums: TOFU reuse with unchanged bytes verifies", function ()
        checksums.verify(tofu_file)
    end)

    t.case("checksums: TOFU changed bytes are rejected", function ()
        local handle = io.open(tofu_file, "ab")
        handle:write("!")
        handle:close()
        t.expect_raise(function ()
            checksums.verify(tofu_file)
        end, "trust-on-first-use", "TOFU change rejection")
    end)

    t.case("checksums: tofu_records surfaces the sandbox record in paste-ready shape", function ()
        local found
        for _, entry in ipairs(checksums.tofu_records()) do
            if entry.leaf == leaf then
                found = entry
            end
        end
        t.assert_true(found ~= nil, "seeded TOFU record must be listed")
        t.assert_true(found.sha256:match("^%x+$") ~= nil, "record carries a hex sha256")
        t.assert_true(found.first_seen ~= "", "record carries a first-seen timestamp")
    end)

    t.case("checksums: the REAL toolchains cache gained no TOFU record", function ()
        local real_record = path.join(layout.toolchains_cache_dir(base.host_os()),
            "checksums", "tofu", leaf .. ".sha256")
        t.assert_true(not os.isfile(real_record),
            "fixture leaked into the real cache: " .. real_record)
    end)

    -- Pinned-positive: a fake in-table entry is impossible (digests pin real
    -- upstream bytes), so verify the smallest registered archive already
    -- sitting in the REAL download cache, read-only. Skips when none exists.
    local best
    local real_downloads = layout.download_cache_dir()
    for registered in pairs(checksums.registry()) do
        local candidate = path.join(real_downloads, registered)
        if os.isfile(candidate) then
            local size = os.filesize(candidate)
            if size and size < 64 * 1024 * 1024 and (not best or size < best.size) then
                best = {file = candidate, size = size}
            end
        end
    end
    if best then
        t.case("checksums: genuine cached archive passes its pinned digest ("
            .. path.filename(best.file) .. ")", function ()
            checksums.verify(best.file)
        end)
    else
        t.skip("checksums: genuine cached archive passes its pinned digest",
            "no registered archive under 64MB in the real download cache")
    end
end
