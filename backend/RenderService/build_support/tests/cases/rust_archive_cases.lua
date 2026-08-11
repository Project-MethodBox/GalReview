-- Fixture regression for the native ar reader (archive.object_members) and
-- the staticlib flattening built on it (cargo.unpack_objects). The reader
-- replaced an external `ar x` whose extraction materialized rustc's long
-- member names (84 characters observed) under the objectdir and crossed the
-- Windows MAX_PATH ceiling for deep build directories; the cases below pin
-- the three dialects rustc's archive writer emits (GNU/SysV, the COFF
-- flavor, BSD/Darwin), byte-exact member payloads, and the property that
-- member-name length never appears in any written path.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("archive", {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "rust", "modules")})
import("cargo", {rootdir = path.join(os.scriptdir(), "..", "..", "languages", "rust", "modules")})

-- an 84-character name shaped like the real compiler_builtins codegen units
local LONG_NAME = "compiler_builtins-0123456789abcdef.compiler_builtins.fedcba9876543210-cgu.000.rcgu.o"

local function pad_field(value, width)
    value = tostring(value)
    assert(#value <= width, "ar header field overflow")
    return value .. string.rep(" ", width - #value)
end

local function member(name_field, data)
    return pad_field(name_field, 16) .. pad_field("0", 12) .. pad_field("0", 6)
        .. pad_field("0", 6) .. pad_field("644", 8) .. pad_field(#data, 10) .. "`\n"
        .. data .. (#data % 2 == 1 and "\n" or "")
end

-- GNU/SysV: `/` symbol table, `//` long-name table with `/`-and-LF
-- terminated entries, `/<offset>` references, `name/` short names
local function gnu_archive(long_data, short_data)
    local longnames = LONG_NAME .. "/\n"
    return "!<arch>\n"
        .. member("/", "\0\0\0\0")
        .. member("//", longnames)
        .. member("/0", long_data)
        .. member("lib.rmeta/", "METADATA")
        .. member("a.o/", short_data)
end

-- COFF flavor: duplicated `/` symbol tables, NUL-terminated `//` entries
local COFF_NAME = "coff-member-name-0123456789.obj"
local function coff_archive(data)
    return "!<arch>\n"
        .. member("/", "\0\0\0\0")
        .. member("/", "\0\0\0\0")
        .. member("//", COFF_NAME .. "\0")
        .. member("/0", data)
end

-- BSD/Darwin: `#1/<n>` inline names (NUL-padded, length counted inside the
-- size field), bare space-padded short names
local BSD_NAME = "whe-0123456789ab.rcgu.o"
local function bsd_archive(long_data, short_data)
    local symdef = "__.SYMDEF SORTED" .. string.rep("\0", 4)
    local inline = BSD_NAME .. "\0"
    return "!<arch>\n"
        .. member("#1/" .. #symdef, symdef .. "\0\0\0\0\0\0\0\0")
        .. member("#1/" .. #inline, inline .. long_data)
        .. member("b.o", short_data)
end

local function write_archive(dir, name, bytes)
    local file = path.join(dir, name)
    os.mkdir(path.directory(file))
    base.writefile_bytes(file, bytes)
    return file
end

local function read_bytes(file)
    return io.readfile(file, {encoding = "binary"})
end

function run(t)
    t.case("rust archive: GNU dialect resolves long names and skips tables", function ()
        local dir = t.tmpdir("ar-gnu")
        local long_data = "\0OBJ\n\255X" -- odd length exercises the pad byte
        local short_data = "A\0B"
        local lib = write_archive(dir, "libwhe.a", gnu_archive(long_data, short_data))
        local members = archive.object_members(lib)
        t.assert_eq(#members, 2, "object member count")
        t.assert_eq(members[1].name, LONG_NAME, "long member name")
        t.assert_eq(members[1].data, long_data, "long member data")
        t.assert_eq(members[2].name, "a.o", "short member name")
        t.assert_eq(members[2].data, short_data, "short member data")
    end)

    t.case("rust archive: COFF flavor honors NUL-terminated name tables", function ()
        local dir = t.tmpdir("ar-coff")
        local lib = write_archive(dir, "libwhe.a", coff_archive("COFFDATA"))
        local members = archive.object_members(lib)
        t.assert_eq(#members, 1, "object member count")
        t.assert_eq(members[1].name, COFF_NAME, "resolved name")
        t.assert_eq(members[1].data, "COFFDATA", "member data")
    end)

    t.case("rust archive: BSD dialect keeps inline-name data boundaries exact", function ()
        local dir = t.tmpdir("ar-bsd")
        local long_data = "BSD\0DATA"
        local short_data = "xy"
        local lib = write_archive(dir, "libwhe.a", bsd_archive(long_data, short_data))
        local members = archive.object_members(lib)
        t.assert_eq(#members, 2, "object member count (symbol table skipped)")
        t.assert_eq(members[1].name, BSD_NAME, "inline long name (NUL padding stripped)")
        t.assert_eq(members[1].data, long_data, "inline-name member data")
        t.assert_eq(members[2].name, "b.o", "bare short name")
        t.assert_eq(members[2].data, short_data, "short member data")
    end)

    t.case("rust archive: malformed inputs fail loudly", function ()
        local dir = t.tmpdir("ar-bad")
        t.expect_raise(function ()
            archive.object_members(write_archive(dir, "thin.a",
                "!<thin>\n" .. member("/", "\0\0\0\0")))
        end, "thin ar archives", "thin archive")
        t.expect_raise(function ()
            archive.object_members(write_archive(dir, "not.a", "NOTANAR\n"))
        end, "not an ar archive", "bad magic")
        local broken = member("a.o/", "AB")
        broken = broken:sub(1, 58) .. "XX" .. broken:sub(61)
        t.expect_raise(function ()
            archive.object_members(write_archive(dir, "corrupt.a", "!<arch>\n" .. broken))
        end, "corrupt ar member header", "bad end marker")
        local short_body = pad_field("a.o/", 16) .. pad_field("0", 12) .. pad_field("0", 6)
            .. pad_field("0", 6) .. pad_field("644", 8) .. pad_field(100, 10) .. "`\nAB"
        t.expect_raise(function ()
            archive.object_members(write_archive(dir, "truncated.a", "!<arch>\n" .. short_body))
        end, "truncated ar member", "truncated member")
        t.expect_raise(function ()
            archive.object_members(write_archive(dir, "noref.a",
                "!<arch>\n" .. member("/5", "ABCD")))
        end, "has no name table entry", "reference without table")
    end)

    t.case("rust unpack: members flatten to short unique names, byte-exact", function ()
        local dir = t.tmpdir("unpack-flatten")
        local gnu_long, gnu_short = "\0GNU\n\255!", "A\0B"
        local bsd_long, bsd_short = "BSD\0DATA", "xy"
        local lib1 = write_archive(dir, "lib1.a", gnu_archive(gnu_long, gnu_short))
        local lib2 = write_archive(dir, "lib2.a", bsd_archive(bsd_long, bsd_short))
        local lib3 = write_archive(dir, "lib3.a", coff_archive("COFFDATA"))
        local owner = path.join(dir, "owner")
        local output = path.join(owner, "staticlib")
        local objects = cargo.unpack_objects({lib1, lib2, lib3}, output, owner)
        t.assert_eq(#objects, 5, "flattened object count")
        t.assert_eq(path.filename(objects[1]), "rust-0001-0001.o", "first name")
        t.assert_eq(path.filename(objects[2]), "rust-0001-0002.o", "second name")
        t.assert_eq(path.filename(objects[3]), "rust-0002-0001.o", "third name")
        t.assert_eq(path.filename(objects[4]), "rust-0002-0002.o", "fourth name")
        t.assert_eq(path.filename(objects[5]), "rust-0003-0001.obj", ".obj extension survives")
        t.assert_eq(read_bytes(objects[1]), gnu_long, "GNU long member payload")
        t.assert_eq(read_bytes(objects[2]), gnu_short, "GNU short member payload")
        t.assert_eq(read_bytes(objects[3]), bsd_long, "BSD long member payload")
        t.assert_eq(read_bytes(objects[4]), bsd_short, "BSD short member payload")
        t.assert_eq(read_bytes(objects[5]), "COFFDATA", "COFF member payload")
    end)

    t.case("rust unpack: the signature marker caches and re-extracts on change", function ()
        local dir = t.tmpdir("unpack-cache")
        local lib = write_archive(dir, "lib.a", gnu_archive("FIRST", "A"))
        local owner = path.join(dir, "owner")
        local output = path.join(owner, "staticlib")
        local objects = cargo.unpack_objects({lib}, output, owner)
        base.writefile_bytes(objects[1], "TAMPERED")
        local cached = cargo.unpack_objects({lib}, output, owner)
        t.assert_eq(#cached, #objects, "cached set size")
        t.assert_eq(read_bytes(cached[1]), "TAMPERED", "matching signature is a no-op")
        write_archive(dir, "lib.a", gnu_archive("SECOND", "A"))
        local refreshed = cargo.unpack_objects({lib}, output, owner)
        t.assert_eq(read_bytes(refreshed[1]), "SECOND", "signature change re-extracts")
    end)

    t.case("rust unpack: a stale pre-native extraction layout is replaced", function ()
        local dir = t.tmpdir("unpack-stale")
        local lib = write_archive(dir, "lib.a", gnu_archive("DATA", "A"))
        local owner = path.join(dir, "owner")
        local output = path.join(owner, "staticlib")
        os.mkdir(path.join(output, "archive-0001"))
        os.mkdir(path.join(output, "objects"))
        base.writefile_bytes(path.join(output, "archive-0001", "leftover.rcgu.o"), "OLD")
        base.writefile_bytes(path.join(output, "objects", "rust-9999-9999.o"), "OLD")
        base.writefile_bytes(path.join(output, ".unpacked"), "stale signature\n")
        local objects = cargo.unpack_objects({lib}, output, owner)
        t.assert_eq(#objects, 2, "fresh object count")
        t.assert_true(not os.isdir(path.join(output, "archive-0001")),
            "extraction directory of the old layout is gone")
        t.assert_true(not os.isfile(path.join(output, "objects", "rust-9999-9999.o")),
            "stale flattened object is gone")
    end)

    t.case("rust unpack: member-name length never reaches the written paths", function ()
        -- the regression that motivated the native reader: an 84-character
        -- member name plus a deep objectdir crossed MAX_PATH under `ar x`;
        -- the flattened writes must stay inside the objectdir's own budget
        local dir = t.tmpdir("unpack-deep")
        local lib = write_archive(dir, "lib.a", gnu_archive("DEEP", "A"))
        local owner = dir
        local output = path.join(owner, "staticlib")
        -- pad toward 200-229 characters: deep enough to sit in the range the
        -- old `ar x` path died in, while <output>/objects/rust-0001-0001.o
        -- stays under 260 even on hosts without long-path support
        local segments = 0
        while #output < 200 and segments < 8 do
            output = path.join(output, "deep-segment-abcdefghijklmnop")
            segments = segments + 1
        end
        local objects = cargo.unpack_objects({lib}, output, owner)
        t.assert_eq(#objects, 2, "object count at depth")
        t.assert_eq(path.filename(objects[1]), "rust-0001-0001.o", "short flattened name")
        t.assert_true(#objects[1] < 260, "written path stays under MAX_PATH")
        t.assert_eq(read_bytes(objects[1]), "DEEP", "payload at depth")
    end)

    t.case("rust unpack: a staticlib without object members fails loudly", function ()
        local dir = t.tmpdir("unpack-empty")
        local lib = write_archive(dir, "empty.a", "!<arch>\n" .. member("/", "\0\0\0\0"))
        local owner = path.join(dir, "owner")
        os.mkdir(owner)
        t.expect_raise(function ()
            cargo.unpack_objects({lib}, path.join(owner, "staticlib"), owner)
        end, "no object members", "empty staticlib")
    end)

    t.case("rust unpack: the output directory must live inside its owner", function ()
        local dir = t.tmpdir("unpack-owner")
        local lib = write_archive(dir, "lib.a", gnu_archive("DATA", "A"))
        local owner = path.join(dir, "owner")
        local outside = path.join(dir, "outside")
        os.mkdir(owner)
        t.expect_raise(function ()
            cargo.unpack_objects({lib}, outside, owner)
        end, "refusing to replace", "owner guard")
    end)
end
