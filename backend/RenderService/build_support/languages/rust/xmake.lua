-- Rust language provider: description shell only. The engine's Rust side is
-- ONE Cargo package (repo-root Cargo.toml, [lib] path = the rs/ tree), so
-- Cargo owns crate compilation, dependency resolution and freshness; this
-- rule validates the tree, invokes Cargo (build + clippy gate), unpacks the
-- staticlib product and injects its object members into the engine archive.
-- GCC/emcc still performs the final link.
--
-- Hook shape (empirically forced, inherited from the previous design):
--   * on_config only fires when the configuration changes, so it cannot own
--     per-build work;
--   * target:add("objectfiles") from rule hooks never reaches the archive
--     job -- its input list is materialized before the hooks run;
--   * therefore before_build produces the objects (Cargo's own fingerprints
--     make a clean rebuild a sub-second no-op) and after_link injects them
--     into the produced archive with `ar rs` (insert-or-replace + index
--     refresh, idempotent; see the after_link hook comment for why
--     after_build races dependent linkers).

local RUST_MODULES_DIR = path.join(os.scriptdir(), "modules")
local CORE_MODULES_DIR = path.join(os.scriptdir(), "..", "..", "core", "modules")

option("rust_nightly")
    set_default("")
    set_showmenu(true)
    set_description("Pinned Rust nightly dist date (YYYY-MM-DD); empty uses the pin file. A first install resolves the newest published nightly and writes the pin; `xmake toolchains update rust` moves it later")
option_end()


-- Declares the crate's source root (the directory the Cargo manifest's [lib]
-- path reaches into; its crate root must be <rootdir>/lib.rs).
function add_rustfiles(rootdir)
    add_rules("rust.cargo.require_rule")
    add_values("rust.cargo.rootdirs", rootdir)
end

-- Declares the Cargo manifest that owns the engine's Rust crate and its
-- third-party dependencies. Cargo compiles the crate graph into a staticlib;
-- the rust.cargo rule absorbs its object members into the engine archive.
function add_rustmanifest(manifest)
    add_rules("rust.cargo.require_rule")
    add_values("rust.cargo.manifests", manifest)
end

-- Optional: declares the prefix every #[no_mangle]/#[export_name] symbol
-- must carry (flat-namespace collision policy; ABI-mandated names stay
-- whitelisted in validate.lua). The prefix is project policy, so it lives in
-- the project's xmake.lua -- omit the declaration to skip prefix validation
-- entirely (owner-confirmed keeper, 2026-08-02: cheap machine enforcement of
-- a real risk -- bare exported names silently collide in the flat namespace,
-- and static-archive resolution does not always fail loudly).
function add_rustexportprefix(prefix)
    add_rules("rust.cargo.require_rule")
    add_values("rust.cargo.export_prefix", prefix)
end

rule("rust.cargo.require_rule")
    on_load(function (target)
        if target:rule("rust.cargo") then
            return
        end
        import("catalog", {rootdir = CORE_MODULES_DIR})
        import("errors", {rootdir = CORE_MODULES_DIR}).fail(
            "add_rustfiles/add_rustmanifest requires add_rules(\"rust.cargo\") on target %s", target:name())
    end)

rule("rust.cargo")
    on_load(function (target)
        import("catalog", {rootdir = CORE_MODULES_DIR})
        local errors = import("errors", {rootdir = CORE_MODULES_DIR})
        local rootdirs = table.wrap(target:values("rust.cargo.rootdirs"))
        if #rootdirs ~= 1 then
            errors.fail(
                "rust.cargo on target %s requires exactly one add_rustfiles(\"<rootdir>\") declaration; found %d",
                target:name(), #rootdirs)
        end
        if type(rootdirs[1]) ~= "string" or rootdirs[1] == "" then
            errors.fail("add_rustfiles root on target %s must be a non-empty path string", target:name())
        end
        target:data_set("rust.cargo.rootdir", path.absolute(rootdirs[1], target:scriptdir()))

        local manifests = table.wrap(target:values("rust.cargo.manifests"))
        if #manifests ~= 1 then
            errors.fail(
                "rust.cargo on target %s requires exactly one add_rustmanifest(\"<Cargo.toml>\") declaration; found %d",
                target:name(), #manifests)
        end
        if type(manifests[1]) ~= "string" or manifests[1] == "" then
            errors.fail("add_rustmanifest path on target %s must be a non-empty path string", target:name())
        end
        target:data_set("rust.cargo.manifest", path.absolute(manifests[1], target:scriptdir()))
    end)

    before_build(function (target)
        -- only the static engine archive absorbs the crate; executables
        -- receive the code through that archive (a second copy would collide)
        if not target:is_static() then
            return
        end
        local cargo = import("cargo", {rootdir = RUST_MODULES_DIR})
        local toolchain = import("toolchain", {rootdir = RUST_MODULES_DIR})
        local settings = import("settings", {rootdir = CORE_MODULES_DIR})
        import("catalog", {rootdir = CORE_MODULES_DIR})
        local errors = import("errors", {rootdir = CORE_MODULES_DIR})
        local config = import("core.project.config")

        local rootdir = target:data("rust.cargo.rootdir")
        local sources = os.files(path.join(rootdir, "**.rs"))
        if #sources == 0 then
            return
        end
        local root_file = path.join(rootdir, "lib.rs")
        if not os.isfile(root_file) then
            errors.fail(
                "rust crate root %s does not exist; the crate root must be lib.rs directly under the add_rustfiles root and the Cargo manifest's [lib] path must point at it",
                root_file)
        end

        -- aggregate-style validation: orphan mod-tree files, #![no_std]
        -- policy, project-declared export prefix (all problems in one pass)
        local export_prefix = table.wrap(target:values("rust.cargo.export_prefix"))[1]
        import("validate", {rootdir = RUST_MODULES_DIR}).run({
            root_file = root_file,
            sources = sources,
            export_prefix = export_prefix
        })

        local gcc_triplet = settings.managed_target(settings.configured_target_os())
        local rust_target = toolchain.rust_target_for(gcc_triplet)
        local manifest = target:data("rust.cargo.manifest")

        -- provision the pinned toolchain on demand, mirroring toolchains.auto;
        -- Cargo is always required now (it owns the whole crate build), wasm
        -- additionally needs rust-src + rust-objcopy for build-std. A target
        -- without a prebuilt std (64-bit wasm) must not be waited on to appear:
        -- build-std is what supplies its core/alloc, so demanding a rust-std
        -- directory would re-enter the installer forever.
        local needs_wasm = toolchain.is_wasm_target(rust_target)
        local std_ready = not toolchain.has_prebuilt_std(rust_target)
            or toolchain.target_std_installed(rust_target)
        if settings.config_bool("toolchains_auto", true) then
            if not (toolchain.host_installed() and std_ready
                and toolchain.clippy_installed() and toolchain.cargo_installed()
                and (not needs_wasm or (toolchain.host_objcopy_installed()
                    and toolchain.sysroot_src_installed()))) then
                errors.log("bootstrapping missing project-local Rust toolchain")
                toolchain.install({rust_target})
            end
        end
        if not toolchain.host_installed() then
            errors.fail("project-local Rust toolchain is not installed; run `xmake toolchains install rust`")
        end

        local mode = tostring(config.get("mode") or "release")
        local built = cargo.build({
            manifest = manifest,
            rust_target = rust_target,
            optimize = mode ~= "debug",
            work_root = path.join(target:objectdir(), "rust", ".cargo-" .. rust_target)
        })

        -- additive clippy gate over the same graph (deny bar declared in the
        -- manifest's [lints]; a clean re-check is a Cargo-cached no-op)
        cargo.check({
            manifest = manifest,
            rust_target = rust_target,
            optimize = mode ~= "debug",
            work_root = path.join(target:objectdir(), "rust", ".cargo-" .. rust_target)
        })

        local objects = cargo.unpack_objects({built.staticlib},
            path.join(target:objectdir(), "rust", ".staticlib-" .. rust_target),
            target:objectdir())

        -- Force the archive to relink whenever the unpacked member set
        -- changes. after_link injects with `ar rs` (replace, never delete),
        -- so a shrinking member set must first recreate the archive from C++
        -- alone or stale Rust objects would linger inside it.
        local member_names = {}
        for _, object in ipairs(objects) do
            table.insert(member_names, path.filename(object))
        end
        local set_signature = rust_target .. "\n" .. table.concat(member_names, "\n") .. "\n"
        local set_file = path.join(target:objectdir(), "rust", ".crate-set")
        local prev_signature = os.isfile(set_file) and io.readfile(set_file) or ""
        if prev_signature ~= set_signature then
            if os.isfile(target:targetfile()) then
                os.tryrm(target:targetfile())
            end
            os.mkdir(path.directory(set_file))
            io.writefile(set_file, set_signature)
        end

        target:data_set("rust.cargo.objects", objects)
    end)
    -- after_link, NOT after_build: after_build hooks run outside the job
    -- graph's dependency ordering, so a dependent executable could link
    -- against the archive while `ar rs` rewrites it (observed as "file
    -- format not recognized"/"file truncated" corruption races). after_link
    -- stays inside the target's link phase, which dependents wait for.
    after_link(function (target)
        local objects = target:data("rust.cargo.objects")
        if not objects or #objects == 0 then
            return
        end
        local errors = import("errors", {rootdir = CORE_MODULES_DIR})
        local archive = target:targetfile()
        if not os.isfile(archive) then
            errors.fail("cannot inject Rust objects: target archive does not exist: %s", archive)
        end
        local ar_program = import("cargo", {rootdir = RUST_MODULES_DIR}).resolve_archiver(target)
        -- batched invocations: 150+ object paths overflow the Windows
        -- command-line limit, and @response-files are GNU-only (the macOS
        -- toolchain stages Apple's BSD ar, which treats "@file" as a member
        -- name). Fixed-size batches work with both ar flavors everywhere.
        local batch = {}
        local function flush()
            if #batch > 0 then
                os.vrunv(ar_program, table.join({"rs", archive}, batch))
                batch = {}
            end
        end
        for _, object in ipairs(objects) do
            table.insert(batch, object)
            if #batch >= 40 then
                flush()
            end
        end
        flush()
    end)

-- Experimental Rust-entry scaffold: `xmake rust export-link` writes the C++
-- link contract (JSON + GNU @response file) plus the entry package's
-- .cargo/config.toml, so a cargo-driven binary can link the engine's raw
-- C++ objects through the project g++ driver. See rust_rules.md §5.
task("rust")
    set_category("plugin")
    on_run(function ()
        -- plugin tasks do not auto-load the project configuration (see the
        -- `xmake toolchains` task note); settings/target resolution needs it
        import("core.project.config").load()
        import("catalog", {rootdir = CORE_MODULES_DIR})
        local option = import("core.base.option")
        local errors = import("errors", {rootdir = CORE_MODULES_DIR})
        local action = option.get("action") or "export-link"
        if action == "export-link" then
            import("link_export", {rootdir = RUST_MODULES_DIR}).run({})
        else
            errors.fail("unknown xmake rust action %s; available actions: export-link", action)
        end
    end)
    set_menu {
        usage = "xmake rust [export-link]",
        description = "Rust-entry link contract export (experimental scaffold)",
        options = {
            {nil, "action", "v", "export-link", "export-link: write the C++ object contract (JSON + @response) and the entry .cargo/config.toml"}
        }
    }
