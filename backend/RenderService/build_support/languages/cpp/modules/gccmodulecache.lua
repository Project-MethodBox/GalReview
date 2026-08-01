-- Keeps xmake's C++ module cache, GCC mapper files, and generated CMIs bound to
-- the active build root and compiler frontend. In an `xmake -P <subproject>`
-- build, xmake deliberately resolves the configured build directory from the
-- caller's working directory while module scan artifacts remain relative to
-- the selected subproject. A later process can therefore resolve
-- `..\build\...` against the wrong directory. GCC mapper temp-file identities
-- also omit the build root, so that incorrect mapping survives the failed
-- process unless it is discarded explicitly.

import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})

local prepared_compilers = {}
local prepared_mapper_roots = {}

local module_path_fields = {"bmifile", "objectfile", "dependfile", "metafile"}

local function comparable_path(value)
    local normalized = path.absolute(value):gsub("\\", "/"):gsub("/+$", "")
    if is_host("windows") then
        normalized = normalized:lower()
    end
    return normalized
end

local function path_is_within(file, root)
    local normalized_file = comparable_path(file)
    local normalized_root = comparable_path(root)
    return normalized_file == normalized_root or normalized_file:startswith(normalized_root .. "/")
end

function mapper_requires_refresh(content, context)
    if type(content) ~= "string" or content == "" then
        return false
    end

    local mapper_root
    local mapped_paths = {}
    for line in content:gmatch("[^\r\n]+") do
        local root = line:match("^root%s+(.+)$")
        if root then
            mapper_root = root
        else
            local mapped = line:match("^%S+%s+(.+)$")
            if mapped then
                table.insert(mapped_paths, mapped)
            end
        end
    end

    if not mapper_root or comparable_path(mapper_root) ~= comparable_path(context.projectdir) then
        return false
    end

    local builddir = path.absolute(context.builddir)
    for _, mapped in ipairs(mapped_paths) do
        local mapped_absolute = path.is_absolute(mapped) and mapped or path.absolute(mapped, mapper_root)
        local normalized = mapped_absolute:gsub("\\", "/")
        if normalized:find("/.gens/", 1, true) and not path_is_within(mapped_absolute, builddir) then
            return true
        end
    end
    return false
end

function refresh_stale_mapper_files(context)
    local projectdir = path.absolute(assert(context.projectdir))
    local builddir = path.absolute(assert(context.builddir))
    local tempdir = path.absolute(context.tempdir or os.tmpdir())
    local key = table.concat({comparable_path(projectdir), comparable_path(builddir), comparable_path(tempdir)}, "|")
    if prepared_mapper_roots[key] then
        return 0, {}
    end

    local removed = 0
    local failed = {}
    for _, mapperfile in ipairs(os.files(path.join(tempdir, "**.mapper.txt"))) do
        local readable, content = errors.trycall(function ()
            return io.readfile(mapperfile, {encoding = "binary"})
        end)
        if readable and mapper_requires_refresh(content, {projectdir = projectdir, builddir = builddir}) then
            os.tryrm(mapperfile)
            if not os.isfile(mapperfile) then
                removed = removed + 1
            else
                table.insert(failed, mapperfile)
            end
        end
    end
    prepared_mapper_roots[key] = true
    return removed, failed
end

local function generated_path(value, builddir)
    local normalized = value:gsub("\\", "/")
    for _, marker in ipairs({"/.gens/", "/.objs/", "/.deps/"}) do
        local offset = normalized:find(marker, 1, true)
        if offset then
            return path.join(builddir, normalized:sub(offset + 1))
        end
    end
end

local function normalize_path(value, context)
    if type(value) ~= "string" or value == "" or path.is_absolute(value) then
        return value
    end

    local generated = generated_path(value, context.builddir)
    if generated then
        return path.absolute(generated)
    end

    for _, base in ipairs({context.projectdir, context.workingdir}) do
        local candidate = path.absolute(value, base)
        if os.isfile(candidate) or os.isdir(candidate) then
            return candidate
        end
    end

    return value
end

local function normalize_list(values, context)
    local changed = 0
    if type(values) ~= "table" then
        return changed
    end

    for index, value in ipairs(values) do
        local normalized = normalize_path(value, context)
        if normalized ~= value then
            values[index] = normalized
            changed = changed + 1
        end
    end
    return changed
end

local function normalize_module(module, context)
    local changed = 0
    if type(module) ~= "table" then
        return changed
    end

    for _, field in ipairs(module_path_fields) do
        local value = module[field]
        local normalized = normalize_path(value, context)
        if normalized ~= value then
            module[field] = normalized
            changed = changed + 1
        end
    end
    return changed
end

local function normalize_modules(modules, context)
    local changed = 0
    if type(modules) ~= "table" then
        return changed
    end

    for _, module in pairs(modules) do
        changed = changed + normalize_module(module, context)
    end
    return changed
end

function normalize_entry(entry, context)
    if type(entry) ~= "table" then
        return 0
    end

    context = {
        projectdir = path.absolute(assert(context.projectdir)),
        workingdir = path.absolute(assert(context.workingdir)),
        builddir = path.absolute(assert(context.builddir))
    }

    local changed = normalize_modules(entry["c++.modules"], context)
    changed = changed + normalize_modules(entry.module_mapper, context)

    local sourcebatch = entry["c++.build.sourcebatch"]
    if type(sourcebatch) == "table" then
        changed = changed + normalize_list(sourcebatch.objectfiles, context)
        changed = changed + normalize_list(sourcebatch.dependfiles, context)
    end

    local artifacts = entry["c++.modules.built_artifacts"]
    if type(artifacts) == "table" then
        changed = changed + normalize_list(artifacts.objectfiles, context)
    end

    return changed
end

local function compiler_identity_files(compiler_path)
    local prefix = path.directory(path.directory(compiler_path))
    local files = {compiler_path}
    local seen = {[comparable_path(compiler_path)] = true}
    local patterns = {
        path.join(prefix, "libexec", "gcc", "**", "cc1plus*"),
        path.join(prefix, "include", "c++", "**", "bits", "std.cc"),
        path.join(prefix, "include", "c++", "**", "bits", "std.compat.cc")
    }
    for _, pattern in ipairs(patterns) do
        for _, file in ipairs(os.files(pattern)) do
            local absolute = path.absolute(file)
            local key = comparable_path(absolute)
            if not seen[key] then
                seen[key] = true
                table.insert(files, absolute)
            end
        end
    end
    table.sort(files)
    return files
end

local function compiler_fingerprint(target)
    local compiler, toolname = target:tool("cxx")
    if not compiler then
        return nil, nil
    end

    local compiler_path = path.absolute(compiler)
    if not os.isfile(compiler_path) then
        return tostring(toolname or "") .. "\n" .. tostring(compiler), nil
    end

    local fingerprint = {tostring(toolname or "")}
    for _, file in ipairs(compiler_identity_files(compiler_path)) do
        table.insert(fingerprint, comparable_path(file))
        table.insert(fingerprint, hash.sha256(file))
    end
    return table.concat(fingerprint, "\n"), compiler_path
end

local function current_cmi_files(target, builddir)
    return os.files(path.join(builddir, ".gens", "*", target:plat(), target:arch(), "**.gcm"))
end

local function remove_current_cmi_trees(target, builddir)
    for _, directory in ipairs(os.dirs(path.join(builddir, ".gens", "*", target:plat(), target:arch()))) do
        if path_is_within(directory, builddir) then
            os.tryrm(directory)
        end
    end
end

local function ensure_compiler_identity(target, cache, cachedir, builddir)
    local marker = path.join(cachedir,
        string.format("cxxmodules.compiler.%s.%s", target:plat(), target:arch()))
    local key = comparable_path(marker)
    if prepared_compilers[key] then
        return false
    end

    local fingerprint, compiler_path = compiler_fingerprint(target)
    if not fingerprint then
        return false
    end

    local previous = os.isfile(marker) and io.readfile(marker) or nil
    -- Without a previous fingerprint there is no sound way to prove an
    -- existing CMI came from this compiler frontend. Pay one conservative
    -- rebuild when adopting the marker instead of trusting mtimes, which can
    -- be preserved by archive extraction or move backwards across machines.
    local invalid = (previous and previous ~= fingerprint) or
        (not previous and #current_cmi_files(target, builddir) > 0)
    if invalid then
        cache:clear()
        cache:save()
        remove_current_cmi_trees(target, builddir)
        local remaining = current_cmi_files(target, builddir)
        if #remaining > 0 then
            errors.fail("stale C++ module files generated by a different compiler frontend could not be removed; stop other xmake processes and delete them before retrying: %s",
                table.concat(remaining, ", "))
        end
        errors.warn("discarded C++ module cache generated by a different compiler frontend: %s", compiler_path or "unknown")
    end

    os.mkdir(path.directory(marker))
    io.writefile(marker, fingerprint)
    prepared_compilers[key] = true
    return invalid
end

function prepare(target, opt)
    opt = opt or {}
    local config = import("core.project.config")
    local localcache = import("core.cache.localcache")
    local cache = opt.cache or localcache.cache("cxxmodules")
    local cachedir = opt.cachedir or path.join(config.directory(), "cache")
    local builddir = path.absolute(opt.builddir or config.builddir({absolute = true}))

    ensure_compiler_identity(target, cache, cachedir, builddir)

    local removed_mappers, failed_mappers = refresh_stale_mapper_files({
        projectdir = opt.projectdir or os.projectdir(),
        builddir = builddir,
        tempdir = opt.tempdir
    })
    if #failed_mappers > 0 then
        errors.fail("stale GCC module mapper files could not be removed; stop other xmake processes and retry: %s",
            table.concat(failed_mappers, ", "))
    end
    if removed_mappers > 0 then
        errors.warn("discarded %d stale GCC module mapper file(s) for build root %s", removed_mappers, builddir)
    end

    local entry = cache:data()[target:fullname()]
    local changed = normalize_entry(entry, {
        projectdir = opt.projectdir or os.projectdir(),
        workingdir = opt.workingdir or os.workingdir(),
        builddir = builddir
    })
    if changed > 0 then
        cache:save()
        errors.warn("normalized %d relative C++ module cache path(s) for target %s", changed, target:fullname())
    end
    return changed
end
