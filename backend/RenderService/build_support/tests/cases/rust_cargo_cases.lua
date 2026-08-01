-- Fixture regression for the Cargo build-message parser (public surface:
-- cargo.parse_build_messages): the staticlib artifact must be found among
-- the line-delimited build JSON, and build-script native-link requests must
-- be attributed only to packages that contribute TARGET rlibs (host-side
-- build scripts and proc-macro host deps are rustc's own link problem, never
-- the foreign final linker's).

import("cargo", {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "rust", "modules")})

local RUST_TARGET = "x86_64-pc-windows-gnu"

local function fixture_paths(t)
    local target_dir = t.tmpdir("rust-cargo-target")
    local target_root = path.join(target_dir, RUST_TARGET, "release")
    local host_root = path.join(target_dir, "release")
    return target_dir, target_root, host_root
end

local function artifact_line(package_id, kinds, filenames)
    local kind_list = {}
    for _, kind in ipairs(kinds) do
        table.insert(kind_list, string.format("%q", kind))
    end
    local file_list = {}
    for _, filename in ipairs(filenames) do
        table.insert(file_list, string.format("%q", (filename:gsub("\\", "/"))))
    end
    return string.format(
        '{"reason":"compiler-artifact","package_id":%q,"target":{"kind":[%s]},"filenames":[%s]}',
        package_id, table.concat(kind_list, ","), table.concat(file_list, ","))
end

local function script_line(package_id, linked_libs)
    local libs = {}
    for _, lib in ipairs(linked_libs) do
        table.insert(libs, string.format("%q", lib))
    end
    return string.format(
        '{"reason":"build-script-executed","package_id":%q,"linked_libs":[%s],"linked_paths":[],"linked_args":[]}',
        package_id, table.concat(libs, ","))
end

function run(t)
    t.case("rust cargo: the staticlib artifact is found among the build messages", function ()
        local target_dir, target_root = fixture_paths(t)
        local staticlib = path.join(target_root, "libwhe.a")
        local messages = table.concat({
            artifact_line("path+file:///repo#whe@0.0.0",
                {"staticlib", "rlib"},
                {staticlib, path.join(target_root, "libwhe.rlib")}),
            ""
        }, "\n")
        local parsed = cargo.parse_build_messages(messages, {
            rust_target = RUST_TARGET,
            cargo_target_dir = target_dir
        })
        t.assert_eq(path.absolute(staticlib), parsed.staticlib, "staticlib path")
        t.assert_eq(#parsed.native_requests, 0, "no native requests")
    end)

    t.case("rust cargo: a target-rlib dependency's native-link request is reported", function ()
        local target_dir, target_root = fixture_paths(t)
        local dep = "registry+https://example#native-dep@1.0.0"
        local messages = table.concat({
            artifact_line(dep, {"lib"}, {path.join(target_root, "deps", "libnative_dep.rlib")}),
            script_line(dep, {"z"}),
            ""
        }, "\n")
        local parsed = cargo.parse_build_messages(messages, {
            rust_target = RUST_TARGET,
            cargo_target_dir = target_dir
        })
        t.assert_eq(#parsed.native_requests, 1, "one native request")
        t.assert_eq(parsed.native_requests[1].package, dep, "offending package")
        t.assert_eq(parsed.native_requests[1].requests[1], "z", "requested library")
    end)

    t.case("rust cargo: a host-only package's build script is exempt", function ()
        -- host rlibs land under target/release (no triple segment): rustc
        -- owns that link (proc-macro dylibs), the engine archive never sees it
        local target_dir, _, host_root = fixture_paths(t)
        local dep = "registry+https://example#host-dep@1.0.0"
        local messages = table.concat({
            artifact_line(dep, {"lib"}, {path.join(host_root, "deps", "libhost_dep.rlib")}),
            script_line(dep, {"hostonly"}),
            ""
        }, "\n")
        local parsed = cargo.parse_build_messages(messages, {
            rust_target = RUST_TARGET,
            cargo_target_dir = target_dir
        })
        t.assert_eq(#parsed.native_requests, 0, "host-only script exempt")
    end)
end
