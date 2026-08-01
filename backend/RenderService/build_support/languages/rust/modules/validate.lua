-- Pre-compile validators for the engine Rust crate (rust.cargo runs them
-- from its before_build hook, before invoking Cargo), in the aggregate
-- validator's spirit: every problem is collected and reported in one pass
-- with exact file locations, and each check exists because the silent
-- failure mode it prevents was judged worse than the friction.
--
--   * orphan detection: a .rs file the crate's mod tree never reaches would
--     silently not participate in the build ("无感" must never mean
--     "silently ignored"); escape hatch: a `// rust.cargo: allow-orphan`
--     line inside the file.
--   * #![no_std] enforcement: C++ owns the host runtime, allocation,
--     diagnostics and final link; alloc is available via the rs/runtime.rs
--     allocator bridge. A std crate would fail at link time with obscure
--     errors.
--   * export prefix: #[no_mangle]/#[export_name] symbols share the global
--     flat namespace with C/C++; a project-declared prefix rule (see
--     add_rustexportprefix) turns collisions from a probability into an
--     impossibility. ABI-mandated names the dist libraries require are
--     whitelisted here. Projects that declare no prefix skip this check.
--
-- Duplicate #[panic_handler] needs no validator anymore: within one crate
-- rustc itself rejects it immediately as a duplicate lang item.

import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})

-- Symbols whose names are fixed by rustc/ABI expectations, not by us.
local EXPORT_WHITELIST = {
    ["rust_eh_personality"] = true,
}

local function read_lines(file)
    local content = io.readfile(file) or ""
    local lines = {}
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        table.insert(lines, line)
    end
    return content, lines
end

-- Collects the files reachable from the crate root by following `mod x;`
-- declarations (standard layout: x.rs or x/mod.rs beside the declaring
-- file; a directory module continues from x/mod.rs). Inline `mod x { ... }`
-- needs no file and is ignored.
local function reachable_files(root_file)
    local reached = {}
    local function visit(file, dir)
        if reached[path.absolute(file)] then
            return
        end
        reached[path.absolute(file)] = true
        local content = read_lines(file)
        -- strip line comments cheaply so commented-out mods don't count
        content = content:gsub("//[^\n]*", "")
        for name in content:gmatch("%f[%w_]mod%s+([%w_]+)%s*;") do
            local sibling = path.join(dir, name .. ".rs")
            local nested = path.join(dir, name, "mod.rs")
            -- Both the file-module (name.rs) and directory-module (name/mod.rs)
            -- forms own their child modules under name/, so the recursion must
            -- descend into dir/name either way (Rust 2018+ resolution). Passing
            -- the parent dir for the file-module form misreads the modern layout
            -- and false-flags legitimate name/child.rs files as orphans.
            if os.isfile(sibling) then
                visit(sibling, path.join(dir, name))
            elseif os.isfile(nested) then
                visit(nested, path.join(dir, name))
            end
        end
    end
    visit(root_file, path.directory(root_file))
    return reached
end

-- problems: array collecting "file: message" strings across all checks
local function check_orphans(root_file, sources, problems)
    local reached = reachable_files(root_file)
    for _, file in ipairs(sources) do
        if not reached[path.absolute(file)] then
            local content = read_lines(file)
            if not content:find("rust.cargo: allow-orphan", 1, true) then
                -- a directory module's mod.rs is declared by the directory
                -- name, not by the literal (and illegal) `mod mod;`
                local suggested = path.basename(file)
                if suggested == "mod" then
                    suggested = path.filename(path.directory(file))
                end
                table.insert(problems, string.format(
                    "%s: not reachable from the crate root's mod tree; add the missing `mod %s;` or mark the file `// rust.cargo: allow-orphan`",
                    file, suggested))
            end
        end
    end
end

local function check_no_std(root_file, problems)
    local content = read_lines(root_file)
    content = content:gsub("//[^\n]*", "")
    if not content:find("#![no_std]", 1, true) then
        table.insert(problems, string.format(
            "%s: crate root must declare #![no_std] (C++ owns the host runtime and final link; alloc is reached through the rs/runtime.rs allocator bridge, not std)",
            root_file))
    end
end

local function check_export_prefix(sources, export_prefix, problems)
    local function flag(file, index, kind, symbol)
        if EXPORT_WHITELIST[symbol] or symbol:startswith(export_prefix) then
            return
        end
        table.insert(problems, string.format(
            '%s:%d: %s symbol "%s" must carry the %s prefix (global namespace collision policy)',
            file, index, kind, symbol, export_prefix))
    end
    for _, file in ipairs(sources) do
        local _, lines = read_lines(file)
        local pending_attribute = nil
        for index, line in ipairs(lines) do
            local stripped = line:gsub("//.*$", "")
            local export_name = stripped:match('#%[export_name%s*=%s*"([^"]+)"%]')
            if export_name then
                flag(file, index, "exported", export_name)
            end
            if pending_attribute then
                -- `static mut` must be tried before `static`: the shorter
                -- pattern would capture "mut" as the symbol name
                local symbol = stripped:match("%f[%w_]fn%s+([%w_]+)")
                    or stripped:match("%f[%w_]static%s+mut%s+([%w_]+)")
                    or stripped:match("%f[%w_]static%s+([%w_]+)")
                if symbol then
                    flag(file, index, "#[no_mangle]", symbol)
                    pending_attribute = nil
                elseif stripped:match("%S") and not stripped:match("^%s*#%[") then
                    pending_attribute = nil
                end
            end
            if stripped:match("#%[no_mangle%]") or stripped:match("#%[unsafe%(no_mangle%)%]") then
                -- attribute and item on one line, or item on a later line
                local same_line = stripped:match("no_mangle.-%f[%w_]fn%s+([%w_]+)")
                    or stripped:match("no_mangle.-%f[%w_]static%s+m?u?t?%s*([%w_]+)")
                if same_line then
                    flag(file, index, "#[no_mangle]", same_line)
                else
                    pending_attribute = index
                end
            end
        end
    end
end

-- Runs every check over the crate tree; fails loudly with the full problem
-- list (one pass, aggregate-validator style).
--   opt: root_file (the crate root, <rootdir>/lib.rs), sources (every .rs
--   under the root), export_prefix (project symbol prefix; nil/empty skips
--   the prefix check -- the policy belongs to the project, not this module)
function run(opt)
    local problems = {}
    check_no_std(opt.root_file, problems)
    check_orphans(opt.root_file, opt.sources, problems)
    if opt.export_prefix and opt.export_prefix ~= "" then
        check_export_prefix(opt.sources, opt.export_prefix, problems)
    end
    if #problems > 0 then
        errors.fail("rust crate validation failed:\n  %s", table.concat(problems, "\n  "))
    end
end
