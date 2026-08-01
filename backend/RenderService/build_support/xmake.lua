-- build_support entry: one include per provider. The root project reaches
-- this file through the build_support/cpp/xmake.lua compatibility shim, so
-- the root xmake.lua never needs to change when providers move.

-- C++ language provider (options, project_gcc toolchain, toolchains.auto /
-- gcc.features / gcc.modules rules, `xmake toolchains` task)
includes(path.join(os.scriptdir(), "languages", "cpp", "xmake.lua"))

-- Android packaging provider (`xmake android` task + apk_* options)
includes(path.join(os.scriptdir(), "android", "xmake.lua"))

-- Rust language provider (rust.cargo rule + rust_nightly option)
includes(path.join(os.scriptdir(), "languages", "rust", "xmake.lua"))

-- Lane launcher provider (`xmake lane` task: concurrent per-lane builds)
includes(path.join(os.scriptdir(), "lane", "xmake.lua"))
