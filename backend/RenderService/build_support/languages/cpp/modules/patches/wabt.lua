-- WABT fork checkout witnesses.
--
-- The GCC wasm backend hands its .wat text to this fork's wat2wasm, which
-- acts as the assembler. The fork used to be patched here on every build;
-- since 2026-08-12 the pinned commit carries those changes itself, so the
-- checkout is verified instead. source_patch_stamp() still feeds the CMake
-- configure signature, so bumping it rebuilds an already-configured tree.
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "..", "core", "modules")})

function source_patch_stamp()
    return "pinned-fork-carries-patches-v3"
end

-- The pinned fork absorbed everything this file used to patch in (2026-08-12),
-- so the checkout is VERIFIED rather than patched -- the same move the GCC
-- wasm profile made. Re-applying would fail outright anyway: the fork words
-- the large-stack change differently from the replacement text below, so
-- neither the anchor nor the applied-fingerprint matches.
--
-- These two witnesses are what a wrong or rolled-back pin would lose, and
-- both failures are otherwise quiet. The large stack is the one that already
-- bit once: without it the assembler dies with no diagnostic at all on the
-- deeply nested branch tables that huge generated modules produce. The rest
-- of the fork's behaviour (relocations, exit codes, 64-bit LEBs) is covered
-- functionally by the toolchain smoke, which assembles and runs real modules.
local VERIFY_WITNESSES = {
    {file = path.join("src", "tools", "wat2wasm.cc"), fingerprint = "kLargeToolStackBytes",
        what = "wat2wasm large-stack tool thread (deep branch tables assemble without a silent stack overflow)"},
    {file = path.join("src", "binary-writer.cc"), fingerprint = "debug_line",
        what = "wat2wasm DWARF line-table emission"},
    {file = path.join("include", "wabt", "ir.h"), fingerprint = "struct SymAlias",
        what = "wat2wasm symbol aliases in relocatable output"},
    {file = path.join("include", "wabt", "ir.h"), fingerprint = "struct CustomFixup",
        what = "wat2wasm custom-section value fixups"},
    {file = path.join("src", "wast-parser.cc"), fingerprint = "ParseAliasAnnotation",
        what = "wat2wasm alias annotation parsing"},
    {file = path.join("src", "binary-writer.cc"), fingerprint = "ResolveCustomFixups",
        what = "wat2wasm custom-section fixup resolution"},
    -- The call site, not the callee's name: OnReturnCallIndirect has existed
    -- all along and only gained the table argument here, so the bare name
    -- would have verified happily against the previous pin (checked: 1 hit
    -- before the change, 1 after). A witness that cannot fail is not one.
    {file = path.join("src", "shared-validator.cc"),
        fingerprint = "func_type.params, func_type.results, table_type.limits",
        what = "wat2wasm takes the table's index width in a returning indirect call"}
}

function verify(src)
    for _, witness in ipairs(VERIFY_WITNESSES) do
        local file = path.join(src, witness.file)
        local content = os.isfile(file) and io.readfile(file) or nil
        if not content or not content:find(witness.fingerprint, 1, true) then
            errors.fail("the pinned WABT fork checkout is missing %s (%s); the pin does not carry the fork's own changes",
                witness.what, witness.file)
        end
    end
end

