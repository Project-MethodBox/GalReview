-- Entry point of the build_support fixture regression suite:
--     xmake lua build_support/tests/run_all.lua [suite]
-- Runs every case suite (or just the named one), prints a PASS/FAIL/SKIP
-- summary, and raises (non-zero exit) when anything failed. See README.md
-- in this directory for the coverage map and the sandbox design.

import("testkit", {rootdir = path.join(os.scriptdir(), "support")})
import("layers_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("gccmodulecheck_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("gccmodulecache_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("checksums_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("rust_validate_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("rust_cargo_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("rust_toolchain_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("rust_link_export_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("wasm_runtime_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("androidndk_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("gccglibc_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("gccfeatures_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("settings_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("gcctargets_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("patches_shared_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("stamps_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("patch_families_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("hostboot_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("install_lock_cases", {rootdir = path.join(os.scriptdir(), "cases")})
import("envs_cases", {rootdir = path.join(os.scriptdir(), "cases")})

local SUITES = {
    {name = "layers", entry = function (t) layers_cases.run(t) end},
    {name = "gccmodulecheck", entry = function (t) gccmodulecheck_cases.run(t) end},
    {name = "gccmodulecache", entry = function (t) gccmodulecache_cases.run(t) end},
    {name = "checksums", entry = function (t) checksums_cases.run(t) end},
    {name = "rust_validate", entry = function (t) rust_validate_cases.run(t) end},
    {name = "rust_cargo", entry = function (t) rust_cargo_cases.run(t) end},
    {name = "rust_toolchain", entry = function (t) rust_toolchain_cases.run(t) end},
    {name = "rust_link_export", entry = function (t) rust_link_export_cases.run(t) end},
    {name = "wasm_runtime", entry = function (t) wasm_runtime_cases.run(t) end},
    {name = "androidndk", entry = function (t) androidndk_cases.run(t) end},
    {name = "gccglibc", entry = function (t) gccglibc_cases.run(t) end},
    {name = "gccfeatures", entry = function (t) gccfeatures_cases.run(t) end},
    {name = "settings", entry = function (t) settings_cases.run(t) end},
    {name = "gcctargets", entry = function (t) gcctargets_cases.run(t) end},
    {name = "patches_shared", entry = function (t) patches_shared_cases.run(t) end},
    {name = "stamps", entry = function (t) stamps_cases.run(t) end},
    {name = "patch_families", entry = function (t) patch_families_cases.run(t) end},
    {name = "hostboot", entry = function (t) hostboot_cases.run(t) end},
    {name = "install_lock", entry = function (t) install_lock_cases.run(t) end},
    {name = "envs", entry = function (t) envs_cases.run(t) end}
}

local function suite_names()
    local names = {}
    for _, suite in ipairs(SUITES) do
        table.insert(names, suite.name)
    end
    return table.concat(names, ", ")
end

function main(filter)
    -- error-text assertions match the English catalog keys; pin the locale
    -- so the suite behaves identically on zh-locale hosts and in CI
    os.setenv("TOOLCHAINS_LANG", "en")
    if filter and filter ~= "" then
        local known = false
        for _, suite in ipairs(SUITES) do
            if suite.name == filter then
                known = true
            end
        end
        if not known then
            os.raise("unknown suite '%s'; available suites: %s", filter, suite_names())
        end
    end

    local root = path.join(os.tmpdir(), "xmake-buildsupport-tests",
        tostring(os.time()) .. "-" .. tostring(os.getpid and os.getpid() or 0))
    os.mkdir(root)
    local ctx = testkit.new_context(root)
    local t = testkit.harness(ctx)
    print("build_support fixture regression (sandbox: " .. root .. ")")

    for _, suite in ipairs(SUITES) do
        if not filter or filter == "" or filter == suite.name then
            print("")
            print("== suite: " .. suite.name .. " ==")
            local ok, err = testkit.protected(function ()
                suite.entry(t)
            end)
            if not ok then
                ctx.fail = ctx.fail + 1
                table.insert(ctx.failures, suite.name .. " (suite aborted)")
                print("[FAIL] " .. suite.name .. " suite aborted outside a case:")
                print("       " .. (tostring(err):gsub("\n", "\n       ")))
            end
        end
    end

    print("")
    print(string.format("== fixture regression: %d pass / %d fail / %d skip ==",
        ctx.pass, ctx.fail, ctx.skip))
    if ctx.fail > 0 then
        print("failed: " .. table.concat(ctx.failures, "; "))
        print("fixture sandbox kept for diagnosis: " .. root)
        os.raise("build_support fixture regression failed: %d case(s)", ctx.fail)
    end
    os.tryrm(root)
end
