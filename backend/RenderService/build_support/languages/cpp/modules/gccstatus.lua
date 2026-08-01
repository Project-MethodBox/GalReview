-- Toolchain status reporting and the `xmake toolchains` CLI dispatch
-- (C++-specific): print_status, the project_gcc ar/ranlib tool-name
-- selection, and run_toolchains_command. The help/options actions stay in
-- the task shell in cpp/xmake.lua because their printers are
-- description-scope globals from commands_help.lua.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
local defaults = import("defaults", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")}).values()
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("hosttools", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("run", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("makerunner", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("checksums", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("gccsources")
import("gcctargets")
import("gccbuild")
import("hostboot")

-- os.scriptdir() is only trustworthy at module load time; capture the Rust
-- language-provider module directory now for the rust dispatch below.
local RUST_MODULES_DIR = path.join(os.scriptdir(), "..", "..", "rust", "modules")

-- Fixed matrix row order (mirrors the commands_help subject order, not the
-- targets/ directory enumeration order).
local MATRIX_SUBJECTS = {"windows", "linux", "android", "macosx", "ios", "emscripten"}

-- Real-machine verification evidence, keyed host_os -> subject. Static by
-- design: the matrix never infers "verified" from probes; update an entry
-- only after an actual on-host toolchain build plus smoke/engine-build
-- evidence lands (and keep the roadmap in sync). Qualifiers matter: e.g.
-- Windows->Linux evidence covers the musl pipeline only.
local VERIFIED_COMBOS = {
    windows = {
        windows = "yes (native, CI + local)",
        linux = "yes (musl cross, 2026-07-10)",
        android = "yes (aarch64, 2026-07-10)",
        emscripten = "yes (wasm32 engine build 2026-07-16; browser cross-origin-isolated console exec, owner-witnessed 2026-07-18)"
    },
    linux = {
        linux = "yes (native gnu 2026-07-11; musl cross exec + managed-glibc aarch64 cross, 2026-07-17; musl engine build + loader-run exec, 2026-07-18)",
        windows = "yes (cross build; test exe executed on a Windows host, 2026-07-17)",
        android = "yes (aarch64 .so smoke 2026-07-17; full engine test build, 2026-07-18)",
        emscripten = "yes (wasm32 engine build + node exec, 2026-07-17)"
    },
    macosx = {
        macosx = "yes (darwin-arm64, CI + device)",
        windows = "yes (PE32+ smoke, 2026-07-10)",
        ios = "yes (toolchain + std::string link probe + LC_BUILD_VERSION platform 2 verification, 2026-07-17)"
    }
}

-- Mirrored option fallbacks. options.lua owns the description-scope
-- originals (option() defaults are evaluated before any module can load, so
-- they cannot move here), and script scope cannot see description globals.
function print_status(target_os)
    target_os = target_os or settings.configured_target_os()
    local source = settings.gcc_source_profile(target_os)
    local source_dir = settings.gcc_source_dir(target_os)
    print("owner root:      " .. layout.owner_root())
    print("toolchains home: " .. layout.toolchains_home())
    print("cache root:      " .. layout.toolchains_cache_root())
    print("gcc source:      " .. source_dir)
    print("source profile:  " .. source.name)
    print("host os:         " .. base.host_os())
    print("host arch:       " .. settings.host_arch_folder())
    print("target os:       " .. target_os)
    print("target arch:     " .. settings.target_arch_folder(target_os))
    print("triplet:         " .. settings.managed_target(target_os))
    print("prefix:          " .. settings.gcc_prefix(target_os))
    print("jobs:            " .. tostring(makerunner.make_jobs()))
    print("build type:      " .. settings.build_type())
    print("build optimize:  -O" .. settings.build_optimize())
    print("build debug:     " .. tostring(settings.build_debug_enabled()))
    print("build cflags:    " .. settings.build_cflags())
    print("build cxxflags:  " .. settings.build_cxxflags())
    print("build ldflags:   " .. settings.build_ldflags())
    print("target cflags:   " .. settings.target_cflags(target_os))
    print("target cxxflags: " .. settings.target_cxxflags(target_os))
    print("strip install:   " .. tostring(settings.strip_enabled()))
    if base.is_windows_host() then
        local host_info = hosttools.windows_host_info()
        print("host compiler:   " .. tostring(host_info.compiler or ""))
        print("host sysroot:    " .. tostring(host_info.sysroot or ""))
        if host_info.smoke_rejected then
            print("smoke rejected:  " .. tostring(host_info.smoke_rejected))
        end
        print("bootstrap:       " .. tostring(settings.value_or("toolchains_bootstrap", "auto")))
        print("bootstrap url:   " .. tostring(settings.value_or("toolchains_bootstrap_url", defaults.windows_bootstrap_url or "latest")))
        print("bootstrap path:  " .. tostring(settings.value_or("toolchains_bootstrap_path", "")))
        print("bootstrap active: " .. tostring(hosttools.windows_bootstrap_state().active_bin or ""))
    end
    local provider = gcctargets.provider_of(target_os)
    if provider.status_lines then
        provider.status_lines(target_os)
    end
    print("compiler exists: " .. tostring(gccbuild.compiler_exists(target_os)))
    print("installed:       " .. tostring(gccbuild.toolchain_installed(target_os, {read_only = true})))
    print("source synced:   " .. tostring(os.isfile(path.join(source_dir, "configure"))))
    print("source git url:  " .. source.url)
    print("source git ref:  " .. source.ref)
    print("source revision: " .. gccsources.managed_toolchains_gcc_source_revision(source_dir))
    print("proxy env:       " .. tostring((os.getenv("HTTP_PROXY") or os.getenv("HTTPS_PROXY") or os.getenv("ALL_PROXY") or os.getenv("http_proxy") or os.getenv("https_proxy") or os.getenv("all_proxy")) ~= nil))
end

-- Matrix column probes. Hard constraint: everything the matrix touches is
-- read-only -- no download, no build, no configure. Missing prerequisites
-- come from the providers' preflight_warnings splits (the loud preflight
-- wraps the same probe), smoke state from the optional smoke_state hook.

local function matrix_smoke_text(subject)
    local provider = gcctargets.provider_of(subject)
    if not provider.smoke_state then
        -- for GCC targets without a dedicated smoke, the engine test suites
        -- are the smoke; that is outside this command's scope
        return "-"
    end
    return tostring(provider.smoke_state(subject))
end

local function matrix_missing_text(subject)
    local provider = gcctargets.provider_of(subject)
    if not provider.preflight_warnings then
        return "-"
    end
    local ok, warnings = errors.trycall(function ()
        return (provider.preflight_warnings(subject))
    end)
    if not ok then
        return "probe failed: " .. tostring(warnings)
    end
    warnings = warnings or {}
    if #warnings == 0 then
        return "-"
    end
    -- warnings may carry embedded newlines (guidance text); keep the row on
    -- one line
    local first = (tostring(warnings[1]):gsub("%s*\r?\n%s*", "; "))
    if #warnings == 1 then
        return first
    end
    return string.format("%s [+%d more; see `xmake toolchains status %s`]", first, #warnings - 1, subject)
end

local function print_matrix_rust_row()
    local rust = import("toolchain", {rootdir = RUST_MODULES_DIR})
    print(string.format("%-11s nightly=%s installed=%s cargo=%s prefix=%s",
        "rust",
        tostring(rust.pinned_nightly()),
        tostring(rust.host_installed()),
        tostring(rust.cargo_installed()),
        tostring(rust.rust_prefix())))
end

-- `xmake toolchains matrix [subject]`: one-line-per-target-OS overview of
-- the cross-toolchain state on this host, plus a rust summary row. Values
-- come from the same probes `status` uses, so the two commands can never
-- disagree; the verified column is the static registry above.
function print_matrix(filter)
    local subjects = MATRIX_SUBJECTS
    local rust_row = true
    if filter and filter ~= "" and filter ~= "all" then
        if filter == "rust" then
            subjects = {}
        else
            local known = false
            for _, name in ipairs(MATRIX_SUBJECTS) do
                if name == filter then
                    known = true
                end
            end
            if not known then
                errors.fail("unknown matrix subject: %s; use windows, linux, android, macosx, ios, emscripten, rust, or host", tostring(filter))
            end
            subjects = {filter}
            rust_row = false
        end
    end
    local host = base.host_os()
    print("cross-toolchain matrix (read-only; probes never download or build)")
    print("host: " .. host .. "/" .. settings.host_arch_folder()
        .. "  configured target: " .. settings.configured_target_os())
    print("")
    local row = "%-11s %-26s %-6s %-17s %-13s %-7s %-10s %-6s %-38s %s"
    print(string.format(row, "subject", "triplet", "arch", "profile", "ref", "synced",
        "installed", "smoke", "verified", "missing prerequisites"))
    for _, subject in ipairs(subjects) do
        local source = settings.gcc_source_profile(subject)
        local ref = tostring(source.ref or "")
        if #ref > 12 then
            ref = ref:sub(1, 12)
        end
        print(string.format(row,
            subject,
            settings.managed_target(subject),
            settings.target_arch_folder(subject),
            source.name,
            ref,
            tostring(os.isfile(path.join(settings.gcc_source_dir(subject), "configure"))),
            tostring(gccbuild.toolchain_installed(subject, {read_only = true})),
            matrix_smoke_text(subject),
            (VERIFIED_COMBOS[host] or {})[subject] or "no",
            matrix_missing_text(subject)))
    end
    if rust_row then
        print("")
        print_matrix_rust_row()
    end
    print("")
    print("verified = real-machine build + smoke evidence for host " .. host
        .. " (static registry; updated only after new on-host verification)")
    print("run `xmake toolchains status <subject>` for full per-subject detail")
end

function project_gcc_ar_tool_name(target_os)
    return gcctargets.target_tools(target_os).ar
end

function project_gcc_ranlib_tool_name(target_os)
    return gcctargets.target_tools(target_os).ranlib
end

-- The help/options actions are answered by the task shell in cpp/xmake.lua
-- (their printers are description-scope globals from commands_help.lua that
-- script-scope modules cannot see); a bare `help` reaching this function
-- would fall through to the unknown-command failure.
function run_toolchains_command(action, subject)
    action = (action and action ~= "") and action or "status"
    if action == "features" then
        errors.fail("GCC features are xmake.lua/config settings, not a toolchains command; run `xmake toolchains help features`")
    end
    -- read-only supply-chain inventory: pinned coverage plus this host's
    -- trust-on-first-use records, printed as paste-ready registry entries so
    -- observed digests can graduate into core/modules/checksums.lua after
    -- the owner re-establishes them first-hand
    if action == "checksums" then
        local pinned = 0
        for _ in pairs(checksums.registry()) do
            pinned = pinned + 1
        end
        print(string.format("pinned archive digests: %d (core/modules/checksums.lua)", pinned))
        local records = checksums.tofu_records()
        if #records == 0 then
            print("trust-on-first-use records on this host: none")
            return
        end
        print(string.format("trust-on-first-use records on this host: %d", #records))
        print("re-establish each digest first-hand (upstream signature, official manifest,")
        print("or multi-source cross-check) before pinning; paste-ready form:")
        print("")
        for _, record in ipairs(records) do
            print(string.format('    ["%s"] = {', record.leaf))
            print('        algorithm = "sha256",')
            print(string.format('        value = "%s",', record.sha256))
            print(string.format('        via = "TOFU on %s host, first seen %s; re-establish first-hand before pinning"',
                base.host_os(), record.first_seen))
            print("    },")
        end
        return
    end

    -- matrix reports every subject when none is given, so it consumes the
    -- raw subject before the configured-target default below is applied
    if action == "matrix" then
        local filter = (subject and subject ~= "") and subject or nil
        if filter == "host" then
            filter = base.host_os()
        end
        print_matrix(filter)
        return
    end
    subject = (subject and subject ~= "") and subject or settings.configured_target_os()
    if subject == "host" then
        subject = base.host_os()
    end
    -- the Rust toolchain is a language provider, not a GCC target OS: it has
    -- its own dist-tarball install/update flow under languages/rust
    -- config pin: record the intended plat/arch/mode so the drift sentinel
    -- can warn when a bare `xmake f` or implicit reconfigure resets them
    if action == "pin" then
        if subject == "clear" then
            if settings.clear_config_pin() then
                print("configuration pin cleared")
            else
                print("no configuration pin was set")
            end
        else
            local plat, arch, mode = settings.write_config_pin()
            print(string.format("pinned configuration: %s/%s/%s (drift now warns on every configure)", plat, arch, mode))
        end
        return
    end

    if subject == "rust" then
        local rust = import("toolchain", {rootdir = RUST_MODULES_DIR})
        if action == "status" then
            rust.status()
        elseif action == "install" or action == "bootstrap" or action == "build" then
            local gcc_triplet = settings.managed_target(settings.configured_target_os())
            rust.install({rust.rust_target_for(gcc_triplet)})
            print("project-local Rust toolchain ready: " .. rust.rust_prefix())
        elseif action == "update" then
            rust.update()
        else
            errors.fail("unsupported rust toolchain command: %s; use status, install, or update", tostring(action))
        end
        return
    end
    -- effective-configuration banner for every state-changing action: the
    -- config traps this manager has hit live (arch residue selecting the
    -- wrong source profile, implicit reconfigures resetting plat) are all
    -- visible in this one line, so the operator never has to remember to
    -- cross-check `status` first
    if action ~= "status" then
        -- when the project config still carries a different arch than the
        -- managed (possibly clamped) toolchain arch, say so explicitly --
        -- printing only the managed side would hide exactly the residue the
        -- banner exists to expose
        local configured = base.canonical_arch(settings.configured_arch(), subject)
        local managed = settings.target_arch(subject)
        local arch_text = settings.target_arch_folder(subject)
        if configured ~= managed then
            arch_text = string.format("configured arch %s -> managed %s", tostring(configured), tostring(managed))
        end
        print(string.format("toolchains %s: subject %s, triplet %s (%s), profile %s",
            tostring(action), tostring(subject), settings.managed_target(subject),
            arch_text, settings.gcc_source_profile(subject).name))
    end
    if action == "status" then
        print_status(subject)
    elseif action == "fetch" or action == "sync" then
        run.run_stage("sync GCC source", subject, function ()
            gccsources.sync_gcc_source(subject, true, false)
            local provider = gcctargets.provider_of(subject)
            if provider.on_fetch then
                provider.on_fetch(subject)
            end
        end)
    elseif action == "install" or action == "bootstrap" then
        if gccbuild.toolchain_installed(subject) then
            gccbuild.finalize_existing_toolchain_install(subject)
            print("project-local GCC already installed: " .. settings.gcc_prefix(subject))
        else
            gccbuild.build_gcc_for(subject, {skip_if_installed = true})
        end
    elseif action == "update" then
        run.run_stage("update GCC source", subject, function ()
            local source_dir = settings.gcc_source_dir(subject)
            local before_revision = gccsources.managed_toolchains_gcc_source_revision(source_dir)
            gccsources.sync_gcc_source(subject, false, false, true)
            gccsources.report_tracking_branch_drift(subject)
            local after_revision = gccsources.managed_toolchains_gcc_source_revision(source_dir)
            if before_revision ~= "" and after_revision ~= "" and before_revision == after_revision then
                print("GCC source is already up to date; no compiler rebuild is needed")
                return
            end
            if gccbuild.compiler_exists(subject) then
                print("GCC source changed; rebuilding with existing build cache")
                gccbuild.build_gcc_for(subject)
            else
                print("source updated; no installed toolchain was rebuilt")
            end
        end)
    elseif action == "bundle" then
        run.run_stage("create source bundle", subject, function ()
            gccsources.create_gcc_source_bundle(subject)
            local provider = gcctargets.provider_of(subject)
            if provider.on_bundle then
                provider.on_bundle(subject)
            end
        end)
    elseif action == "build" then
        print("`xmake toolchains build` now only manages the toolchain; project binaries are built by plain `xmake`.")
        gccbuild.build_gcc_for(subject)
    elseif action == "smoke" or action == "verify" then
        local provider = gcctargets.provider_of(subject)
        if not provider.smoke_refresh then
            errors.fail("the smoke toolchain command currently supports only targets with dedicated smoke hooks: emscripten, macosx")
        end
        -- a provider may declare the whole command a no-op for this host
        -- BEFORE the install-or-refresh decision below; without this, a
        -- fresh checkout would start a full toolchain build whose result
        -- the no-op smoke never uses
        if provider.smoke_noop_reason then
            local reason = provider.smoke_noop_reason(subject)
            if reason then
                print(reason)
                return
            end
        end
        -- the full outer gate (compiler + config signature + provider
        -- installed_extra): an SDK or backend-tool swap must route through
        -- the rebuild instead of smoking the old toolchain and stamping the
        -- new identity over it
        if not gccbuild.toolchain_installed(subject) then
            gccbuild.build_gcc_for(subject, {skip_if_installed = true})
        else
            provider.smoke_refresh(subject)
        end
        provider.smoke_link(subject)
    elseif action == "rebuild" or action == "repatch" then
        run.run_stage("rebuild GCC from source", subject, function ()
            local build = settings.gcc_build_dir(subject)
            if os.isdir(build) then
                print("discarding cached GCC build directory for a clean patched rebuild: " .. build)
                gccbuild.reset_build_dir(build)
            end
            local binutils = settings.binutils_build_dir(subject)
            if os.isdir(binutils) then
                gccbuild.reset_build_dir(binutils)
            end
            -- Drop the installed-binutils identity so build_binutils_for does
            -- not short-circuit on the existing as/ld -- a clean patched
            -- rebuild must actually rebuild binutils too.
            os.tryrm(gccbuild.managed_toolchains_binutils_identity_file(subject))
            local provider = gcctargets.provider_of(subject)
            if provider.on_rebuild_reset then
                provider.on_rebuild_reset(subject)
            end
            -- a from-scratch reconfigure needs a bootstrap host toolchain whose
            -- bin directory is reliably first on the build PATH (cc1 is found via
            -- PATH); force a project-private one so rebuild does not depend on a
            -- possibly-shadowed host MinGW under a spaced install path.
            hostboot.set_force_private_bootstrap(true)
            gccbuild.build_gcc_for(subject)
        end)
    else
        errors.fail("unknown toolchains command: %s; run `xmake toolchains help`", action)
    end
end
