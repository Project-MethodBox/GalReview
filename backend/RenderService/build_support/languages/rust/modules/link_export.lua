-- Exports the C++ side's link inputs for a cargo-driven Rust-entry link:
-- the scaffold inverse of the rust.cargo rule (there, xmake pulls Cargo's
-- staticlib into the engine archive; here, Cargo pulls xmake's raw C++
-- objects into rustc's link).
--
-- Two files, one contract, written under <buildir>/rust_link/:
--   * link_export.json -- the documented machine-readable contract (for
--     humans and future tools; the entry build.rs deliberately does NOT
--     parse it: the zero-dependency policy leaves it no JSON parser);
--   * link_objects.rsp -- the same object list as a GNU @response file,
--     which the g++ linker driver expands natively, so the entry build.rs
--     forwards a single `@<file>` argument and parses nothing. The
--     response file also dodges the Windows command-line length ceiling
--     that forced the 40-per-batch ar invocations in the rust.cargo rule.
--
-- The exported objects are the PRE-absorption C++ objects
-- (target:objectfiles(); the Rust objects the rule injects post-link never
-- appear there). That is deliberate twice over: the entry reaches Rust code
-- through the crate's rlib, so absorbed-archive objects would duplicate
-- every Rust symbol, and raw .o command-line inputs (unlike .a members)
-- always keep their C++ static initializers.
--
-- The generated <entry>/.cargo/config.toml carries the knowledge a build
-- script cannot inject (Cargo has no directive for choosing the linker):
--   linker = the project g++ DRIVER (not plain gcc -- libstdc++ rides on
--   the driver's implicit library knowledge), plus
--   -Clink-self-contained=off (drop rustc's bundled MinGW CRT so startup
--   objects and runtime come from the project toolchain's sysroot).

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("toolchain")

local function write_generated(file, content)
    if os.isfile(file) and io.readfile(file) == content then
        return
    end
    os.mkdir(path.directory(file))
    base.writefile_bytes(file, content)
end

local function slashes(value)
    return tostring(value):gsub("\\", "/")
end

-- JSON string escaping for the hand-built contract: the encoder is manual
-- so the output is deterministic (stable key order, one object per line)
-- and diff/content-compare friendly.
function json_string(value)
    return '"' .. slashes(value):gsub('([\\"])', "\\%1"):gsub("%c", "") .. '"'
end

-- One @response-file line per object: forward slashes (accepted by GCC on
-- every host) and double quotes keep paths with spaces intact.
function respfile_line(object)
    return '"' .. slashes(object) .. '"'
end

-- Objects first, then the library tail: rustc passes -nodefaultlibs to the
-- driver and puts its own -l set BEFORE these late link-args, so every
-- library the exported objects need must reappear here, after them (ld
-- resolves archives left to right). The @file carries both so the ordering
-- is self-contained and the consumer stays zero-knowledge.
function render_response(objects, libs)
    local lines = {}
    for _, object in ipairs(objects) do
        table.insert(lines, respfile_line(object))
    end
    -- One --start/end-group around the whole tail: the MinGW runtime set is
    -- mutually recursive (mingw32/mingwex/msvcrt; the stock GCC spec repeats
    -- the group twice for the same reason), and grouping ends the ordering
    -- whack-a-mole once and for all. The -Wl, prefix survives the driver.
    if libs and #libs > 0 then
        table.insert(lines, "-Wl,--start-group")
        for _, lib in ipairs(libs) do
            table.insert(lines, "-l" .. lib)
        end
        table.insert(lines, "-Wl,--end-group")
    end
    return table.concat(lines, "\n") .. "\n"
end

function render_json(contract)
    local lines = {
        "{",
        '    "version": 1,',
        '    "target_os": ' .. json_string(contract.target_os) .. ",",
        '    "gcc_triplet": ' .. json_string(contract.gcc_triplet) .. ",",
        '    "rust_target": ' .. json_string(contract.rust_target) .. ",",
        '    "linker": ' .. json_string(contract.linker) .. ",",
        '    "response_file": ' .. json_string(contract.response_file) .. ",",
        '    "libs": [' .. (function ()
            local quoted = {}
            for _, lib in ipairs(contract.libs or {}) do
                table.insert(quoted, json_string(lib))
            end
            return table.concat(quoted, ", ")
        end)() .. "],",
        '    "objects": ['
    }
    for index, object in ipairs(contract.objects) do
        table.insert(lines, "        " .. json_string(object)
            .. (index < #contract.objects and "," or ""))
    end
    table.insert(lines, "    ]")
    table.insert(lines, "}")
    return table.concat(lines, "\n") .. "\n"
end

function render_cargo_config(linker, rust_target, host_rust_target, hostlib_dir)
    local quoted_linker = "\"" .. slashes(linker):gsub('"', '\\"') .. "\""
    -- Space-joined STRING form deliberately: newer nightly cargo (observed
    -- 1.99.0-nightly 2026-07-17) rejects the array form for host-config
    -- rustflags; the string form is accepted by both config tables on every
    -- toolchain in play.
    local hostlib_flag = hostlib_dir
        and (" -Clink-arg=-L" .. slashes(hostlib_dir)) or ""
    return table.concat({
        "# Generated by `xmake rust export-link`; machine-absolute, do not commit.",
        "# Carries what a build script cannot set: the linker (project g++, whose",
        "# driver supplies libstdc++/CRT knowledge) and link-self-contained=off",
        "# (rustc's bundled MinGW CRT yields to the project toolchain's). The",
        "# hostlib -L entry (when present) supplies the libgcc_eh.a alias for",
        "# project GCC builds that expose only libgcc.a -- rustc's windows-gnu",
        "# link line asks for -lgcc_eh unconditionally. Cargo never applies",
        "# [target] rustflags to host artifacts (build scripts), so a host",
        "# table carries them too -- nightly host-config, enabled inline via",
        "# [unstable] (the pinned toolchain is nightly by design). The host",
        "# table is TRIPLE-SCOPED on purpose: rust-analyzer drives this",
        "# manifest with the developer's rustup toolchain, whose msvc host",
        "# must not inherit gnu-only linker flags.",
        "target-applies-to-host = false",
        "",
        -- Bare `cargo run`/`cargo clippy` in the entry directory must default
        -- to the GNU target: the exported objects are MinGW COFF and the
        -- library tail is GNU-flavored, so the host-default msvc target can
        -- only produce LNK gibberish. With rustup this needs a one-time
        -- `rustup target add x86_64-pc-windows-gnu`.
        "[build]",
        "target = \"" .. rust_target .. "\"",
        "",
        "[unstable]",
        "host-config = true",
        "target-applies-to-host = true",
        "",
        "[host." .. host_rust_target .. "]",
        "linker = " .. quoted_linker,
        "rustflags = \"-Clink-self-contained=off" .. hostlib_flag .. "\"",
        "",
        "[target." .. rust_target .. "]",
        "linker = " .. quoted_linker,
        "rustflags = \"-Clink-self-contained=off" .. hostlib_flag .. "\"",
        ""
    }, "\n")
end

-- Runs the export against the configured project. opt:
--   target_name (default "WhiteHopeEngine"), entry_dir (default
--   WhiteHopeEngine.Test/rust_entry), output_dir (default
--   <buildir>/rust_link). The project configuration must be loaded.
function run(opt)
    opt = opt or {}
    local config = import("core.project.config")
    local project = import("core.project.project")

    local target_name = opt.target_name or "WhiteHopeEngine"
    local target = project.target(target_name)
    if not target then
        errors.fail("Rust link export cannot find target %s in this project", target_name)
    end

    local objects = {}
    local missing = {}
    for _, object in ipairs(table.wrap(target:objectfiles())) do
        local absolute = slashes(path.absolute(object))
        table.insert(objects, absolute)
        if not os.isfile(absolute) then
            table.insert(missing, absolute)
        end
    end
    table.sort(objects)
    if #objects == 0 then
        errors.fail("Rust link export found no C++ objects on target %s", target_name)
    end
    if #missing > 0 then
        errors.fail("Rust link export requires built C++ objects; run `xmake build %s` first (%d missing, e.g. %s)",
            target_name, #missing, missing[1])
    end

    local target_os = settings.configured_target_os()
    local gcc_triplet = settings.managed_target(target_os)
    local rust_target = toolchain.rust_target_for(gcc_triplet)
    local linker = path.join(settings.gcc_prefix(target_os), "bin", base.exe(gcc_triplet .. "-g++"))
    if not os.isfile(linker) then
        errors.fail("Rust link export cannot find the project g++ linker driver: %s; run `xmake toolchains install %s`",
            linker, target_os)
    end

    -- The library tail: the target's declared syslinks, then the C++/MinGW
    -- runtime closure a normal g++ link would supply from its spec defaults
    -- (killed by rustc's -nodefaultlibs): libstdc++ (operator new bridge,
    -- __cxa guards), libgcc (emutls, soft-fp), mingwex/msvcrt/kernel32/
    -- user32. The engine loads richer Windows APIs at runtime via
    -- LoadLibraryW, so the static closure stays this small.
    local libs = {}
    local seen_libs = {}
    for _, lib in ipairs(table.join(table.wrap(target:get("syslinks")),
        {"stdc++exp", "stdc++", "gcc", "mingw32", "mingwex", "winpthread",
         "msvcrt", "kernel32", "user32"})) do
        if not seen_libs[lib] then
            seen_libs[lib] = true
            table.insert(libs, lib)
        end
    end

    local output_dir = path.absolute(opt.output_dir
        or path.join((config.builddir and config.builddir() or config.buildir()) or "build", "rust_link"))
    local response_file = slashes(path.join(output_dir, "link_objects.rsp"))
    local contract_file = path.join(output_dir, "link_export.json")
    write_generated(response_file, render_response(objects, libs))
    write_generated(contract_file, render_json({
        target_os = target_os,
        gcc_triplet = gcc_triplet,
        rust_target = rust_target,
        linker = linker,
        response_file = response_file,
        libs = libs,
        objects = objects
    }))

    local entry_dir = opt.entry_dir
        or path.join(os.projectdir(), "WhiteHopeEngine.Test", "rust_entry")

    -- Project GCC builds expose only libgcc.a, while rustc's windows-gnu
    -- link line asks for -lgcc_eh; mirror the pipeline's alias trick (an
    -- INPUT() linker script named libgcc_eh.a) next to the generated config.
    local hostlib_dir
    local eh_probe = base.trim(os.iorunv(linker, {"-print-file-name=libgcc_eh.a"}, {try = true}) or "")
    if eh_probe == "" or not os.isfile(eh_probe) then
        local libgcc = base.trim(os.iorunv(linker, {"-print-file-name=libgcc.a"}, {try = true}) or "")
        if libgcc ~= "" and os.isfile(libgcc) then
            hostlib_dir = path.join(entry_dir, ".cargo", "hostlib")
            write_generated(path.join(hostlib_dir, "libgcc_eh.a"),
                "INPUT(\"" .. slashes(path.absolute(libgcc)) .. "\")\n")
        end
    end

    write_generated(path.join(entry_dir, ".cargo", "config.toml"),
        render_cargo_config(linker, rust_target, toolchain.host_rust_target(), hostlib_dir))

    errors.log("exported C++ link contract for the Rust entry")
    print("  objects:  %d -> %s", #objects, response_file)
    print("  contract: %s", slashes(contract_file))
    print("  linker:   %s (link-self-contained=off)", slashes(linker))
    return {
        contract_file = contract_file,
        response_file = response_file,
        objects = objects,
        linker = linker,
        rust_target = rust_target
    }
end
