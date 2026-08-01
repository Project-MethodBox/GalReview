-- Managed Emscripten toolset: the single owner of the pinned emcc/LLVM/node
-- (and Windows python) archive set the emscripten target links with. The
-- pinned release archive carries the full LLVM toolset (wasm-ld, llvm-ar/nm/
-- objcopy/ranlib/strip), the emscripten frontend (emcc), and a prebuilt
-- sysroot; node and the Windows python are separate pinned archives. The
-- install is pure unpack-and-wire: extract the archives, generate the
-- embedded .emscripten config plus thin launchers that pin EM_CONFIG (and
-- EMSDK_PYTHON on Windows), and write a stamp. Every query function here is
-- side-effect free and returns nil until the install is complete; only
-- ensure_installed()/prefetch() touch the network or the filesystem.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
local defaults = import("defaults", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")}).values()
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("download", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("checksums", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("run", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("install_lock", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})

-- Bump when the generated layout (config file, launchers, directory shape)
-- changes; a mismatching stamp forces one clean reinstall.
local STAMP_SCHEMA = "emsdk-managed-v1"

function version()
    return defaults.emscripten_version
end

function releases_hash()
    return defaults.emscripten_releases_hash
end

function pinned_node_version()
    return defaults.emscripten_node_version
end

function install_root()
    return path.join(layout.toolchains_home(), base.host_os(), "emsdk", version())
end

local function stamp_file()
    return path.join(install_root(), ".xmake-emsdk-stamp")
end

local function host_arch()
    return base.canonical_arch(os.arch(), base.host_os())
end

-- Archive set for one host. The win-x64/linux-x64/mac-arm64 sets carry
-- pinned digests in core/modules/checksums.lua; every other host key uses
-- the same upstream URL patterns and falls back to trust-on-first-use.
local function archive_specs()
    local host = base.host_os()
    local arch = host_arch()
    if arch ~= "x86_64" and arch ~= "aarch64" then
        return nil
    end
    local os_segment = host == "windows" and "win" or (host == "macosx" and "mac" or "linux")
    local release_ext = host == "windows" and "zip" or "tar.xz"
    local release_variant = arch == "aarch64" and "-arm64" or ""
    local arch_key = arch == "aarch64" and "arm64" or "x64"
    local specs = {}
    table.insert(specs, {
        component = "release",
        url = string.format("%s/%s/%s/wasm-binaries%s.%s", defaults.emscripten_releases_base_url,
            os_segment, releases_hash(), release_variant, release_ext),
        -- upstream serves every release under the same wasm-binaries leaf;
        -- the cache leaf must stay version- and host-qualified because the
        -- digest registry and the shared download cache key on the leaf
        leaf = string.format("emscripten-%s-%s-%s-wasm-binaries.%s", version(), os_segment, arch_key, release_ext),
        markers = {"emscripten", "bin"}
    })
    local node_plat = host == "windows" and "win" or (host == "macosx" and "darwin" or "linux")
    local node_ext = host == "windows" and "zip" or (host == "macosx" and "tar.gz" or "tar.xz")
    local node_leaf = string.format("node-v%s-%s-%s.%s", pinned_node_version(), node_plat, arch_key, node_ext)
    table.insert(specs, {
        component = "node",
        url = string.format("%s/v%s/%s", defaults.emscripten_node_base_url, pinned_node_version(), node_leaf),
        leaf = node_leaf,
        -- the official dist layout keeps node.exe at the archive root on
        -- Windows and under bin/ elsewhere
        markers = host == "windows" and {"node.exe"} or {"bin"}
    })
    if host == "windows" then
        local python_leaf = string.format("python-%s-win-%s.zip", defaults.emscripten_win_python_version,
            arch == "aarch64" and "arm64" or "amd64")
        table.insert(specs, {
            component = "python",
            url = string.format("%s/deps/%s", defaults.emscripten_releases_base_url, python_leaf),
            leaf = python_leaf,
            markers = {"python.exe"}
        })
    end
    return specs
end

-- internal path builders (no installed() gate) ------------------------------

local function managed_upstream_dir()
    return path.join(install_root(), "upstream")
end

local function managed_emscripten_dir()
    return path.join(managed_upstream_dir(), "emscripten")
end

local function managed_emcc_file()
    local dir = managed_emscripten_dir()
    if base.is_windows_host() then
        return path.join(dir, "emcc.bat")
    end
    return path.join(dir, "emcc")
end

local function managed_launcher_file(name)
    return path.join(install_root(), "bin", base.is_windows_host() and (name .. ".bat") or name)
end

local function managed_node_file()
    if base.is_windows_host() then
        return path.join(install_root(), "node", "node.exe")
    end
    return path.join(install_root(), "node", "bin", "node")
end

local function managed_python_file()
    return path.join(install_root(), "python", "python.exe")
end

local function managed_config_file()
    return path.join(managed_emscripten_dir(), ".emscripten")
end

local function managed_sysroot_dir()
    return path.join(managed_emscripten_dir(), "cache", "sysroot")
end

local function managed_sysroot_usable()
    local sysroot = managed_sysroot_dir()
    return os.isfile(path.join(sysroot, "include", "pthread.h"))
        and os.isdir(path.join(sysroot, "lib", "wasm32-emscripten"))
end

local function stamp_signature()
    local lines = {
        "schema=" .. STAMP_SCHEMA,
        "emscripten_version=" .. version(),
        "releases_hash=" .. releases_hash(),
        "node_version=" .. pinned_node_version(),
        "node_channel=nodejs-dist",
        "host=" .. base.host_os() .. "-" .. host_arch()
    }
    if base.is_windows_host() then
        table.insert(lines, "win_python_version=" .. defaults.emscripten_win_python_version)
    end
    return table.concat(lines, "\n") .. "\n"
end

-- public queries -------------------------------------------------------------

function installed()
    return os.isfile(stamp_file())
        and io.readfile(stamp_file()) == stamp_signature()
        and os.isfile(managed_emcc_file())
        and os.isfile(managed_launcher_file("emcc"))
        and os.isfile(managed_config_file())
        and os.isfile(managed_node_file())
        and (not base.is_windows_host() or os.isfile(managed_python_file()))
        and managed_sysroot_usable()
end

-- The real emcc entry point inside the release tree; sysroot derivation and
-- version reads want this one, invocations should use emcc_launcher_path().
function emcc_path()
    if not installed() then
        return nil
    end
    return managed_emcc_file()
end

function emcc_launcher_path()
    if not installed() then
        return nil
    end
    return managed_launcher_file("emcc")
end

function node_path()
    if not installed() then
        return nil
    end
    return managed_node_file()
end

function upstream_bin_dir()
    if not installed() then
        return nil
    end
    return path.join(managed_upstream_dir(), "bin")
end

function wasm_ld_path()
    local bindir = upstream_bin_dir()
    if not bindir then
        return nil
    end
    local candidate = path.join(bindir, base.exe("wasm-ld"))
    if os.isfile(candidate) then
        return candidate
    end
end

function sysroot()
    if not installed() then
        return nil
    end
    return managed_sysroot_dir()
end

-- version readers -------------------------------------------------------------

local emcc_version_memo = {}

-- Reads the emscripten version for any real emcc path: the sibling
-- emscripten-version.txt first (fast, quoted string), then one
-- `emcc --version` run as the fallback.
function emscripten_version_of(emcc)
    if not emcc or emcc == "" then
        return nil
    end
    local key = tostring(emcc)
    if emcc_version_memo[key] ~= nil then
        return emcc_version_memo[key] ~= "" and emcc_version_memo[key] or nil
    end
    local version_file = path.join(path.directory(emcc), "emscripten-version.txt")
    if os.isfile(version_file) then
        local text = base.trim(io.readfile(version_file) or ""):gsub("^\"", ""):gsub("\"$", "")
        if text ~= "" then
            emcc_version_memo[key] = text
            return text
        end
    end
    local ok, output = errors.trycall(function ()
        return os.iorunv(emcc, {"--version"})
    end)
    local parsed = ok and type(output) == "string"
        and output:match("emcc[^\r\n]-(%d+%.%d+%.%d+[%w%.%-]*)") or nil
    emcc_version_memo[key] = parsed or ""
    return parsed
end

function installed_emscripten_version()
    return emscripten_version_of(emcc_path())
end

local node_version_memo = {}

function node_version_of(node)
    if not node or node == "" then
        return nil
    end
    local key = tostring(node)
    if node_version_memo[key] ~= nil then
        return node_version_memo[key] ~= "" and node_version_memo[key] or nil
    end
    local ok, output = errors.trycall(function ()
        return os.iorunv(node, {"--version"})
    end)
    local parsed = ok and type(output) == "string" and base.trim(output) or ""
    node_version_memo[key] = parsed
    return parsed ~= "" and parsed or nil
end

-- install ---------------------------------------------------------------------

local unsupported_host_warned = false

local function warn_unsupported_host()
    if not unsupported_host_warned then
        unsupported_host_warned = true
        errors.warn("no pinned Emscripten archive set is defined for host %s/%s; the managed toolset is unavailable and emcc/node/wasm-ld fall back to explicit configuration or PATH",
            base.host_os(), host_arch())
    end
end

local function has_markers(dir, markers)
    for _, marker in ipairs(markers) do
        if not os.exists(path.join(dir, marker)) then
            return false
        end
    end
    return true
end

local function locate_content_root(dir, markers)
    if has_markers(dir, markers) then
        return dir
    end
    for _, sub in ipairs(os.dirs(path.join(dir, "*"))) do
        if has_markers(sub, markers) then
            return sub
        end
    end
end

local function install_archive(spec, destination)
    local archive = path.join(layout.download_cache_dir(), spec.leaf)
    local staging = path.join(layout.extract_cache_dir("emsdk"), spec.leaf .. ".extract")
    download.download_and_extract_archive(spec.url, archive, staging)
    local content = locate_content_root(staging, spec.markers)
    if not content then
        errors.fail("downloaded %s did not contain the expected content layout under %s", spec.leaf, staging)
    end
    layout.remove_toolchains_path(destination)
    os.mkdir(path.directory(destination))
    if content == staging then
        os.mv(staging, destination)
    else
        os.mv(content, destination)
        layout.remove_toolchains_path(staging)
    end
end

local function write_config()
    local lines = {
        "# generated by build_support gccemsdk.lua; do not edit -- a managed",
        "# reinstall regenerates this file",
        "NODE_JS = '" .. base.shpath(managed_node_file()) .. "'",
        "LLVM_ROOT = '" .. base.shpath(path.join(managed_upstream_dir(), "bin")) .. "'",
        "BINARYEN_ROOT = '" .. base.shpath(managed_upstream_dir()) .. "'",
        "EMSCRIPTEN_ROOT = '" .. base.shpath(managed_emscripten_dir()) .. "'"
    }
    if base.is_windows_host() then
        table.insert(lines, "PYTHON = '" .. base.shpath(managed_python_file()) .. "'")
    end
    base.writefile_bytes(managed_config_file(), table.concat(lines, "\n") .. "\n")
end

local function write_launchers()
    os.mkdir(path.join(install_root(), "bin"))
    for _, name in ipairs({"emcc", "em++"}) do
        local launcher = managed_launcher_file(name)
        if base.is_windows_host() then
            -- mirror the upstream entry point (python -E on the driver
            -- script) but pin EM_CONFIG and EMSDK_PYTHON so a polluted
            -- environment or a python-less PATH cannot change tool identity
            base.writefile_bytes(launcher, table.concat({
                "@echo off",
                "setlocal",
                "set \"EM_CONFIG=" .. base.shpath(managed_config_file()) .. "\"",
                "set \"EMSDK_PYTHON=" .. managed_python_file() .. "\"",
                "set \"_PYTHON_SYSCONFIGDATA_NAME=\"",
                "\"%EMSDK_PYTHON%\" -E \"" .. path.join(managed_emscripten_dir(), name .. ".py") .. "\" %*",
                "endlocal & exit /b %ERRORLEVEL%",
                ""
            }, "\r\n"))
        else
            base.writefile_bytes(launcher, table.concat({
                "#!/bin/sh",
                "EM_CONFIG=" .. base.shquote(managed_config_file()),
                "export EM_CONFIG",
                "exec " .. base.shquote(path.join(managed_emscripten_dir(), name)) .. " \"$@\"",
                ""
            }, "\n"))
            run.run_program("making managed Emscripten " .. name .. " launcher executable",
                "chmod", {"+x", launcher}, {target_os = "emscripten"})
        end
    end
end

local function install()
    local specs = archive_specs()
    for _, spec in ipairs(specs) do
        local destination = path.join(install_root(),
            spec.component == "release" and "upstream" or spec.component)
        install_archive(spec, destination)
    end
    write_config()
    write_launchers()
    base.writefile_bytes(stamp_file(), stamp_signature())
    if not installed() then
        errors.fail("managed Emscripten toolset install finished but is still not detected as complete: %s", install_root())
    end
    print("managed Emscripten toolset installed: " .. install_root())
end

-- Idempotent: returns the install root when the pinned toolset is (or
-- becomes) available, nil when this host has no pinned archive set. Download
-- or extraction failures raise; callers that can degrade to PATH tools wrap
-- this in errors.trycall and warn.
function ensure_installed()
    if installed() then
        return install_root()
    end
    if not archive_specs() then
        warn_unsupported_host()
        return nil
    end
    local lockdir = path.join(layout.toolchains_home(), base.host_os(), "emsdk")
    install_lock.guard(path.join(lockdir, ".install.lock"), function ()
        if not installed() then
            print("installing managed Emscripten toolset " .. version()
                .. " (node " .. pinned_node_version() .. ") into " .. install_root())
            install()
        end
    end)
    return install_root()
end

-- Download and digest-check the pinned archives without extracting or
-- installing anything (the `xmake toolchains fetch` hook).
function prefetch()
    local specs = archive_specs()
    if not specs then
        warn_unsupported_host()
        return
    end
    for _, spec in ipairs(specs) do
        local archive = path.join(layout.download_cache_dir(), spec.leaf)
        download.download_file(spec.url, archive)
        checksums.verify(archive)
    end
end

function status_lines(target_os)
    print("emsdk pin:       " .. version() .. " (releases " .. releases_hash() .. ")")
    print("emsdk root:      " .. install_root())
    print("emsdk installed: " .. tostring(installed()))
end
