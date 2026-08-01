-- Configure-time validators for the C++ module tree (the gcc.modules rule
-- runs them from its on_config hook), in the rust validate.lua spirit:
-- every problem is collected and reported in one pass with exact file
-- locations, and each check exists because the silent failure mode it
-- prevents was judged worse than the friction.
--
--   * interface-unit classification: the predicate the rule uses to demote
--     non-interface units back to private fileconfig (the demotion itself
--     mutates target state and stays in the rule shell).
--   * aggregate completeness: a leaf partition missing from its branch
--     aggregate compiles fine but its exports silently never reach
--     `import <module>;` consumers, failing far from the cause.
--   * partition-name <-> file-path consistency: naming_rules item 4 derives
--     an interface partition's name from its path; the aggregate checks
--     trust declared names, so a wrong name would otherwise pass.
--   * import cycle detection and branch-layer direction: spec
--     module-organization items 10 and 11.
--
-- collect_problems/scan_units only consume a { [sourcefile] = content }
-- table plus optional overrides, so fixture content tables can drive them
-- without a target or a configured project.

import("layers", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})

-- Deterministic iteration order over the shared content table (the rule
-- shell builds it from target:sourcefiles(); fixtures build it by hand).
local function sorted_files(file_contents)
    local files = {}
    for sourcefile in pairs(file_contents) do
        table.insert(files, sourcefile)
    end
    table.sort(files)
    return files
end

-- Path of a module unit relative to the source root, dotted-name form without
-- the .cpp suffix, or nil when the file is not under that root. The source root
-- is the directory of the primary interface unit (see collect_problems), never
-- a hardcoded project path -- so moving the source tree does not silently
-- disable the path-consistency check.
local function module_relative_path(sourcefile, source_root, projectdir)
    if not source_root then
        return nil
    end
    local normalized = path.absolute(sourcefile, projectdir):gsub("\\", "/")
    local root = path.absolute(source_root, projectdir):gsub("\\", "/"):gsub("/+$", "") .. "/"
    if normalized:sub(1, #root) ~= root then
        return nil
    end
    return normalized:sub(#root + 1):match("(.+)%.cpp$")
end

-- Unconditional imports only: imports inside any #if/#ifdef region are
-- configuration-dependent and are skipped -- a project's dormant feature
-- gates may intentionally keep textual cycles that never activate together
-- (owner-controlled redesign areas), and platform-gated imports differ per
-- build anyway.
local function unconditional_imports(content, unit_by_name)
    local imports = {}
    local depth = 0
    for line in content:gmatch("[^\r\n]+") do
        if line:find("^%s*#%s*if") then
            depth = depth + 1
        elseif line:find("^%s*#%s*endif") then
            depth = math.max(depth - 1, 0)
        elseif depth == 0 then
            local part = line:match("^%s*export%s+import%s+:%s*([%w_.]+)%s*;")
                or line:match("^%s*import%s+:%s*([%w_.]+)%s*;")
            if part and unit_by_name[part] then
                table.insert(imports, part)
            end
        end
    end
    return imports
end

-- True when the unit content is a module interface unit. A named
-- `module <name>;` before any `export module` marks an implementation
-- unit; the bare global-module-fragment opener `module;` does not match
-- and keeps the scan going. Callers own the missing-content case (the
-- rule shell treats unreadable files as interface units so
-- misclassification stays loud).
function is_interface_unit(content)
    for line in content:gmatch("[^\r\n]+") do
        if line:find("^%s*export%s+module%s") then
            return true
        end
        if line:find("^%s*module%s+[%w_]") then
            return false
        end
    end
    return false
end

-- A unit whose BMI other units can import, so dependent targets need it
-- propagated: a module interface unit (export module M[:P]) or a module
-- partition implementation unit (module M:P; -- the language's "internal
-- partition" form, [module.unit]). Plain implementation units (module M;)
-- are not importable and must stay target-private.
function is_importable_unit(content)
    for line in content:gmatch("[^\r\n]+") do
        if line:find("^%s*export%s+module%s") then
            return true
        end
        if line:find("^%s*module%s+[%w_]") then
            return line:find("^%s*module%s+[%w_%.]+%s*:") ~= nil
        end
    end
    return false
end

-- Classifies every unit by its module declaration. Returns
-- {primaries = module name -> {file=, content=},
--  aggregates = partition (no dot) -> {file=, content=, mod=},
--  leaves = list of {file=, part=, internal=},
--  impl_partitions = list of {file=, part=}}.
-- A leaf marked with the comment `gcc.modules: internal` is intentionally
-- not re-exported. An impl-partition unit (`module M:P;`, no export) carries
-- no re-export obligation but IS importable (its BMI is consumed), so its own
-- cross-branch imports must still be subject to the layer/cycle checks.
function scan_units(file_contents)
    local primaries = {}
    local aggregates = {}
    local leaves = {}
    local impl_partitions = {}
    for _, sourcefile in ipairs(sorted_files(file_contents)) do
        local content = file_contents[sourcefile]
        for line in content:gmatch("[^\r\n]+") do
            local mod, part = line:match("^%s*export%s+module%s+([%w_.]+)%s*:%s*([%w_.]+)%s*;")
            if mod then
                if part:find(".", 1, true) then
                    table.insert(leaves, {file = sourcefile, part = part,
                        internal = content:find("gcc.modules: internal", 1, true) ~= nil})
                else
                    aggregates[part] = {file = sourcefile, content = content, mod = mod}
                end
                break
            end
            local pmod = line:match("^%s*export%s+module%s+([%w_.]+)%s*;")
            if pmod then
                primaries[pmod] = {file = sourcefile, content = content}
                break
            end
            -- module partition implementation unit (`module M:P;`): importable,
            -- so it participates in the dependency graph even though it is not
            -- re-exported. A dotted partition name marks it.
            local ipart = line:match("^%s*module%s+[%w_.]+%s*:%s*([%w_.]+)%s*;")
            if ipart and ipart:find(".", 1, true) then
                table.insert(impl_partitions, {file = sourcefile, part = ipart})
                break
            end
            -- plain implementation unit (`module M;`): no re-export, no
            -- importable partition identity.
            if line:match("^%s*module%s+[%w_]") then
                break
            end
        end
    end
    return {primaries = primaries, aggregates = aggregates, leaves = leaves,
        impl_partitions = impl_partitions}
end

-- Runs every module-organization check over the shared content table and
-- returns the sorted problem list (the fixture-regression hook: pure over
-- file_contents plus opts, no target/config access).
--   opts.projectdir: path-derivation base, defaults to os.projectdir()
--   opts.level_of:   manual branch-layer lookup. When given (the project
--                    declared an explicit layer order), the branch check runs
--                    the direction check below. When ABSENT, the layering is
--                    derived from the module graph itself, so the branch check
--                    degrades to branch-cycle detection (a derived order can
--                    never be violated in direction, only looped).
function collect_problems(file_contents, opts)
    local projectdir = opts and opts.projectdir or os.projectdir()
    local level_of = opts and opts.level_of
    local units = scan_units(file_contents)
    local primaries = units.primaries
    local aggregates = units.aggregates
    local leaves = units.leaves

    -- Source root = the directory of the primary interface unit (the
    -- `export module M;` with no partition, which lives at the tree root). All
    -- path-consistency checks derive names relative to this, so no project path
    -- is baked into build_support and a relocated tree stays validated.
    local source_root
    do
        local primary_files = {}
        for _, primary in pairs(primaries) do
            table.insert(primary_files, primary.file)
        end
        table.sort(primary_files)
        source_root = primary_files[1] and path.directory(primary_files[1]) or nil
    end

    -- Aggregate completeness validation: derive the expected re-export
    -- lists from the module declarations themselves and fail the
    -- configuration with the exact lines to fix.
    local problems = {}
    for branch, agg in pairs(aggregates) do
        local listed = {}
        for part in agg.content:gmatch("export%s+import%s+:%s*([%w_.]+)%s*;") do
            listed[part] = true
        end
        for _, leaf in ipairs(leaves) do
            if leaf.part:sub(1, #branch + 1) == branch .. "." then
                if leaf.internal then
                    if listed[leaf.part] then
                        table.insert(problems, string.format(
                            "%s is marked `gcc.modules: internal` but still re-exported; remove `export import :%s;` from %s",
                            leaf.file, leaf.part, agg.file))
                    end
                elseif not listed[leaf.part] then
                    table.insert(problems, string.format(
                        "missing re-export: add `export import :%s;` to %s (declared in %s)",
                        leaf.part, agg.file, leaf.file))
                end
                listed[leaf.part] = nil
            end
        end
        for part in pairs(listed) do
            if part:sub(1, #branch + 1) == branch .. "." then
                table.insert(problems, string.format(
                    "stale re-export: %s lists `%s` but no source file declares that partition",
                    agg.file, part))
            end
        end
    end
    local leafset = {}
    for _, leaf in ipairs(leaves) do
        leafset[leaf.part] = true
    end
    for mod, primary in pairs(primaries) do
        local listed = {}
        for part in primary.content:gmatch("export%s+import%s+:%s*([%w_.]+)%s*;") do
            listed[part] = true
        end
        for branch, agg in pairs(aggregates) do
            if agg.mod == mod then
                if not listed[branch] then
                    table.insert(problems, string.format(
                        "missing re-export: add `export import :%s;` to the primary interface %s (aggregate %s)",
                        branch, primary.file, agg.file))
                end
                listed[branch] = nil
            end
        end
        -- leaves whose branch has no aggregate partition are re-exported
        -- by the primary interface directly
        for _, leaf in ipairs(leaves) do
            local branch = leaf.part:match("^([%w_]+)%.")
            if not (branch and aggregates[branch]) then
                if leaf.internal then
                    if listed[leaf.part] then
                        table.insert(problems, string.format(
                            "%s is marked `gcc.modules: internal` but still re-exported; remove `export import :%s;` from %s",
                            leaf.file, leaf.part, primary.file))
                    end
                elseif not listed[leaf.part] then
                    table.insert(problems, string.format(
                        "missing re-export: add `export import :%s;` to the primary interface %s (declared in %s)",
                        leaf.part, primary.file, leaf.file))
                end
                listed[leaf.part] = nil
            end
        end
        for part in pairs(listed) do
            if part:find(".", 1, true) then
                if not leafset[part] then
                    table.insert(problems, string.format(
                        "stale re-export: primary interface %s lists `:%s` but no source file declares that partition",
                        primary.file, part))
                end
            elseif not aggregates[part] then
                table.insert(problems, string.format(
                    "stale re-export: primary interface %s lists `:%s` but no partition declares it",
                    primary.file, part))
            end
        end
    end
    -- Partition-name <-> file-path consistency: naming_rules item 4 makes
    -- an interface partition's name the file path relative to
    -- WhiteHopeEngine/cpp joined with dots, and the aggregate checks above
    -- trust declared names -- a partition declared under a wrong name
    -- would still pass as long as the aggregate lists the same wrong
    -- name. Aggregates use the bare branch name and must live at
    -- <Branch>/<Branch>.cpp (spec module-organization item 3).
    for _, leaf in ipairs(leaves) do
        local rel = module_relative_path(leaf.file, source_root, projectdir)
        if rel then
            local expected = rel:gsub("/", ".")
            if leaf.part ~= expected then
                table.insert(problems, string.format(
                    "partition name does not match its file path: %s declares `:%s` but the path derives `:%s` (rename the file or the partition so they agree; a `module` keyword segment must be spelled differently in BOTH, e.g. pe_module.cpp)",
                    leaf.file, leaf.part, expected))
            end
        end
    end
    -- A dot-free partition is either a branch aggregate (declared in
    -- <Branch>/<Branch>.cpp, spec item 3) or a plain single-file leaf at
    -- the cpp root (like Version.cpp, where the path-derived name and the
    -- partition name already coincide).
    for branch, agg in pairs(aggregates) do
        local rel = module_relative_path(agg.file, source_root, projectdir)
        if rel and rel ~= branch .. "/" .. branch and rel ~= branch then
            table.insert(problems, string.format(
                "partition `:%s` must be declared in %s/%s.cpp (branch aggregate) or %s.cpp (root leaf) under the module source root, not in %s",
                branch, branch, branch, branch, agg.file))
        end
    end

    -- Partition import cycle detection over UNCONDITIONAL imports only:
    -- the compiler diagnoses cycles too, but mid-build and one edge at a
    -- time; here the whole cycle is named up front at configure time.
    local unit_by_name = {}
    for _, leaf in ipairs(leaves) do
        unit_by_name[leaf.part] = {file = leaf.file, content = file_contents[leaf.file]}
    end
    for branch, agg in pairs(aggregates) do
        unit_by_name[branch] = {file = agg.file, content = agg.content}
    end
    -- Impl-partition units are importable, so include them as graph nodes: both
    -- their outgoing cross-branch imports and imports targeting them count.
    for _, unit in ipairs(units.impl_partitions) do
        unit_by_name[unit.part] = {file = unit.file, content = file_contents[unit.file]}
    end
    local visiting = {}
    local visited = {}
    local cycle
    local function visit(name, chain)
        if cycle or visited[name] then
            return
        end
        if visiting[name] then
            local start = 1
            for index, entry in ipairs(chain) do
                if entry == name then
                    start = index
                    break
                end
            end
            cycle = {}
            for index = start, #chain do
                table.insert(cycle, chain[index])
            end
            table.insert(cycle, name)
            return
        end
        visiting[name] = true
        table.insert(chain, name)
        for _, imported in ipairs(unconditional_imports(unit_by_name[name].content, unit_by_name)) do
            visit(imported, chain)
            if cycle then
                break
            end
        end
        table.remove(chain)
        visiting[name] = false
        visited[name] = true
    end
    local unit_names = {}
    for name in pairs(unit_by_name) do
        table.insert(unit_names, name)
    end
    table.sort(unit_names)
    for _, name in ipairs(unit_names) do
        visit(name, {})
        if cycle then
            break
        end
    end
    if cycle then
        table.insert(problems, string.format(
            "partition import cycle among unconditional imports: %s (only the first cycle found is reported; break one edge to continue)",
            table.concat(cycle, " -> ")))
    end

    -- Branch-layer check (spec item 11). Two modes, chosen by whether the
    -- project declared an explicit layer order (opts.level_of):
    --
    -- MANUAL (opts.level_of given): direction check -- cross-branch
    -- unconditional imports must point at a STRICTLY lower layer, and
    -- same-level sibling branches must not depend on each other. Branches the
    -- declaration does not rank are unconstrained (the gate is exactly as
    -- strong as the declaration); same-branch imports and gated (#if) imports
    -- are free. Leaf exemption: a partition whose own unconditional-import
    -- list is empty (nothing but `import std;`, or nothing at all) can never
    -- be a link in ANY cross-branch cycle -- it has no outgoing edge for a
    -- cycle to continue through, whichever branch's directory it sits under --
    -- so importing it is never a violation. The exemption re-evaluates every
    -- run, so a partition that later grows a real cross-branch import loses it
    -- automatically; there is no static allowlist to fall out of sync.
    --
    -- AUTO (opts.level_of absent): the layering is derived from this very
    -- module graph, so no import can point "the wrong way" by construction --
    -- the only remaining failure is a branch-level cycle. layers.from_module_graph
    -- applies the same leaf exemption, so a relocated pure-leaf mirror (e.g. a
    -- JNI ABI mirror living in LibraryEngine but imported by OSCallEngine)
    -- does not fabricate a nominal loop.
    if level_of then
        -- Delegate to layers.direction_violations so the check uses the same
        -- grouping strategy (partition-prefix or by-module) and leaf exemption
        -- as the auto path -- multi-module projects with a manual layer order
        -- get full direction enforcement, not just cycle detection.
        for _, v in ipairs(layers.direction_violations(file_contents, level_of, {grouping = opts and opts.grouping})) do
            table.insert(problems, string.format(
                "layer violation in %s: `%s` (%s, level %d) imports `%s` (%s, level %d); cross-node imports must target a strictly lower layer (spec item 11, declared layer order)",
                v.file, v.importer_id, v.importer_group, v.importer_level,
                v.imported_id, v.imported_group, v.imported_level))
        end
    else
        local auto = layers.from_module_graph(file_contents, {grouping = opts and opts.grouping})
        if auto.cycle then
            table.insert(problems, string.format(
                "branch dependency cycle among unconditional cross-branch imports: %s (a branch must not transitively import itself; break one cross-branch edge -- pure-leaf ABI/type mirrors are exempt)",
                table.concat(auto.cycle, " -> ")))
        end
    end

    table.sort(problems)
    return problems
end

-- Runs the full validation over the shared content table and fails the
-- configuration with every problem at once (mirrors rust validate.run).
function run(file_contents, opts)
    local problems = collect_problems(file_contents, opts)
    if #problems > 0 then
        os.raise("module aggregate validation failed (%d problem(s)):\n  %s",
            #problems, table.concat(problems, "\n  "))
    end
end

-- Stale-cache / MAX_PATH guard: switching plat or arch leaves the
-- previous configuration's BMI cache tree under
-- build/.gens/<target>/<oldplat>/<oldarch>/, and the host-keyed
-- cxxmodules localcache keeps handing those locations to incremental
-- builds. Reused entries then get dependency files under the NEW
-- plat's .deps root carrying the OLD tree's project-relative path;
-- long partition names overflow Windows MAX_PATH and the build dies
-- saving .gcm.d files with a cryptic "cannot open file ... Unknown
-- Error (3)". Detect foreign-plat cache trees up front and name the
-- Self-healing since 2026-07-18 (the manual remedy proved unreliable in
-- practice): every wasm<->windows session recreates the dangerous pair,
-- and under `-P` the localcache file lives in the SUBPROJECT's .xmake, so
-- the old remedy text pointed users at the wrong copy. The checker knows
-- the exact dangerous coupling -- a foreign-plat BMI tree PLUS the
-- localcache entries referencing it -- so it removes both itself and says
-- so. The cost is one module re-scan plus a foreign-plat BMI rebuild on
-- the next switch back: exactly the toll the underlying GCC CMI defect
-- makes mandatory, since reusing those entries across the switch is what
-- fails with "Unknown Error (3)". Unreferenced foreign trees stay
-- untouched (a sibling project keying the same targets maintains its own
-- tree and its own localcache -- that coexistence is fine).
--
-- opt.builddir/opt.cachefile/opt.host exist for the fixture suite, which
-- must never point this at the real project state. opt.host lets the
-- fixture exercise the self-healing core on every CI runner regardless of
-- which OS actually executes the test process -- without it, the sentinel's
-- only behavioral test could pass on a Windows runner and would necessarily
-- fail on any other host (the platform gate makes the function a no-op
-- there), since the assertions expect the healing to have actually run.
function warn_foreign_plat_cache(target, opt)
    opt = opt or {}
    -- A lane build (`xmake lane`) isolates its config/localcache per plat via
    -- XMAKE_CONFIGDIR while several plats share the conventional build tree
    -- concurrently. The cross-plat BMI reuse this sweep heals cannot happen
    -- under an isolated localcache, and deleting a sibling lane's gens would
    -- corrupt an in-flight parallel build -- so stand down for real lane
    -- builds. The fixture suite drives this function explicitly and always
    -- passes opt.builddir, so it is never mistaken for a lane.
    if not opt.builddir and os.getenv("TOOLCHAINS_LANE") then
        return
    end
    local host = opt.host or os.host()
    if host ~= "windows" then
        return
    end
    local builddir = opt.builddir or "build"
    if not opt.builddir then
        local configured = try { function ()
            local config = import("core.project.config")
            return config.builddir()
        end }
        if configured and configured ~= "" then
            builddir = configured
        end
    end
    local gens_root = path.join(builddir, ".gens", target:name())
    local current = path.absolute(path.join(gens_root, target:plat(), target:arch())):lower()
    local foreign = {}
    for _, dir in ipairs(os.dirs(path.join(gens_root, "*", "*"))) do
        if path.absolute(dir):lower() ~= current and #os.dirs(path.join(dir, "*", "rules", "bmi")) > 0 then
            table.insert(foreign, dir)
        end
    end
    if #foreign == 0 then
        return
    end
    -- Candidate localcache files. Under `xmake -P <subproject>` the sandbox
    -- projectdir follows the -P directory while the build's REAL localcache
    -- lives beside the resolved builddir (the core project root) -- found
    -- live 2026-07-18: -P builds read the empty subproject cache and never
    -- healed, which is exactly how the manual remedy kept "not working".
    local candidates = {}
    if opt.cachefile then
        candidates[path.absolute(opt.cachefile):lower()] = opt.cachefile
    else
        for _, root in ipairs({os.projectdir(), path.directory(path.absolute(builddir))}) do
            if root and root ~= "" then
                local file = path.join(root, ".xmake", os.host(), os.arch(), "cache", "cxxmodules")
                candidates[path.absolute(file):lower()] = file
            end
        end
    end
    -- the xmake module sandbox exposes no global `next`, so presence is
    -- tracked with an explicit list instead of next()-probing the set
    local referenced = {}
    local removed = {}
    local referencing_files = {}
    for _, cachefile in pairs(candidates) do
        local cache_content = os.isfile(cachefile) and (io.readfile(cachefile) or "") or ""
        local normalized = cache_content:gsub("\\\\", "/"):gsub("\\", "/")
        local hit = false
        for _, dir in ipairs(foreign) do
            local tail = path.absolute(dir):gsub("\\", "/"):match("(%.gens/.+)$")
            if tail and normalized:find(tail, 1, true) then
                if not referenced[dir] then
                    referenced[dir] = true
                    table.insert(removed, dir)
                end
                hit = true
            end
        end
        if hit then
            table.insert(referencing_files, cachefile)
        end
    end
    if #removed == 0 then
        return
    end
    for _, dir in ipairs(removed) do
        os.tryrm(dir)
        -- drop the plat shell too once its last arch tree is gone, so the
        -- gens root does not accumulate empty foreign-plat husks
        local parent = path.directory(dir)
        if os.isdir(parent) and #os.filedirs(path.join(parent, "*")) == 0 then
            os.tryrm(parent)
        end
    end
    table.sort(removed)
    for _, cachefile in ipairs(referencing_files) do
        os.tryrm(cachefile)
    end
    local leftover = {}
    for _, dir in ipairs(removed) do
        if os.isdir(dir) then
            table.insert(leftover, dir)
        end
    end
    for _, cachefile in ipairs(referencing_files) do
        if os.isfile(cachefile) then
            table.insert(leftover, cachefile)
        end
    end
    if #leftover == 0 then
        errors.warn("removed stale cross-plat C++ module caches (reusing them across a plat switch fails with \"Unknown Error (3)\"; the affected plat re-scans on its next build): %s",
            table.concat(removed, ", "))
    else
        errors.warn("stale cross-plat C++ module caches could not be fully removed (files may be locked); delete them manually before building, or run a clean `xmake f -c` + full rebuild: %s",
            table.concat(leftover, ", "))
    end
end
