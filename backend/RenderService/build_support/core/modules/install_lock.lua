-- Cross-process install lock (shared): serialize concurrent installs of the
-- same managed prefix across independent xmake processes. Two `xmake` runs
-- that both find a toolchain/component missing -- a parallel CI matrix, two
-- terminals, an editor's background build racing a manual one -- would
-- otherwise both start writing the same prefix, and interleaved
-- download/configure/make/install corrupts it. Callers pass a per-prefix
-- lock-file path so distinct prefixes never contend.
--
-- Built on xmake's io.openlock, an OS advisory file lock (LockFileEx on
-- Windows, flock/fcntl on POSIX): the kernel releases it automatically when
-- the holder process exits, so a killed or crashed build never strands the
-- lock and no stale-lock recovery is needed.
--
-- Acquisition is a cooperative try-and-yield loop, never a blocking lock():
-- xmake runs build jobs as coroutines on one thread, so two targets that
-- both provision the same managed component reach this guard within a
-- single process. A blocking acquire there stops the whole scheduler --
-- the holder coroutine can never resume to release, so the build hangs
-- forever at zero CPU with no child process (observed deterministically
-- when two targets in one project both needed the Rust wasm runtime;
-- single-job builds of the same tree passed, which is what identified it).
-- os.sleep yields inside a coroutine and plainly sleeps outside one, so the
-- same loop serves in-process jobs and independent processes alike.
--
-- Still NOT reentrant: never nest guard() on the same lock file within one
-- call chain (the inner acquire would wait for an outer one that cannot
-- return). Sequential acquire/release of the same lock is fine, and so is
-- concurrent acquisition from separate jobs, which now queues instead of
-- deadlocking.

import("errors")

local ACQUIRE_POLL_INTERVAL_MS = 50

-- Run fn while holding the exclusive per-prefix install lock at lockfile.
-- Returns fn's result. The lock is released even if fn raises, and the raise
-- is re-propagated after unlocking so callers still see the real failure
-- instead of a lock leak.
function guard(lockfile, fn)
    os.mkdir(path.directory(lockfile))
    local lock = io.openlock(lockfile)
    while not lock:trylock() do
        os.sleep(ACQUIRE_POLL_INTERVAL_MS)
    end
    local ok, result = errors.trycall(fn)
    lock:unlock()
    if not ok then
        errors.fail("%s", tostring(result))
    end
    return result
end
