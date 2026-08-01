-- Failure reporting, guarded calls and small runtime helpers. Script scope:
-- os.raise and the try/catch DSL are available directly (core.base.utils is
-- NOT importable from inside an import()-module, so trycall builds on
-- try/catch with upvalue capture -- the catch handler's return value does not
-- propagate through try{}'s own result, verified empirically).
--
-- All user-facing text funnels through i18n.tr: registered messages localize
-- by OS language (en/zh), unregistered ones pass through verbatim.

import("i18n")

function fail(message, ...)
    local text = i18n.tr(message, ...)
    print("error: " .. text)
    os.raise(text)
end

function warn(message, ...)
    print("warning: " .. i18n.tr(message, ...))
end

-- Translate-and-format WITHOUT printing: for builders that assemble
-- user-facing lines consumed later (preflight warnings/actions handed to
-- run.stop_with_guidance, matrix cells). Keeping the format string literal
-- at the call site is what makes the text catalog-translatable; plain
-- concatenation stays English by policy (see core/modules/catalog.lua).
function message(message, ...)
    return i18n.tr(message, ...)
end

function log(message, ...)
    local stamp = os.date and os.date("%H:%M:%S") or ""
    if stamp ~= "" then
        print("[toolchains " .. stamp .. "] " .. i18n.tr(message, ...))
    else
        print("[toolchains] " .. i18n.tr(message, ...))
    end
end

-- Friendly failure envelope for command entry points: on any error --
-- expected fail() or unexpected Lua error -- print what command failed plus
-- actionable suggestions in the user's language, keep the raw error attached
-- for diagnosis (never hide it), and re-raise briefly so the exit code and
-- xmake's own error path stay intact.
function friendly_guard(command_label, suggestions, script)
    local ok, raw = trycall(script)
    if ok then
        return
    end
    print("")
    print(i18n.tr("the command `%s` did not complete successfully", command_label))
    for _, suggestion in ipairs(suggestions or {}) do
        print("  - " .. i18n.tr(suggestion))
    end
    print(i18n.tr("---- original error (kept for diagnosis) ----"))
    print(tostring(raw))
    os.raise(i18n.tr("command failed: %s", command_label))
end

-- Envelope/self-owned message translations.
i18n.register({
    ["the command `%s` did not complete successfully"] = "命令 `%s` 未能成功完成",
    ["---- original error (kept for diagnosis) ----"] = "---- 原始错误(供诊断保留)----",
    ["command failed: %s"] = "命令执行失败:%s"
})

function trycall(script)
    local ok, result
    try
    {
        function ()
            result = script()
            ok = true
        end,
        catch
        {
            function (errors)
                ok = false
                -- exception values can be error OBJECTS, not strings; callers
                -- historically treat the second return as printable/matchable
                -- text, so normalize here
                result = errors ~= nil and tostring(errors) or nil
            end
        }
    }
    return ok, result
end

function sleep(seconds)
    if os.sleep then
        os.sleep(seconds)
    end
end
