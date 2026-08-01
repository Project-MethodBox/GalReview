-- Pinned integrity registry for every managed-toolchain archive that has a
-- knowable-good digest, plus a trust-on-first-use fallback for the few that
-- upstream neither signs nor publishes a hash for. Keyed by the download
-- cache leaf name (the archive filename, which equals the last path segment
-- of the pinned URL in core/modules/defaults.lua). The download layer runs
-- verify() on every archive it fetches OR reuses from cache before anything
-- is extracted, executed, or built, so encrypted-transport trust (TLS) is
-- backed by end-to-end content trust.
--
-- Each digest below was established once, out of band, at the strongest
-- assurance the upstream offers; the `via` note records how. Build hosts
-- never repeat the signature/network checks -- they only recompute and
-- compare the cheap digest -- so maintainer-signature-grade assurance costs
-- only a local hash at build time. When bumping a pinned version in
-- defaults.lua, re-establish its digest the same way and update it here.

import("base")
import("errors")
import("layout")
import("hosttools")

local CHECKSUMS = {
    ["binutils-2.45.tar.xz"] = {
        algorithm = "sha512",
        value = "c7b10a7466d9fd398d7a0b3f2a43318432668d714f2ec70069a31bdc93c86d28e0fe83792195727167743707fbae45337c0873a0786416db53bbf22860c16ce7",
        via = "upstream manifest sourceware.org/pub/binutils/releases/sha512.sum (2026-07-17)"},
    ["musl-1.2.5.tar.gz"] = {
        algorithm = "sha256",
        value = "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4",
        via = "gpg signature, key 836489290BB6B70F99FFDA0556BCDB593020450F musl libc <musl@libc.org> (2026-07-17)"},
    ["m4-1.4.19.tar.xz"] = {
        algorithm = "sha256",
        value = "63aede5c6d33b6d9b13511cd0be2cac046f2e70fd0a07aa9573a04a82783af96",
        via = "gpg signature via gnu-keyring, key 71C2CC22B1C4602927D2F3AAA7A16B4A2527436A Eric Blake (2026-07-17)"},
    ["mingw-w64-v14.0.0.tar.bz2"] = {
        algorithm = "sha256",
        value = "6eaf921d9eb987d3820b364ea9775bc19b965ec81490b6fdd716526c28e1995c",
        via = "gpg signature, key CAF5641F74F7DFBA88AE205693BDB53CD4EBC740 JonY (mingw-w64) (2026-07-17)"},
    ["flex-2.6.4.tar.gz"] = {
        algorithm = "sha256",
        value = "e87aae032bf07c26f85ac0ed3250998c37621d95f8bd748b31f15b33c45ee995",
        via = "first-party hash agreed by Homebrew core and Arch Linux .SRCINFO (2026-07-17)"},
    ["win_flex_bison-2.5.25.zip"] = {
        algorithm = "sha256",
        value = "8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135",
        via = "first-party hash of the official lexxmark/winflexbison GitHub release binary over TLS (2026-07-17)"},
    ["w64devkit-x64-2.8.0.7z.exe"] = {
        algorithm = "sha256",
        value = "6252bf34fe2231a55ac7f03d482b36d2c7c58697990551bba508102cfb3f342e",
        via = "github release attested asset digest, skeeto/w64devkit v2.8.0 (2026-07-17)"},
    ["w64devkit-x86-2.8.0.7z.exe"] = {
        algorithm = "sha256",
        value = "5d546d7eb8bcb8280088770abd3633ec2a9131c45e22dd2a0b4fd4971da8e23b",
        via = "github release attested asset digest, skeeto/w64devkit v2.8.0 (2026-07-17)"},
    -- managed Emscripten toolset 4.0.13 (gccemsdk.lua). The release archives
    -- and the Windows python package publish no upstream signature or hash;
    -- their leaves are version- and host-qualified locally because upstream
    -- serves every release under the same wasm-binaries name. Only the
    -- win-x64/linux-x64/mac-arm64 host set is pinned; other hosts use the
    -- same URL patterns with the trust-on-first-use fallback below.
    ["emscripten-4.0.13-win-x64-wasm-binaries.zip"] = {
        algorithm = "sha256",
        value = "a363d6e92dcaf0024d378f1faabb61a139d9152a796f66a475a48e33e90f6adb",
        via = "first-party hash of storage.googleapis.com/webassembly/emscripten-releases-builds/win/32b8ae819674cb42b8ac2191afeb9571e33ad5e2/wasm-binaries.zip over TLS (2026-07-17)"},
    ["emscripten-4.0.13-linux-x64-wasm-binaries.tar.xz"] = {
        algorithm = "sha256",
        value = "2ad887035e3e5cac78abcaeca3b3881897f03b9919d008cbc0ef41d7641247c9",
        via = "first-party hash of storage.googleapis.com/webassembly/emscripten-releases-builds/linux/32b8ae819674cb42b8ac2191afeb9571e33ad5e2/wasm-binaries.tar.xz over TLS (2026-07-17)"},
    ["emscripten-4.0.13-mac-arm64-wasm-binaries.tar.xz"] = {
        algorithm = "sha256",
        value = "12ac26e298ef973207eba9332e28da375ec2ba1d32e68e0d8b32de3c886a2e39",
        via = "first-party hash of storage.googleapis.com/webassembly/emscripten-releases-builds/mac/32b8ae819674cb42b8ac2191afeb9571e33ad5e2/wasm-binaries-arm64.tar.xz over TLS (2026-07-17)"},
    ["node-v22.16.0-win-x64.zip"] = {
        algorithm = "sha256",
        value = "21c2d9735c80b8f86dab19305aa6a9f6f59bbc808f68de3eef09d5832e3bfbbd",
        via = "upstream signed manifest nodejs.org/dist/v22.16.0/SHASUMS256.txt (2026-07-17)"},
    ["node-v22.16.0-linux-x64.tar.xz"] = {
        algorithm = "sha256",
        value = "f4cb75bb036f0d0eddf6b79d9596df1aaab9ddccd6a20bf489be5abe9467e84e",
        via = "upstream signed manifest nodejs.org/dist/v22.16.0/SHASUMS256.txt (2026-07-17)"},
    ["node-v22.16.0-darwin-arm64.tar.gz"] = {
        algorithm = "sha256",
        value = "1d7f34ec4c03e12d8b33481e5c4560432d7dc31a0ef3ff5a4d9a8ada7cf6ecc9",
        via = "upstream signed manifest nodejs.org/dist/v22.16.0/SHASUMS256.txt (2026-07-17)"},
    ["python-3.13.3-0-win-amd64.zip"] = {
        algorithm = "sha256",
        value = "6fe7a540c6b8b185780467cf7495e884ee62316ec4abb19e1c735b8a77c62465",
        via = "first-party hash of storage.googleapis.com/webassembly/emscripten-releases-builds/deps/python-3.13.3-0-win-amd64.zip over TLS (2026-07-17)"},
    -- Android NDK official archives for the recommended release r27c, the
    -- fallback path of `xmake android ndk install r27c` (android/modules/
    -- sdk.lua composes exactly these leaf names). Each sha256 was computed
    -- first-hand from an archive fetched over TLS from dl.google.com, and
    -- the same bytes were cross-checked against the SHA-1 and size Google
    -- publishes in the official SDK repository manifest
    -- dl.google.com/android/repository/repository2-3.xml.
    ["android-ndk-r27c-windows.zip"] = {
        algorithm = "sha256",
        value = "27e49f11e0cee5800983d8af8f4acd5bf09987aa6f790d4439dda9f3643d2494",
        via = "first-party sha256 over TLS; sha1 ac5f7762764b1f15341094e148ad4f847d050c38 and size 781511249 match repository2-3.xml (2026-07-17)"},
    ["android-ndk-r27c-linux.zip"] = {
        algorithm = "sha256",
        value = "59c2f6dc96743b5daf5d1626684640b20a6bd2b1d85b13156b90333741bad5cc",
        via = "first-party sha256 over TLS; sha1 090e8083a715fdb1a3e402d0763c388abb03fb4e and size 663987688 match repository2-3.xml (2026-07-17)"},
    ["android-ndk-r27c-darwin.zip"] = {
        algorithm = "sha256",
        value = "8c5685457c58a88527367d46d3f14e8c727d962c39f85344cff0c0768a73c3b7",
        via = "first-party sha256 computed on the macOS test host over TLS; sha1 0217c10ffbec496bb9fbfbb3c6fc2477c6b77297 and size 836128272 match repository2-3.xml (2026-07-17)"},
    -- managed glibc sysroot inputs (languages/cpp/modules/gccglibc.lua; the
    -- version set and the shared kernel-headers archive are pinned in
    -- core/modules/defaults.lua glibc_versions). Each digest was computed
    -- first-hand from an archive fetched through the managed download layer
    -- and then bound to upstream signing evidence as recorded in via.
    ["glibc-2.39.tar.xz"] = {
        algorithm = "sha256",
        value = "f77bd47cf8170c57365ae7bf86696c118adb3b120d3259c64c502d3dc1e2d926",
        via = "gpg signature on ftp.gnu.org archive, key 7273542B39962DF7B299931416792B4EA25340F8 Carlos O'Donell (2026-07-17)"},
    ["glibc-2.41.tar.xz"] = {
        algorithm = "sha256",
        value = "a5a26b22f545d6b7d7b3dd828e11e428f24f4fac43c934fb071b6a7d0828e901",
        via = "gpg signature on ftp.gnu.org archive, signing subkey FD19E6D31B192EE4DC63EAD3DC2B16215ED5412A of key 35B17DF5752577CA0C541CEB94BFDF4484AD142F Andreas K. Huettel, glibc release manager (2026-07-17)"},
    ["glibc-2.43.tar.xz"] = {
        algorithm = "sha256",
        value = "d9c86c6b5dbddb43a3e08270c5844fc5177d19442cf5b8df4be7c07cd5fa3831",
        via = "gpg signature on ftp.gnu.org archive, signing subkey FD19E6D31B192EE4DC63EAD3DC2B16215ED5412A of key 35B17DF5752577CA0C541CEB94BFDF4484AD142F Andreas K. Huettel, glibc release manager (2026-07-17)"},
    ["linux-6.12.95.tar.xz"] = {
        algorithm = "sha256",
        value = "a9e8c51fcb1e695d1d35dde5886cba579cb6f29c9646c5889f39d63841d4b9f6",
        via = "gpg signature by key 647F28654894E3BD457199BE38DBBDC86092693E Greg Kroah-Hartman on the uncompressed tar, cross-checked against the kernel.org autosigner-signed sha256sums.asc entry for the .tar.xz (2026-07-17)"},
}

-- Exposed so a consistency check can confirm every pinned URL in defaults.lua
-- still resolves to a registered leaf after a version bump.
function registry()
    return CHECKSUMS
end

-- xmake ships a Lua hash wrapper for sha256 but not sha512, so sha512 (used
-- by the binutils release manifest) falls back to the same external tool the
-- GCC-prerequisite verifier already depends on, then to certutil on Windows.
local function compute_digest(archive, algorithm)
    if algorithm == "sha256" then
        return hash.sha256(archive)
    end
    if algorithm == "sha512" then
        local sha512sum = hosttools.find_tool_path("sha512sum")
        if sha512sum then
            local ok, out = errors.trycall(function () return os.iorunv(sha512sum, {archive}) end)
            local hex = ok and type(out) == "string" and out:match("^%s*(%x+)")
            if hex and #hex == 128 then
                return hex:lower()
            end
        end
        if base.is_windows_host() then
            local certutil = hosttools.find_tool_path("certutil")
            if certutil then
                local ok, out = errors.trycall(function () return os.iorunv(certutil, {"-hashfile", archive, "SHA512"}) end)
                if ok and type(out) == "string" then
                    for line in out:gmatch("[^\r\n]+") do
                        local hex = (line:gsub("%s", ""))
                        if hex:match("^%x+$") and #hex == 128 then
                            return hex:lower()
                        end
                    end
                end
            end
        end
        errors.fail("cannot compute SHA-512 for %s: no sha512sum or certutil is available", archive)
    end
    errors.fail("unknown checksum algorithm %s registered for %s", tostring(algorithm), tostring(archive))
end

local function tofu_record_path(leaf)
    return path.join(layout.toolchains_cache_dir(base.host_os()), "checksums", "tofu", leaf .. ".sha256")
end

-- True when this leaf has a pinned upstream digest (verified by comparison,
-- not trust-on-first-use).
function is_pinned(leaf)
    return CHECKSUMS[leaf] ~= nil
end

-- True when a trust-on-first-use digest has already been established for this
-- leaf on this host.
function has_tofu_record(leaf)
    return os.isfile(tofu_record_path(leaf))
end

-- Drops a leaf's trust-on-first-use record so the next download re-establishes
-- it from scratch. The unusable-archive recovery path uses this so a corrupt
-- first download that got recorded does not permanently reject the good
-- re-download with a digest mismatch.
function clear_tofu_record(leaf)
    local record = tofu_record_path(leaf)
    if os.isfile(record) then
        os.tryrm(record)
    end
end

-- For artifacts upstream neither signs nor hashes (a user-selected NDK
-- version, an overridden URL): record the digest of the first download and
-- require every later fetch or cache reuse to match it, so a silently
-- swapped cache is still caught even without an upstream reference value.
local function verify_trust_on_first_use(archive, leaf)
    local actual = compute_digest(archive, "sha256")
    local record = tofu_record_path(leaf)
    if os.isfile(record) then
        local stored = (io.readfile(record) or ""):match("sha256:(%x+)")
        if not stored or stored:lower() ~= actual then
            print(string.format("trust-on-first-use digest changed for %s", leaf))
            print(string.format("  recorded: %s", tostring(stored)))
            print(string.format("  now:      %s", actual))
            print(string.format("  if this artifact was legitimately updated, delete %s and rerun to re-trust;", record))
            print("  otherwise the cached download was replaced -- do not proceed until you know which")
            errors.fail("trust-on-first-use integrity check failed: %s", leaf)
        end
        return
    end
    os.mkdir(path.directory(record))
    local tmp = layout.unique_cache_path(record, "tofu")
    io.writefile(tmp, string.format("format:tofu-v1\nsha256:%s\nleaf:%s\nfirst-seen:%s\n",
        actual, leaf, os.date("!%Y-%m-%dT%H:%M:%SZ")))
    os.mv(tmp, record)
    print(string.format("no pinned digest for %s; trusting this first download and recording it (%s)", leaf, actual))
end

-- Read-only inventory of the trust-on-first-use records this host has
-- accumulated. TOFU records live in the host-local cache and die with it
-- (a cold CI host re-trusts from zero), so digests worth keeping should
-- graduate into the pinned CHECKSUMS registry above; the
-- `xmake toolchains checksums` command prints these as paste-ready entries
-- for the owner to re-establish first-hand and pin.
function tofu_records()
    local records = {}
    local dir = path.join(layout.toolchains_cache_dir(base.host_os()), "checksums", "tofu")
    for _, file in ipairs(os.files(path.join(dir, "*.sha256"))) do
        local content = io.readfile(file) or ""
        table.insert(records, {
            leaf = content:match("leaf:([^\r\n]*)") or path.basename(file),
            sha256 = content:match("sha256:(%x+)") or "",
            first_seen = content:match("first%-seen:([^\r\n]*)") or "",
            record = file
        })
    end
    table.sort(records, function (a, b)
        return a.leaf < b.leaf
    end)
    return records
end

-- Default archive verifier wired into download_and_extract_archive. Raises on
-- mismatch (the caller re-downloads once, then fails hard); returns silently
-- when the bytes are trusted.
function verify(archive)
    local leaf = path.filename(archive)
    local entry = CHECKSUMS[leaf]
    if not entry then
        return verify_trust_on_first_use(archive, leaf)
    end
    local actual = compute_digest(archive, entry.algorithm)
    if actual:lower() ~= entry.value:lower() then
        print(string.format("integrity check FAILED for %s", leaf))
        print(string.format("  expected (%s): %s", entry.algorithm, entry.value))
        print(string.format("  actual:          %s", actual))
        print(string.format("  pinned digest established via %s", entry.via))
        print("  if you bumped this version in core/modules/defaults.lua, re-establish and update its digest in core/modules/checksums.lua")
        errors.fail("archive integrity check failed: %s", leaf)
    end
end
