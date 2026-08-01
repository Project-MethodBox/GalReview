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
-- NOT reentrant within a single process: never nest guard() on the same
-- lock file (a second acquire on the same path from the same process would
-- deadlock). Sequential acquire/release of the same lock in one process is
-- fine; only holding-then-re-acquiring is the hazard.

import("errors")

-- Run fn while holding the exclusive per-prefix install lock at lockfile.
-- Returns fn's result. The lock is released even if fn raises, and the raise
-- is re-propagated after unlocking so callers still see the real failure
-- instead of a lock leak.
function guard(lockfile, fn)
    os.mkdir(path.directory(lockfile))
    local lock = io.openlock(lockfile)
    lock:lock()
    local ok, result = errors.trycall(fn)
    lock:unlock()
    if not ok then
        errors.fail("%s", tostring(result))
    end
    return result
end
