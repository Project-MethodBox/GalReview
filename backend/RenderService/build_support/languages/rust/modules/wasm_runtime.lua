-- Thread-capable Rust core runtime rlibs for wasm32-unknown-emscripten,
-- consumed by the gccwasm TOOLCHAIN ACCEPTANCE smoke only (it compiles a
-- probe with direct rustc + `--extern noprelude:` injection and links the
-- rlibs through emcc by hand). The engine build itself no longer uses this:
-- rust.cargo builds the whole crate through Cargo, whose -Zbuild-std flags
-- rebuild core/compiler_builtins/alloc with the same atomics and bulk-memory
-- contract inline.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("hosttools", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("envs", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("run", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("install_lock", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("toolchain")

local RUST_TARGET = "wasm32-unknown-emscripten"
local RUNTIME_VERSION = "atomic-build-std-v1"
local TARGET_RUSTFLAG = "-Ctarget-feature=+atomics,+bulk-memory,+mutable-globals"

local function runtime_variant(opt)
    -- alloc is a permanent part of the runtime; the atomics build-std set is
    -- always core+compiler_builtins+alloc, so the cache variant is fixed.
    return "core-alloc"
end

local function runtime_lib_dir(opt)
    return path.join(toolchain.rust_prefix(), "lib", "rustlib", RUST_TARGET,
        RUNTIME_VERSION .. "-" .. runtime_variant(opt))
end

local function build_root(opt)
    return path.join(layout.toolchains_cache_root(), "rust", toolchain.pinned_nightly(),
        RUNTIME_VERSION, base.host_os() .. "-" .. settings.host_arch_folder(), runtime_variant(opt))
end

local function expected_crates(opt)
    return {"core", "compiler_builtins", "alloc"}
end

-- Locates one rlib per expected crate under `root`. Three layout shapes are
-- probed because the callers hand over two different kinds of tree and Cargo
-- moved its intermediate artifacts upstream:
--   * `lib<name>-*.rlib`                       -- our own flat cache dir;
--   * `deps/lib<name>-*.rlib`                  -- cargo target layout up to
--     nightly-2026-02-18;
--   * `build/<name>/*/out/lib<name>-*.rlib`    -- the 2026 build-dir split
--     (observed nightly-2026-08-01: `deps` is left empty and intermediates
--     land in per-crate `build/<crate>/<hash>/out` folders).
-- Exactly one artifact must remain across all shapes -- the build tree is
-- wiped before every rebuild (safe_remove_tree below), so stale-hash
-- duplicates cannot accumulate; anything else is a hard failure, never a
-- silent pick.
function find_rlibs(root, opt, strict)
    local rlibs = {}
    for _, name in ipairs(expected_crates(opt)) do
        local matches = os.files(path.join(root, "lib" .. name .. "-*.rlib"))
        table.join2(matches, os.files(path.join(root, "deps", "lib" .. name .. "-*.rlib")))
        table.join2(matches, os.files(path.join(root, "build", name, "*", "out", "lib" .. name .. "-*.rlib")))
        if #matches ~= 1 then
            if strict then
                errors.fail("Rust WebAssembly atomic runtime expected one lib%s rlib under %s, found %d",
                    name, root, #matches)
            end
            return
        end
        table.insert(rlibs, {name = name, path = matches[1]})
    end
    return rlibs
end

local function write_generated(file, content)
    if os.isfile(file) and io.readfile(file) == content then
        return
    end
    os.mkdir(path.directory(file))
    base.writefile_bytes(file, content)
end

local function safe_remove_tree(candidate, owner, label)
    candidate = path.absolute(candidate)
    owner = path.absolute(owner)
    local relative = path.relative(candidate, owner):gsub("\\", "/")
    if relative == "." or relative == ".." or relative:startswith("../")
        or relative:startswith("/") or relative:match("^%a:/") then
        errors.fail("refusing to remove %s outside its owning directory: %s (owner %s)",
            label, candidate, owner)
    end
    os.tryrm(candidate)
end

local function toml_path(value)
    return tostring(value):gsub("\\", "/"):gsub('"', '\\"')
end

-- `-print-file-name` echoes the bare name back when the compiler cannot
-- locate the file, so a hit requires an actual on-disk path.
local function probe_runtime_file(gcc, name)
    local out = os.iorunv(gcc, {"-print-file-name=" .. name}, {try = true})
    out = base.trim(out or "")
    if out ~= "" and os.isfile(out) then
        return out
    end
end

-- Same candidate policy as cargo.lua's [host] override: the project's own
-- Windows-target toolchain first, PATH only as a probed fallback (an
-- unrelated cross shim on PATH -- opam's OCaml MinGW wrapper, say --
-- answers to the triplet-gcc name but cannot locate its own libgcc.a).
-- Unlike there, no usable candidate is fatal here: build-std must compile
-- and link host build scripts (compiler_builtins has one).
local function windows_host_config(root)
    if not base.is_windows_host() then
        return "", nil
    end

    local candidates = {
        path.join(settings.gcc_prefix("windows"), "bin",
            base.exe(settings.managed_target("windows") .. "-gcc")),
        hosttools.preferred_host_tool_any({settings.host_triplet() .. "-gcc", "gcc"})
    }
    for _, gcc in ipairs(candidates) do
        if gcc and os.isfile(gcc) then
            local libgcc_eh = probe_runtime_file(gcc, "libgcc_eh.a")
            local libgcc = libgcc_eh or probe_runtime_file(gcc, "libgcc.a")
            if libgcc then
                local rustflags = ""
                if not libgcc_eh then
                    local hostlib = path.join(root, "hostlib")
                    local alias = path.join(hostlib, "libgcc_eh.a")
                    write_generated(alias, "INPUT(\"" .. toml_path(path.absolute(libgcc)) .. "\")\n")
                    rustflags = "\nrustflags = [\"-Clink-arg=-L" .. toml_path(path.absolute(hostlib)) .. "\"]"
                end
                local config = table.concat({
                    "target-applies-to-host = false",
                    "",
                    "[host]",
                    "linker = \"" .. toml_path(path.absolute(gcc)) .. "\"" .. rustflags,
                    ""
                }, "\n")
                return config, path.directory(gcc)
            end
        end
    end

    errors.fail("no usable MinGW host GCC for Cargo build-std; run `xmake toolchains install windows` or install a real MinGW GCC (a PATH shim that cannot locate its libgcc.a is rejected)")
end

local function runtime_signature(opt)
    local rustc_version = base.trim(os.iorunv(toolchain.rustc_path(), {"--version", "--verbose"}))
    local cargo_version = base.trim(os.iorunv(toolchain.cargo_path(), {"--version", "--verbose"}))
    return table.concat({
        RUNTIME_VERSION,
        runtime_variant(opt),
        TARGET_RUSTFLAG,
        rustc_version,
        cargo_version,
        ""
    }, "\n")
end

-- Forward declaration so ensure() (defined next) captures it as an upvalue;
-- the body is assigned just below.
local build_atomic_runtime

function ensure(opt)
    opt = opt or {}
    if not toolchain.cargo_installed() then
        errors.fail("project-local nightly Cargo is required to build the threaded Rust WebAssembly runtime; run `xmake toolchains install rust`")
    end
    if not toolchain.sysroot_src_installed() then
        errors.fail("rust-src is required to build the threaded Rust WebAssembly runtime; run `xmake toolchains install rust`")
    end

    local output = runtime_lib_dir(opt)
    local marker = path.join(output, ".xmake-runtime")
    local signature = runtime_signature(opt)
    local function cached()
        local rlibs = find_rlibs(output, opt, false)
        if rlibs and os.isfile(marker) and io.readfile(marker) == signature then
            return rlibs
        end
    end
    local ready = cached()
    if ready then
        return ready
    end

    -- Serialize the destructive rebuild across processes: safe_remove_tree of
    -- the shared output followed by a non-atomic rebuild+copy means two
    -- concurrent provisioners of the same runtime variant could wipe or
    -- half-populate the output under each other (strict find_rlibs then sees 0
    -- and hard-fails, or a consumer links against a deleted rlib). Mirrors the
    -- emsdk .install.lock / bootstrap.lock pattern, with a double-check so a
    -- process that waited behind the lock reuses the finished build.
    local lockdir = path.join(layout.toolchains_cache_root(), "rust")
    return install_lock.guard(path.join(lockdir, ".wasm-runtime.lock"), function ()
        local done = cached()
        if done then
            return done
        end
        return build_atomic_runtime(opt, output, marker, signature)
    end)
end

build_atomic_runtime = function(opt, output, marker, signature)
    local root = build_root(opt)
    safe_remove_tree(root, layout.toolchains_cache_root(), "Rust WebAssembly build-std cache")
    safe_remove_tree(output, toolchain.rust_prefix(), "Rust WebAssembly atomic runtime")

    local manifest = table.concat({
        "[package]",
        "name = \"wasm_atomic_runtime_probe\"",
        "version = \"0.0.0\"",
        "edition = \"2024\"",
        "",
        "[lib]",
        "path = \"src/lib.rs\"",
        "",
        "[profile.release]",
        "panic = \"abort\"",
        "codegen-units = 1",
        ""
    }, "\n")
    local lock = table.concat({
        "# This file is automatically generated by WhiteHopeEngine build support.",
        "version = 4",
        "",
        "[[package]]",
        "name = \"wasm_atomic_runtime_probe\"",
        "version = \"0.0.0\"",
        ""
    }, "\n")
    local source = table.concat({
        "#![no_std]",
        "",
        "use core::sync::atomic::{AtomicUsize, Ordering};",
        "",
        "pub fn wasm_atomic_runtime_probe(value: &AtomicUsize) -> usize {",
        "\tvalue.fetch_add(1, Ordering::SeqCst)",
        "}",
        ""
    }, "\n")
    write_generated(path.join(root, "Cargo.toml"), manifest)
    write_generated(path.join(root, "Cargo.lock"), lock)
    write_generated(path.join(root, "src", "lib.rs"), source)

    local host_config, host_bin = windows_host_config(root)
    if host_config ~= "" then
        write_generated(path.join(root, ".cargo", "config.toml"), host_config)
    end

    local target_dir = path.join(root, "target")
    local cargo_envs = envs.with_path(envs.proxy_envs(), host_bin)
    cargo_envs.CARGO_HOME = path.join(layout.toolchains_cache_root(), "rust", "cargo-home")
    cargo_envs.CARGO_TARGET_DIR = target_dir
    cargo_envs.CARGO_ENCODED_RUSTFLAGS = TARGET_RUSTFLAG
    cargo_envs.RUSTC = toolchain.rustc_path()
    cargo_envs.RUSTDOC = toolchain.rustdoc_path()
    cargo_envs.CARGO_INCREMENTAL = "0"

    local build_std = "core,compiler_builtins,alloc"
    local args = {"build", "-Z", "build-std=" .. build_std}
    if base.is_windows_host() then
        table.join2(args, {"-Z", "host-config", "-Z", "target-applies-to-host"})
    end
    table.join2(args, {"--target", RUST_TARGET, "--release", "--locked"})
    errors.log("building threaded Rust core runtime for " .. RUST_TARGET)
    run.run_program("build Rust WebAssembly atomic core runtime", toolchain.cargo_path(), args, {
        target_os = "emscripten",
        curdir = root,
        envs = cargo_envs
    })

    local built = find_rlibs(path.join(target_dir, RUST_TARGET, "release"), opt, true)
    os.mkdir(output)
    for _, rlib in ipairs(built) do
        os.cp(rlib.path, path.join(output, path.filename(rlib.path)))
    end
    base.writefile_bytes(marker, signature)
    return find_rlibs(output, opt, true)
end
