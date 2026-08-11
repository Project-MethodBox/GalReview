-- Toolchain identity resolution for the gcc.features rule. Pure logic with
-- no imports and no ambient reads: the rule callback passes the ambient
-- facts (global toolchain config, platform, managed default) through the
-- context table, which keeps this decision unit-testable by the fixture
-- regression suite (tests/cases/gccfeatures_cases.lua).
--
-- History: the pre-extraction rule-local resolver only recognized GCC
-- positively. A target that explicitly declared a NON-GCC toolchain
-- (set_toolchains("msvc"), a clang toolset, ...) matched nothing in the
-- loop and fell through to the managed-GCC default, so gcc.features
-- force-injected GCC flags into that target anyway -- link.exe then treats
-- "-Wl,..." as a file name and dies with LNK1104 (consumer-wiring audit
-- defect G4, 2026-07-17). Explicit declarations now terminate resolution
-- in both directions.

-- Resolves the toolchain identity the gcc.features rule should treat the
-- target as. context fields (all optional):
--   global_toolchain  -- get_config("toolchain") at the call site
--   mingw_plat        -- is_plat("mingw") at the call site
--   default_toolchain -- settings.default_project_gcc_toolchain_for_current_platform()
function toolchain_of(target, context)
    context = context or {}
    if target and target.get then
        if target.data
            and (target:data("toolchains.auto.declared") == "gcc"
                or target:data("toolchains.auto.declared") == "mingw") then
            return target:data("toolchains.auto.declared")
        end
        local cxx = tostring(target:get("toolset.cxx") or "")
        if cxx:find("g++", 1, true) or cxx:find("gcc", 1, true) then
            return "gcc"
        end
        local explicit
        for _, item in ipairs(table.wrap(target:get("toolchains"))) do
            -- strip the "@platform" suffix (gcc@mingw etc.) so the suffixed
            -- spelling resolves like the bare one (folded in from the former
            -- toolchains.auto copy of this logic, 2026-08-02)
            local name = tostring(item):lower():gsub("@.*$", "")
            if name == "gcc" or name == "mingw" then
                return name
            elseif name == "project_gcc" or name == "managed_gcc" then
                return "gcc"
            elseif name ~= "envs" then
                -- "envs" is environment-driven, not an identity: a
                -- gcc-looking toolset already resolved above and a non-GCC
                -- toolset resolves as external below, so envs itself
                -- neither claims nor denies GCC here.
                explicit = explicit or name
            end
        end
        -- An explicit non-GCC declaration must never fall through to the
        -- global/default resolution below: that default is the managed GCC,
        -- and force-injected GCC flags break the declared toolchain's link
        -- line (the G4 LNK1104 shape).
        if explicit then
            return explicit
        end
        if cxx ~= "" then
            return "external"
        end
    end
    local global = tostring(context.global_toolchain or ""):lower()
    if global ~= "" then
        return global
    end
    if context.mingw_plat then
        return "mingw"
    end
    return context.default_toolchain or ""
end

function is_gcc_toolchain(name)
    return name == "gcc" or name == "mingw"
end
