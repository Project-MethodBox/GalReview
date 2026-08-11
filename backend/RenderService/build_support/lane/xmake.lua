-- Lane launcher provider: `xmake lane <plat> [action]` runs an isolated
-- per-lane build so multiple platforms build concurrently in one checkout
-- without blocking each other, and without touching the root configuration
-- or the user's environment. The mechanism lives in core/modules/lane.lua.

local CORE_MODULES_DIR = path.join(os.scriptdir(), "..", "core", "modules")

task("lane")
    set_category("plugin")
    on_run(function ()
        local option = import("core.base.option")
        local lane = import("lane", {rootdir = CORE_MODULES_DIR})
        lane.run(option.get("lane"), option.get("action"),
            option.get("subject"), option.get("extra"))
    end)
    set_menu
    {
        usage = "xmake lane <plat> [config|build|rebuild|run|clean|show] [target|mode] [arch]",
        description = "Build a platform lane in an isolated config/build/temp so lanes run concurrently in one checkout",
        -- All positional values: xmake plugin-task menus reject custom -x
        -- flags (they collide with the global parser), so every argument is a
        -- value positional, matching `xmake android` / `xmake toolchains`.
        options =
        {
            {nil, "lane", "v", nil, "lane platform: windows, linux, macosx, ios, android, wasm, wasm64"},
            {nil, "action", "v", "build", "config, build (default), rebuild, run, clean, or show"},
            {nil, "subject", "v", "", "target name (build/run/clean) or build mode (config: debug/release)"},
            {nil, "extra", "v", "", "target arch for the config action (default chosen per plat)"}
        }
    }
