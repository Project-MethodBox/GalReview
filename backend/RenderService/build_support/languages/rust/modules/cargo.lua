-- Cargo driver for the engine's Rust crate. Cargo owns dependency
-- resolution, feature/build-script handling, checksums and compilation of the
-- whole crate graph (the repo-root manifest whose [lib] path is the rs/
-- tree); this module invokes it, gates it with clippy, and hands the
-- staticlib product's object members to the rust.cargo rule for absorption
-- into the engine archive. GCC/emcc still performs the final link.
--
-- The staticlib crate-type is load-bearing: producing it runs rustc's own
-- final-link step, which bundles core/compiler_builtins/alloc and
-- synthesizes the allocator-shim symbols liballoc references
-- (__rust_alloc_error_handler, __rust_no_alloc_shim_is_unstable_v2) -- the
-- exact symbols the previous object-only model had to lift out of a
-- throwaway staticlib by hand.
--
-- Native link requests from dependency build scripts are deliberately
-- rejected: silently dropping a `rustc-link-*` directive would defer the
-- failure (or worse, a wrong library choice) to the foreign final linker.
--
-- What this module does NOT check: whether a dependency itself is
-- #![no_std]. std isn't a Cargo dependency (it's linked implicitly from the
-- sysroot), so `cargo metadata` carries no signal to detect it; a std-using
-- crate compiles fine here and only fails later as an obscure symbol/link
-- error out of GCC's final link. See the warning above [dependencies] in the
-- repo-root Cargo.toml -- confirm no_std support by hand before adding one.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("hosttools", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("envs", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("toolchain")
import("archive")

local BUILD_STD_CRATES = "core,compiler_builtins,alloc"
local WASM_TARGET_RUSTFLAG = "-Ctarget-feature=+atomics,+bulk-memory,+mutable-globals"

local function write_generated(file, content)
    if os.isfile(file) and io.readfile(file) == content then
        return
    end
    os.mkdir(path.directory(file))
    base.writefile_bytes(file, content)
end

local function toml_path(value)
    return tostring(value):gsub("\\", "/"):gsub('"', '\\"')
end

-- Resolves the Unix-ar-compatible archiver that injects the Rust staticlib's
-- object members into the engine archive. target:tool("ar") alone
-- is not trustworthy: when the project GCC toolchain is absent, xmake
-- silently falls back to the MSVC toolchain, whose "ar" answer is link.exe
-- -- feeding it Unix ar verbs produces the baffling `LNK1181: cannot open
-- input file 'x.obj'`. The project toolchain's <triplet>-ar is therefore
-- the first candidate; the target's own answer is accepted only when it
-- does not look like MSVC link/lib (Apple's staged BSD ar stays fine).
function resolve_archiver(target)
    local target_os = settings.configured_target_os()
    local project_ar = path.join(settings.gcc_prefix(target_os), "bin",
        base.exe(settings.managed_target(target_os) .. "-ar"))
    if os.isfile(project_ar) then
        return project_ar
    end
    local tool = target:tool("ar")
    if tool then
        local name = path.filename(tool):lower():gsub("%.exe$", "")
        if name ~= "link" and name ~= "lib" then
            return tool
        end
    end
    errors.fail("no Unix-compatible archiver for the Rust objects on target %s (the MSVC link/lib fallback cannot process GNU archives); install the project GCC toolchain: `xmake toolchains install %s`",
        target:name(), target_os)
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

-- Cargo must link host build scripts/proc macros even during a cross build.
-- Match wasm_runtime's proven MinGW host setup, including the libgcc_eh alias
-- needed by project-local GCC builds that expose only libgcc.a.
--
-- Candidate order matters: the project's own Windows-target toolchain comes
-- first (host-capable MinGW, and the toolchain the engine already trusts);
-- PATH lookup is only a fallback, and every candidate must pass the
-- runtime-library probe -- an unrelated cross shim on PATH (opam's OCaml
-- MinGW wrapper, for example) answers to the same triplet-gcc name but
-- cannot locate its own libgcc.a. No usable candidate skips the override
-- instead of failing: a crate graph with no build scripts or proc macros
-- (the common case) never links host code.
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
                return table.concat({
                    "target-applies-to-host = false",
                    "",
                    "[host]",
                    "linker = \"" .. toml_path(path.absolute(gcc)) .. "\"" .. rustflags,
                    ""
                }, "\n"), path.directory(gcc)
            end
        end
    end

    errors.log("no usable MinGW host GCC; skipping the Cargo [host] linker override (only build scripts/proc-macros need it)")
    return "", nil
end

local function decode_json(text, what)
    import("core.base.json")
    local ok, value = errors.trycall(function ()
        return json.decode(text)
    end)
    if not ok or type(value) ~= "table" then
        errors.fail("could not decode %s JSON emitted by Cargo: %s", what, tostring(value))
    end
    return value
end

local function contains(values, wanted)
    for _, value in ipairs(values or {}) do
        if value == wanted then
            return true
        end
    end
    return false
end

local function path_within(candidate, owner)
    candidate = path.absolute(candidate)
    owner = path.absolute(owner)
    local relative = path.relative(candidate, owner):gsub("\\", "/")
    return relative == "." or (relative ~= ".." and not relative:startswith("../")
        and not relative:startswith("/") and not relative:match("^%a:/"))
end

-- Public for fixture tests: walks Cargo's line-delimited build JSON and
-- returns { staticlib, native_requests }. The staticlib is the engine crate's
-- product. native_requests lists build-script `rustc-link-*` directives from
-- packages that contribute TARGET rlibs (host-side build scripts and the
-- proc-macro toolchain's own host deps are exempt: rustc manages that link
-- itself, the foreign final link never sees them).
function parse_build_messages(messages, opt)
    local target_root = path.join(opt.cargo_target_dir, opt.rust_target)
    local staticlib = nil
    local target_packages = {}
    local script_requests = {}

    for line in tostring(messages):gmatch("[^\r\n]+") do
        if line:sub(1, 1) == "{" then
            local ok, message = errors.trycall(function ()
                return decode_json(line, "build message")
            end)
            if ok and type(message) == "table" then
                local reason = message.reason
                if reason == "compiler-message" then
                    local rendered = message.message and message.message.rendered
                    if rendered and rendered ~= "" then
                        print(rendered)
                    end
                elseif reason == "compiler-artifact" then
                    local id = tostring(message.package_id or "")
                    local is_staticlib = contains((message.target or {}).kind, "staticlib")
                    for _, filename in ipairs(message.filenames or {}) do
                        filename = path.absolute(filename)
                        if is_staticlib and (filename:endswith(".a") or filename:endswith(".lib")) then
                            staticlib = filename
                        elseif filename:endswith(".rlib") and path_within(filename, target_root) then
                            target_packages[id] = true
                        end
                    end
                elseif reason == "build-script-executed" then
                    local requests = table.join(
                        message.linked_libs or {},
                        message.linked_paths or {},
                        message.linked_args or {})
                    if #requests > 0 then
                        table.insert(script_requests, {
                            package = tostring(message.package_id or ""),
                            requests = requests
                        })
                    end
                end
            end
        end
    end

    local native_requests = {}
    for _, script in ipairs(script_requests) do
        if target_packages[script.package] then
            table.insert(native_requests, script)
        end
    end
    return {staticlib = staticlib, native_requests = native_requests}
end

local function cargo_environment(work_root, manifest, opt)
    local host_config, host_bin = windows_host_config(work_root)
    local host_config_written = host_config ~= ""
    if host_config_written then
        write_generated(path.join(work_root, ".cargo", "config.toml"), host_config)
    end

    local cargo_envs = envs.with_path(envs.proxy_envs(), host_bin)
    cargo_envs.CARGO_HOME = path.join(layout.toolchains_cache_root(), "rust", "cargo-home")
    -- target/ beside the manifest (the repo root, gitignored): a plain
    -- `cargo build` from the shell and this rule share one artifact cache,
    -- because the invocations are flag-identical for non-wasm targets (the
    -- lint bar and profiles live in the manifest, not in RUSTFLAGS).
    cargo_envs.CARGO_TARGET_DIR = path.join(path.directory(manifest), "target")
    cargo_envs.CARGO_INCREMENTAL = "0"
    cargo_envs.RUSTC = toolchain.rustc_path()
    cargo_envs.RUSTDOC = toolchain.rustdoc_path()

    local rustflags = {}
    if toolchain.is_wasm_target(opt.rust_target) then
        -- the atomics contract must match the Emscripten pthread final link;
        -- build-std below rebuilds core/compiler_builtins/alloc with it.
        -- Both memory models take it: the 64-bit link is a pthread link too.
        table.insert(rustflags, WASM_TARGET_RUSTFLAG)
    end
    cargo_envs.CARGO_ENCODED_RUSTFLAGS = table.concat(rustflags, string.char(31))
    return cargo_envs, host_config_written
end

local function common_args(subcommand, manifest, opt, host_config_written)
    local args = {subcommand}
    if toolchain.is_wasm_target(opt.rust_target) then
        table.insert(args, "-Z")
        table.insert(args, "build-std=" .. BUILD_STD_CRATES)
    end
    -- target-applies-to-host/[host] in the generated config are unstable
    -- Cargo features: without these two flags Cargo silently ignores them and
    -- resolves the host (build script/proc-macro) linker on its own,
    -- defeating the MinGW GCC override.
    if host_config_written then
        table.join2(args, {"-Z", "host-config", "-Z", "target-applies-to-host"})
    end
    table.join2(args, {
        "--manifest-path", manifest,
        "--target", opt.rust_target,
        "--lib"
    })
    if opt.optimize then
        table.insert(args, "--release")
    end
    return args
end

-- No lockfile requirement: the crate policy is zero third-party
-- dependencies, so Cargo.lock is untracked and regenerated freely. If the
-- policy ever changes, the day the first dependency lands is the day to
-- commit Cargo.lock and restore --locked here (see rust_rules.md).
local function check_inputs(manifest)
    if not os.isfile(manifest) then
        errors.fail("Rust crate manifest does not exist: %s", manifest)
    end
    if not toolchain.cargo_installed() then
        errors.fail("project-local nightly Cargo is required to build the Rust crate; run `xmake toolchains install rust`")
    end
end

-- Compiles the crate (and its dependencies) into the staticlib.
--   opt: manifest, rust_target, optimize, work_root
-- Returns { staticlib }. Cargo owns freshness: an up-to-date tree is a
-- sub-second no-op, so this runs unconditionally per build.
function build(opt)
    local manifest = path.absolute(opt.manifest)
    check_inputs(manifest)

    local work_root = path.absolute(opt.work_root)
    os.mkdir(work_root)
    local cargo_envs, host_config_written = cargo_environment(work_root, manifest, opt)

    errors.log("compiling Rust crate")
    -- `cargo rustc --crate-type staticlib,rlib` rather than plain build: the
    -- manifest deliberately declares only rlib (an ordinary library), because
    -- declared crate-types are built even when the crate is a dependency, and
    -- a staticlib must be link-complete (allocator + panic handler) -- that
    -- requirement is exactly the engine coupling, so only the engine pipeline
    -- may ask for it. The staticlib is what makes rustc run its own
    -- final-link step, bundling core/alloc/compiler_builtins and synthesizing
    -- the allocator-shim symbols liballoc references.
    local args = common_args("rustc", manifest, opt, host_config_written)
    table.join2(args, {"--crate-type", "staticlib,rlib"})
    table.insert(args, "--message-format=json-render-diagnostics")
    local messages = os.iorunv(toolchain.cargo_path(), args, {
        curdir = work_root,
        envs = cargo_envs
    })

    local parsed = parse_build_messages(messages, {
        rust_target = opt.rust_target,
        cargo_target_dir = cargo_envs.CARGO_TARGET_DIR
    })
    for _, script in ipairs(parsed.native_requests) do
        errors.fail(
            "Rust dependency %s requests native linker inputs (%s); Cargo dependencies currently accept pure-Rust/no_std crates only because GCC owns the final link",
            script.package, table.concat(script.requests, ", "))
    end
    if not parsed.staticlib then
        errors.fail("Cargo build succeeded but produced no staticlib artifact for %s", opt.rust_target)
    end
    return {staticlib = parsed.staticlib}
end

-- Additive clippy gate over the same crate graph: cargo check with
-- clippy-driver as the workspace wrapper (exactly what `cargo clippy` does),
-- so only the engine crate is linted, never the dependencies. The deny bar
-- itself lives declaratively in the manifest's [lints] tables. Skipped when
-- clippy is not installed, leaving the build's own deny-warnings as the
-- floor. Cargo fingerprints the wrapper, so a clean re-check is a no-op.
function check(opt)
    local clippy = toolchain.clippy_driver_path()
    if not os.isfile(clippy) then
        return
    end
    local manifest = path.absolute(opt.manifest)
    check_inputs(manifest)

    local work_root = path.absolute(opt.work_root)
    os.mkdir(work_root)
    local cargo_envs, host_config_written = cargo_environment(work_root, manifest, opt)
    cargo_envs.RUSTC_WORKSPACE_WRAPPER = clippy

    errors.log("checking Rust crate with clippy")
    os.runv(toolchain.cargo_path(), common_args("check", manifest, opt, host_config_written), {
        curdir = work_root,
        envs = cargo_envs
    })
end

local function safe_remove_tree(candidate, owner)
    candidate = path.absolute(candidate)
    owner = path.absolute(owner)
    if not path_within(candidate, owner) or candidate == owner then
        errors.fail("refusing to replace Rust dependency object cache outside its owner: %s (owner %s)", candidate, owner)
    end
    os.tryrm(candidate)
end

-- The staticlib is a rustc product, not a foreign-linker input. Flatten its
-- object members under unique names before the Engine archive consumes
-- them; unique names prevent `ar r` from replacing equal-basename members
-- from different source archives. The members are read natively
-- (archive.lua) and each one is written straight to its short flattened
-- name: the previous `ar x` step materialized rustc's member names (84
-- characters observed) under the objectdir first, and with a deep build
-- directory (`xmake f -o <path>`) that crossed the Windows MAX_PATH ceiling
-- of the non-long-path-aware binutils, killing the extraction mid-archive
-- with `<member>.rcgu.o: No such file or directory`. Writing only
-- rust-NNNN-NNNN.o names keeps this step inside the same path budget as
-- every other objectdir artifact.
function unpack_objects(archives, output_dir, owner_dir)
    output_dir = path.absolute(output_dir)
    owner_dir = path.absolute(owner_dir)
    local marker = path.join(output_dir, ".unpacked")
    local signature_lines = {}
    for _, archive_file in ipairs(archives or {}) do
        table.insert(signature_lines, path.absolute(archive_file) .. "=" .. hash.sha256(archive_file))
    end
    local signature = table.concat(signature_lines, "\n") .. "\n"
    local object_dir = path.join(output_dir, "objects")
    if os.isfile(marker) and io.readfile(marker) == signature then
        local cached = table.join(
            os.files(path.join(object_dir, "*.o")),
            os.files(path.join(object_dir, "*.obj")))
        table.sort(cached)
        return cached
    end

    safe_remove_tree(output_dir, owner_dir)
    os.mkdir(object_dir)
    local objects = {}
    for archive_index, archive_file in ipairs(archives or {}) do
        local members = archive.object_members(archive_file)
        if #members == 0 then
            errors.fail("Rust staticlib contains no object members to absorb: %s", archive_file)
        end
        for member_index, member in ipairs(members) do
            local extension = member.name:lower():endswith(".obj") and ".obj" or ".o"
            local flattened = path.join(object_dir,
                string.format("rust-%04d-%04d%s", archive_index, member_index, extension))
            base.writefile_bytes(flattened, member.data)
            table.insert(objects, flattened)
        end
    end
    write_generated(marker, signature)
    table.sort(objects)
    return objects
end
