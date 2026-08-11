-- Native reader for the ar archives rustc produces (the staticlib whose
-- object members the rust.cargo rule absorbs into the engine archive).
--
-- Why not `ar x`: extraction materializes every member under its own name,
-- and rustc member names run long (84 characters observed for
-- compiler_builtins codegen units). MinGW binutils are not long-path aware,
-- so `<objectdir>/.../<member>` crossed the Windows MAX_PATH ceiling as soon
-- as the configured build directory (`xmake f -o`) sat in a deep location --
-- the extraction died mid-archive with the baffling
-- `<member>.rcgu.o: No such file or directory` (reproduced 2026-08-05: the
-- same ar/archive pair extracts all 314 members in a short directory and
-- dies at the first 84-character name in a 178-character one). Reading the
-- format here lets the caller write each member straight to its short
-- flattened name, so the Rust step never exceeds the path budget the rest
-- of the objectdir already lives within.
--
-- Dialect coverage matches what rustc's archive writer emits across the
-- engine's targets: GNU/SysV (ELF and wasm targets: `//` long-name table
-- with `/`-terminated entries), the COFF flavor of the same (windows-gnu:
-- NUL-terminated table entries, duplicated `/` symbol tables), and
-- BSD/Darwin (Apple targets: `#1/<n>` inline names, NUL-padded). Thin
-- archives are rejected loudly: rustc never emits them, so one here means
-- the product is not the expected staticlib.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})

local AR_MAGIC = "!<arch>\n"
local THIN_MAGIC = "!<thin>\n"

local function member_size(header, archive, offset)
    local size = tonumber(base.trim(header:sub(49, 58)))
    if not size or size < 0 or math.floor(size) ~= size then
        errors.fail("corrupt ar member header at byte %d: %s", offset, archive)
    end
    return size
end

-- Resolves a GNU `/<offset>` name against the `//` long-name table. Entries
-- are `name/` terminated by LF (GNU) or NUL (the COFF flavor); both appear
-- in the wild, so both terminators are honored.
local function long_name(longnames, ref, archive, offset)
    local pos = tonumber(ref:sub(2))
    if not pos or not longnames or pos >= #longnames then
        errors.fail("ar long-name reference %s has no name table entry: %s", ref, archive)
    end
    local entry = longnames:sub(pos + 1):match("^([^\n%z]*)") or ""
    entry = (entry:gsub("/$", ""))
    if entry == "" then
        errors.fail("ar long-name reference %s has no name table entry: %s", ref, archive)
    end
    return entry
end

-- Reads every member of the archive in file order and returns
-- { {name = <member name>, data = <exact bytes>}, ... } for the object-file
-- members (*.o / *.obj). Symbol tables, long-name tables and any metadata
-- members are skipped -- the same selection the previous extract-then-glob
-- implementation made, minus the on-disk materialization of long names.
function object_members(archive)
    archive = path.absolute(archive)
    local bytes = io.readfile(archive, {encoding = "binary"})
    if type(bytes) ~= "string" or #bytes < #AR_MAGIC then
        errors.fail("cannot read ar archive: %s", archive)
    end
    local magic = bytes:sub(1, #AR_MAGIC)
    if magic == THIN_MAGIC then
        errors.fail("thin ar archives are not supported for Rust staticlib absorption: %s", archive)
    end
    if magic ~= AR_MAGIC then
        errors.fail("not an ar archive (bad global magic): %s", archive)
    end

    local members = {}
    local longnames = nil
    local total = #bytes
    local offset = #AR_MAGIC + 1
    while offset + 59 <= total do
        local header = bytes:sub(offset, offset + 59)
        if header:sub(59, 60) ~= "`\n" then
            errors.fail("corrupt ar member header at byte %d: %s", offset, archive)
        end
        local size = member_size(header, archive, offset)
        local data_start = offset + 60
        if data_start + size - 1 > total then
            errors.fail("truncated ar member at byte %d: %s", offset, archive)
        end

        local name_field = header:sub(1, 16)
        local name = nil
        local data_from = data_start
        local data_size = size
        local bsd_len = tonumber(name_field:match("^#1/(%d+)"))
        if bsd_len then
            -- BSD/Darwin: the name (NUL-padded for alignment) leads the data
            -- area and its length is included in the size field
            if bsd_len > size then
                errors.fail("corrupt ar member header at byte %d: %s", offset, archive)
            end
            name = (bytes:sub(data_start, data_start + bsd_len - 1):gsub("%z+$", ""))
            data_from = data_start + bsd_len
            data_size = size - bsd_len
        elseif name_field:sub(1, 1) == "/" then
            local ref = base.trim(name_field)
            if ref == "//" then
                longnames = bytes:sub(data_start, data_start + size - 1)
            elseif ref ~= "/" and ref ~= "/SYM64/" then
                name = long_name(longnames, ref, archive, offset)
            end
            -- `/` and `/SYM64/` are symbol tables: no name, skipped below
        else
            -- short name: GNU terminates with `/`, BSD pads with spaces only
            name = (base.trim(name_field):gsub("/$", ""))
        end

        if name and name ~= "" then
            local lowered = name:lower()
            if lowered:endswith(".o") or lowered:endswith(".obj") then
                table.insert(members, {
                    name = name,
                    data = bytes:sub(data_from, data_from + data_size - 1)
                })
            end
        end
        -- members are 2-byte aligned; the final pad byte may be absent at EOF
        offset = data_start + size + (size % 2)
    end
    return members
end
