-- Host tool discovery and validation: PATH/tool-dir scanning, the compiler
-- smoke test that rejects shim compilers, host MinGW sysroot detection, and
-- capability probes (GNU tar/wget). Also owns the "active Windows bootstrap
-- bin" process state that used to live in description-scope globals.

import("base")
import("errors")
import("layout")
import("settings")

-- Windows portable-bootstrap activation state (per xmake process). The
-- bootstrap provisioning logic sets these; tool discovery prepends the
-- active bin everywhere.
local bootstrap_state = {
    active_bin = nil,
    cleanup_root = nil,
    cleanup_archive = nil,
    use_lock = nil
}

function windows_bootstrap_state()
    return bootstrap_state
end

function set_windows_bootstrap_active_bin(bindir)
    bootstrap_state.active_bin = bindir
end

function set_windows_bootstrap_cleanup(root, archive)
    bootstrap_state.cleanup_root = root or bootstrap_state.cleanup_root
    bootstrap_state.cleanup_archive = archive or bootstrap_state.cleanup_archive
end

-- The shared advisory lock this process holds on the bootstrap directory while
-- it may still be using it. cleanup releases it before probing whether the
-- shared tree can be removed without robbing a concurrent build of its cc1.
function set_windows_bootstrap_use_lock(lock)
    bootstrap_state.use_lock = lock
end

function clear_windows_bootstrap_state()
    bootstrap_state.active_bin = nil
    bootstrap_state.cleanup_root = nil
    bootstrap_state.cleanup_archive = nil
    bootstrap_state.use_lock = nil
end

function windows_bootstrap_search_dirs()
    local dirs = {}
    if bootstrap_state.active_bin and bootstrap_state.active_bin ~= "" and os.isdir(bootstrap_state.active_bin) then
        table.insert(dirs, bootstrap_state.active_bin)
    end
    return dirs
end

function windows_short_path(value)
    if not base.is_windows_host() then
        return value
    end
    if not tostring(value):find(" ", 1, true) then
        return value
    end
    local mapped = value:gsub("^([A-Za-z]):\\Program Files %(x86%)", "%1:\\PROGRA~2")
    mapped = mapped:gsub("^([A-Za-z]):\\Program Files", "%1:\\PROGRA~1")
    if mapped ~= value and not mapped:find(" ", 1, true) and (os.isdir(mapped) or os.isfile(mapped)) then
        return mapped
    end
    local out = os.iorunv("cmd", {"/c", "for %I in (\"" .. value .. "\") do @echo %~sI"}, {try = true})
    if out and out ~= "" then
        out = out:gsub("^%s+", ""):gsub("%s+$", "")
        if out ~= "" and not out:find(" ", 1, true) then
            return out
        end
    end
    return value
end

function project_tool_search_dirs()
    local root = layout.tools_cache_dir()
    local candidates = {
        path.join(root, "bin"),
        path.join(root, "winflexbison"),
        path.join(root, "m4", "bin"),
        path.join(root, "flex", "bin"),
        path.join(root, "bison", "bin")
    }
    for _, dir in ipairs(windows_bootstrap_search_dirs()) do
        table.insert(candidates, dir)
    end
    local dirs = {}
    for _, dir in ipairs(candidates) do
        if os.isdir(dir) then
            table.insert(dirs, dir)
        end
    end
    return dirs
end

function find_tool_paths(program)
    local result = {}
    local seen = {}
    local function add(candidate)
        if candidate and candidate ~= "" and os.isfile(candidate) then
            candidate = path.absolute(candidate)
            local key = candidate:gsub("\\", "/")
            if base.is_windows_host() then
                key = key:lower()
            end
            if not seen[key] then
                seen[key] = true
                table.insert(result, candidate)
            end
        end
    end
    if os.isfile(program) then
        add(program)
        return result
    end
    local exts = {""}
    if base.is_windows_host() then
        exts = {".exe", ".cmd", ".bat", ""}
    end
    for _, dir in ipairs(project_tool_search_dirs()) do
        for _, ext in ipairs(exts) do
            add(path.join(dir, program .. ext))
        end
    end
    for _, dir in ipairs((os.getenv("PATH") or ""):split(base.pathsep(), {plain = true})) do
        for _, ext in ipairs(exts) do
            add(path.join(dir, program .. ext))
        end
    end
    return result
end

function find_tool_path(program)
    return find_tool_paths(program)[1]
end

function windows_mingw_bin_dir()
    if not base.is_windows_host() then
        return nil
    end
    local gcc = find_tool_path(settings.host_triplet() .. "-gcc") or find_tool_path("gcc")
    if gcc then
        local bindir = path.directory(gcc)
        if os.isdir(bindir) then
            return windows_short_path(bindir)
        end
    end
end

function preferred_posix_shell()
    if base.is_windows_host() then
        for _, dir in ipairs(project_tool_search_dirs()) do
            local shell = path.join(dir, base.exe("sh"))
            if os.isfile(shell) then
                return shell
            end
        end
        local mingwbin = windows_mingw_bin_dir()
        if mingwbin then
            local shell = path.join(mingwbin, base.exe("sh"))
            if os.isfile(shell) then
                return shell
            end
        end
    end
    return find_tool_path("sh") or "sh"
end

function windows_extra_path_dirs()
    local dirs = {}
    if base.is_windows_host() then
        for _, dir in ipairs(project_tool_search_dirs()) do
            table.insert(dirs, windows_short_path(dir))
        end
        local mingwbin = windows_mingw_bin_dir()
        if mingwbin then
            table.insert(dirs, mingwbin)
        end
    end
    return dirs
end

function preferred_host_tool(program)
    if base.is_windows_host() then
        for _, dir in ipairs(windows_extra_path_dirs()) do
            local candidate = path.join(dir, base.exe(program))
            if os.isfile(candidate) then
                return candidate
            end
        end
    end
    return find_tool_path(program) or program
end

function preferred_project_tool(program)
    for _, dir in ipairs(project_tool_search_dirs()) do
        local candidate = path.join(dir, base.exe(program))
        if os.isfile(candidate) then
            return candidate
        end
    end
end

function preferred_host_tool_any(candidates)
    for _, candidate in ipairs(candidates) do
        local project_tool = preferred_project_tool(candidate)
        if project_tool then
            return project_tool
        end
        local tool = preferred_host_tool(candidate)
        if os.isfile(tool) or tool ~= candidate then
            return tool
        end
    end
    return candidates[1]
end

function shell_host_tool(program)
    return base.shell_path_entry(preferred_host_tool(program))
end

function shell_host_tool_any(candidates)
    return base.shell_path_entry(preferred_host_tool_any(candidates))
end

function host_tool_output(program, args)
    local out = os.iorunv(program, args or {}, {try = true})
    return base.trim(out)
end

function tool_exists_any(programs)
    for _, program in ipairs(programs) do
        local tool = preferred_host_tool(program)
        if os.isfile(tool) or find_tool_path(program) then
            return true
        end
    end
    return false
end

function tool_exists(program)
    return tool_exists_any({program})
end

function tar_supports_xz()
    local tar = preferred_host_tool("tar")
    if not tar or tar == "" then
        return false
    end
    local ok, out = errors.trycall(function ()
        return os.iorunv(tar, {"--version"})
    end)
    if not ok then
        return false
    end
    out = tostring(out or ""):lower()
    return out:find("liblzma", 1, true) ~= nil or out:find("bsdtar", 1, true) ~= nil
end

local tar_force_local_verdicts = {}

function tar_supports_force_local(tar)
    if not tar or tar == "" then
        return false
    end
    local cached = tar_force_local_verdicts[tar]
    if cached ~= nil then
        return cached
    end
    local ok, out = errors.trycall(function ()
        return os.iorunv(tar, {"--version"})
    end)
    local verdict = ok and tostring(out or ""):lower():find("gnu tar", 1, true) ~= nil
    verdict = verdict or false
    tar_force_local_verdicts[tar] = verdict
    return verdict
end

local wget_gnu_verdicts = {}

function wget_is_gnu(wget)
    if not wget or wget == "" then
        return false
    end
    local cached = wget_gnu_verdicts[wget]
    if cached ~= nil then
        return cached
    end
    local ok, out = errors.trycall(function ()
        return os.iorunv(wget, {"--version"})
    end)
    local verdict = (ok and tostring(out or ""):lower():find("gnu wget", 1, true) ~= nil) or false
    wget_gnu_verdicts[wget] = verdict
    return verdict
end

local smoke_verdicts = {}

-- A compiler discovered on PATH can be a wrapper or shim (opam/DKML shims,
-- package-manager launchers) that survives existence and sysroot probes yet
-- drops or mangles real command lines; GCC's own build then fails thousands
-- of steps later with errors like "no input files" or "cannot execute cc1".
-- Validate candidates up front by compiling, linking, and running a tiny
-- program in the same shape the GCC build uses: sh-driven, with -D defines,
-- a ../-relative source path, and a separate link step. When no POSIX shell
-- is available yet, fall back to invoking the compiler directly: less
-- faithful to the sh-driven build shape, but a kit whose backend is gone
-- (interrupted extraction, antivirus quarantine of cc1) must still be
-- rejected here instead of thousands of steps into configure (field
-- incident 2026-07-18: the former vacuous pass on shell-less hosts let a
-- broken bootstrap reach configure, which died with the cryptic
-- "C compiler cannot create executables").
function compiler_smoke_ok(cc, cxx, shell)
    local key = tostring(cc) .. "\n" .. tostring(cxx or "") .. "\n" .. tostring(shell or "")
    local cached = smoke_verdicts[key]
    if cached ~= nil then
        return cached
    end
    shell = shell or preferred_posix_shell()
    local shelled = os.isfile(shell)
    local root = layout.unique_cache_path("compiler-smoke", "smoke")
    local srcdir = path.join(root, "src")
    local workdir = path.join(root, "work")
    -- Neutralize the hostile GCC-relevant vars inherited from the launching
    -- shell (GCC_EXEC_PREFIX / COMPILER_PATH / CPATH / *_INCLUDE_PATH / ...)
    -- so the smoke test reproduces the same hermetic environment the real
    -- toolchain build uses (shell_envs/make_envs both wrap this). xmake MERGES
    -- the parent env into a child, so without this a stray var would make gcc
    -- fail here and falsely reject a perfectly good host compiler. Imported
    -- lazily because envs imports hosttools (avoids a load-time import cycle).
    local envs = import("envs").with_hermetic_build_envs({})
    local bindirs = {}
    for _, tool in ipairs({cc, cxx}) do
        if tool and os.isfile(tool) then
            table.insert(bindirs, path.directory(tool))
        end
    end
    if #bindirs > 0 then
        envs.PATH = table.concat(bindirs, base.pathsep()) .. base.pathsep() .. (os.getenv("PATH") or "")
    end
    local steps = {{cc, "smoke.c", "smoke_c"}}
    if cxx then
        table.insert(steps, {cxx, "smoke.cpp", "smoke_cxx"})
    end
    local ok, result = errors.trycall(function ()
        os.mkdir(srcdir)
        os.mkdir(workdir)
        io.writefile(path.join(srcdir, "smoke.c"),
            "int main(void)\n{\n\treturn WHE_SMOKE_ANSWER - 42;\n}\n")
        io.writefile(path.join(srcdir, "smoke.cpp"),
            "#include <string>\n\nint main()\n{\n\tstd::string text(\"whe\");\n\treturn static_cast<int>(text.size()) - 3;\n}\n")
        for _, step in ipairs(steps) do
            local tool, source, output = step[1], step[2], step[3]
            local produced = output .. (base.is_windows_host() and ".exe" or "")
            if shelled then
                os.runv(shell, {"-c", base.shquote(tool) .. " -DWHE_SMOKE_ANSWER=42 -c ../src/" .. source .. " -o " .. output .. ".o"},
                    {curdir = workdir, envs = envs, timeout = 120000})
                os.runv(shell, {"-c", base.shquote(tool) .. " " .. output .. ".o -o " .. produced},
                    {curdir = workdir, envs = envs, timeout = 120000})
            else
                os.runv(tool, {"-DWHE_SMOKE_ANSWER=42", "-c", "../src/" .. source, "-o", output .. ".o"},
                    {curdir = workdir, envs = envs, timeout = 120000})
                os.runv(tool, {output .. ".o", "-o", produced},
                    {curdir = workdir, envs = envs, timeout = 120000})
            end
            local produced_path = path.join(workdir, produced)
            if not os.isfile(produced_path) then
                return false
            end
            os.runv(produced_path, {}, {curdir = workdir, envs = envs, timeout = 120000})
        end
        return true
    end)
    local verdict = ok and result == true
    errors.trycall(function ()
        layout.remove_toolchains_path(root)
        return true
    end)
    smoke_verdicts[key] = verdict
    if not verdict then
        errors.warn("host compiler failed the compile/link/run smoke test and will not be used: %s", tostring(cc))
    end
    return verdict
end

function sibling_host_tool(cc, names)
    local bindir = path.directory(cc)
    for _, name in ipairs(names) do
        local candidate = path.join(bindir, base.exe(name))
        if os.isfile(candidate) then
            return candidate
        end
    end
end

function windows_mingw_sysroot_is_complete(root)
    return root and root ~= ""
        and os.isfile(path.join(root, "include", "stdio.h"))
        and os.isfile(path.join(root, "include", "stdarg.h"))
        and os.isfile(path.join(root, "include", "limits.h"))
        and os.isfile(path.join(root, "lib", "crt2.o"))
end

function windows_mingw_sysroot_from_compiler(cc)
    local candidates = {}
    local seen = {}
    local function add(root)
        if root and root ~= "" then
            root = path.absolute(root)
            local key = root:gsub("\\", "/")
            if base.is_windows_host() then
                key = key:lower()
            end
            if not seen[key] then
                seen[key] = true
                table.insert(candidates, root)
                table.insert(candidates, path.join(root, settings.host_triplet()))
            end
        end
    end

    local sysroot = host_tool_output(cc, {"-print-sysroot"})
    if sysroot ~= "" and os.isdir(sysroot) then
        add(sysroot)
    end

    local bindir = path.directory(cc)
    add(path.join(bindir, ".."))

    local include = host_tool_output(cc, {"-print-file-name=include"})
    if include ~= "" then
        add(path.join(path.directory(include), "..", "..", "..", ".."))
    end

    local crt2 = host_tool_output(cc, {"-print-file-name=crt2.o"})
    if crt2 ~= "" and os.isfile(crt2) then
        add(path.join(path.directory(crt2), ".."))
    end

    for _, root in ipairs(candidates) do
        if windows_mingw_sysroot_is_complete(root) then
            return root
        end
    end
end

local windows_host_info_cache

function invalidate_windows_host_info()
    windows_host_info_cache = nil
end

function windows_host_info()
    if windows_host_info_cache then
        return windows_host_info_cache
    end
    local candidates = {}
    for _, program in ipairs({settings.host_triplet() .. "-gcc", "gcc"}) do
        for _, tool in ipairs(find_tool_paths(program)) do
            table.insert(candidates, tool)
        end
    end
    local smoke_rejected
    for _, cc in ipairs(candidates) do
        local sysroot = windows_mingw_sysroot_from_compiler(cc)
        if sysroot then
            local cxx = sibling_host_tool(cc, {settings.host_triplet() .. "-g++", "g++"})
            if compiler_smoke_ok(cc, cxx) then
                windows_host_info_cache = {compiler = cc, sysroot = sysroot}
                return windows_host_info_cache
            end
            smoke_rejected = smoke_rejected or cc
        end
    end
    windows_host_info_cache = {compiler = candidates[1] or (settings.host_triplet() .. "-gcc"), smoke_rejected = smoke_rejected}
    return windows_host_info_cache
end

function windows_host_compiler()
    return windows_host_info().compiler
end

function windows_host_sysroot()
    return windows_host_info().sysroot
end
