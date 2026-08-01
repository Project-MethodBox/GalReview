-- GCC source patches owned by the darwin-arm64 source profile. The libgcc
-- fragment fix is anchor self-gated: apply() runs for every profile and
-- only changes trees whose libgcc/config.host carries the Darwin Arm64
-- case, so profile dispatch stays in the source files themselves.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})
import("shared")

function apply(ctx)
    local src = ctx.src
    local warn_patch_drift = shared.warn_patch_drift

    -- The Darwin Arm64 branch added a final aarch64/t-no-eh fragment so
    -- libSystem remains the only unwinder provider. A later MinGW change
    -- removed that shared fragment without updating Darwin. Configure silently
    -- ignores the missing file and restores GCC's generic unwinder sources.
    -- Install a Darwin-owned replacement before the AArch64 runtime fragments:
    -- this removes only the generic unwinder while preserving newer SME and
    -- heap-trampoline helpers appended by those later fragments.
    local config_host = path.join(src, "libgcc", "config.host")
    if os.isfile(config_host) then
        local content = io.readfile(config_host)
        local block_begin = content:find("aarch64*-*-darwin*)", 1, true)
        local block_end = block_begin and content:find("\n\t;;", block_begin, true) or nil
        if block_begin and block_end then
            block_end = block_end + #"\n\t;;"
            local block = content:sub(block_begin, block_end)
            local first_runtime_fragment = "\ttmake_file=\"${tmake_file} ${cpu_type}/t-aarch64\"\n"
            local missing_no_eh_fragment = "\ttmake_file=\"${tmake_file} ${cpu_type}/t-no-eh\"\n"
            local darwin_no_eh_fragment = "\ttmake_file=\"${tmake_file} ${cpu_type}/t-darwin-no-eh\"\n"
            local patched_block = block
            if not patched_block:find(darwin_no_eh_fragment, 1, true) then
                patched_block = base.replace_plain(patched_block, first_runtime_fragment,
                    darwin_no_eh_fragment .. first_runtime_fragment)
            end
            patched_block = base.replace_plain(patched_block, missing_no_eh_fragment, "")
            if patched_block ~= block then
                print("patching Darwin Arm64 libgcc fragments: keep system unwinder and AArch64 runtime helpers")
                local patched = content:sub(1, block_begin - 1) .. patched_block .. content:sub(block_end + 1)
                base.writefile_bytes(config_host, patched)
                content = patched
            end

            if patched_block:find(darwin_no_eh_fragment, 1, true) then
                local fragment = path.join(src, "libgcc", "config", "aarch64", "t-darwin-no-eh")
                local fragment_content =
                    "# Darwin supplies the unwinder through libSystem. This fragment runs before\n" ..
                    "# the AArch64 runtime fragments so their target helpers remain enabled.\n" ..
                    "LIB2ADDEH =\n"
                if not os.isfile(fragment) or io.readfile(fragment) ~= fragment_content then
                    print("writing Darwin Arm64 libgcc no-EH fragment: " .. fragment)
                    base.writefile_bytes(fragment, fragment_content)
                end
            else
                warn_patch_drift(patched_block, darwin_no_eh_fragment,
                    "libgcc/config.host Darwin Arm64 system-unwinder fragment ordering",
                    "Darwin Arm64 may compile GCC's generic unwinder or drop required AArch64 runtime helpers.")
            end
        end
    end
end

function register_postconditions(ctx)
    local target_os = ctx.target_os
    if target_os and settings.gcc_source_profile(target_os).name == "darwin-arm64" then
        table.insert(ctx.postconditions, {file = path.join("libgcc", "config.host"),
            fingerprint = "${cpu_type}/t-darwin-no-eh",
            what = "Darwin Arm64 system-unwinder libgcc fragment ordering"})
        table.insert(ctx.postconditions, {file = path.join("libgcc", "config", "aarch64", "t-darwin-no-eh"),
            what = "Darwin Arm64 libgcc no-EH fragment file"})
    end
end
