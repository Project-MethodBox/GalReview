-- Process execution wrappers and staged-failure reporting.

import("base")
import("errors")
import("layout")
import("settings")

function proxy_env_enabled()
    return (os.getenv("HTTP_PROXY")
        or os.getenv("HTTPS_PROXY")
        or os.getenv("ALL_PROXY")
        or os.getenv("http_proxy")
        or os.getenv("https_proxy")
        or os.getenv("all_proxy")) ~= nil
end

function print_error_context(label, target_os, extra)
    target_os = target_os or settings.configured_target_os()
    print("toolchain stage failed: " .. tostring(label))
    print("  owner root: " .. layout.owner_root())
    print("  toolchains home: " .. layout.toolchains_home())
    print("  cache: " .. layout.toolchains_cache_root())
    print("  host: " .. base.host_os() .. "/" .. settings.host_arch_folder())
    print("  target: " .. target_os .. "/" .. settings.target_arch_folder(target_os) .. " (" .. settings.managed_target(target_os) .. ")")
    print("  prefix: " .. settings.gcc_prefix(target_os))
    print("  proxy env: " .. tostring(proxy_env_enabled()))
    for _, item in ipairs(extra or {}) do
        if item[2] and tostring(item[2]) ~= "" then
            print("  " .. tostring(item[1]) .. ": " .. tostring(item[2]))
        end
    end
end

function stop_with_guidance(target_os, title, warnings, actions)
    target_os = target_os or settings.configured_target_os()
    print("")
    print("Managed GCC toolchain preflight")
    print("  " .. tostring(title))
    print("  owner root:      " .. layout.owner_root())
    print("  toolchains home: " .. layout.toolchains_home())
    print("  host:            " .. base.host_os() .. "/" .. settings.host_arch_folder())
    print("  target:          " .. target_os .. "/" .. settings.target_arch_folder(target_os) .. " (" .. settings.managed_target(target_os) .. ")")
    print("  prefix:          " .. settings.gcc_prefix(target_os))
    print("")
    for _, item in ipairs(warnings or {}) do
        errors.warn("%s", item)
    end
    if actions and #actions > 0 then
        print("")
        print("Next steps:")
        for _, item in ipairs(actions) do
            print("  " .. tostring(item))
        end
    end
    print("")
    errors.fail("%s", tostring(title))
end

function run_stage(label, target_os, script, extra)
    local ok, result = errors.trycall(script)
    if ok then
        return result
    end
    -- the caught exception text is the ONLY clue for failures that raise
    -- without printing first (nil-calls, module errors); swallowing it made
    -- a CI-wide breakage undiagnosable from the logs (2026-07-10)
    if result and result ~= "" then
        print("stage error: " .. tostring(result))
    end
    print_error_context(label, target_os, extra)
    errors.fail("%s failed; fix the reported cause and rerun the same xmake command", tostring(label))
end

function execv(program, args, opt)
    if os.execv then
        return os.execv(program, args or {}, opt or {})
    end
    return os.vrunv(program, args or {}, opt or {})
end

function run_program(label, program, args, opt)
    local runopt = {}
    opt = opt or {}
    for key, value in pairs(opt) do
        if key ~= "target_os" then
            runopt[key] = value
        end
    end
    local ok = errors.trycall(function ()
        execv(program, args or {}, runopt)
    end)
    if ok then
        return true
    end
    print_error_context(label, opt.target_os or settings.configured_target_os(), {
        {"command", base.command_text(program, args)},
        {"working directory", opt.curdir}
    })
    errors.fail("%s failed", tostring(label))
end
