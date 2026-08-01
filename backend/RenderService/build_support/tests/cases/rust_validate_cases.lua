-- Fixture regression for the rust crate validators: validate.run() over
-- hand-built temp crate trees shaped like the real one (a single crate whose
-- root is lib.rs at the source-root top, modules in ordinary Rust layout).
-- Discovery is gone -- Cargo owns the crate graph -- so the fixtures call
-- validate.run with an explicit root_file + sources list, exactly like the
-- rust.cargo rule does.

import("validate", {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "rust", "modules")})

local CRATE_ROOT = [==[
#![no_std]

mod runtime;
]==]

local RUNTIME_MODULE = [==[
#[panic_handler]
fn whe_panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}
]==]

local function write_crate(t, rs)
    t.write(path.join(rs, "lib.rs"), CRATE_ROOT)
    t.write(path.join(rs, "runtime.rs"), RUNTIME_MODULE)
end

local function run_validate(rs)
    validate.run({
        root_file = path.join(rs, "lib.rs"),
        sources = os.files(path.join(rs, "**.rs"))
    })
end

function run(t)
    t.case("rust validate: healthy crate tree validates clean", function ()
        local rs = t.tmpdir("rust-clean")
        write_crate(t, rs)
        run_validate(rs)
    end)

    t.case("rust validate: a file module's submodule under name/ is reachable (modern layout)", function ()
        -- lib.rs -> mod feature; (file module feature.rs) -> mod detail;
        -- whose file lives at feature/detail.rs. The file module owns its
        -- children under feature/, exactly like feature/mod.rs; a wrong
        -- parent-dir resolution would false-flag detail.rs as an orphan.
        local rs = t.tmpdir("rust-file-module-submodule")
        t.write(path.join(rs, "lib.rs"), "#![no_std]\n\nmod feature;\n")
        t.write(path.join(rs, "feature.rs"), "mod detail;\n")
        t.write(path.join(rs, "feature", "detail.rs"), "pub fn whe_detail() {}\n")
        run_validate(rs)
    end)

    t.case("rust validate: unreferenced mod.rs is reported as an orphan", function ()
        local rs = t.tmpdir("rust-orphan")
        write_crate(t, rs)
        t.write(path.join(rs, "stray", "mod.rs"), "pub fn whe_stray() {}\n")
        local message = t.expect_raise(function ()
            run_validate(rs)
        end, "not reachable from", "orphan mod.rs")
        t.assert_match(message, "mod stray;", "directory-module fix suggested by dir name, not `mod mod;`")
    end)

    t.case("rust validate: `// rust.cargo: allow-orphan` silences the orphan check", function ()
        local rs = t.tmpdir("rust-orphan-allowed")
        write_crate(t, rs)
        t.write(path.join(rs, "stray", "mod.rs"),
            "// rust.cargo: allow-orphan\npub fn whe_stray() {}\n")
        run_validate(rs)
    end)

    t.case("rust validate: crate root without #![no_std] is rejected", function ()
        local rs = t.tmpdir("rust-no-nostd")
        t.write(path.join(rs, "lib.rs"), "mod runtime;\n")
        t.write(path.join(rs, "runtime.rs"), RUNTIME_MODULE)
        t.expect_raise(function ()
            run_validate(rs)
        end, "must declare #![no_std]", "missing no_std")
    end)

    t.case("rust validate: #[unsafe(no_mangle)] export without the whe_ prefix is rejected", function ()
        local rs = t.tmpdir("rust-export-prefix")
        write_crate(t, rs)
        t.write(path.join(rs, "exports.rs"), [==[
// rust.cargo: allow-orphan
#[unsafe(no_mangle)]
pub extern "C" fn bad_symbol_name() {}
]==])
        t.expect_raise(function ()
            run_validate(rs)
        end, "must carry the whe_ prefix", "unprefixed export")
    end)

    t.case("rust validate: the ABI whitelist exempts rust_eh_personality", function ()
        local rs = t.tmpdir("rust-abi-whitelist")
        write_crate(t, rs)
        t.write(path.join(rs, "personality.rs"),
            "// rust.cargo: allow-orphan\n#[unsafe(no_mangle)]\nextern \"C\" fn rust_eh_personality() {}\n")
        run_validate(rs)
    end)
end
