-- Fixture regression for the shared cross-process install lock
-- (core/modules/install_lock.lua). guard() wraps xmake's io.openlock so the
-- OS releases the lock on process death; these in-process cases pin the parts
-- of the contract that a lock leak or a wrong error path would silently break:
-- the wrapped result is returned, the lock file's parent is created, and -- the
-- load-bearing one -- the lock is released even when the guarded body raises
-- (so the raise propagates AND a later acquire does not deadlock). Full
-- cross-process contention cannot be exercised from one xmake process; that is
-- covered by the real toolchain-install paths that funnel through guard().
--
-- The in-process contention property -- two build-job coroutines reaching the
-- same guard must queue instead of hanging the scheduler -- likewise has no
-- deterministic single-thread fixture (the cooperative wait only yields under
-- xmake's own coroutine scheduler). Its real proof is a parallel build of a
-- project whose targets both provision one managed component: that
-- deterministically deadlocked while guard used a blocking acquire, and passes
-- with the try-and-yield loop.

local install_lock = import("install_lock",
    {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules"), anonymous = true})

function run(t)
    t.case("guard returns the wrapped body's result", function ()
        local lockfile = path.join(t.tmpdir("install-lock-result"), ".install.lock")
        t.assert_eq(install_lock.guard(lockfile, function () return 42 end), 42,
            "guard result")
    end)

    t.case("guard creates the lock file's parent directory on demand", function ()
        -- point the lock below directories that do not exist yet, as a first
        -- install into a fresh prefix would
        local lockfile = path.join(t.tmpdir("install-lock-mkdir"), "prefix", "bin", ".install.lock")
        install_lock.guard(lockfile, function () return true end)
        t.assert_true(os.isfile(lockfile), "lock file exists after guard")
    end)

    t.case("guard re-raises the body's error yet still releases the lock", function ()
        local lockfile = path.join(t.tmpdir("install-lock-raise"), ".install.lock")
        t.expect_raise(function ()
            install_lock.guard(lockfile, function ()
                os.raise("boom inside guarded install")
            end)
        end, "boom inside guarded install", "guard re-raises the body error")
        -- a leaked lock would make this second acquire on the same file block
        -- forever; it completing proves the raising path unlocked first
        t.assert_eq(install_lock.guard(lockfile, function () return "released" end), "released",
            "lock reacquired after a raised guard")
    end)

    t.case("sequential guards on the same lock file both run (no self-deadlock)", function ()
        local lockfile = path.join(t.tmpdir("install-lock-seq"), ".install.lock")
        t.assert_eq(install_lock.guard(lockfile, function () return 1 end), 1, "first guard")
        t.assert_eq(install_lock.guard(lockfile, function () return 2 end), 2, "second guard")
    end)
end
