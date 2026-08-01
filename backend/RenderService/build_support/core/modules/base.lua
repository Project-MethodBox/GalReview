-- Language-agnostic pure helpers: string/path/arch primitives with no
-- dependency on any other build_support module. Import()-module rules for
-- this tree (established by the phase-0 spikes, 2026-07-10):
--   * modules run in script scope: use os/path/io/table directly, never the
--     old xos()/xpath() indirection;
--   * sibling modules import each other with a bare import("name") -- it
--     resolves against the importing module's own directory;
--   * os.scriptdir() is only trustworthy at module LOAD time (top level);
--     inside functions it reflects the caller's script, so capture needed
--     paths in a module-top local.

function trim(value)
    -- outer parentheses matter: gsub returns (string, count) and a bare
    -- multi-return here poisons callers like tonumber(trim(x))
    return ((value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function shpath(value)
    local text = value:gsub("\\", "/")
    return text
end

function shquote(value)
    return "'" .. shpath(value):gsub("'", "'\\''") .. "'"
end

-- Same transform as shpath, kept as a distinct name for call sites building a
-- PATH-list entry rather than a shell command argument (the two could
-- reasonably diverge later, e.g. UNC-path handling).
function shell_path_entry(value)
    return shpath(value)
end

function host_os()
    local host = os.host()
    if host == "macos" or host == "macosx" then
        return "macosx"
    end
    return host
end

function is_windows_host()
    return host_os() == "windows"
end

function exe(name)
    return is_windows_host() and (name .. ".exe") or name
end

function pathsep()
    return is_windows_host() and ";" or ":"
end

-- Same value as pathsep, kept as a distinct name for shell-command-line PATH
-- construction versus os.getenv("PATH")-splitting.
function shell_pathsep()
    return pathsep()
end

function escape_pattern(value)
    return (value:gsub("([^%w])", "%%%1"))
end

function replace_plain(content, needle, replacement)
    -- both sides are literal text: escape gsub captures in the replacement
    -- too, otherwise diagnostic format strings like %qD inside patch bodies
    -- raise "invalid use of '%' in replacement string" on first application
    return (content:gsub(escape_pattern(needle), (replacement:gsub("%%", "%%%%"))))
end

function append_flags_once(value, flags)
    value = trim(value or "")
    flags = trim(flags or "")
    if flags == "" then
        return value
    end
    -- Token-boundary match, not substring: padding both sides with a space
    -- turns "is flags already a whitespace-delimited run in value" into a
    -- plain substring search, so "-DFOO" no longer false-matches inside an
    -- already-present "-DFOO_ENABLED=1".
    if (" " .. value .. " "):find(" " .. flags .. " ", 1, true) then
        return value
    end
    if value == "" then
        return flags
    end
    return value .. " " .. flags
end

function normalized_path(value)
    local text = path.absolute(value):gsub("\\", "/")
    if is_windows_host() then
        text = text:lower()
    end
    return text
end

function canonical_arch(arch, target_os)
    if arch == "arm64" or arch == "aarch64" then
        return "aarch64"
    elseif arch == "arm64-v8a" then
        return "aarch64"
    elseif arch == "x64" or arch == "x86_64" then
        return "x86_64"
    elseif arch == "x86" or arch == "i386" then
        return "i686"
    elseif arch == "armeabi-v7a" then
        return target_os == "android" and "armv7a" or "armv7"
    end
    return arch
end

function arch_folder_name(arch)
    if arch == "x86_64" then
        return "x64"
    elseif arch == "aarch64" then
        return "arm64"
    elseif arch == "i686" then
        return "x86"
    end
    return arch
end

function first_existing(candidates, fallback)
    for _, candidate in ipairs(candidates) do
        if os.exists(candidate) then
            return candidate
        end
    end
    return fallback or candidates[1]
end

function file_nonempty(file)
    if not os.isfile(file) then
        return false
    end
    if os.filesize then
        return os.filesize(file) > 0
    end
    return true
end

function copy_if_exists(source, target)
    if os.exists(source) then
        os.cp(source, target)
    end
end

function writefile_bytes(file, content)
    local handle, err = io.open(file, "wb")
    if not handle then
        os.raise(string.format("failed to open file for binary write: %s (%s)", file, tostring(err)))
    end
    handle:write(content or "")
    handle:close()
end

function command_text(program, args)
    local text = tostring(program or "")
    for _, arg in ipairs(args or {}) do
        text = text .. " " .. tostring(arg)
    end
    return text
end
