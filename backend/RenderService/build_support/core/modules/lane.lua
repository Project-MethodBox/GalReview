-- Lane launcher: run an xmake subcommand against an isolated per-lane
-- configuration/build/temp layout, so several platforms can build
-- concurrently in one checkout without contending on the single project
-- lock, the shared build tree, or (on race-prone hosts) the OS temp that
-- rustc uses. A lane's isolation lives entirely in command-scoped
-- environment variables handed to a freshly spawned child xmake: the
-- parent's own configuration is never touched, and nothing is written to
-- the user's persistent environment.
--
-- Why a child process, not projectdir: config.directory() -- which keys
-- project.lock -- is resolved once at xmake startup from XMAKE_CONFIGDIR
-- (first priority) or projectdir, before any task runs, so a task cannot
-- re-key its own lock. projectdir cannot isolate an in-tree lane either:
-- xmake walks up to the outermost xmake.lua, collapsing a nested lane back
-- onto the root. Only XMAKE_CONFIGDIR, read at the child's startup,
-- isolates a lane that lives inside the checkout.

import("base")
import("errors")

-- Default target arch per lane (a lane is named after its plat). Overridden
-- when the caller passes --arch; plats absent here let xmake/policy choose
-- (android arch policy, macosx/ios aarch64 clamp).
local DEFAULT_ARCH =
{
    windows = "x64",
    mingw = "x86_64",
    linux = "x86_64",
    wasm = "wasm32",
    emscripten = "wasm32"
}
local DEFAULT_MODE = "debug"

-- A lane owns its platform's conventional build/<plat>/ directory and nothing
-- else. Products land in the ordinary build/<plat>/<arch>/<mode>/ tree -- the
-- exact path a plain `xmake build` produces, so a lane never invents a separate
-- output folder (the build dir is left at its default; only config/lock/mapper
-- are isolated). The per-lane config/lock and the C++ module mapper live in
-- dot-dirs beside the products, under the same build/<plat>/ home.
local function lane_layout(root, lane)
    local home = path.join(root, "build", lane)
    return
    {
        name = lane,
        home = home,
        configdir = home,
        xtmpdir = path.join(home, ".mapper"),
        ostmpdir = path.join(home, ".ostmp")
    }
end

-- Command-scoped environment for the child xmake. XMAKE_CONFIGDIR re-keys the
-- lock + config + localcache (the whole reason lanes do not serialize on the
-- single project lock); XMAKE_TMPDIR re-keys the C++ module mapper.
-- TOOLCHAINS_LANE marks the child as a lane so the gcc.modules foreign-plat
-- cache sweep stands down: several lanes legitimately keep different plats' module BMIs side by
-- side in the shared build tree, and each lane's isolated localcache makes the
-- cross-plat reuse that sweep heals impossible anyway. The OS temp
-- (TMP/TEMP/TMPDIR), where rustc writes codegen intermediates, is only re-keyed
-- off Windows: a Windows host shares the short default %TEMP% safely (verified
-- -- concurrent cold builds do not collide there) and a per-lane OS temp would
-- only push rust paths toward MAX_PATH, whereas a POSIX host (notably macOS)
-- genuinely races two rustc on shared temp and has no MAX_PATH ceiling.
local function lane_envs(layout)
    local envs =
    {
        XMAKE_CONFIGDIR = layout.configdir,
        XMAKE_TMPDIR = layout.xtmpdir,
        TOOLCHAINS_LANE = layout.name
    }
    if not base.is_windows_host() then
        os.mkdir(layout.ostmpdir)
        envs.TMP = layout.ostmpdir
        envs.TEMP = layout.ostmpdir
        envs.TMPDIR = layout.ostmpdir
    end
    return envs
end

local function xmake_program()
    if os.programfile then
        local program = os.programfile()
        if program and program ~= "" then
            return program
        end
    end
    return "xmake"
end

local function is_configured(layout)
    return #os.files(path.join(layout.configdir, "**", "xmake.conf")) > 0
end

-- Spawn the child xmake with the lane environment. stdio is inherited so the
-- build streams live; os.execv raises on a non-zero child exit, surfacing the
-- failure as a task failure.
local function run_child(root, layout, argv)
    os.mkdir(layout.configdir)
    os.mkdir(layout.xtmpdir)
    os.execv(xmake_program(), argv, {curdir = root, envs = lane_envs(layout)})
end

local function do_config(root, lane, layout, opt)
    local arch = opt.arch or DEFAULT_ARCH[lane]
    local mode = opt.mode or DEFAULT_MODE
    local argv = {"f", "-p", lane}
    if arch then
        table.insert(argv, "-a")
        table.insert(argv, arch)
    end
    table.insert(argv, "-m")
    table.insert(argv, mode)
    -- Pin the conventional build tree explicitly. Its value equals xmake's
    -- default (<root>/build), but stating it absolutely stops a relative
    -- default from resolving under XMAKE_CONFIGDIR, so products land in the
    -- ordinary build/<plat>/<arch>/<mode>/ path a plain build would use.
    table.insert(argv, "-o")
    table.insert(argv, path.join(root, "build"))
    table.insert(argv, "-y")
    run_child(root, layout, argv)
end

local function ensure_configured(root, lane, layout, opt)
    if not is_configured(layout) then
        do_config(root, lane, layout, opt)
    end
end

-- Entry point invoked by the `xmake lane` task shell. Arguments are all
-- positional (xmake plugin-task menus reject custom -x flags -- they collide
-- with the global parser -- so the project's tasks use value positionals):
--   subject = target name for build/run/clean, or build mode for config
--   extra   = target arch for config
local function clean_arg(value)
    if value and value ~= "" then
        return value
    end
    return nil
end

function run(lane, action, subject, extra)
    if not lane or lane == "" then
        errors.fail("xmake lane requires a platform lane, e.g. `xmake lane wasm build` (windows|linux|macosx|ios|android|wasm)")
    end
    action = clean_arg(action) or "build"
    subject = clean_arg(subject)
    extra = clean_arg(extra)
    local root = os.projectdir()
    local layout = lane_layout(root, lane)

    if action == "config" or action == "configure" or action == "f" then
        do_config(root, lane, layout, {mode = subject, arch = extra})
        return
    end

    if action == "build" or action == "b" or action == "rebuild" then
        ensure_configured(root, lane, layout, {})
        local argv = {"build"}
        if action == "rebuild" then
            table.insert(argv, "-r")
        end
        if subject then
            table.insert(argv, subject)
        end
        run_child(root, layout, argv)
        return
    end

    if action == "run" or action == "clean" then
        local argv = {action}
        if subject then
            table.insert(argv, subject)
        end
        run_child(root, layout, argv)
        return
    end

    if action == "show" then
        run_child(root, layout, {"show"})
        return
    end

    errors.fail("unknown lane action '%s' (use config|build|rebuild|run|clean|show)", action)
end
