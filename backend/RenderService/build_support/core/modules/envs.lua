-- Child-process environment construction: proxy passthrough (explicit env
-- first, detected OS proxy settings as the fallback), PATH assembly, hermetic
-- neutralization of hostile inherited variables, and the pinned host-tool
-- variables handed to configure/make.

import("base")
import("hosttools")
import("settings")
import("errors")

function inherited_path_entries()
    local entries = {}
    for _, dir in ipairs((os.getenv("PATH") or ""):split(base.pathsep(), {plain = true})) do
        if dir and dir ~= "" then
            table.insert(entries, dir)
        end
    end
    return entries
end

-- Pure parser for the WinINET user proxy settings (the Windows Settings ->
-- Network -> Proxy values under HKCU Internet Settings). ProxyServer is either
-- a bare "host:port" (one proxy for every protocol) or a per-protocol list
-- "http=h:p;https=h:p;socks=h:p". A bare WinINET proxy is an HTTP proxy that
-- tunnels https via CONNECT, hence the http:// scheme on both slots; a
-- socks-only configuration maps to socks5h:// (proxy-side DNS, matching how
-- this machine's TLS-inspecting-proxy escape hatch is used). ProxyOverride is
-- a ";" list where "<local>" means local addresses; entries are passed through
-- as NO_PROXY verbatim otherwise (curl/git ignore wildcard forms they do not
-- understand, which is harmless).
function parse_windows_system_proxy(server, override)
    server = base.trim(tostring(server or ""))
    if server == "" then
        return nil
    end
    local slots = {}
    if server:find("=", 1, true) then
        for _, item in ipairs(server:split(";", {plain = true})) do
            local scheme, address = item:match("^%s*(%w+)%s*=%s*(.-)%s*$")
            if scheme and address and address ~= "" then
                slots[scheme:lower()] = address
            end
        end
    else
        slots.all = server
    end
    local function with_scheme(address, default_scheme)
        if not address or address == "" then
            return nil
        end
        if address:find("://", 1, true) then
            return address
        end
        return default_scheme .. "://" .. address
    end
    local http = with_scheme(slots.all or slots.http, "http")
    local https = with_scheme(slots.all or slots.https or slots.http, "http")
    if not http and not https and slots.socks then
        http = with_scheme(slots.socks, "socks5h")
        https = http
    end
    if not http and not https then
        return nil
    end
    local no_proxy
    override = base.trim(tostring(override or ""))
    if override ~= "" then
        local entries = {}
        for _, item in ipairs(override:split(";", {plain = true})) do
            item = base.trim(item)
            if item == "<local>" then
                table.insert(entries, "localhost")
                table.insert(entries, "127.0.0.1")
                table.insert(entries, "::1")
            elseif item ~= "" then
                table.insert(entries, item)
            end
        end
        if #entries > 0 then
            no_proxy = table.concat(entries, ",")
        end
    end
    return {http = http or https, https = https or http, no_proxy = no_proxy}
end

-- Pure parser for `scutil --proxy` output (macOS system proxy dictionary).
function parse_macos_system_proxy(text)
    text = tostring(text or "")
    local function enabled(name)
        return text:match(name .. "Enable%s*:%s*1") ~= nil
    end
    local function value(name)
        return text:match(name .. "%s*:%s*([^%s}]+)")
    end
    local http, https
    if enabled("HTTP") and value("HTTPProxy") then
        http = "http://" .. value("HTTPProxy") .. ":" .. (value("HTTPPort") or "80")
    end
    if enabled("HTTPS") and value("HTTPSProxy") then
        https = "http://" .. value("HTTPSProxy") .. ":" .. (value("HTTPSPort") or "443")
    end
    if not http and not https and enabled("SOCKS") and value("SOCKSProxy") then
        local socks = "socks5h://" .. value("SOCKSProxy") .. ":" .. (value("SOCKSPort") or "1080")
        http = socks
        https = socks
    end
    if not http and not https then
        return nil
    end
    local no_proxy
    local exceptions = text:match("ExceptionsList%s*:%s*<array>%s*{(.-)}")
    if exceptions then
        local entries = {}
        for item in exceptions:gmatch("%d+%s*:%s*([^%s]+)") do
            table.insert(entries, item)
        end
        if #entries > 0 then
            no_proxy = table.concat(entries, ",")
        end
    end
    return {http = http or https, https = https or http, no_proxy = no_proxy}
end

-- Detects the operating system's own proxy configuration (owner 2026-08-01:
-- builds must follow the system proxy automatically instead of demanding a
-- manually exported environment variable). Windows reads the WinINET user
-- settings from the registry; macOS asks scutil; Linux desktops have no single
-- authority, so the environment stays the only source there. The result is
-- memoized per process and injected only into this build's child environments
-- -- nothing is ever persisted back into the user's configuration.
function system_proxy()
    if _g.system_proxy_probed then
        return _g.system_proxy_value
    end
    _g.system_proxy_probed = true
    local detected
    if base.is_windows_host() then
        -- winos is a sandbox built-in (import("core.base.winos") is NOT
        -- importable from module scripts and fails)
        detected = try
        {
            function ()
                local key = "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"
                local enable = winos.registry_query(key .. ";ProxyEnable")
                if (tonumber(tostring(enable)) or 0) == 0 then
                    return nil
                end
                local server = winos.registry_query(key .. ";ProxyServer")
                local override = try { function () return winos.registry_query(key .. ";ProxyOverride") end }
                return parse_windows_system_proxy(server, override)
            end
        }
    elseif os.host() == "macosx" then
        detected = try
        {
            function ()
                return parse_macos_system_proxy(os.iorunv("scutil", {"--proxy"}))
            end
        }
    end
    if detected then
        errors.log("using the system proxy %s for downloads and build child processes (export HTTP_PROXY/ALL_PROXY to override it, or turn the system proxy off)", detected.https or detected.http)
    end
    _g.system_proxy_value = detected
    return detected
end

function proxy_envs_without_path()
    local envs = {}
    for _, key in ipairs({"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"}) do
        local value = os.getenv(key)
        if value and value ~= "" then
            envs[key] = value
        end
    end
    -- Any explicit proxy variable means the user has taken over; otherwise the
    -- detected system proxy fills the same variables for every child process.
    if not (envs.HTTP_PROXY or envs.HTTPS_PROXY or envs.ALL_PROXY
        or envs.http_proxy or envs.https_proxy or envs.all_proxy) then
        local detected = system_proxy()
        if detected then
            envs.HTTP_PROXY = detected.http
            envs.http_proxy = detected.http
            envs.HTTPS_PROXY = detected.https
            envs.https_proxy = detected.https
            if detected.no_proxy and not envs.NO_PROXY and not envs.no_proxy then
                envs.NO_PROXY = detected.no_proxy
                envs.no_proxy = detected.no_proxy
            end
        end
    end
    return envs
end

function proxy_envs()
    local envs = proxy_envs_without_path()
    local path_entries = hosttools.windows_extra_path_dirs()
    for _, dir in ipairs(inherited_path_entries()) do
        table.insert(path_entries, dir)
    end
    if #path_entries > 0 then
        envs.PATH = table.concat(path_entries, base.pathsep())
    end
    return envs
end

function with_posix_shell(envs)
    if base.is_windows_host() then
        local shell = base.shpath(hosttools.preferred_posix_shell())
        envs.SHELL = shell
        envs.MAKESHELL = shell
        envs.CONFIG_SHELL = shell
    end
    return envs
end

-- xmake's envs option merges over the inherited environment (verified: a
-- variable set only in the parent still reaches the child), so stray build
-- variables exported on a foreign machine leak straight into configure and
-- make. Neutralize the dangerous ones, but only when actually inherited: an
-- empty-string override yields an empty value rather than an unset, and an
-- unconditional empty CPATH/CONFIG_SITE would itself change behavior.
local hostile_build_envs = {
    "MAKEFLAGS", "MFLAGS", "GNUMAKEFLAGS", "MAKELEVEL",
    "GREP_OPTIONS", "CDPATH", "BASH_ENV", "ENV",
    "GCC_EXEC_PREFIX", "COMPILER_PATH", "LIBRARY_PATH",
    "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH",
    "DEPENDENCIES_OUTPUT", "SUNPRO_DEPENDENCIES",
    "CONFIG_SITE", "DESTDIR", "CPPFLAGS", "LIBS"
}

function with_hermetic_build_envs(envs)
    for _, key in ipairs(hostile_build_envs) do
        local inherited = os.getenv(key)
        if envs[key] == nil and inherited and inherited ~= "" then
            envs[key] = ""
        end
    end
    envs.LC_ALL = "C"
    envs.LANG = "C"
    envs.LANGUAGE = "C"
    return envs
end

function build_tool_vars()
    if not base.is_windows_host() then
        return {}
    end

    local triplet = settings.host_triplet()
    local install = hosttools.shell_host_tool("install")
    local grep = hosttools.shell_host_tool("grep")
    return {
        {"CC", hosttools.shell_host_tool_any({triplet .. "-gcc", "gcc"})},
        {"CXX", hosttools.shell_host_tool_any({triplet .. "-g++", "g++"})},
        {"AR", hosttools.shell_host_tool_any({triplet .. "-ar", "ar"})},
        {"AS", hosttools.shell_host_tool_any({triplet .. "-as", "as"})},
        {"LD", hosttools.shell_host_tool_any({triplet .. "-ld", "ld"})},
        {"NM", hosttools.shell_host_tool_any({triplet .. "-nm", "nm"})},
        {"RANLIB", hosttools.shell_host_tool_any({triplet .. "-ranlib", "ranlib"})},
        {"STRIP", hosttools.shell_host_tool_any({triplet .. "-strip", "strip"})},
        {"DLLTOOL", hosttools.shell_host_tool_any({triplet .. "-dlltool", "dlltool"})},
        {"INSTALL", install .. " -c"},
        {"INSTALL_PROGRAM", install .. " -c"},
        {"INSTALL_SCRIPT", install .. " -c"},
        {"INSTALL_DATA", install .. " -c -m 644"},
        {"MKDIR_P", hosttools.shell_host_tool("mkdir") .. " -p"},
        {"SED", hosttools.shell_host_tool("sed")},
        {"GREP", grep},
        {"EGREP", grep .. " -E"},
        {"FGREP", grep .. " -F"},
        {"AWK", hosttools.shell_host_tool_any({"awk", "gawk"})},
        {"FLEX", hosttools.shell_host_tool_any({"flex", "win_flex"})},
        {"LEX", hosttools.shell_host_tool_any({"flex", "win_flex"})},
        {"BISON", hosttools.shell_host_tool_any({"bison", "win_bison"})},
        {"YACC", hosttools.shell_host_tool_any({"bison", "win_bison"}) .. " -y"},
        {"WINDRES", hosttools.shell_host_tool_any({triplet .. "-windres", "windres"})}
    }
end

function with_build_tool_vars(envs)
    for _, item in ipairs(build_tool_vars()) do
        envs[item[1]] = item[2]
    end
    return envs
end

function shell_envs(...)
    local envs = proxy_envs_without_path()
    local entries = {}
    for _, item in ipairs({...}) do
        if item and item ~= "" then
            table.insert(entries, item)
        end
    end
    for _, dir in ipairs(hosttools.windows_extra_path_dirs()) do
        table.insert(entries, dir)
    end
    for _, dir in ipairs(inherited_path_entries()) do
        table.insert(entries, dir)
    end
    for index, dir in ipairs(entries) do
        entries[index] = base.shell_path_entry(dir)
    end
    if #entries > 0 then
        envs.PATH = table.concat(entries, base.shell_pathsep())
    end
    return settings.apply_build_envs(with_build_tool_vars(with_posix_shell(with_hermetic_build_envs(envs))))
end

function with_path(envs, ...)
    envs = envs or proxy_envs()
    local entries = {}
    for _, item in ipairs({...}) do
        if item and item ~= "" then
            table.insert(entries, item)
        end
    end
    local old_path = envs.PATH or os.getenv("PATH")
    if old_path and old_path ~= "" then
        table.insert(entries, old_path)
    end
    envs.PATH = table.concat(entries, base.pathsep())
    return envs
end

function make_envs(...)
    return settings.apply_build_envs(with_build_tool_vars(with_posix_shell(with_hermetic_build_envs(with_path(proxy_envs(), ...)))))
end
