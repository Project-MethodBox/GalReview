-- Shared harness for the build_support fixture regression suite
-- (build_support/tests/run_all.lua). Design constraints:
--   * xmake import() exposes only functions, so all mutable state lives in
--     an explicit context table created by new_context() and captured by
--     the closures harness() returns -- module-instance identity never
--     matters.
--   * no pcall: guarded execution goes through errors.trycall (try/catch).
--   * fixtures never touch the real source tree or the real toolchains
--     cache. Modules that write cache state (checksums TOFU records) are
--     imported from a sandbox REPLICA of build_support created by
--     replicate_build_support(): layout.lua self-bootstraps its owner root
--     by walking up from its own script directory to the nearest
--     "build_support" folder, so a replica preserving that shape redirects
--     the whole .toolchains tree into the fixture sandbox. Fresh replicas
--     also give fresh module instances, which is how per-process caches
--     (androidndk.resolve, gccglibc.resolve_version) are reset per case.

import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})

function new_context(root)
    return {root = root, pass = 0, fail = 0, skip = 0, failures = {}, serial = 0}
end

-- Runs a zero-argument function under try/catch; returns ok, error-text.
function protected(fn)
    return errors.trycall(fn)
end

function harness(ctx)
    local t = {}

    t.case = function (name, fn)
        local ok, err = errors.trycall(fn)
        if ok then
            ctx.pass = ctx.pass + 1
            print(string.format("[PASS] %s", name))
        else
            ctx.fail = ctx.fail + 1
            table.insert(ctx.failures, name)
            print(string.format("[FAIL] %s", name))
            print("       " .. (tostring(err):gsub("\n", "\n       ")))
        end
    end

    t.skip = function (name, reason)
        ctx.skip = ctx.skip + 1
        print(string.format("[SKIP] %s (%s)", name, reason))
    end

    t.assert_true = function (condition, message)
        assert(condition, message or "assertion failed")
    end

    t.assert_eq = function (got, want, label)
        assert(got == want, string.format("%s: expected %s, got %s",
            label or "value", tostring(want), tostring(got)))
    end

    -- plain-text containment (no Lua patterns), so messages with %, [ or ]
    -- can be matched verbatim
    t.assert_match = function (text, needle, label)
        assert(type(text) == "string" and text:find(needle, 1, true) ~= nil,
            string.format("%s: expected to find %q in:\n%s",
                label or "match", needle, tostring(text)))
    end

    -- asserts fn raises; optionally that the error text contains needle;
    -- returns the error text for further matching
    t.expect_raise = function (fn, needle, label)
        local ok, err = errors.trycall(fn)
        assert(not ok, string.format("%s: expected a raise but the call succeeded",
            label or "expect_raise"))
        if needle then
            t.assert_match(tostring(err), needle, label)
        end
        return tostring(err)
    end

    -- fresh, uniquely named directory inside the run sandbox
    t.tmpdir = function (leaf)
        ctx.serial = ctx.serial + 1
        local dir = path.join(ctx.root, string.format("%03d-%s", ctx.serial, leaf))
        os.mkdir(dir)
        return dir
    end

    t.write = function (file, content)
        os.mkdir(path.directory(file))
        io.writefile(file, content)
    end

    -- Copies the requested build_support subdirectories (top-level *.lua of
    -- each) into a fresh sandbox replica that preserves the
    -- <root>/build_support/<subdir> shape, and returns the replica's
    -- build_support path. The real tree is only ever read.
    t.replicate_build_support = function (subdirs, label)
        local sandbox = t.tmpdir(label)
        local replica = path.join(sandbox, "build_support")
        for _, sub in ipairs(subdirs) do
            local src = path.join(os.projectdir(), "build_support", sub)
            local dst = path.join(replica, sub)
            os.mkdir(dst)
            os.cp(path.join(src, "*.lua"), dst)
        end
        return replica
    end

    return t
end
