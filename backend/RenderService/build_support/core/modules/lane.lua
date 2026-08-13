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

-- Lane registry: which plat a lane configures and, where the project pins one,
-- which arch. A lane is normally named after its plat; a lane whose name
-- differs exists to give a SECOND arch of that plat its own configuration, so
-- both can stay configured and build concurrently (wasm64 is a multilib of
-- wasm32-unknown-emscripten -- same plat, same toolchain, different memory
-- model). Lanes absent from the table configure the plat they are named after
-- and let xmake/policy choose the arch (android arch policy, macosx/ios
-- aarch64 clamp); an explicit --arch always wins.
local LANES =
{
    windows = {plat = "windows", arch = "x64"},
    mingw = {plat = "mingw", arch = "x86_64"},
    linux = {plat = "linux", arch = "x86_64"},
    wasm = {plat = "wasm", arch = "wasm32"},
    wasm64 = {plat = "wasm", arch = "wasm64"},
    emscripten = {plat = "emscripten", arch = "wasm32"},
    -- xmake has no `ios` plat -- the Apple mobile one is `iphoneos`. A lane
    -- named after the missing plat still "worked" for the engine, because the
    -- managed toolchain is chosen by target OS rather than by the plat
    -- string, so a static library came out right either way. An EXECUTABLE
    -- does not: on an unrecognized plat xmake falls back to its generic
    -- (GNU-shaped) packaging, which answers set_strip("all") by shelling out
    -- to `objcopy --only-keep-debug` -- a tool no Mach-O toolchain ships, so
    -- the release link died right after producing a perfectly good binary
    -- (2026-08-12). Naming the real plat routes it to the Apple path, which
    -- uses dsymutil (present in the prefix) and emits a .dSYM instead.
    ios = {plat = "iphoneos", arch = "arm64"},
    -- Android's unpinned arch resolves to xmake's own default, armeabi-v7a --
    -- an architecture this project has never provisioned a toolchain for. A
    -- bare `xmake lane android build` therefore did not build anything: it
    -- silently began compiling a complete arm cross-GCC from source, visible
    -- only as `preparing project-local GCC for windows/android/arm` a few
    -- lines into the log (2026-08-12, ~36 minutes before it was noticed).
    -- x86_64 is the arch this project actually provisions and packages (see
    -- the no-dex APK flow), so the lane names it. Another arch stays one
    -- positional away: `xmake lane android config debug arm64`.
    android = {plat = "android", arch = "x86_64"}
}
local DEFAULT_MODE = "debug"

local function lane_spec(lane)
    return LANES[lane] or {plat = lane}
end

-- A lane owns state inside its platform's conventional build/<plat>/ directory
-- and nothing else. Products land in the ordinary build/<plat>/<arch>/<mode>/
-- tree -- the exact path a plain `xmake build` produces, so a lane never
-- invents a separate output folder (the build dir is left at its default; only
-- config/lock/mapper are isolated). The plat's own lane keeps that directory as
-- its config home; a second-arch lane nests its state in a dot-dir beside it,
-- which keeps every artifact of one platform under one build/<plat>/ roof --
-- the visible subfolders there are then exactly the arch product trees.
-- Public because it doubles as the fixture surface for the lane mapping.
function lane_layout(root, lane)
    local spec = lane_spec(lane)
    local home = path.join(root, "build", spec.plat)
    local state = lane == spec.plat and home or path.join(home, "." .. lane)
    return
    {
        name = lane,
        plat = spec.plat,
        arch = spec.arch,
        home = home,
        configdir = state,
        xtmpdir = path.join(state, ".mapper"),
        ostmpdir = path.join(state, ".ostmp")
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
-- build streams live. The child's failure is re-reported here instead of
-- letting os.execv raise: its message ("execv(...) failed(-1), unknown
-- reason") hides which side failed. A non-zero status is the child's own
-- exit code and its diagnostics are already in the streamed output above;
-- -1 is also what a parent-side wait failure yields (xmake reuses it as a
-- sentinel), and a nil status means the child could not be spawned at all.
local function run_child(root, layout, argv)
    os.mkdir(layout.configdir)
    os.mkdir(layout.xtmpdir)
    local program = xmake_program()
    local status, why = os.execv(program, argv, {curdir = root, envs = lane_envs(layout), try = true})
    if status == nil then
        errors.fail("lane %s: failed to launch the child xmake (%s): %s",
            layout.name, program, why or "unknown spawn error")
    end
    if status ~= 0 then
        errors.fail("lane %s: child `xmake %s` exited with status %d%s -- its diagnostics are in the"
            .. " output above%s", layout.name, table.concat(argv, " "), status,
            why and (" (" .. why .. ")") or "",
            status == -1 and " (a -1 can also mean the parent failed waiting on the child)" or "")
    end
end

local function do_config(root, layout, opt)
    local arch = opt.arch or layout.arch
    local mode = opt.mode or DEFAULT_MODE
    local argv = {"f", "-p", layout.plat}
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

local function ensure_configured(root, layout, opt)
    if not is_configured(layout) then
        do_config(root, layout, opt)
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
        errors.fail("xmake lane requires a platform lane, e.g. `xmake lane wasm build` (windows|linux|macosx|ios|android|wasm|wasm64)")
    end
    action = clean_arg(action) or "build"
    subject = clean_arg(subject)
    extra = clean_arg(extra)
    local root = os.projectdir()
    local layout = lane_layout(root, lane)

    if action == "config" or action == "configure" or action == "f" then
        do_config(root, layout, {mode = subject, arch = extra})
        return
    end

    if action == "build" or action == "b" or action == "rebuild" then
        ensure_configured(root, layout, {})
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
