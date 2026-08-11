-- Fixture regression for gccsources.managed_toolchains_read_git_head -- the
-- file-based HEAD resolver that replaced `git rev-parse` on the revision
-- probes, which run many times per build. Since the common path no longer has
-- a git process behind it, the parsing itself has to be right; these cases pin
-- each layout the resolver claims to understand plus the "return nil and let
-- git decide" contract for everything else.

local gccsources = import("gccsources",
    {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "cpp", "modules"), anonymous = true})

local COMMIT = "ac20dcd5f8c5ae858f9b2d9cdf4140c0738e5e27"
local OTHER_COMMIT = "651c9ffbce3d0525d2d1324fab79160e5fcf8173"

function run(t)
    local function fake_repo(leaf, head_text)
        local src = t.tmpdir(leaf)
        os.mkdir(path.join(src, ".git"))
        io.writefile(path.join(src, ".git", "HEAD"), head_text)
        return src
    end

    t.case("git head: detached HEAD holds the commit directly", function ()
        -- the managed checkouts' own shape: `git checkout --force FETCH_HEAD`
        local src = fake_repo("git-head-detached", COMMIT .. "\n")
        t.assert_eq(gccsources.managed_toolchains_read_git_head(src), COMMIT, "detached HEAD commit")
    end)

    t.case("git head: symbolic HEAD resolves through the loose ref file", function ()
        local src = fake_repo("git-head-loose", "ref: refs/heads/main\n")
        os.mkdir(path.join(src, ".git", "refs", "heads"))
        io.writefile(path.join(src, ".git", "refs", "heads", "main"), COMMIT .. "\n")
        t.assert_eq(gccsources.managed_toolchains_read_git_head(src), COMMIT, "loose ref commit")
    end)

    t.case("git head: symbolic HEAD falls through to packed-refs", function ()
        local src = fake_repo("git-head-packed", "ref: refs/heads/main\n")
        io.writefile(path.join(src, ".git", "packed-refs"), table.concat({
            "# pack-refs with: peeled fully-peeled sorted",
            OTHER_COMMIT .. " refs/heads/other",
            COMMIT .. " refs/heads/main",
            ""
        }, "\n"))
        t.assert_eq(gccsources.managed_toolchains_read_git_head(src), COMMIT, "packed ref commit")
    end)

    t.case("git head: unresolvable layouts return nil so the git probe stays in charge", function ()
        local dangling = fake_repo("git-head-dangling", "ref: refs/heads/gone\n")
        t.assert_true(gccsources.managed_toolchains_read_git_head(dangling) == nil,
            "symbolic HEAD with no matching ref")
        local truncated = fake_repo("git-head-truncated", "ac20dcd\n")
        t.assert_true(gccsources.managed_toolchains_read_git_head(truncated) == nil,
            "short object name is not a resolved commit")
        local plain = t.tmpdir("git-head-nonrepo")
        t.assert_true(gccsources.managed_toolchains_read_git_head(plain) == nil,
            "directory without .git")
    end)
end
