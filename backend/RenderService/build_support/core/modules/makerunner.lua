-- GNU make invocation: argument assembly, tee-style logging, failure-log
-- surfacing and the transient-retry wrapper.

import("base")
import("errors")
import("layout")
import("settings")
import("hosttools")
import("run")

function make_args_for(make, ...)
    local jobs = tonumber(settings.value_or("toolchains_jobs", settings.default_jobs())) or tonumber(settings.default_jobs()) or 8
    if jobs < 1 then
        jobs = 1
    end
    local args = {"-j" .. tostring(math.floor(jobs)), "MAKEINFO=true", "TEXI2DVI=true"}
    for _, item in ipairs({...}) do
        table.insert(args, item)
    end
    return args
end

function make_jobs()
    local jobs = tonumber(settings.value_or("toolchains_jobs", settings.default_jobs())) or tonumber(settings.default_jobs()) or 8
    if jobs < 1 then
        jobs = 1
    end
    return math.floor(jobs)
end

function make_tool_args()
    if not base.is_windows_host() then
        return {}
    end
    local grep = hosttools.shell_host_tool("grep")
    return {
        "GREP=" .. grep,
        "EGREP=" .. grep .. " -E",
        "FGREP=" .. grep .. " -F",
        "SED=" .. hosttools.shell_host_tool("sed"),
        "AWK=" .. hosttools.shell_host_tool_any({"awk", "gawk"})
    }
end

function shell_command(program, args)
    local command = base.shquote(program)
    for _, arg in ipairs(args or {}) do
        command = command .. " " .. base.shquote(arg)
    end
    return command
end

function make_target_log_file(build, target)
    local name = tostring((target and target ~= "") and target or "all")
    name = name:gsub("[^%w%._%-]+", "_")
    return path.join(build, "xmake-logs", "make-" .. name .. ".log")
end

function print_log_tail(file, line_count)
    if not os.isfile(file) then
        return
    end
    print("")
    print("make output log: " .. file)
    local content = io.readfile(file) or ""
    local lines = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end
    local first = math.max(1, #lines - (line_count or 160))
    for index = first, #lines do
        local line = lines[index]
        if line and line ~= "" then
            print("  " .. line)
        end
    end
end

function run_make_with_log(make, args, opt, logfile)
    local statusfile = logfile .. ".status"
    os.mkdir(path.directory(logfile))
    layout.remove_toolchains_path(logfile)
    layout.remove_toolchains_path(statusfile)

    local command = shell_command(make, args)
    local script = "(" .. command .. "; printf '%s\\n' $? > " .. base.shquote(statusfile) .. ") 2>&1 | tee " .. base.shquote(logfile)
        .. "; status=$(cat " .. base.shquote(statusfile) .. " 2>/dev/null || printf 1); rm -f " .. base.shquote(statusfile) .. "; exit \"$status\""
    run.execv(hosttools.preferred_posix_shell(), {"-c", script}, opt)
end

function print_make_failure_logs(build, target_os, target, logfile)
    local triplet = settings.managed_target(target_os)
    local candidates = {
        path.join(build, triplet, "libstdc++-v3", "config.log"),
        path.join(build, triplet, "libgcc", "config.log"),
        path.join(build, "gcc", "config.log"),
        path.join(build, "libcpp", "config.log"),
        path.join(build, "intl", "config.log"),
        path.join(build, "libiberty", "config.log"),
        path.join(build, "fixincludes", "config.log"),
        path.join(build, "gmp", "config.log"),
        path.join(build, "mpfr", "config.log"),
        path.join(build, "mpc", "config.log"),
        path.join(build, "isl", "config.log"),
        path.join(build, "config.log")
    }
    local seen = {}
    for _, file in ipairs(candidates) do
        if os.isfile(file) and not seen[file] then
            seen[file] = true
            print("")
            print("related configure log: " .. file)
            local content = io.readfile(file) or ""
            local lines = {}
            for line in (content .. "\n"):gmatch("([^\n]*)\n") do
                table.insert(lines, line)
            end
            local first = math.max(1, #lines - 80)
            for index = first, #lines do
                local line = lines[index]
                if line and line ~= "" then
                    print("  " .. line)
                end
            end
        end
    end
    if logfile then
        print_log_tail(logfile, 220)
    end
    if target and tostring(target):find("libstdc++", 1, true) then
        print("")
        print("hint: all-target-libstdc++-v3 failed; the first compiler/linker error above this make summary is the root cause.")
        print("hint: if the visible output only shows Error 2, rerun the same command after checking the related libstdc++ config.log printed above.")
    end
    if target == "configure-gcc" then
        print("")
        print("hint: configure-gcc failed after host prerequisite stages; the first configure or compiler error above this make summary is the root cause.")
        print("hint: if the visible output only shows Error 2, rerun the same command after checking the related config.log tails printed above.")
    end
end

-- opt.before_retry runs between the two attempts. It exists because a make
-- run can legitimately regenerate its own Makefile mid-flight -- GNU make
-- honours the `config.status: configure` rule, re-execs config.status and
-- restarts -- which silently discards any patch the caller had applied to the
-- generated Makefile. A retry over the regenerated file then reproduces the
-- same failure, so the caller gets a chance to re-apply first (2026-08-12: the
-- cross toolchains' gettext no-op override was lost exactly this way and both
-- attempts died in gettext's configure).
function run_make_target(make, build, buildenvs, target, opt)
    opt = opt or {}
    local args = (target and target ~= "") and make_args_for(make, target) or make_args_for(make)
    args = table.join(args, make_tool_args())
    local logfile = make_target_log_file(build, target)
    if target and target ~= "" then
        errors.log(string.format("running make target: %s (-j%d)", target, make_jobs()))
    else
        errors.log(string.format("running make (-j%d)", make_jobs()))
    end
    local ok = errors.trycall(function ()
        run_make_with_log(make, args, {curdir = build, envs = buildenvs}, logfile)
    end)
    if not ok then
        errors.warn("make failed; retrying once in case a transient file lock (antivirus or indexer) broke a build step")
        errors.sleep(2)
        if opt.before_retry then
            opt.before_retry()
        end
        ok = errors.trycall(function ()
            run_make_with_log(make, args, {curdir = build, envs = buildenvs}, logfile)
        end)
    end
    if not ok then
        local target_os = settings.configured_target_os()
        run.print_error_context("make", target_os, {
            {"make target", tostring((target and target ~= "") and target or "all")},
            {"command", base.command_text(make, args)},
            {"build directory", build},
            {"make log", logfile},
            {"host compiler", base.is_windows_host() and hosttools.windows_host_compiler() or nil}
        })
        print_make_failure_logs(build, target_os, target, logfile)
        if base.is_windows_host() and not hosttools.windows_bootstrap_state().active_bin then
            print("hint: if the errors above look like broken host tools (\"no input files\", \"cannot execute 'cc1'\"), rerun after `xmake f --toolchains_bootstrap=portable` to force a project-private bootstrap toolchain instead of the host one")
        end
        errors.fail("make step failed; the build directory is kept for incremental reruns after the cause is fixed")
    end
end
