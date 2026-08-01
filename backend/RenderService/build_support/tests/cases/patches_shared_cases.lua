-- Fixture regression for languages/cpp/modules/patches/shared.lua -- the
-- strict anchor-pinned patch primitives every patch family builds on. Until
-- now their positive/negative behavior was only exercised by the real-tree
-- battery (delete the stamp, re-fetch, watch the postconditions); these
-- cases pin the framework semantics on tiny synthetic files instead, so a
-- primitive regression fails here in seconds.

local REPLICA_SUBDIRS = {"core/modules", "languages/cpp/modules", "languages/cpp/modules/patches"}

function run(t)
    local replica = t.replicate_build_support(REPLICA_SUBDIRS, "patches-shared-sandbox")
    local shared = import("shared",
        {rootdir = path.join(replica, "languages", "cpp", "modules", "patches"), anonymous = true})
    local src = path.join(path.directory(replica), "fake-src")
    os.mkdir(src)
    local ctx = {src = src}
    local counter = 0
    local function fresh_file(content)
        counter = counter + 1
        local file = path.join(src, "file-" .. counter .. ".txt")
        io.writefile(file, content)
        return file
    end

    t.case("patches: strict_replace splices at a unique anchor", function ()
        local file = fresh_file("head\nANCHOR\ntail\n")
        shared.strict_replace(ctx, file, "ANCHOR", "ANCHOR\nPATCHED", "test patch")
        t.assert_match(io.readfile(file), "ANCHOR\nPATCHED", "patched content")
    end)

    t.case("patches: strict_replace is idempotent once the replacement exists", function ()
        local file = fresh_file("head\nANCHOR\ntail\n")
        shared.strict_replace(ctx, file, "ANCHOR", "ANCHOR\nPATCHED", "test patch")
        local first = io.readfile(file)
        shared.strict_replace(ctx, file, "ANCHOR", "ANCHOR\nPATCHED", "test patch")
        t.assert_eq(io.readfile(file), first, "second apply must not change the file")
    end)

    t.case("patches: strict_replace fails loudly on a missing source file", function ()
        t.expect_raise(function ()
            shared.strict_replace(ctx, path.join(src, "absent.txt"), "A", "B", "test patch")
        end, "source file is missing", "missing-file failure")
    end)

    t.case("patches: strict_replace fails loudly on a drifted anchor", function ()
        local file = fresh_file("head\ntail\n")
        t.expect_raise(function ()
            shared.strict_replace(ctx, file, "ANCHOR", "ANCHOR\nPATCHED", "test patch")
        end, "anchor drifted", "drift failure")
    end)

    t.case("patches: strict_replace fails loudly on an ambiguous anchor", function ()
        local file = fresh_file("ANCHOR\nmiddle\nANCHOR\n")
        t.expect_raise(function ()
            shared.strict_replace(ctx, file, "ANCHOR", "ANCHOR\nPATCHED", "test patch")
        end, "ambiguous", "ambiguity failure")
    end)

    t.case("patches: remove_exact_patch retires a block exactly once", function ()
        local file = fresh_file("keep\nOLD-BLOCK\nkeep\n")
        shared.remove_exact_patch(ctx, file, "OLD-BLOCK\n", "test migration")
        t.assert_eq(io.readfile(file), "keep\nkeep\n", "block removed")
        shared.remove_exact_patch(ctx, file, "OLD-BLOCK\n", "test migration")
        t.assert_eq(io.readfile(file), "keep\nkeep\n", "absent block is a no-op")
    end)

    t.case("patches: remove_exact_patch refuses an ambiguous block", function ()
        local file = fresh_file("OLD\nx\nOLD\n")
        t.expect_raise(function ()
            shared.remove_exact_patch(ctx, file, "OLD\n", "test migration")
        end, "ambiguous", "ambiguity failure")
    end)

    t.case("patches: strict_replace_migrated upgrades the previous shape first", function ()
        local file = fresh_file("head\nOLD-SHAPE\ntail\n")
        shared.strict_replace_migrated(ctx, file, "ANCHOR", "OLD-SHAPE", "NEW-SHAPE", "test patch")
        t.assert_match(io.readfile(file), "NEW-SHAPE", "migrated content")
        t.assert_true(not io.readfile(file):find("OLD-SHAPE", 1, true), "previous shape retired")
    end)

    t.case("patches: strict_write_new tolerates identical and rejects foreign files", function ()
        local file = path.join(src, "generated.h")
        shared.strict_write_new(ctx, file, "content-v1", "test header")
        shared.strict_write_new(ctx, file, "content-v1", "test header")
        t.assert_eq(io.readfile(file), "content-v1", "identical rewrite is a no-op")
        t.expect_raise(function ()
            shared.strict_write_new(ctx, file, "content-v2", "test header")
        end, "already exists with different content", "foreign-content failure")
    end)

    t.case("patches: strict_write_owned updates owned files and rejects unowned ones", function ()
        local marker = "test-ownership-marker"
        local file = path.join(src, "owned.h")
        shared.strict_write_owned(ctx, file, "v1 " .. marker, marker, "test owned header")
        shared.strict_write_owned(ctx, file, "v2 " .. marker, marker, "test owned header")
        t.assert_match(io.readfile(file), "v2", "owned update applied")
        local foreign = fresh_file("hand-written content")
        t.expect_raise(function ()
            shared.strict_write_owned(ctx, foreign, "v3 " .. marker, marker, "test owned header")
        end, "an unowned file exists", "unowned failure")
    end)
end
