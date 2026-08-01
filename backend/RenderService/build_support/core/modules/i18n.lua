-- Locale-aware message translation for user-facing build diagnostics.
-- gettext-shaped: the English format string IS the catalog key, so call
-- sites never change and unregistered messages pass through verbatim --
-- coverage grows progressively without ever blocking a diagnostic.
--
-- Only two locales by project policy: zh (any Chinese system locale) and en
-- (everything else). The language is detected from the SYSTEM, not
-- configured: Windows reads the user locale from the registry; Unix hosts
-- read the POSIX locale channel (LC_ALL/LC_MESSAGES/LANG -- on those
-- systems that IS the system-language transport) and, when the session
-- carries none (GUI-launched tools, minimal SSH/CI shells), fall back to
-- the system-level stores (macOS `defaults read -g AppleLocale`, Linux
-- /etc/locale.conf). Anything undetectable is English.
-- TOOLCHAINS_LANG=zh|en stays as the explicit override -- how the fixture
-- suite pins en and how a user can force a language without touching the
-- OS; it is never required for detection.
--
-- Leaf module: may import base only (errors.lua imports THIS module; an
-- errors import here would cycle).

import("base")

local locale_cache
local catalog = {}

local function windows_locale()
    local output
    try
    {
        function ()
            output = os.iorunv("reg", {"query", "HKCU\\Control Panel\\International", "/v", "LocaleName"})
        end,
        catch
        {
            function ()
            end
        }
    }
    return output and output:match("LocaleName%s+REG_SZ%s+(%S+)") or ""
end

local function macos_system_locale()
    local output
    try
    {
        function ()
            output = os.iorunv("defaults", {"read", "-g", "AppleLocale"})
        end,
        catch
        {
            function ()
            end
        }
    }
    return output and output:match("%S+") or ""
end

local function linux_system_locale()
    local content
    try
    {
        function ()
            content = io.readfile("/etc/locale.conf")
        end,
        catch
        {
            function ()
            end
        }
    }
    return content and content:match("LANG%s*=%s*\"?([^\"\r\n]+)") or ""
end

local function detect_locale()
    local lang = os.getenv("TOOLCHAINS_LANG") or ""
    if lang == "" then
        if base.is_windows_host() then
            lang = windows_locale()
        else
            -- POSIX semantics: a SET-BUT-EMPTY LC_ALL/LC_MESSAGES counts as
            -- unset and the next variable must still be consulted; a plain
            -- Lua `or` chain would stop at the first empty string (external
            -- review, 2026-07-18).
            for _, name in ipairs({"LC_ALL", "LC_MESSAGES", "LANG"}) do
                local value = os.getenv(name)
                if value and value ~= "" then
                    lang = value
                    break
                end
            end
            if lang == "" then
                lang = base.host_os() == "macosx" and macos_system_locale() or linux_system_locale()
            end
        end
    end
    return tostring(lang):lower():match("^zh") and "zh" or "en"
end

function locale()
    if not locale_cache then
        locale_cache = detect_locale()
    end
    return locale_cache
end

-- messages: { ["english format string"] = "中文格式串", ... }
-- Translations MUST keep the exact format specifiers of their key; tr()
-- falls back to the English text if a translation fails to format.
function register(messages)
    for key, zh in pairs(messages) do
        catalog[key] = zh
    end
end

function tr(message, ...)
    message = tostring(message)
    local translated = locale() == "zh" and catalog[message] or nil
    local args = table.pack(...)
    if args.n == 0 then
        return translated or message
    end
    if translated then
        local formatted
        try
        {
            function ()
                formatted = string.format(translated, table.unpack(args, 1, args.n))
            end,
            catch
            {
                function ()
                end
            }
        }
        if formatted then
            return formatted
        end
    end
    return string.format(message, table.unpack(args, 1, args.n))
end
