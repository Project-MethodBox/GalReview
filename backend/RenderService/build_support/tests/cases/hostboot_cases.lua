-- Fixture regression for hostboot.lua bootstrap health probes. Two shapes:
-- (1) bootstrap_backend_missing -- the 2026-07-18 field incident where the
-- gcc/g++ drivers survive on disk but cc1/cc1plus are gone (interrupted
-- extraction or antivirus quarantine), which the earlier existence and
-- sysroot probes could not see (pure-injection cases: no process launch).
-- (2) is_w64devkit_alias -- the 2026-07-22 defect where a text-mode read of a
-- binary alias stub lost the "w64devkit (alias)" marker, so triplet driver
-- aliases were never replaced with real binaries and every from-scratch
-- private-bootstrap GCC build died at configure "cannot execute 'cc1'"; the
-- alias cases write real binary files under the sandbox tmpdir.

local MODULES = path.join(os.scriptdir(), "..", "..", "languages", "cpp", "modules")

local function load_hostboot()
    return import("hostboot", {rootdir = MODULES, anonymous = true})
end

function run(t)
    t.case("hostboot: healthy kit resolves both backends", function ()
        local hostboot = load_hostboot()
        local missing = hostboot.bootstrap_backend_missing("gcc.exe", "g++.exe", {
            resolve = function (_, name)
                return "E:/kit/libexec/gcc/x86_64-w64-mingw32/16.1.0/" .. name .. ".exe"
            end,
            isfile = function () return true end
        })
        t.assert_true(missing == nil, "both backends resolve to existing files")
    end)

    t.case("hostboot: quarantined cc1 (resolved path gone from disk) is rejected", function ()
        local hostboot = load_hostboot()
        local missing, resolved = hostboot.bootstrap_backend_missing("gcc.exe", "g++.exe", {
            resolve = function (_, name)
                return "E:/kit/libexec/gcc/x86_64-w64-mingw32/16.1.0/" .. name .. ".exe"
            end,
            isfile = function () return false end
        })
        t.assert_true(missing == "cc1", "the first missing backend is reported")
        t.assert_true(resolved:find("cc1.exe", 1, true) ~= nil, "the driver's answer is surfaced")
    end)

    t.case("hostboot: bare-name echo (driver found nothing) is rejected", function ()
        local hostboot = load_hostboot()
        local missing, resolved = hostboot.bootstrap_backend_missing("gcc.exe", nil, {
            resolve = function (_, name) return name end,
            isfile = function () return true end
        })
        t.assert_true(missing == "cc1", "a bare echo means the driver resolved nothing")
        t.assert_true(resolved == "cc1", "the echoed name is surfaced")
    end)

    t.case("hostboot: cc1 intact but cc1plus missing is rejected", function ()
        local hostboot = load_hostboot()
        local missing = hostboot.bootstrap_backend_missing("gcc.exe", "g++.exe", {
            resolve = function (_, name)
                if name == "cc1" then
                    return "E:/kit/libexec/cc1.exe"
                end
                return name
            end,
            isfile = function () return true end
        })
        t.assert_true(missing == "cc1plus", "the C++ backend is probed as well")
    end)

    t.case("hostboot: unrunnable driver is rejected", function ()
        local hostboot = load_hostboot()
        local missing = hostboot.bootstrap_backend_missing("gcc.exe", nil, {
            resolve = function () return nil end,
            isfile = function () return true end
        })
        t.assert_true(missing == "cc1", "a driver that cannot run cannot vouch for its kit")
    end)

    -- is_w64devkit_alias must binary-read the candidate .exe: a text-mode read
    -- inflates/mangles a binary's bytes so the "w64devkit (alias)" marker
    -- vanishes, which left every from-scratch private-bootstrap GCC build stuck
    -- at configure "cannot execute 'cc1'" (the surviving alias was never
    -- replaced with the real self-locating driver). These cases pin the marker
    -- detection on binary content the old text-mode read demonstrably missed.
    t.case("hostboot: is_w64devkit_alias finds the marker in a binary alias stub", function ()
        local hostboot = load_hostboot()
        local stub = path.join(t.tmpdir("alias-stub"), "x86_64-w64-mingw32-gcc.exe")
        io.writefile(stub,
            "MZ\144\0\3\0\0\0\255\255w64devkit (alias): could not start process\0PE\0\0\200\201\202",
            {encoding = "binary"})
        t.assert_true(hostboot.managed_toolchains_is_w64devkit_alias(stub),
            "the marker must be found via a binary read despite surrounding nul/high bytes")
    end)

    t.case("hostboot: is_w64devkit_alias rejects a real (marker-free) binary", function ()
        local hostboot = load_hostboot()
        local real = path.join(t.tmpdir("alias-real"), "gcc.exe")
        io.writefile(real, "MZ\144\0\3\0\0\0\255\255 a real driver carries no alias marker \0PE\0\0\200",
            {encoding = "binary"})
        t.assert_true(not hostboot.managed_toolchains_is_w64devkit_alias(real),
            "a binary without the marker is not an alias")
    end)

    t.case("hostboot: is_w64devkit_alias flags a small readelf stub by the size heuristic", function ()
        local hostboot = load_hostboot()
        local rd = path.join(t.tmpdir("alias-readelf"), "x86_64-w64-mingw32-readelf.exe")
        io.writefile(rd, "\0\1\2 tiny readelf shim with no textual marker \255\254", {encoding = "binary"})
        t.assert_true(hostboot.managed_toolchains_is_w64devkit_alias(rd),
            "a small readelf-named binary is an alias by the size heuristic")
    end)

    -- Detecting the stub is not enough: host-tool SELECTION has to refuse it,
    -- because an alias resolves its real driver through PATH under the same
    -- name -- and the environment that builds a toolchain puts that
    -- toolchain's own install prefix first on PATH. For a host-targeted build
    -- the prefix holds a driver with the very same triplet-prefixed name, so
    -- declaring the stub as CC made the bootstrap compiler re-exec the
    -- compiler being rebuilt and fail with "cannot execute 'cc1'" (2026-08-12,
    -- on a host kit; the private bootstrap hid it because provisioning
    -- replaces its stubs with real binaries). Candidate names are deliberately
    -- nonsense so a tool of the same name on the real PATH cannot answer.
    local function alias_selection_sandbox(t, label)
        local replica = t.replicate_build_support({"core/modules"}, label)
        local modules = path.join(replica, "core", "modules")
        local hosttools = import("hosttools", {rootdir = modules, anonymous = true})
        local layout = import("layout", {rootdir = modules, anonymous = true})
        local base = import("base", {rootdir = modules, anonymous = true})
        local bin = path.join(layout.tools_cache_dir(), "bin")
        os.mkdir(bin)
        return hosttools, base, bin
    end

    local function write_alias_stub(file)
        io.writefile(file, "MZ\144\0\3\0\0\0\255\255w64devkit (alias): could not start process\0PE\0\0",
            {encoding = "binary"})
    end

    local function write_real_driver(file)
        io.writefile(file, "MZ\144\0\3\0\0\0\255\255 a real self-locating driver \0PE\0\0\200",
            {encoding = "binary"})
    end

    t.case("host tools: a preferred alias stub loses to the real later candidate", function ()
        local hosttools, base, bin = alias_selection_sandbox(t, "alias-select-skip")
        write_alias_stub(path.join(bin, base.exe("zzwhe-triplet-cc")))
        write_real_driver(path.join(bin, base.exe("zzwhe-cc")))
        local chosen = hosttools.preferred_host_tool_any({"zzwhe-triplet-cc", "zzwhe-cc"})
        t.assert_match(tostring(chosen), "zzwhe-cc", "selection must skip the alias stub")
        t.assert_true(not tostring(chosen):find("zzwhe-triplet-cc", 1, true),
            "the alias stub must not be declared as a build tool")
    end)

    t.case("host tools: an alias is still returned when nothing else resolves", function ()
        local hosttools, base, bin = alias_selection_sandbox(t, "alias-select-only")
        write_alias_stub(path.join(bin, base.exe("zzwhe-lonely-cc")))
        local chosen = hosttools.preferred_host_tool_any({"zzwhe-lonely-cc", "zzwhe-absent-cc"})
        t.assert_match(tostring(chosen), "zzwhe-lonely-cc",
            "the only tool that exists beats a name that does not")
    end)

    t.case("host tools: a real preferred candidate still wins outright", function ()
        local hosttools, base, bin = alias_selection_sandbox(t, "alias-select-real-first")
        write_real_driver(path.join(bin, base.exe("zzwhe-first-cc")))
        write_real_driver(path.join(bin, base.exe("zzwhe-second-cc")))
        local chosen = hosttools.preferred_host_tool_any({"zzwhe-first-cc", "zzwhe-second-cc"})
        t.assert_match(tostring(chosen), "zzwhe-first-cc", "preference order must be preserved")
    end)

    -- Shared bootstrap directory reader-writer guard (2026-07-23): the
    -- .cache/windows/bootstrap/<arch> tree is shared by every Windows-hosted
    -- build, so a concurrent build must not have its cc1 deleted mid-configure.
    -- Two invariants keep that safe: the lockfile is a SIBLING of the deletable
    -- root (so removing the tree never removes it out from under a waiter), and
    -- the shared/exclusive advisory primitive round-trips.
    t.case("hostboot: bootstrap use-lockfile is a sibling of the shared root", function ()
        local hostboot = load_hostboot()
        local root = path.join("C:", "cache", "windows", "bootstrap", "x64")
        local lockfile = hostboot.windows_bootstrap_use_lockfile(root)
        t.assert_true(lockfile == root .. ".use.lock", "the lockfile is derived from the root")
        t.assert_true(path.directory(lockfile) == path.directory(root),
            "the lockfile shares the root's parent, so deleting the root cannot remove it")
    end)

    t.case("hostboot: bootstrap use-lock round-trips shared then exclusive", function ()
        -- trylock returns a real boolean (the sandbox does not wrap it), unlike
        -- lock() which raises on failure and returns nothing on success.
        local lockfile = path.join(t.tmpdir("boot-uselock"), "x64.use.lock")
        local shared = io.openlock(lockfile)
        t.assert_true(shared ~= nil, "the lockfile opens")
        t.assert_true(shared:trylock({shared = true}), "a shared lock is acquired")
        shared:unlock()
        shared:close()
        local exclusive = io.openlock(lockfile)
        t.assert_true(exclusive:trylock(),
            "an exclusive lock is acquired once the shared lock is released")
        exclusive:unlock()
        exclusive:close()
    end)

    -- The safety-critical decision cleanup_windows_bootstrap_toolchain makes:
    -- while any build holds the shared use-lock, the cleanup exclusive trylock
    -- must FAIL so the shared tree is not deleted out from under a build that is
    -- still configuring against its cc1. Cross-handle exclusion within one
    -- process holds on Windows (LockFileEx) and POSIX flock but not fcntl, so a
    -- control probe gates the concurrent-holder assertion; the release direction
    -- is asserted unconditionally.
    t.case("hostboot: a held shared use-lock makes the cleanup exclusive probe fail", function ()
        local dir = t.tmpdir("rw-decision")
        local control = path.join(dir, "control.lock")
        local c1 = io.openlock(control)
        t.assert_true(c1:trylock(), "control exclusive lock is taken")
        local c2 = io.openlock(control)
        local enforced = not c2:trylock()
        if not enforced then
            c2:unlock()
        end
        c2:close()
        c1:unlock()
        c1:close()

        local lockfile = path.join(dir, "x64.use.lock")
        local holder = io.openlock(lockfile)
        t.assert_true(holder:trylock({shared = true}), "a concurrent build holds the shared lock")
        if enforced then
            local cleaner = io.openlock(lockfile)
            t.assert_true(not cleaner:trylock(),
                "cleanup's exclusive probe fails while the shared lock is held, so it skips deletion")
            cleaner:close()
        end
        holder:unlock()
        holder:close()

        local after = io.openlock(lockfile)
        t.assert_true(after:trylock(),
            "the exclusive probe succeeds once no build holds the shared lock, so cleanup may delete")
        after:unlock()
        after:close()
    end)
end
