-- Fixture regression for the provider contract (gcctargets.provider_contract).
-- Both directions are enforced against every shipped targets/<os>.lua:
--   * every required hook must be exported (a forgotten lifecycle hook
--     fails here, not at install time on some host);
--   * every exported function must be a known hook or a declared family
--     helper (a typo'd optional hook -- which the dispatcher would silently
--     never call -- fails here as an undeclared export).
-- The provider list is discovered through gcctargets.known_target_oses(),
-- so adding targets/<newos>.lua automatically joins the battery.

local gcctargets = import("gcctargets",
    {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "cpp", "modules"), anonymous = true})

local TARGETS_DIR = path.join(os.scriptdir(), "..", "..", "languages", "cpp", "modules", "targets")

local function exported_functions(provider)
    local names = {}
    for key, value in pairs(provider) do
        if type(value) == "function" and not key:match("^_") then
            table.insert(names, key)
        end
    end
    table.sort(names)
    return names
end

function run(t)
    local contract = gcctargets.provider_contract()
    local subjects = gcctargets.known_target_oses()

    t.case("gcctargets: the contract covers every shipped provider", function ()
        t.assert_true(#subjects >= 6, "expected at least six providers, found " .. #subjects)
        for _, subject in ipairs(subjects) do
            t.assert_true(contract.family[subject] ~= nil,
                "provider has no family entry in the contract: " .. subject)
        end
    end)

    t.case("gcctargets: every required hook has a doc line", function ()
        for name, spec in pairs(contract.hooks) do
            t.assert_true(type(spec.doc) == "string" and #spec.doc > 0,
                "hook without doc: " .. name)
        end
    end)

    t.case("gcctargets: every build plan is structurally sound", function ()
        local context = {build = path.join(t.tmpdir("plan-golden"), "fake-build"),
            patch = function () end}
        for _, subject in ipairs(subjects) do
            local provider = import(subject, {rootdir = TARGETS_DIR, anonymous = true})
            local plan = provider.build_plan(subject, context)
            t.assert_true(type(plan) == "table" and #plan > 0,
                subject .. " build plan must be a non-empty step list")
            for index, step in ipairs(plan) do
                -- real step shapes (gccbuild consumer contract): make-target
                -- steps carry targets (the empty string means a bare `make`),
                -- pure-callback steps carry before/after instead
                local has_targets = type(step.targets) == "table" and #step.targets > 0
                local has_callback = type(step.before) == "function" or type(step.after) == "function"
                t.assert_true(has_targets or has_callback,
                    subject .. " step " .. index .. " carries neither make targets nor callbacks")
                for _, target in ipairs(step.targets or {}) do
                    t.assert_true(type(target) == "string",
                        subject .. " step " .. index .. " has a non-string make target")
                end
            end
        end
    end)

    t.case("gcctargets: only GNU-binutils targets report needs_binutils", function ()
        -- The install gate's pre-identity binutils migration keys on
        -- needs_binutils (through managed_toolchains_builds_binutils), NOT on the
        -- mere presence of a <triplet>-as/<triplet>-ld pair: the Apple providers
        -- stage exactly those names as thin cctools wrappers for targets that
        -- never build binutils, so a needs_binutils=true here would rebuild
        -- iOS/macOS on every gate check (the bug this pins). Host-independent:
        -- needs_binutils is a provider constant, not gated on is_cross_target.
        local expected = {linux = true, android = true, windows = true,
            macosx = false, ios = false, emscripten = false}
        for os_name, want in pairs(expected) do
            t.assert_eq(gcctargets.needs_binutils(os_name), want,
                "needs_binutils mismatch for " .. os_name)
        end
    end)

    t.case("gcctargets: a provider that stages its own backend tools must not need binutils", function ()
        -- build_binutils_for runs only when the provider has NO
        -- prepare_backend_tools AND needs_binutils; a provider claiming both is a
        -- contradiction that would desync the install gate's migration predicate
        -- from the actual builder. Auto-covers every current and future provider.
        for _, subject in ipairs(subjects) do
            local provider = import(subject, {rootdir = TARGETS_DIR, anonymous = true})
            if type(provider.prepare_backend_tools) == "function" then
                t.assert_true(gcctargets.needs_binutils(subject) == false,
                    subject .. " defines prepare_backend_tools but also reports needs_binutils")
            end
        end
    end)

    t.case("gcctargets: the ios build plan matches its golden shape", function ()
        local provider = import("ios", {rootdir = TARGETS_DIR, anonymous = true})
        local plan = provider.build_plan("ios", {build = "unused", patch = function () end})
        t.assert_eq(#plan, 3, "ios plan stage count")
        t.assert_eq(table.concat(plan[1].targets, " "),
            "all-gcc install-gcc configure-target-libgcc", "stage 1 targets")
        t.assert_eq(table.concat(plan[2].targets, " "),
            "all-target-libgcc install-target-libgcc", "stage 2 targets")
        t.assert_eq(table.concat(plan[3].targets, " "),
            "configure-target-libstdc++-v3 all-target-libstdc++-v3 install-target-libstdc++-v3",
            "stage 3 targets")
        t.assert_true(plan[3].patch == true, "stage 3 must request the build-tree patch")
    end)

    for _, subject in ipairs(subjects) do
        t.case("gcctargets: " .. subject .. " provider satisfies the contract", function ()
            local provider = import(subject, {rootdir = TARGETS_DIR, anonymous = true})
            local family = {}
            for _, name in ipairs(contract.family[subject] or {}) do
                family[name] = true
            end
            for name, spec in pairs(contract.hooks) do
                if spec.required then
                    t.assert_true(type(provider[name]) == "function",
                        subject .. " is missing required hook " .. name)
                end
            end
            for _, name in ipairs(exported_functions(provider)) do
                t.assert_true(contract.hooks[name] ~= nil or family[name] == true,
                    subject .. " exports an undeclared function (typo'd hook or missing contract entry): " .. name)
            end
        end)
    end
end
