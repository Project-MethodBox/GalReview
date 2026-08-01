-- Description-scope code sees neither import nor raise/error at load or run
-- time (verified empirically), so failing needs the errors module injected
-- from script scope: the toolchains task shell calls the binder below before
-- any help printer can run.
local errors

function managed_toolchains_bind_gcc_features_help_errors(errors_module)
    errors = errors_module
end

local i18n

function managed_toolchains_bind_gcc_features_help_i18n(i18n_module)
    i18n = i18n_module
end

-- Same gettext-shaped channel as commands_help.lua: registered lines render
-- in the detected system language, unregistered ones (usage syntax, flag
-- dumps, the terse per-feature summaries) pass through in English.
local function tr(text, ...)
    if i18n then
        return i18n.tr(text, ...)
    end
    return text
end

local function sorted_managed_gcc_feature_names()
    local names = {}
    for name, _ in pairs(MANAGED_GCC_FEATURES or {}) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

function print_managed_gcc_features_help(feature_name)
    local features = MANAGED_GCC_FEATURES or {}
    local groups = MANAGED_GCC_FEATURE_GROUPS or {}
    if feature_name and feature_name ~= "" then
        local feature = features[feature_name]
        if not feature then
            errors.fail("unknown managed GCC feature: %s", feature_name)
        end
        print(feature_name .. ": " .. feature.summary)
        print("category: " .. feature.category)
        if feature.language then
            print("language: " .. feature.language)
        end
        if feature.cxxflags then
            print("cxxflags: " .. table.concat(feature.cxxflags, " "))
        end
        if feature.ldflags then
            print("ldflags:  " .. table.concat(feature.ldflags, " "))
        end
        if feature.shflags then
            print("shflags:  " .. table.concat(feature.shflags, " "))
        end
        if feature.defines then
            print("defines:  " .. table.concat(feature.defines, " "))
        end
        if feature.links then
            print("links:    " .. table.concat(feature.links, " "))
        end
        return
    end

    print("usage:")
    print("  target(\"name\")")
    print("      add_gcc_features(\"all\")")
    print("  target(\"name\")")
    print("      add_gcc_features(\"reflection\", \"contracts\")")
    print("  target(\"name\")")
    print("      add_gcc_features({\"reflection\", \"contracts\"})")
    print("  target(\"name\")")
    print("      set_gcc_features(\"all\")")
    print("  target(\"name\")")
    print("      add_rules(\"gcc.features\", {features = {\"reflection\"}})")
    print("  xmake f --gcc_features=all")
    print("")
    print(tr("When the configured toolchain is gcc/mingw or the target has project-local GCC toolsets, gcc.features is applied automatically."))
    print(tr("For other toolchains, all GCC feature settings are ignored."))
    print("")
    print(tr("`all` enables positive GCC C++ frontend/runtime features in this manager."))
    print(tr("no_*/off/ignore disabling switches, mutually exclusive ABI choices, special emission modes,"))
    print(tr("and OpenMP/OpenACC runtime switches are closed by default and stay opt-in."))
    print(tr("With set_policy(\"build.c++.modules\", true), xmake compiles the std module itself; compile_std_module stays opt-in."))
    print("")
    print(tr("groups:"))
    -- sorted: pairs() order is unspecified and made this help output
    -- non-deterministic between runs
    local group_names = {}
    for name in pairs(groups) do
        table.insert(group_names, name)
    end
    table.sort(group_names)
    for _, name in ipairs(group_names) do
        print(string.format("  %-16s %s", name, table.concat(groups[name], ", ")))
    end
    print("")
    print(tr("features:"))
    for _, name in ipairs(sorted_managed_gcc_feature_names()) do
        local feature = features[name]
        print(string.format("  %-34s %-12s %s", name, feature.category, feature.summary))
    end
end
