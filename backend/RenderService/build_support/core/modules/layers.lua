-- General C++20-module dependency-layering resolver. build_support is a
-- project-agnostic toolchain system, so this module holds no project data and
-- makes no assumption about any one project's module organization: it turns a
-- set of module units into a layered dependency graph, and the CONSUMER
-- decides how units group into layer-nodes. A layering comes from one of two
-- sources, both driven by the project:
--
--   * MANUAL (from_manual): the project declares the layer order explicitly as
--     "<level>:<name>" entries (equal levels are same-layer siblings). Names
--     are opaque identifiers -- any project, any grouping. A human-authored
--     order lets a direction check catch "imported the wrong way" even when
--     that does not form a cycle.
--
--   * AUTOMATIC (from_module_graph): scan the project's module units and derive
--     the layering from the actual import graph via topological longest-path.
--     No table to maintain -- but with the order derived from the code itself,
--     a direction check degrades to CYCLE detection (only A->B->A loops, not a
--     merely wrong-direction import). `.cycle` is returned so a checker can
--     report the loop.
--
-- Grouping strategy (from_module_graph's `opts.grouping`) decides what a
-- layer-node is:
--   * "module" (DEFAULT, fully general): one node per NAMED module. Works for
--     any ordinary C++20-modularized project -- `import othermodule;` is an
--     edge, partitions collapse into their owning module.
--   * "partition-prefix": one node per FIRST SEGMENT of a partition name, for a
--     project that puts everything in a single named module and uses partitions
--     as its modularity units (imports are `import :partition;`). Aggregate
--     partitions (dot-free, at <Name>/<Name>.cpp) and impl partitions are
--     handled; a root-level single-file partition is not a node.
--   * a custom { classify=, imports= } table (see the built-ins below).
--
-- Both entry points return a layering object with the same surface:
--   level_of(name)          -> integer level, or nil if the name is unranked
--   may_depend(upper,lower) -> true iff level(lower) < level(upper)
--   known_names()           -> every ranked node, sorted
-- from_module_graph additionally sets .cycle (a dependency loop, or nil).
--
-- In every strategy an import is counted only when it is UNCONDITIONAL (outside
-- any #if/#ifdef region -- configuration-dependent imports differ per build)
-- and its target is a unit that actually exists in the scanned set.

local function make_layering(levels)
    local layering = {}

    function layering.level_of(name)
        return levels[name]
    end

    function layering.may_depend(upper, lower)
        local upper_level = levels[upper]
        local lower_level = levels[lower]
        if not upper_level or not lower_level then
            return false
        end
        return lower_level < upper_level
    end

    function layering.known_names()
        local names = {}
        for name in pairs(levels) do
            table.insert(names, name)
        end
        table.sort(names)
        return names
    end

    return layering
end

-- Builds a layering from explicit "<level>:<name>" entries (the manual
-- declaration). Raises on any bad entry -- malformed syntax, a non-positive
-- level, or the same name listed twice -- so a typo fails the build loudly
-- instead of silently mis-ranking or dropping a node. Levels must be >= 1:
-- level 0 (and below) is reserved for language-runtime nodes that sit under
-- every other node (see the rust provider's RUNTIME_LEVEL), and a 0/negative
-- node would tie or outrank the runtime and be denied its supply.
function from_manual(entries)
    local levels = {}
    for _, entry in ipairs(entries or {}) do
        local level_text, name = tostring(entry):match("^%s*(%-?%d+)%s*:%s*([%w_]+)%s*$")
        if not name then
            os.raise("malformed layer entry %q: expected \"<level>:<name>\" (e.g. \"4:OSCallEngine\")", tostring(entry))
        end
        local level = tonumber(level_text)
        if level < 1 then
            os.raise("invalid layer level in %q: levels must be >= 1 (0 and below are reserved for the language runtime)", tostring(entry))
        end
        if levels[name] and levels[name] ~= level then
            os.raise("node %q is declared at two different layers (%d and %d); each may appear at exactly one level", name, levels[name], level)
        end
        levels[name] = level
    end
    return make_layering(levels)
end

-- Applies fn to every line of content that sits outside any #if/#ifdef region.
local function each_unconditional_line(content, fn)
    local depth = 0
    for line in content:gmatch("[^\r\n]+") do
        if line:find("^%s*#%s*if") then
            depth = depth + 1
        elseif line:find("^%s*#%s*endif") then
            depth = math.max(depth - 1, 0)
        elseif depth == 0 then
            fn(line)
        end
    end
end

-- === Built-in grouping strategies ===
-- A strategy answers two questions about a module unit:
--   classify(sourcefile, content) -> { id=, group= } or { group= } or nil
--       `id` is the unit's importable identity (nil = not importable, but its
--       own imports still contribute edges), `group` is the layer-node it
--       belongs to; nil skips the unit entirely.
--   imports(content) -> list of imported unit ids (unconditional only)
-- The graph builder below is otherwise strategy-agnostic.

-- General default: one layer-node per NAMED module. `export module foo;` and
-- `export module foo:part;` both belong to node "foo"; `import bar;` is an edge
-- to node "bar"; own-partition imports (`import :part;`) stay intra-node. No
-- leaf exemption: a module you import is genuinely below you even if it has no
-- further dependencies of its own.
local by_module = {
    exempt_leaves = false,
    classify = function(sourcefile, content)
        for line in content:gmatch("[^\r\n]+") do
            local mod, part = line:match("^%s*export%s+module%s+([%w_.]+)%s*:%s*([%w_.]+)%s*;")
            if mod then
                return {id = mod .. ":" .. part, group = mod}
            end
            local pmod = line:match("^%s*export%s+module%s+([%w_.]+)%s*;")
            if pmod then
                return {id = pmod, group = pmod}
            end
            local imod, ipart = line:match("^%s*module%s+([%w_.]+)%s*:%s*([%w_.]+)%s*;")
            if imod then
                return {id = imod .. ":" .. ipart, group = imod}
            end
            local plainmod = line:match("^%s*module%s+([%w_.]+)%s*;")
            if plainmod then
                -- implementation unit: not importable, but its imports count
                return {group = plainmod}
            end
            -- a bare `module;` global fragment opener has no name; keep scanning
        end
        return nil
    end,
    imports = function(content)
        local ids = {}
        each_unconditional_line(content, function(line)
            local id = line:match("^%s*export%s+import%s+([%w_.:]+)%s*;")
                or line:match("^%s*import%s+([%w_.:]+)%s*;")
            -- a leading ':' is an own-partition import (intra-module) -- skip
            if id and id:sub(1, 1) ~= ":" then
                table.insert(ids, id)
            end
        end)
        return ids
    end
}

-- Single-module-with-partitions projects: one layer-node per FIRST SEGMENT of
-- the partition name. `export module M:A.b;` -> node A; a dot-free aggregate at
-- <A>/<A>.cpp -> node A; `module M:A.b;` (impl partition) -> node A. Primaries,
-- plain impl units, and a root-level single-file partition (dot-free NOT at
-- <name>/<name>.cpp, e.g. Version.cpp) are not nodes. Imports are `import :X;`.
-- Leaf exemption ON: a partition physically located in a node's directory but
-- self-contained (a relocated ABI/type mirror imported across nodes) must not
-- fabricate a nominal cycle -- see build_graph.
local by_partition_prefix = {
    exempt_leaves = true,
    classify = function(sourcefile, content)
        for line in content:gmatch("[^\r\n]+") do
            local mod, part = line:match("^%s*export%s+module%s+([%w_.]+)%s*:%s*([%w_.]+)%s*;")
            if mod then
                if part:find(".", 1, true) then
                    return {id = part, group = part:match("^([%w_]+)")}
                elseif path.filename(path.directory(sourcefile)) == part then
                    return {id = part, group = part}
                end
                return nil
            end
            if line:match("^%s*export%s+module%s+[%w_.]+%s*;") then
                return nil
            end
            local imod, ipart = line:match("^%s*module%s+([%w_.]+)%s*:%s*([%w_.]+)%s*;")
            if imod and ipart:find(".", 1, true) then
                return {id = ipart, group = ipart:match("^([%w_]+)")}
            end
            if line:match("^%s*module%s+[%w_]") then
                return nil
            end
        end
        return nil
    end,
    imports = function(content)
        local ids = {}
        each_unconditional_line(content, function(line)
            local id = line:match("^%s*export%s+import%s+:%s*([%w_.]+)%s*;")
                or line:match("^%s*import%s+:%s*([%w_.]+)%s*;")
            if id then
                table.insert(ids, id)
            end
        end)
        return ids
    end
}

local STRATEGIES = {
    ["module"] = by_module,
    ["partition-prefix"] = by_partition_prefix
}

-- Picks a grouping strategy from the module tree itself, so the common cases
-- need no declaration. Exactly one named module that has partitions is the
-- "single module used through its partitions" shape -> partition-prefix;
-- anything else (several named modules, or one module with no partitions) is an
-- ordinary project -> group by named module. A project whose shape defeats this
-- heuristic can still pass an explicit grouping.
local function detect_grouping(file_contents)
    local modules = {}
    local module_count = 0
    local has_partition = false
    for _, content in pairs(file_contents) do
        for line in content:gmatch("[^\r\n]+") do
            local mod, part = line:match("^%s*module%s+([%w_.]+)%s*:%s*([%w_.]+)%s*;")
            local emod, epart = line:match("^%s*export%s+module%s+([%w_.]+)%s*:%s*([%w_.]+)%s*;")
            local pmod = line:match("^%s*export%s+module%s+([%w_.]+)%s*;")
            local imod = line:match("^%s*module%s+([%w_.]+)%s*;")
            local name = emod or mod or pmod or imod
            if name then
                if not modules[name] then
                    modules[name] = true
                    module_count = module_count + 1
                end
                if epart or part then
                    has_partition = true
                end
                break
            end
        end
    end
    if module_count == 1 and has_partition then
        return "partition-prefix"
    end
    return "module"
end

-- Builds the layer-node dependency graph { node -> { imported node -> true } }.
--
-- Leaf exemption (only when strategy.exempt_leaves is set): an import whose
-- TARGET unit is a pure leaf (its own unconditional import list is empty) does
-- NOT create an edge. A pure leaf is a self-contained unit with no outgoing
-- edges, so it can never be a link in any dependency cycle no matter which node
-- it belongs to. Dropping these edges cannot hide a real cycle (a leaf has
-- nowhere to continue the chain to) but it keeps a relocated leaf -- e.g. an
-- ABI mirror moved into another node's directory but still imported across --
-- from fabricating a nominal loop no real dependency backs. This matters only
-- where a node is a DIRECTORY grouping that can hold a foreign self-contained
-- unit (partition-prefix); in the module model an imported module is genuinely
-- below you, so the exemption is off there.
-- Scans the tree into { units, all, is_leaf } for a strategy. `units` maps an
-- importable id -> { group, content, file }; `all` also includes id-less units
-- (impl units that carry edges but nothing imports them); `is_leaf` is filled
-- only when the strategy exempts leaves. `resolved_imports` keeps only imports
-- that resolve to a scanned unit.
local function analyze(file_contents, strategy)
    local units = {}
    local all = {}
    for sourcefile, content in pairs(file_contents) do
        local classified = strategy.classify(sourcefile, content)
        if classified and classified.group then
            local unit = {id = classified.id, group = classified.group, content = content, file = sourcefile}
            if classified.id then
                units[classified.id] = unit
            end
            table.insert(all, unit)
        end
    end
    local function resolved_imports(content)
        local out = {}
        for _, id in ipairs(strategy.imports(content)) do
            if units[id] then
                table.insert(out, id)
            end
        end
        return out
    end
    local is_leaf = {}
    if strategy.exempt_leaves then
        for id, unit in pairs(units) do
            is_leaf[id] = #resolved_imports(unit.content) == 0
        end
    end
    return {units = units, all = all, is_leaf = is_leaf, resolved_imports = resolved_imports}
end

-- Builds the layer-node dependency graph { node -> { imported node -> true } }.
--
-- Leaf exemption (only when strategy.exempt_leaves is set): an import whose
-- TARGET unit is a pure leaf (its own unconditional import list is empty) does
-- NOT create an edge. A pure leaf is a self-contained unit with no outgoing
-- edges, so it can never be a link in any dependency cycle no matter which node
-- it belongs to. Dropping these edges cannot hide a real cycle (a leaf has
-- nowhere to continue the chain to) but it keeps a relocated leaf -- e.g. an
-- ABI mirror moved into another node's directory but still imported across --
-- from fabricating a nominal loop no real dependency backs. This matters only
-- where a node is a DIRECTORY grouping that can hold a foreign self-contained
-- unit (partition-prefix); in the module model an imported module is genuinely
-- below you, so the exemption is off there.
local function build_graph(scanned)
    local graph = {}
    local function ensure(node)
        graph[node] = graph[node] or {}
    end
    for _, unit in ipairs(scanned.all) do
        ensure(unit.group)
        for _, id in ipairs(scanned.resolved_imports(unit.content)) do
            local target = scanned.units[id].group
            if target ~= unit.group and not scanned.is_leaf[id] then
                graph[unit.group][target] = true
            end
        end
    end
    return graph
end

-- Depth-first cycle search. Returns the first loop as a { A, B, ..., A } path,
-- or nil when the graph is acyclic.
local function find_cycle(graph)
    local visiting = {}
    local visited = {}
    local found
    local function visit(node, chain)
        if found or visited[node] then
            return
        end
        if visiting[node] then
            local start = 1
            for index, entry in ipairs(chain) do
                if entry == node then
                    start = index
                    break
                end
            end
            found = {}
            for index = start, #chain do
                table.insert(found, chain[index])
            end
            table.insert(found, node)
            return
        end
        visiting[node] = true
        table.insert(chain, node)
        local targets = {}
        for target in pairs(graph[node]) do
            table.insert(targets, target)
        end
        table.sort(targets)
        for _, target in ipairs(targets) do
            visit(target, chain)
            if found then
                break
            end
        end
        table.remove(chain)
        visiting[node] = false
        visited[node] = true
    end
    local nodes = {}
    for node in pairs(graph) do
        table.insert(nodes, node)
    end
    table.sort(nodes)
    for _, node in ipairs(nodes) do
        visit(node, {})
        if found then
            break
        end
    end
    return found
end

-- Longest-path level of each node: a node with no outgoing edges is level 1,
-- otherwise 1 + the maximum level among the nodes it imports. Assumes the graph
-- is acyclic (callers check .cycle first).
local function topo_levels(graph)
    local levels = {}
    local function level_of(node)
        if levels[node] then
            return levels[node]
        end
        local max_dep = 0
        for target in pairs(graph[node]) do
            local dep_level = level_of(target)
            if dep_level > max_dep then
                max_dep = dep_level
            end
        end
        levels[node] = max_dep + 1
        return levels[node]
    end
    for node in pairs(graph) do
        level_of(node)
    end
    return levels
end

-- Builds a layering by scanning the project's own module tree. `opts.grouping`
-- is a built-in strategy name ("module" default, "partition-prefix") or a
-- custom { classify=, imports= } table. The result carries .cycle (nil when
-- acyclic); when a cycle is present the levels are empty (the checker reports
-- the loop and fails the build, so downstream lookups never run against a
-- cyclic graph in practice).
local function resolve_strategy(file_contents, opts)
    local grouping = (opts and opts.grouping) or detect_grouping(file_contents)
    if type(grouping) ~= "string" then
        return grouping
    end
    local strategy = STRATEGIES[grouping]
    if not strategy then
        os.raise("unknown layer grouping %q: built-in strategies are \"module\" and \"partition-prefix\" (or pass a {classify=, imports=} table)", grouping)
    end
    return strategy
end

function from_module_graph(file_contents, opts)
    local strategy = resolve_strategy(file_contents, opts)
    local graph = build_graph(analyze(file_contents, strategy))
    local cycle = find_cycle(graph)
    local levels = cycle and {} or topo_levels(graph)
    local layering = make_layering(levels)
    layering.cycle = cycle
    return layering
end

-- Direction-enforcement check against a HUMAN-declared layering (level_of):
-- every cross-node unconditional import must target a STRICTLY lower layer.
-- Uses the same grouping strategy and leaf exemption as from_module_graph, so
-- it works for any project shape (partition-prefix or module). Returns a list
-- of violations { file, importer_id, importer_group, importer_level,
-- imported_id, imported_group, imported_level }, sorted deterministically.
-- Nodes the declaration does not rank (level_of returns nil) are unconstrained.
function direction_violations(file_contents, level_of, opts)
    local strategy = resolve_strategy(file_contents, opts)
    local scanned = analyze(file_contents, strategy)
    local violations = {}
    for _, unit in ipairs(scanned.all) do
        local importer_level = level_of(unit.group)
        if importer_level then
            for _, id in ipairs(scanned.resolved_imports(unit.content)) do
                local target = scanned.units[id]
                if target.group ~= unit.group and not scanned.is_leaf[id] then
                    local imported_level = level_of(target.group)
                    if imported_level and imported_level >= importer_level then
                        table.insert(violations, {
                            file = unit.file,
                            importer_id = unit.id or unit.group,
                            importer_group = unit.group,
                            importer_level = importer_level,
                            imported_id = id,
                            imported_group = target.group,
                            imported_level = imported_level
                        })
                    end
                end
            end
        end
    end
    table.sort(violations, function (a, b)
        if a.file ~= b.file then return a.file < b.file end
        if a.importer_id ~= b.importer_id then return a.importer_id < b.importer_id end
        return a.imported_id < b.imported_id
    end)
    return violations
end
