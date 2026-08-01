-- Project-local Rust nightly toolchain, assembled from the official dist
-- standalone tarballs (never rustup: no global state, no self-update). The
-- spike-verified facts this module is built on:
--   * rustc and every rust-std component MUST come from the same dated dist
--     directory -- crate metadata is checked by exact compiler commit;
--   * the dist components overlay into one prefix (rustc/* + each
--     rust-std-<target>/*), and rustc derives its sysroot from its own
--     binary location, so no --sysroot plumbing is needed afterwards;
--   * Windows host tarballs are .tar.xz and extract with the host tar.
--
-- Layout: .toolchains/<host>/rust/<nightly-date>/ (bin/, lib/rustlib/...).
-- Pinning: the active date comes from the rust_nightly option/env, then the
-- pin file, then DEFAULT_NIGHTLY. A first install with no explicit pin
-- resolves the newest published nightly and writes the pin file -- Rust is
-- consumed as prebuilt official dist (no source build, no local patches to
-- break), so unlike the pinned-by-necessity GCC source stack the newest
-- nightly is the right first-install default (owner decision 2026-07-25).
-- `xmake toolchains update rust` moves the pin later.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("download", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("install_lock", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})

-- Compatibility anchor only: prefixes installed before first-install-resolves-
-- newest landed (2026-07-25) carry no pin file, and their component overlays
-- (clippy, rust-std, the rustc self-heal) must keep matching what is on disk.
-- A fresh first install never uses this date -- it resolves the newest
-- published nightly instead.
local DEFAULT_NIGHTLY = "2026-02-18"
local DIST_BASE = "https://static.rust-lang.org/dist"

-- GCC triplet -> rustc target, the frozen-design alignment table. windows
-- MUST map to -gnu (MinGW ABI/CRT), never -msvc.
local RUST_TARGETS = {
    ["x86_64-w64-mingw32"] = "x86_64-pc-windows-gnu",
    ["aarch64-w64-mingw32"] = "aarch64-pc-windows-gnullvm",
    ["x86_64-linux-gnu"] = "x86_64-unknown-linux-gnu",
    ["x86_64-linux-musl"] = "x86_64-unknown-linux-musl",
    ["aarch64-linux-gnu"] = "aarch64-unknown-linux-gnu",
    ["aarch64-linux-musl"] = "aarch64-unknown-linux-musl",
    ["aarch64-linux-android"] = "aarch64-linux-android",
    ["arm-linux-androideabi"] = "armv7-linux-androideabi",
    ["x86_64-linux-android"] = "x86_64-linux-android",
    ["i686-linux-android"] = "i686-linux-android",
    ["wasm32-unknown-emscripten"] = "wasm32-unknown-emscripten",
    -- iOS device: a fixed triplet with no darwin-style version suffix (see
    -- settings.default_triplet), so it keys the table directly, unlike the
    -- version-suffixed *-apple-darwin case handled by the fallback below.
    -- Simulator/catalyst (different rustc targets) stay unmapped until their
    -- phase lands, and fail loudly rather than mis-map to the device target.
    ["aarch64-apple-ios"] = "aarch64-apple-ios"
}

function rust_target_for(gcc_triplet)
    gcc_triplet = tostring(gcc_triplet or "")
    local mapped = RUST_TARGETS[gcc_triplet]
    if mapped then
        return mapped
    end
    -- apple triplets carry a darwin version suffix (x86_64-apple-darwin20)
    local apple_arch = gcc_triplet:match("^([%w_]+)%-apple%-darwin")
    if apple_arch then
        return apple_arch .. "-apple-darwin"
    end
    errors.fail("no rustc target mapping for GCC triplet %s; extend RUST_TARGETS in languages/rust/modules/toolchain.lua", gcc_triplet)
end

function host_rust_target()
    local host = base.host_os()
    local arch = base.canonical_arch(os.arch(), host)
    if host == "windows" then
        return arch == "x86_64" and "x86_64-pc-windows-gnu" or (arch .. "-pc-windows-gnullvm")
    elseif host == "macosx" then
        return arch .. "-apple-darwin"
    end
    return arch .. "-unknown-linux-gnu"
end

function rust_home()
    return path.join(layout.toolchains_home(), base.host_os(), "rust")
end

-- True when any target of the loaded project attaches the rust.cargo rule --
-- the single opt-in that says "this project ships Rust". Toolchain-level
-- stages (e.g. the wasm smoke's Rust leg) consult this so a build_support
-- checkout embedded in a C++-only project never provisions Rust on its own;
-- explicit commands (`xmake toolchains install rust`) stay unaffected. When
-- no project is loadable in the calling context the answer is conservatively
-- false -- Rust work must never start as a side effect of a failed probe.
function project_enables_rust()
    local ok, enabled = errors.trycall(function ()
        local project = import("core.project.project")
        for _, target in pairs(project.targets()) do
            if target:rule("rust.cargo") then
                return true
            end
        end
        return false
    end)
    return ok == true and enabled == true
end

local function pin_file()
    return path.join(rust_home(), "pin")
end

function pinned_nightly()
    local configured = tostring(settings.value_or("rust_nightly", ""))
    if configured ~= "" then
        return configured
    end
    local file = pin_file()
    if os.isfile(file) then
        local pinned = base.trim(io.readfile(file) or "")
        if pinned ~= "" then
            return pinned
        end
    end
    return DEFAULT_NIGHTLY
end

-- True when the date is explicitly chosen (option/env or pin file) rather than
-- falling through to the built-in default.
local function has_explicit_pin()
    if tostring(settings.value_or("rust_nightly", "")) ~= "" then
        return true
    end
    local file = pin_file()
    return os.isfile(file) and base.trim(io.readfile(file) or "") ~= ""
end

-- Pure parser for the channel manifest's `date = "YYYY-MM-DD"` line (the
-- manifest is TOML but this one line is all we need; fixture-tested).
function parse_nightly_date(manifest_text)
    return (tostring(manifest_text or "")):match('date%s*=%s*"(%d%d%d%d%-%d%d%-%d%d)"')
end

-- Downloads the current channel manifest and returns the newest published
-- nightly date. Shared by the first install and `xmake toolchains update rust`.
function resolve_newest_nightly()
    local manifest_url = DIST_BASE .. "/channel-rust-nightly.toml"
    local staging = path.join(layout.toolchains_cache_root(), "rust", "channel-rust-nightly.toml")
    -- force: resolution must always look at the CURRENT channel manifest
    download.download_file(manifest_url, staging, true)
    local date = parse_nightly_date(io.readfile(staging) or "")
    if not date then
        errors.fail("cannot parse the nightly date from %s", manifest_url)
    end
    return date
end

function rust_prefix()
    return path.join(rust_home(), pinned_nightly())
end

function rustc_path()
    return path.join(rust_prefix(), "bin", base.exe("rustc"))
end

function rustdoc_path()
    return path.join(rust_prefix(), "bin", base.exe("rustdoc"))
end

function cargo_path()
    return path.join(rust_prefix(), "bin", base.exe("cargo"))
end

-- clippy-driver is the rustc-shaped lint front end: it is fed the same argv as
-- a crate's real compile plus the clippy lint groups. Host-only (lints run on
-- the build host) and version-locked to rustc, since it links rustc's internal
-- driver library from the same dated dist.
function clippy_driver_path()
    return path.join(rust_prefix(), "bin", base.exe("clippy-driver"))
end

function clippy_installed()
    return os.isfile(clippy_driver_path())
end

function target_lib_dir(rust_target)
    return path.join(rust_prefix(), "lib", "rustlib", rust_target, "lib")
end

-- The exact link ingredients a no_std crate needs besides its own object
-- (spike-verified). liballoc is always part of the set -- the engine allocator
-- bridge is a permanent part of rs/runtime, so every crate's heap resolves.
function core_rlibs(rust_target, opt)
    local libdir = target_lib_dir(rust_target)
    local stems = {"libcore-*.rlib", "libcompiler_builtins-*.rlib", "liballoc-*.rlib"}
    local ingredients = {}
    for _, stem in ipairs(stems) do
        local matches = os.files(path.join(libdir, stem))
        if #matches == 0 then
            errors.fail("rust-std for %s is missing %s under %s; run `xmake toolchains install rust`", rust_target, stem, libdir)
        end
        table.insert(ingredients, matches[1])
    end
    return ingredients
end

local function component_url(component, rust_target, date)
    return string.format("%s/%s/%s-nightly-%s.tar.xz", DIST_BASE, date, component, rust_target)
end

-- Overlay one dist component (already extracted) into the prefix.
-- File-level copy on purpose: directory-level os.cp REPLACES an existing
-- destination directory, so overlaying a second component would silently
-- delete everything the first one put under prefix/lib (each rust-std
-- overlay nuked the previously installed target's rustlib -- observed).
local function overlay_component(extract_dir, inner_dir, prefix)
    local source = path.join(extract_dir, inner_dir)
    if not os.isdir(source) then
        errors.fail("dist component layout unexpected: %s does not exist", source)
    end
    for _, file in ipairs(os.files(path.join(source, "**"))) do
        local destination = path.join(prefix, path.relative(file, source))
        os.mkdir(path.directory(destination))
        os.cp(file, destination)
    end
end

local function install_component(component, rust_target, date, prefix, inner_dir)
    local staging = path.join(layout.toolchains_cache_root(), "rust", date, component .. "-" .. rust_target)
    local archive = path.join(layout.download_cache_dir(),
        string.format("%s-nightly-%s-%s.tar.xz", component, rust_target, date))
    local url = component_url(component, rust_target, date)
    download.download_and_extract_archive(url, archive, staging)
    local extracted = os.dirs(path.join(staging, component .. "-nightly-*"))[1]
    if not extracted then
        errors.fail("downloaded %s for %s did not contain a %s-nightly-* folder under %s", component, rust_target, component, staging)
    end
    overlay_component(extracted, inner_dir, prefix)
end

function host_installed()
    return os.isfile(rustc_path())
end

-- rustc ships its LLVM helper tools (rust-objcopy, rust-lld, gcc-ld,
-- wasm-component-ld) under lib/rustlib/<host>/bin. cargo build-std shells out
-- to rust-objcopy while compiling compiler_builtins, so a prefix that has
-- rustc but lost this self-contained bin -- a half-finished overlay, or a stale
-- pre-tools install -- must re-overlay the rustc component rather than die at
-- wasm build-std time (observed 2026-07-22: a macOS prefix with rustc present
-- but its rust-objcopy absent). rust-objcopy is the sentinel: re-overlaying
-- rustc restores the whole bin, so checking this one file is enough to trigger
-- the heal.
function host_selfcontained_bin_dir()
    return path.join(rust_prefix(), "lib", "rustlib", host_rust_target(), "bin")
end

function host_objcopy_path()
    return path.join(host_selfcontained_bin_dir(), base.exe("rust-objcopy"))
end

function host_objcopy_installed()
    return os.isfile(host_objcopy_path())
end

function cargo_installed()
    return os.isfile(cargo_path())
end

function target_std_installed(rust_target)
    return os.isdir(target_lib_dir(rust_target))
end

function sysroot_src_installed()
    return os.isdir(path.join(rust_prefix(), "lib", "rustlib", "src", "rust", "library"))
end

-- rust-src is target-independent (no triplet suffix in the tarball name) and
-- exists purely for tooling: rust-analyzer needs the sysroot sources for
-- source-level core:: navigation. Builds never read it.
local function install_rust_src(date, prefix)
    local staging = path.join(layout.toolchains_cache_root(), "rust", date, "rust-src")
    local archive = path.join(layout.download_cache_dir(), string.format("rust-src-nightly-%s.tar.xz", date))
    local url = string.format("%s/%s/rust-src-nightly.tar.xz", DIST_BASE, date)
    download.download_and_extract_archive(url, archive, staging)
    local extracted = os.dirs(path.join(staging, "rust-src-nightly*"))[1]
    if not extracted then
        errors.fail("downloaded rust-src did not contain a rust-src-nightly* folder under %s", staging)
    end
    overlay_component(extracted, "rust-src", prefix)
    if not sysroot_src_installed() then
        errors.fail("rust-src was installed but %s still does not exist; the dist component layout may have changed",
            path.join(prefix, "lib", "rustlib", "src", "rust", "library"))
    end
end

-- Ensures the host rustc plus rust-std for every requested rustc target.
-- targets: array of rustc target names (host std is always included since
-- rustc itself wants its own target's core for host-targeted builds).
function install(targets)
    -- Cross-process install lock: two xmake runs that both find the Rust
    -- toolchain missing would otherwise extract dist components into the same
    -- prefix concurrently and corrupt it. The lock file lives in rust_home()
    -- (date-independent), so the first-install pin resolution below is also
    -- serialized: the process that waited re-reads the pin the winner wrote and
    -- installs the very same dated dist. The per-component `..._installed()`
    -- checks below run under the lock, so a process that waited behind it
    -- reuses whatever the other one finished instead of re-extracting.
    return install_lock.guard(path.join(rust_home(), ".rust-install.lock"), function ()
    -- First install with no explicit pin: resolve the newest published nightly
    -- instead of silently aging on the built-in default. The resolved date is
    -- written to the pin file so every later overlay (clippy, rust-std, the
    -- rustc self-heal) stays on the exact same dated dist; machines already
    -- installed under the built-in default keep their on-disk date (the
    -- host_installed() guard) instead of drifting away from it.
    if not has_explicit_pin() and not host_installed() then
        local resolved = resolve_newest_nightly()
        os.mkdir(rust_home())
        io.writefile(pin_file(), resolved .. "\n")
        errors.log("first Rust toolchain install: resolved the newest published nightly %s", resolved)
    end
    local prefix = rust_prefix()
    local date = pinned_nightly()
    local host_target = host_rust_target()
    -- Cargo is part of the managed Rust toolchain even though it never owns
    -- Engine crate compilation or the final link: it resolves/builds locked
    -- third-party dependencies for every target and additionally orchestrates
    -- wasm build-std. rust-objcopy, however, is a wasm build-std requirement
    -- only and must not trigger a rustc re-overlay for ordinary targets.
    local needs_cargo = true
    local needs_wasm_objcopy = false
    for _, rust_target in ipairs(targets or {}) do
        if rust_target == "wasm32-unknown-emscripten" then
            needs_wasm_objcopy = true
        end
    end
    -- cargo build-std (wasm) shells out to rustc's self-contained rust-objcopy;
    -- an existing rustc that has lost it re-overlays the rustc component (which
    -- restores the whole self-contained bin) instead of failing at build time.
    local rustc_selfcontained_incomplete =
        needs_wasm_objcopy and host_installed() and not host_objcopy_installed()
    if not host_installed() or rustc_selfcontained_incomplete then
        if rustc_selfcontained_incomplete then
            errors.log("re-overlaying rustc for " .. host_target .. ": its self-contained rust-objcopy (needed by cargo build-std) is missing")
        else
            errors.log("installing project-local Rust nightly " .. date .. " for " .. host_target)
        end
        install_component("rustc", host_target, date, prefix, "rustc")
    end
    if needs_cargo and not cargo_installed() then
        errors.log("installing project-local Cargo nightly " .. date .. " for locked Rust dependencies and WebAssembly build-std")
        install_component("cargo", host_target, date, prefix, "cargo")
    end
    -- clippy is the additive lint gate over rustc's own -D warnings bar; the
    -- dist tarball's inner component directory is "clippy-preview".
    if not clippy_installed() then
        errors.log("installing project-local clippy nightly " .. date .. " for " .. host_target)
        install_component("clippy", host_target, date, prefix, "clippy-preview")
    end
    local wanted = {[host_target] = true}
    for _, rust_target in ipairs(targets or {}) do
        wanted[rust_target] = true
    end
    for rust_target in pairs(wanted) do
        if not target_std_installed(rust_target) then
            errors.log("installing rust-std for " .. rust_target .. " (nightly " .. date .. ")")
            install_component("rust-std", rust_target, date, prefix,
                path.join("rust-std-" .. rust_target))
            -- a silent half-install (bad overlay glob, poisoned staging,
            -- foreign layout) must stop here, not at first use
            if not target_std_installed(rust_target) then
                errors.fail("rust-std for %s was installed but %s still does not exist; the dist component layout may have changed",
                    rust_target, target_lib_dir(rust_target))
            end
        end
    end
    if not sysroot_src_installed() then
        errors.log("installing rust-src (rust-analyzer sysroot sources, nightly " .. date .. ")")
        install_rust_src(date, prefix)
    end
    if not host_installed() then
        errors.fail("Rust toolchain install finished but rustc is still missing: %s", rustc_path())
    end
    if needs_cargo and not cargo_installed() then
        errors.fail("Rust toolchain install finished but Cargo is still missing: %s", cargo_path())
    end
    if needs_wasm_objcopy and not host_objcopy_installed() then
        errors.fail("Rust toolchain install finished but rustc's self-contained rust-objcopy is still missing: %s (cargo build-std of compiler_builtins needs it)", host_objcopy_path())
    end
    if not clippy_installed() then
        errors.fail("Rust toolchain install finished but clippy-driver is still missing: %s", clippy_driver_path())
    end
    return prefix
    end)
end

-- Resolves the newest published nightly date and rewrites the pin file.
function update()
    local date = resolve_newest_nightly()
    local previous = pinned_nightly()
    os.mkdir(rust_home())
    io.writefile(pin_file(), date .. "\n")
    if previous == date then
        print("Rust nightly pin is already at the newest published date: " .. date)
    else
        print(string.format("Rust nightly pin moved: %s -> %s (run `xmake toolchains install rust` to fetch it)", previous, date))
    end
    return date
end

function status()
    local date = pinned_nightly()
    print(string.format("%-16s %s", "nightly pin:", date .. (os.isfile(pin_file()) and " (pin file)" or " (built-in default; a first install resolves the newest nightly)")))
    print(string.format("%-16s %s", "prefix:", rust_prefix()))
    print(string.format("%-16s %s", "rustc:", host_installed() and rustc_path() or "(not installed)"))
    print(string.format("%-16s %s", "cargo:", cargo_installed() and cargo_path() or "(not installed; required for locked dependencies and wasm build-std)"))
    if host_installed() then
        local ok, version = errors.trycall(function ()
            return os.iorunv(rustc_path(), {"--version"})
        end)
        if ok and version then
            print(string.format("%-16s %s", "version:", base.trim(version)))
        end
    end
    local rustlib = path.join(rust_prefix(), "lib", "rustlib")
    local installed = {}
    for _, dir in ipairs(os.dirs(path.join(rustlib, "*"))) do
        if os.isdir(path.join(dir, "lib")) then
            table.insert(installed, path.filename(dir))
        end
    end
    table.sort(installed)
    print(string.format("%-16s %s", "std targets:", #installed > 0 and table.concat(installed, ", ") or "(none)"))
end
