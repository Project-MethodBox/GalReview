-- Fixture regression for core/modules/lane.lua's lane -> plat/arch mapping.
-- A lane is normally named after its plat, but wasm64 is a MULTILIB of
-- wasm32-unknown-emscripten: same plat, same toolchain, different memory
-- model. Two lanes therefore share one plat, and each still needs its own
-- configuration -- xmake keys xmake.conf and project.lock by config directory
-- (host-keyed, never target-keyed), so two lanes pointed at one directory
-- would overwrite each other's plat/arch/mode and serialize on one lock.
-- These cases pin both halves: which plat/arch a lane configures, and where
-- its private state lives.

local lane = import("lane",
    {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules"), anonymous = true})

local ROOT = path.join("E:", "checkout")

function run(t)
    t.case("lane: a plat-named lane keeps build/<plat> as its config home", function ()
        local layout = lane.lane_layout(ROOT, "wasm")
        t.assert_eq(layout.plat, "wasm", "plat")
        t.assert_eq(layout.arch, "wasm32", "arch")
        t.assert_eq(layout.configdir, path.join(ROOT, "build", "wasm"), "config home")
    end)

    t.case("lane: wasm64 configures the wasm plat with the 64-bit arch", function ()
        local layout = lane.lane_layout(ROOT, "wasm64")
        t.assert_eq(layout.plat, "wasm", "a second-arch lane must not invent a plat")
        t.assert_eq(layout.arch, "wasm64", "arch")
    end)

    t.case("lane: a second-arch lane nests its state under the plat's own directory", function ()
        local wasm32 = lane.lane_layout(ROOT, "wasm")
        local wasm64 = lane.lane_layout(ROOT, "wasm64")
        t.assert_eq(wasm64.home, wasm32.home, "both lanes live under one plat home")
        t.assert_eq(wasm64.configdir, path.join(ROOT, "build", "wasm", ".wasm64"), "nested config home")
        t.assert_true(wasm64.configdir ~= wasm32.configdir,
            "the two lanes must not share a configuration directory")
        t.assert_true(wasm64.xtmpdir ~= wasm32.xtmpdir,
            "the two lanes must not share a C++ module mapper directory")
    end)

    t.case("lane: an unregistered lane configures the plat it is named after", function ()
        local layout = lane.lane_layout(ROOT, "macosx")
        t.assert_eq(layout.plat, "macosx", "plat")
        -- no pinned arch: the macosx aarch64 clamp and the android arch
        -- policy stay the single source of truth for those plats
        t.assert_true(layout.arch == nil, "an unregistered lane must not pin an arch")
        t.assert_eq(layout.configdir, path.join(ROOT, "build", "macosx"), "config home")
    end)

    -- The lane is spelled `ios` because that is the OS everyone says, but the
    -- plat xmake actually has is `iphoneos`. Letting the lane name through as
    -- a plat put every ios build on xmake's generic (GNU-shaped) packaging
    -- path. That stayed invisible while ios only ever built a static library
    -- -- the managed toolchain is chosen by target OS, not by the plat string,
    -- so the objects were right regardless. It surfaced the first time a
    -- release EXECUTABLE was linked (2026-08-12): the generic path answers
    -- set_strip("all") by running `objcopy --only-keep-debug`, and no Mach-O
    -- toolchain ships objcopy, so the build failed immediately after
    -- producing a perfectly good binary.
    -- Leaving android unpinned did not mean "let policy decide" -- it meant
    -- xmake's own default, armeabi-v7a, for which this project has never
    -- provisioned a toolchain. The lane then quietly started building a whole
    -- arm cross-GCC instead of the engine.
    t.case("lane: android pins the arch this project actually provisions", function ()
        local layout = lane.lane_layout(ROOT, "android")
        t.assert_eq(layout.plat, "android", "plat")
        t.assert_eq(layout.arch, "x86_64", "an unpinned android arch falls to armeabi-v7a")
    end)

    t.case("lane: ios configures the real iphoneos plat, not its own name", function ()
        local layout = lane.lane_layout(ROOT, "ios")
        t.assert_eq(layout.plat, "iphoneos", "ios must map to the plat xmake really has")
        t.assert_eq(layout.arch, "arm64", "arch")
        t.assert_eq(layout.home, path.join(ROOT, "build", "iphoneos"),
            "a lane's state belongs under its plat's build directory")
    end)
end
