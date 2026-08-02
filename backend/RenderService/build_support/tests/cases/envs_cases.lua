-- Fixture regression for the system-proxy parsers in core/modules/envs.lua
-- (owner 2026-08-01: builds must follow the OS proxy configuration
-- automatically instead of demanding manually exported variables). Anchor
-- scenario: this dev machine's real WinINET settings -- ProxyEnable=1,
-- ProxyServer=127.0.0.1:5210, ProxyOverride="<local>;localhost;127.*;..." --
-- were invisible to every download until the detection landed. The parsers
-- are pure (registry/scutil I/O stays in the thin system_proxy() shell), so
-- these cases pin the mapping itself.

local envs = import("envs",
    {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules"), anonymous = true})

function run(t)
    t.case("envs: a bare WinINET proxy maps to http:// on both slots", function ()
        local proxy = envs.parse_windows_system_proxy("127.0.0.1:5210", nil)
        t.assert_eq(proxy.http, "http://127.0.0.1:5210", "http slot")
        t.assert_eq(proxy.https, "http://127.0.0.1:5210", "https slot")
        t.assert_true(proxy.no_proxy == nil, "no override -> no NO_PROXY")
    end)

    t.case("envs: the WinINET override list becomes NO_PROXY with <local> expanded", function ()
        local proxy = envs.parse_windows_system_proxy("127.0.0.1:5210",
            "<local>;localhost;127.*;192.168.*")
        t.assert_eq(proxy.no_proxy, "localhost,127.0.0.1,::1,localhost,127.*,192.168.*",
            "override entries pass through, <local> expands")
    end)

    t.case("envs: a per-protocol WinINET list keeps http/https apart and https falls back to http", function ()
        local split = envs.parse_windows_system_proxy("http=10.0.0.1:5211;https=10.0.0.2:5212", nil)
        t.assert_eq(split.http, "http://10.0.0.1:5211", "http slot")
        t.assert_eq(split.https, "http://10.0.0.2:5212", "https slot")
        local http_only = envs.parse_windows_system_proxy("http=10.0.0.1:5211", nil)
        t.assert_eq(http_only.https, "http://10.0.0.1:5211", "https falls back to the http entry")
    end)

    t.case("envs: a socks-only WinINET entry maps to socks5h on both slots", function ()
        local proxy = envs.parse_windows_system_proxy("socks=127.0.0.1:5213", nil)
        t.assert_eq(proxy.http, "socks5h://127.0.0.1:5213", "http slot")
        t.assert_eq(proxy.https, "socks5h://127.0.0.1:5213", "https slot")
    end)

    t.case("envs: empty or disabled WinINET settings yield nil", function ()
        t.assert_true(envs.parse_windows_system_proxy("", nil) == nil, "empty server")
        t.assert_true(envs.parse_windows_system_proxy(nil, "<local>") == nil, "nil server")
        t.assert_true(envs.parse_windows_system_proxy("ftp=10.0.0.3:5214", nil) == nil,
            "ftp-only configuration is unusable for http(s) downloads")
    end)

    t.case("envs: scutil output with HTTP/HTTPS proxies parses including the exceptions list", function ()
        local proxy = envs.parse_macos_system_proxy(table.concat({
            "<dictionary> {",
            "  ExceptionsList : <array> {",
            "    0 : *.local",
            "    1 : 169.254/16",
            "  }",
            "  HTTPEnable : 1",
            "  HTTPPort : 5215",
            "  HTTPProxy : 192.168.1.10",
            "  HTTPSEnable : 1",
            "  HTTPSPort : 5215",
            "  HTTPSProxy : 192.168.1.10",
            "  SOCKSEnable : 0",
            "}"
        }, "\n"))
        t.assert_eq(proxy.http, "http://192.168.1.10:5215", "http slot")
        t.assert_eq(proxy.https, "http://192.168.1.10:5215", "https slot")
        t.assert_eq(proxy.no_proxy, "*.local,169.254/16", "exceptions list")
    end)

    t.case("envs: scutil output with everything disabled yields nil (real Mac test-host shape)", function ()
        t.assert_true(envs.parse_macos_system_proxy(table.concat({
            "<dictionary> {",
            "  HTTPEnable : 0",
            "  HTTPSEnable : 0",
            "  SOCKSEnable : 0",
            "}"
        }, "\n")) == nil, "all-disabled dictionary")
    end)

    t.case("envs: scutil proxy entries without ports use the repository port range", function ()
        local proxy = envs.parse_macos_system_proxy(table.concat({
            "<dictionary> {",
            "  HTTPEnable : 1",
            "  HTTPProxy : 127.0.0.1",
            "  HTTPSEnable : 1",
            "  HTTPSProxy : 127.0.0.1",
            "}",
        }, "\n"))
        t.assert_eq(proxy.http, "http://127.0.0.1:5257", "HTTP default stays in range")
        t.assert_eq(proxy.https, "http://127.0.0.1:5258", "HTTPS default stays in range")

        local socks = envs.parse_macos_system_proxy(table.concat({
            "<dictionary> {",
            "  SOCKSEnable : 1",
            "  SOCKSProxy : 127.0.0.1",
            "}",
        }, "\n"))
        t.assert_eq(socks.http, "socks5h://127.0.0.1:5259", "SOCKS default stays in range")
        t.assert_eq(socks.https, "socks5h://127.0.0.1:5259", "SOCKS default is shared")
    end)
end
