-- The chunk-local helpers below run only from the gcc.features rule callback
-- (script scope owns import); they reach the settings module through this
-- late-bound upvalue, assigned at callback entry. Cross-chunk plain-global
-- lookups are NOT reliable from callbacks (xmake's cold-configure
-- target/rule validation, _check_targets -> _load_rule, runs on_load under
-- an xpcall sandbox whose _ENV does not see globals populated by an earlier
-- includes() chunk -- only closure upvalues survive that boundary, verified
-- by reproducing "attempt to call a nil value" on a clean `xmake f -c -y`).
local CORE_MODULES_DIR = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")
local CPP_MODULES_DIR = path.join(os.scriptdir(), "..", "modules")
local settings
local errors
local gccfeatures

local managed_gcc_features = MANAGED_GCC_FEATURES
local managed_gcc_feature_groups = MANAGED_GCC_FEATURE_GROUPS

-- Resolution logic lives in modules/gccfeatures.lua (pure, fixture-tested);
-- this wrapper only supplies the ambient facts that need script scope.
local function is_gcc_features_toolchain(target)
    return gccfeatures.is_gcc_toolchain(gccfeatures.toolchain_of(target, {
        global_toolchain = get_config("toolchain"),
        mingw_plat = is_plat("mingw"),
        default_toolchain = settings.default_project_gcc_toolchain_for_current_platform()
    }))
end

local function append_feature_value(out, value)
    if value == nil or value == false then
        return
    end
    if type(value) == "table" then
        for _, item in ipairs(value) do
            append_feature_value(out, item)
        end
        for key, enabled in pairs(value) do
            if type(key) == "string" and enabled == true then
                append_feature_value(out, key)
            end
        end
    else
        for item in tostring(value):gmatch("[^,%s]+") do
            table.insert(out, item)
        end
    end
end

local function collect_feature_values(...)
    local result = {}
    for _, value in ipairs({...}) do
        append_feature_value(result, value)
    end
    return result
end

local function expand_managed_gcc_features(values)
    local result = {}
    local seen = {}
    local function add_one(name)
        if managed_gcc_feature_groups[name] then
            for _, grouped in ipairs(managed_gcc_feature_groups[name]) do
                add_one(grouped)
            end
            return
        end
        if not managed_gcc_features[name] then
            -- errors is late-bound at on_load entry; the description _ENV at
            -- run time has no error()/os.raise, so a bare error() here was a
            -- latent nil-call (pre-existing defect, fixed 2026-07-10)
            errors.fail("unknown managed GCC feature: %s", name)
        end
        if not seen[name] then
            seen[name] = true
            table.insert(result, name)
        end
    end
    local raw = {}
    append_feature_value(raw, values)
    for _, name in ipairs(raw) do
        add_one(name)
    end
    return result
end

local function add_unique_target_values(target, key, values, opt)
    if not values then
        return
    end
    local existing = {}
    local current = target:get(key)
    if type(current) == "table" then
        for _, value in ipairs(current) do
            existing[value] = true
        end
    elseif current then
        existing[current] = true
    end
    for _, value in ipairs(values) do
        if not existing[value] then
            target:add(key, value, opt or {})
            existing[value] = true
        end
    end
end

local function target_rule_values(target, name)
    local result = {}
    if is_gcc_features_toolchain(target) then
        append_feature_value(result,
            settings.configured_target_os() == "emscripten" and "wasm_emscripten_defaults" or "all")
    end
    append_feature_value(result, settings.value_or("gcc_features", ""))
    if target.values then
        append_feature_value(result, target:values(name))
    end
    local values = target:get("values")
    if type(values) == "table" then
        append_feature_value(result, values[name])
    end
    if extraconf then
        append_feature_value(result, extraconf("rules", "gcc.features", "features"))
    end
    return result
end

local function apply_managed_gcc_features(target, features)
    if not is_gcc_features_toolchain(target) then
        return
    end
    local target_os = settings.configured_target_os()
    local unsupported_by_target = {
        windows = {
            ms_calling_conventions = true
        },
        macosx = {
            extern_tls_init = true
        },
        emscripten = {
            extern_tls_init = true
        }
    }
    for _, name in ipairs(expand_managed_gcc_features(features)) do
        if unsupported_by_target[target_os] and unsupported_by_target[target_os][name] then
            goto continue
        end
        local feature = managed_gcc_features[name]
        if feature.language then
            target:set("languages", feature.language)
        end
        add_unique_target_values(target, "cxxflags", feature.cxxflags, {force = true})
        add_unique_target_values(target, "ldflags", feature.ldflags, {force = true})
        add_unique_target_values(target, "shflags", feature.shflags, {force = true})
        add_unique_target_values(target, "defines", feature.defines)
        add_unique_target_values(target, "links", feature.links)
        ::continue::
    end
end

function add_gcc_features(...)
    add_rules("gcc.features")
    add_values("gcc.features", collect_feature_values(...))
end

function set_gcc_features(...)
    add_rules("gcc.features")
    set_values("gcc.features", collect_feature_values(...))
end

rule("gcc.features")
    on_load(function (target)
        settings = settings or import("settings", {rootdir = CORE_MODULES_DIR})
        errors = errors or import("errors", {rootdir = CORE_MODULES_DIR})
        gccfeatures = gccfeatures or import("gccfeatures", {rootdir = CPP_MODULES_DIR})
        apply_managed_gcc_features(target, target_rule_values(target, "gcc.features"))
    end)
