-- Fixture regression for the Rust-entry link-contract renderers
-- (languages/rust/modules/link_export.lua): the hand-built JSON must
-- round-trip through a real JSON parser, and the @response/config.toml
-- forms must keep Windows paths (backslashes, spaces) intact. The
-- imperative run() needs a configured project and is exercised by the
-- `xmake rust export-link` guard paths instead.

import("link_export", {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "rust", "modules")})

function run(t)
    t.case("rust link export: response lines quote and forward-slash paths", function ()
        t.assert_eq(link_export.respfile_line([[D:\Coding\White Hope\a.o]]),
            '"D:/Coding/White Hope/a.o"', "backslashes and spaces")
        t.assert_eq(link_export.render_response({[[a\b.o]], "c.o"}),
            '"a/b.o"\n"c.o"\n', "one quoted line per object")
        t.assert_eq(link_export.render_response({"a.o"}, {"stdc++", "gcc"}),
            '"a.o"\n-Wl,--start-group\n-lstdc++\n-lgcc\n-Wl,--end-group\n',
            "library tail wrapped in one ld group (MinGW runtime set is mutually recursive)")
    end)

    t.case("rust link export: JSON contract round-trips through a real parser", function ()
        local json = import("core.base.json", {anonymous = true})
        local rendered = link_export.render_json({
            target_os = "windows",
            gcc_triplet = "x86_64-w64-mingw32",
            rust_target = "x86_64-pc-windows-gnu",
            linker = [[D:\tc\bin\x86_64-w64-mingw32-g++.exe]],
            response_file = [[D:\b\rust_link\link_objects.rsp]],
            libs = {"stdc++", "kernel32"},
            objects = {[[D:\b\one.o]], [[D:\b\two.o]]}
        })
        local decoded = json.decode(rendered)
        t.assert_eq(decoded.version, 1, "contract version")
        t.assert_eq(decoded.linker, "D:/tc/bin/x86_64-w64-mingw32-g++.exe", "linker forward-slashed")
        t.assert_eq(#decoded.objects, 2, "object count")
        t.assert_eq(decoded.objects[2], "D:/b/two.o", "object path forward-slashed")
        t.assert_eq(#decoded.libs, 2, "library tail count")
        t.assert_eq(decoded.rust_target, "x86_64-pc-windows-gnu", "rust target")
    end)

    t.case("rust link export: cargo config pins linker and self-contained off", function ()
        local config = link_export.render_cargo_config(
            [[D:\tc\bin\x86_64-w64-mingw32-g++.exe]], "x86_64-pc-windows-gnu",
            "x86_64-pc-windows-gnu")
        t.assert_match(config, "[target.x86_64-pc-windows-gnu]", "target table header")
        t.assert_match(config, 'linker = "D:/tc/bin/x86_64-w64-mingw32-g++.exe"', "linker path")
        t.assert_match(config, "link-self-contained=off", "project CRT wins over rustc's bundled MinGW")
        -- Triple-scoped host table: a generic [host] would leak gnu-only
        -- flags into rust-analyzer's rustup-msvc host builds.
        t.assert_match(config, "[host.x86_64-pc-windows-gnu]", "host table scoped to the project host triple")
        -- Bare `cargo run` must default to the GNU target (MinGW COFF
        -- objects + GNU library tail cannot link under host-default msvc).
        t.assert_match(config, 'target = "x86_64-pc-windows-gnu"', "[build] target pinned")
    end)
end
