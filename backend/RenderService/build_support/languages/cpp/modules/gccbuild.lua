-- GCC build orchestration (C++-specific): installed-toolchain validation
-- (config-signature stamp, std-module fallback detection), binutils
-- download/configure/build, the Windows-host makefile patch pass, and the
-- build_gcc_for driver that sequences a full toolchain build. Per-target-OS
-- knowledge (sysroots, runtimes, configure args, build plans, target-side
-- patches) lives in the provider modules under targets/, dispatched through
-- gcctargets.provider_of; the shared install-tree probes live in gccinstall.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
local defaults = import("defaults", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")}).values()
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("hosttools", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("envs", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("run", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("download", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("makerunner", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("install_lock", {rootdir = path.join(os.scriptdir(), "..", "..", "..", "core", "modules")})
import("gccsources")
import("gccpatches")
import("hostboot")
import("gcctargets")
import("gccinstall")

-- Mirrored option fallbacks. options.lua owns the description-scope
-- originals (option() defaults are evaluated before any module can load, so
-- they cannot move here), and script scope cannot see description globals.
function compiler_exists(target_os)
    local provider = gcctargets.provider_of(target_os)
    if provider.compiler_exists then
        return provider.compiler_exists(target_os)
    end
    return gccinstall.compiler_exists(target_os)
end

function target_libgcc_file(target_os)
    return gccinstall.target_libgcc_file(target_os)
end

function target_static_libgcc_available(target_os)
    return gccinstall.target_static_libgcc_available(target_os)
end

function managed_toolchains_installed_config_matches(target_os)
    local expected = base.trim(settings.build_config_signature(target_os))
    local stamp = settings.stamp_file(target_os)
    if not os.isfile(stamp) then
        return false
    end
    local content = io.readfile(stamp)
    local begin_marker = "build_config_signature_begin\n"
    local end_marker = "\nbuild_config_signature_end"
    local begin_pos = content:find(begin_marker, 1, true)
    if begin_pos then
        local signature_start = begin_pos + #begin_marker
        local end_pos = content:find(end_marker, signature_start, true)
        if end_pos then
            if base.trim(content:sub(signature_start, end_pos - 1)) ~= expected then
                return false
            end
            -- Source identity is compared for EVERY profile. mainline was
            -- historically exempt, which let a gcc_ref/gcc_git_url change
            -- silently keep reusing a compiler built from the old revision
            -- (found by external review, 2026-07-18 -- and live on the dev
            -- machine: a pre-pinning stamp carried ref=master while the
            -- tree and the pin had both moved on). Stamps from before the
            -- identity fields were recorded cannot be verified at all, so
            -- they get the same one-honest-rebuild treatment as the
            -- missing-signature case below.
            local source = settings.gcc_source_profile(target_os)
            local function stamp_value(name)
                return content:match("[\r\n]" .. base.escape_pattern(name) .. "=([^\r\n]*)") or ""
            end
            local installed_revision = stamp_value("source_revision")
            if stamp_value("source_profile") == "" and stamp_value("source_url") == ""
                and stamp_value("source_ref") == "" and installed_revision == "" then
                errors.warn("existing toolchain stamp has no recorded source identity (%s); treating it as out of date and rebuilding once to establish one", stamp)
                return false
            end
            if stamp_value("source_profile") ~= source.name
                or stamp_value("source_url") ~= source.url
                or stamp_value("source_ref") ~= source.ref then
                return false
            end
            if installed_revision == "" then
                return false
            end
            local current_revision = gccsources.managed_toolchains_gcc_source_revision(settings.gcc_source_dir(target_os))
            if current_revision ~= "" and current_revision ~= installed_revision then
                return false
            end
            -- Local patch identity: source_patch_stamp_version bumps whenever a
            -- registered GCC source patch changes. It gates source RE-patching
            -- (the marker name embeds it) but, until now, not the install gate.
            -- Editing a local patch under the SAME upstream revision leaves the
            -- source identity and the build-config signature unchanged, so the
            -- gate would report "already installed" and the auto-install path
            -- would silently reuse a compiler built from the OLD patch set
            -- (external review, 2026-07-20). A stamp written before this field
            -- existed cannot prove which patches built it, so it gets the same
            -- one-honest-rebuild treatment as a pre-key source stamp above.
            local installed_patch_version = stamp_value("source_patch_version")
            if installed_patch_version == "" then
                return false
            end
            if installed_patch_version ~= tostring(gccpatches.source_patch_stamp_version(target_os)) then
                return false
            end
            -- Binutils identity: a snapshot-url bump must not be reported as
            -- "already installed". The identity file is written next to the
            -- installed cross as/ld after a build.
            local binutils_identity_file = managed_toolchains_binutils_identity_file(target_os)
            if os.isfile(binutils_identity_file) then
                if base.trim(io.readfile(binutils_identity_file)) ~= managed_toolchains_binutils_identity() then
                    return false
                end
            elseif managed_toolchains_builds_binutils(target_os) then
                -- Migration: a pre-identity install that went through
                -- build_binutils_for has the cross as/ld but no identity file, so
                -- a url bump could not be detected. Treat an as/ld-present-but-
                -- unstamped tree as unknown provenance and rebuild once to
                -- establish the identity (same one-honest-rebuild treatment the
                -- GCC source-identity check gives a pre-key stamp). Gated on
                -- managed_toolchains_builds_binutils -- the SAME predicate that
                -- drives build_binutils_for -- so it fires only for targets that
                -- actually build project binutils. A bare is_cross_target check
                -- was wrong: the Apple providers stage <triplet>-as/<triplet>-ld
                -- as thin cctools wrappers for iOS (and macOS on a Mac host),
                -- which never build binutils, so it rebuilt those toolchains on
                -- every gate check.
                local bindir = path.join(settings.gcc_prefix(target_os), "bin")
                local triplet = settings.managed_target(target_os)
                if base.file_nonempty(path.join(bindir, base.exe(triplet .. "-as")))
                    and base.file_nonempty(path.join(bindir, base.exe(triplet .. "-ld"))) then
                    errors.warn("cross binutils has no recorded snapshot identity (%s); rebuilding once to establish one", binutils_identity_file)
                    return false
                end
            end
            return true
        end
    end
    -- Legacy/corrupted stamp with no recorded signature: we cannot verify it
    -- matches the current build configuration, so treat it as a mismatch
    -- (forces exactly one rebuild, which re-stamps with a comparable
    -- signature) instead of silently grandfathering a possibly-stale
    -- toolchain in as current.
    errors.warn("existing toolchain stamp has no recorded build-config signature (%s); treating it as out of date and rebuilding once to establish one", stamp)
    return false
end

-- opt.read_only skips the installed-tree repair (which can delete alias files
-- and rewrite the configure cache when the tree is poisoned) so the read-only
-- `status`/`matrix` commands honour their documented no-side-effect contract.
function toolchain_installed(target_os, opt)
    if not compiler_exists(target_os) then
        return false
    end
    local provider = gcctargets.provider_of(target_os)
    if provider.repair_installed_tree and not (opt and opt.read_only) then
        provider.repair_installed_tree(target_os)
    end
    if not managed_toolchains_installed_config_matches(target_os) then
        return false
    end
    if provider.installed_extra then
        return provider.installed_extra(target_os)
    end
    return gccinstall.installed_runtime_complete(target_os)
end

function cleanup_windows_bootstrap_toolchain_after_success(target_os)
    local state = hosttools.windows_bootstrap_state()
    if not state.cleanup_root and not state.cleanup_archive then
        return
    end
    if not toolchain_installed(target_os) then
        errors.warn("keeping temporary Windows bootstrap files because the project-local GCC install is not fully usable yet")
        return
    end
    hostboot.cleanup_windows_bootstrap_toolchain()
end

local function find_extracted_binutils_source(outputdir)
    if os.isfile(path.join(outputdir, "configure")) and os.isdir(path.join(outputdir, "binutils")) and os.isdir(path.join(outputdir, "bfd")) then
        return outputdir
    end
    for _, dir in ipairs(os.dirs(path.join(outputdir, "*"))) do
        if os.isfile(path.join(dir, "configure")) and os.isdir(path.join(dir, "binutils")) and os.isdir(path.join(dir, "bfd")) then
            return dir
        end
    end
    errors.fail("downloaded binutils archive did not contain a binutils source tree")
end

function patch_binutils_source(src)
    if base.host_os() ~= "macosx" then
        return
    end
    local file = path.join(src, "zlib", "zutil.h")
    if not os.isfile(file) then
        return
    end

    local content = io.readfile(file)
    local patched = base.replace_plain(content,
        "#        define fdopen(fd,mode) NULL /* No fdopen() */",
        "/* xmake: keep the macOS SDK fdopen declaration visible. */")
    if patched ~= content then
        print("patching binutils zlib for macOS SDK fdopen")
        base.writefile_bytes(file, patched)
    end
end

-- The binutils snapshot URL that the installed cross as/ld should have been
-- built from. Recorded next to them so a URL bump is detected instead of
-- silently reusing the old assembler/linker (the analogue of the GCC
-- source-identity check in managed_toolchains_installed_config_matches).
function managed_toolchains_binutils_identity()
    return base.trim(settings.value_or("binutils_snapshot_url", defaults.binutils_snapshot_url))
end

function managed_toolchains_binutils_identity_file(target_os)
    return path.join(settings.gcc_prefix(target_os), "bin", ".binutils-identity")
end

-- The exact set of targets whose build produces project GNU binutils and so
-- writes a .binutils-identity next to the cross as/ld: a cross target that
-- needs binutils and does not stage its own backend tool family. The install
-- gate's pre-identity migration MUST key on this rather than on the mere
-- presence of a <triplet>-as/<triplet>-ld pair -- the Apple providers stage
-- exactly those names as thin cctools wrappers (targets/*.lua stage_tools) for
-- iOS/macOS, which never build binutils (needs_binutils = false), so a bare
-- is_cross_target check rebuilt the whole iOS toolchain on every install-gate
-- check. Kept in lockstep with the build_binutils_for call site (build_gcc_for)
-- so the gate and the builder cannot drift apart.
function managed_toolchains_builds_binutils(target_os)
    if gcctargets.provider_of(target_os).prepare_backend_tools then
        return false
    end
    return settings.is_cross_target(target_os) and gcctargets.needs_binutils(target_os)
end

local function download_binutils_snapshot(force)
    local url = settings.value_or("binutils_snapshot_url", defaults.binutils_snapshot_url)
    local src = layout.binutils_source_dir()
    local stamp = path.join(src, ".xmake-source")
    local source_signature = url .. "\n"
    if not force and os.isfile(path.join(src, "configure")) and os.isfile(stamp) and io.readfile(stamp) == source_signature then
        patch_binutils_source(src)
        return src
    end

    local cache = layout.download_cache_dir()
    local archive = path.join(cache, gccsources.archive_leaf_name(url, "binutils.tar.xz"))
    local extracted = layout.extract_cache_dir("binutils-source")
    download.download_and_extract_archive(url, archive, extracted, force)

    local source_root = find_extracted_binutils_source(extracted)
    layout.remove_toolchains_path(src)
    os.mkdir(path.directory(src))
    os.mv(source_root, src)
    patch_binutils_source(src)
    io.writefile(stamp, source_signature)
    layout.remove_toolchains_path(extracted)
    return src
end

local function strip_installed_toolchain(target_os)
    if not settings.strip_enabled() then
        return
    end

    local prefix = settings.gcc_prefix(target_os)
    local triplet = settings.managed_target(target_os)
    local host_strip = hosttools.preferred_host_tool_any({settings.host_triplet() .. "-strip", "strip"})
    local target_strip = hostboot.managed_tool(path.join(prefix, "bin"), triplet, "strip")
    if not os.isfile(target_strip) then
        target_strip = host_strip
    end

    local seen = {}
    local function has_strippable_file_magic(file)
        local data = io.readfile(file, {encoding = "binary"}) or ""
        if #data < 2 then
            return false
        end
        if data:sub(1, 4) == "\127ELF" then
            return true
        end
        if data:sub(1, 2) == "MZ" then
            return true
        end
        if data:sub(1, 8) == "!<arch>\n" then
            return true
        end

        local b1, b2, b3, b4 = data:byte(1, 4)
        if b1 == 0xfe and b2 == 0xed and b3 == 0xfa and (b4 == 0xce or b4 == 0xcf) then
            return true
        end
        if (b1 == 0xce or b1 == 0xcf) and b2 == 0xfa and b3 == 0xed and b4 == 0xfe then
            return true
        end
        return b1 == 0xca and b2 == 0xfe and b3 == 0xba and b4 == 0xbe
    end
    local function should_strip_installed_file(file)
        local normalized = tostring(file):gsub("\\", "/")
        if normalized:find("/install%-tools/", 1, false) then
            return false
        end
        local leaf = path.filename(file)
        if leaf == "mkinstalldirs" or leaf == "mkheaders" then
            return false
        end
        if leaf:endswith(".sh") or leaf:endswith(".py") or leaf:endswith(".txt") or leaf:endswith(".la") then
            return false
        end
        return has_strippable_file_magic(file)
    end
    local function collect(pattern)
        local files = {}
        for _, file in ipairs(os.files(pattern)) do
            if os.isfile(file) and not os.islink(file) and should_strip_installed_file(file) and not seen[file] then
                seen[file] = true
                table.insert(files, file)
            end
        end
        return files
    end
    local function append_all(result, values)
        for _, value in ipairs(values) do
            table.insert(result, value)
        end
    end
    local function strip_files(strip, args, files)
        local count = 0
        if not strip or strip == "" then
            return 0
        end
        for _, file in ipairs(files) do
            local argv = {}
            for _, arg in ipairs(args) do
                table.insert(argv, arg)
            end
            table.insert(argv, file)
            local ok = errors.trycall(function ()
                os.vrunv(strip, argv, {try = true})
            end)
            if ok then
                count = count + 1
            else
                errors.warn("skipping unstrippable installed file: %s", file)
            end
        end
        return count
    end

    local host_files = {}
    if base.is_windows_host() then
        append_all(host_files, collect(path.join(prefix, "bin", "*.exe")))
        append_all(host_files, collect(path.join(prefix, "libexec", "**", "*.exe")))
        append_all(host_files, collect(path.join(prefix, "**", "*.dll")))
    else
        append_all(host_files, collect(path.join(prefix, "bin", "*")))
        append_all(host_files, collect(path.join(prefix, "libexec", "**", "*")))
    end

    local target_files = {}
    for _, pattern in ipairs(gcctargets.target_tools(target_os).strip_globs) do
        append_all(target_files, collect(path.join(prefix, pattern)))
    end

    local target_debug_files = {}
    append_all(target_debug_files, collect(path.join(prefix, "lib", "gcc", triplet, "**", "*.a")))
    append_all(target_debug_files, collect(path.join(prefix, "lib", "gcc", triplet, "**", "*.o")))
    append_all(target_debug_files, collect(path.join(prefix, triplet, "**", "*.a")))
    append_all(target_debug_files, collect(path.join(prefix, triplet, "**", "*.o")))

    local strip_unneeded_args = {"--strip-unneeded"}
    local strip_debug_args = {"--strip-debug"}
    if base.host_os() == "macosx" then
        strip_unneeded_args = {"-x"}
        strip_debug_args = {"-S"}
    end

    local stripped = 0
    stripped = stripped + strip_files(host_strip, strip_unneeded_args, host_files)
    stripped = stripped + strip_files(target_strip, strip_unneeded_args, target_files)
    stripped = stripped + strip_files(target_strip, strip_debug_args, target_debug_files)
    if stripped > 0 then
        print(string.format("stripped %d installed toolchain file(s)", stripped))
    end
end

local function install_stamp(target_os)
    local stamp = settings.stamp_file(target_os)
    os.mkdir(path.directory(stamp))
    local extra = gcctargets.stamp_extra(target_os)
    local source = settings.gcc_source_profile(target_os)
    local source_revision = gccsources.managed_toolchains_gcc_source_revision(settings.gcc_source_dir(target_os))
    io.writefile(stamp, string.format("host=%s\ntarget_os=%s\ntriplet=%s\nref=%s\nsource_profile=%s\nsource_url=%s\nsource_ref=%s\nsource_revision=%s\nsource_patch_version=%s\n%sinstalled_at=%s\nbuild_config_signature_begin\n%sbuild_config_signature_end\n",
        base.host_os(), target_os, settings.managed_target(target_os), source.ref, source.name, source.url, source.ref,
        source_revision, tostring(gccpatches.source_patch_stamp_version(target_os)), extra, os.date(), settings.build_config_signature(target_os)))
end

-- One-time migration for stamps written before a provider stamp_extra key
-- existed: the read-only gates (status/matrix/installed_extra) grandfather
-- missing keys because probes must not mutate, so this WRITE path adopts
-- the current identity for them and closes the drift-detection window
-- without forcing a rebuild. Value MISMATCHES are deliberately untouched
-- here -- those are the outer gate's job and force a rebuild instead.
local function migrate_stamp_extra_keys(target_os)
    local stamp = settings.stamp_file(target_os)
    local content = io.readfile(stamp) or ""
    -- The key probe scans the WHOLE stamp text, so a key that only exists
    -- inside the build_config_signature block also counts as present. That
    -- is deliberate: for providers whose stamp_extra mirrors
    -- signature_extra (ios, macosx) the two appear and disappear together
    -- historically, and a value-bearing line in either place already gives
    -- the drift gates something to compare against.
    local missing_lines = {}
    for line in tostring(gcctargets.stamp_extra(target_os)):gmatch("[^\n]+") do
        local key = line:match("^([%w_]+)=")
        if key and not content:match("[\r\n]" .. key .. "=") then
            table.insert(missing_lines, line)
        end
    end
    if #missing_lines == 0 then
        return
    end
    errors.warn("install stamp predates the current provider identity keys; adopting the current identity so drift detection starts now: %s", stamp)
    -- Targeted append of ONLY the missing key lines. A full install_stamp()
    -- rewrite would re-derive source_revision from the source cache, and
    -- with that cache deleted -- a supported state: the install gate skips
    -- the revision comparison when no tree is present -- it would blank a
    -- perfectly valid recorded revision and force a pointless full rebuild
    -- on the next gate run (external review, 2026-07-18). Everything the
    -- current environment cannot re-derive stays byte-identical.
    local block = table.concat(missing_lines, "\n") .. "\n"
    local insert_at = content:find("\ninstalled_at=", 1, true)
        or content:find("\nbuild_config_signature_begin", 1, true)
    if insert_at then
        content = content:sub(1, insert_at) .. block .. content:sub(insert_at + 1)
    else
        content = content .. block
    end
    io.writefile(stamp, content)
end

function finalize_existing_toolchain_install(target_os)
    local provider = gcctargets.provider_of(target_os)
    if provider.ensure_smoke_current then
        provider.ensure_smoke_current(target_os)
    end
    if provider.finalize then
        provider.finalize(target_os)
    end
    if not os.isfile(settings.stamp_file(target_os)) then
        errors.log("finalizing existing project-local GCC toolchain")
        strip_installed_toolchain(target_os)
        install_stamp(target_os)
    else
        migrate_stamp_extra_keys(target_os)
    end
end

function reset_build_dir(build)
    return gccinstall.reset_build_dir(build)
end

function managed_toolchains_gcc_configure_makefile_complete(makefile)
    if not os.isfile(makefile) then
        return false
    end
    local content = io.readfile(makefile) or ""
    return content:find("configure%-gcc", 1, false) ~= nil
end

local function patch_install_macros_to_cp_file(file, label)
    if not base.is_windows_host() then
        return
    end
    if not os.isfile(file) then
        return
    end
    local content = io.readfile(file)
    local patched = content
    patched = patched:gsub("%$%(INSTALL%)%s+%-d", "mkdir -p")
    patched = patched:gsub("%S*install%.exe %-c %-d", "mkdir -p")
    for _, var in ipairs({"INSTALL", "INSTALL_PROGRAM", "INSTALL_DATA", "INSTALL_SCRIPT", "INSTALL_HEADER"}) do
        patched = patched:gsub("([^\n]*" .. var .. "%s*:?=%s*)%S*install%.exe %-c %-m%s+%d+", "%1cp -f")
        patched = patched:gsub("([^\n]*" .. var .. "%s*:?=%s*)%S*install%.exe %-c", "%1cp -f")
        patched = patched:gsub("%$%(" .. var .. "%)%s+%-m%s+%d+", "cp -f")
        patched = patched:gsub("%$%(" .. var .. "%)", "cp -f")
    end
    patched = patched:gsub("%S*install%.exe %-c %-m%s+%d+", "cp -f")
    patched = patched:gsub("%S*install%.exe %-c", "cp -f")
    patched = patched:gsub("cp %-f%s+%-m%s+%d+", "cp -f")
    patched = patched:gsub("cp %-f%s+%-d", "mkdir -p")
    if patched ~= content then
        print("patching " .. label .. ": avoid install.exe copies")
        base.writefile_bytes(file, patched)
    end
end

local function patch_makefiles_avoid_install(root, label)
    if not base.is_windows_host() then
        return
    end
    patch_install_macros_to_cp_file(path.join(root, "Makefile"), label .. "/Makefile")
    for _, generated in ipairs(os.files(path.join(root, "**", "Makefile"))) do
        patch_install_macros_to_cp_file(generated, label .. "/" .. path.relative(generated, root))
    end
end

-- GCC's own configure proves "not cross compiling" by running a freshly
-- compiled probe that WRITES a file (fopen conftest.out). Security software
-- that distrusts brand-new unsigned executables turns that into configure's
-- opaque "cannot run C compiled programs" -- observed 2026-08-01: Windows
-- Controlled Folder Access blocked conftest.exe inside the build tree
-- (Defender operational event 1123) minutes after a Defender platform
-- restart, on a machine where the very same probe passes once the platform
-- settles. Run the same compile+run+write probe up front so the failure is
-- immediate and the message actionable instead of autoconf archaeology.
function ensure_fresh_binary_can_run(build, build_envs)
    local cc = build_envs and build_envs.CC
    if not cc or cc == "" then
        return
    end
    os.mkdir(build)
    local marker_leaf = "toolchain-run-probe.out"
    local source = path.join(build, "toolchain-run-probe.c")
    local program = path.join(build, base.exe("toolchain-run-probe"))
    local marker = path.join(build, marker_leaf)
    os.tryrm(marker)
    io.writefile(source, table.concat({
        "#include <stdio.h>",
        "int main(void)",
        "{",
        "\tFILE *file = fopen(\"" .. marker_leaf .. "\", \"w\");",
        "\treturn file == NULL || fclose(file) != 0;",
        "}",
        ""
    }, "\n"))
    local compiled = errors.trycall(function ()
        os.runv(cc, {"-o", program, source}, {curdir = build, envs = build_envs})
    end)
    if not compiled or not os.isfile(program) then
        os.tryrm(source)
        errors.fail("the configure-stage C compiler %s cannot compile a trivial probe under %s; the bootstrap toolchain is broken or quarantined -- fix or reinstall it, then rerun the same xmake command", cc, build)
    end
    local ran = errors.trycall(function ()
        os.runv(program, {}, {curdir = build, envs = build_envs})
    end)
    local wrote = os.isfile(marker)
    os.tryrm(source)
    os.tryrm(program)
    os.tryrm(marker)
    if not ran or not wrote then
        errors.fail("a freshly compiled test program cannot run or write a file inside the build tree %s, so GCC configure is bound to fail with its opaque \"cannot run C compiled programs\". This is almost always security software distrusting brand-new unsigned executables: on Windows check the Defender operational log for event 1123 (Controlled Folder Access), move the project out of the protected-folder list or pause the interference, then rerun the same xmake command", build)
    end
end

local function configure_binutils(target_os)
    local src = layout.binutils_source_dir()
    local build = settings.binutils_build_dir(target_os)
    local prefix = settings.gcc_prefix(target_os)
    local triplet = settings.managed_target(target_os)
    local envs = settings.apply_build_envs(envs.shell_envs(path.join(prefix, "bin")), target_os)
    envs.MAKEINFO = "true"
    local relsrc = path.relative(src, build)
    local args = {
        "--prefix=" .. base.shpath(prefix),
        "--build=" .. settings.host_triplet(),
        "--host=" .. settings.host_triplet(),
        "--target=" .. triplet,
        "--disable-nls",
        "--disable-werror",
        "--disable-gdb",
        "--disable-gprofng",
        "--disable-sim",
        "--disable-readline",
        "--enable-ld=yes",
        "--enable-gold=no",
        "--enable-plugins=no"
    }
    local sysroot = gcctargets.target_sysroot(target_os)
    if sysroot and os.isdir(sysroot) then
        table.insert(args, "--with-sysroot=" .. base.shpath(sysroot))
    end
    local sigfile = path.join(build, ".xmake-configure")
    local signature = gccinstall.configure_signature(args, target_os, nil, gcctargets.signature_extra(target_os))
    local old_signature = os.isfile(sigfile) and base.trim(io.readfile(sigfile)) or ""
    if os.isfile(path.join(build, "Makefile")) and old_signature ~= base.trim(signature) then
        reset_build_dir(build)
    end
    os.mkdir(build)
    if os.isfile(path.join(build, "Makefile")) then
        print("using existing binutils build directory: " .. build)
    else
        ensure_fresh_binary_can_run(build, envs)
        gccsources.run_script(path.join(relsrc, "configure"), args, {curdir = build, envs = envs})
        io.writefile(sigfile, signature)
    end
    return build, envs
end

local function build_binutils_for(target_os)
    if not settings.is_cross_target(target_os) then
        return
    end
    local provider = gcctargets.provider_of(target_os)
    local prefix = settings.gcc_prefix(target_os)
    local triplet = settings.managed_target(target_os)
    local bindir = path.join(prefix, "bin")
    local target_as = path.join(bindir, base.exe(triplet .. "-as"))
    local target_ld = path.join(bindir, base.exe(triplet .. "-ld"))
    local identity_file = managed_toolchains_binutils_identity_file(target_os)
    local want_identity = managed_toolchains_binutils_identity()
    -- Short-circuit only when the installed as/ld were built from the CURRENT
    -- snapshot URL. Without the identity guard a binutils_snapshot_url bump (or
    -- a `rebuild`, which clears the identity file) would keep the old linker
    -- forever, since the freshly-reset build dir below is never reached.
    if base.file_nonempty(target_as) and base.file_nonempty(target_ld)
        and os.isfile(identity_file) and base.trim(io.readfile(identity_file)) == want_identity then
        if provider.stage_binutils then
            provider.stage_binutils(target_os)
        end
        return
    end
    download_binutils_snapshot(false)
    local build, envs = configure_binutils(target_os)
    patch_makefiles_avoid_install(build, "binutils")
    local make = hosttools.preferred_host_tool(settings.value_or("toolchains_make", "make"))
    for _, target in ipairs({"all-binutils", "all-gas", "all-ld"}) do
        makerunner.run_make_target(make, build, envs, target)
    end
    patch_makefiles_avoid_install(build, "binutils")
    for _, target in ipairs({"install-binutils", "install-gas", "install-ld"}) do
        makerunner.run_make_target(make, build, envs, target)
    end
    io.writefile(identity_file, want_identity)
    if provider.stage_binutils then
        provider.stage_binutils(target_os)
    end
end

local function configure_gcc(target_os)
    local src = settings.gcc_source_dir(target_os)
    local build = settings.gcc_build_dir(target_os)
    local prefix = settings.gcc_prefix(target_os)
    local triplet = settings.managed_target(target_os)
    local provider = gcctargets.provider_of(target_os)
    os.mkdir(prefix)
    if provider.prepare_sysroot then
        provider.prepare_sysroot(target_os)
    end
    -- deliberately macosx-gated (not a generic stage_tools dispatch): the
    -- other providers stage their tools once in build_gcc_for, and staging
    -- them a second time here would be a new side effect.
    gcctargets.stage_macosx_target_tools(target_os)
    local envs = settings.apply_build_envs(envs.shell_envs(path.join(prefix, "bin")), target_os)
    if provider.apply_envs then
        envs = provider.apply_envs(target_os, envs)
    end
    envs.MAKEINFO = "true"
    local relsrc = path.relative(src, build)
    local args = {
        "--prefix=" .. base.shpath(prefix),
        "--build=" .. settings.host_triplet(),
        "--host=" .. settings.host_triplet(),
        "--target=" .. triplet,
        "--enable-languages=c,c++",
        "--disable-bootstrap",
        "--disable-multilib",
        "--disable-nls",
        "--disable-libsanitizer",
        "--disable-libgomp",
        "--disable-libquadmath",
        "--disable-libssp",
        "--disable-libvtv",
        "--disable-libatomic",
        "--disable-lto",
        "--disable-plugin",
        "--disable-libstdcxx-pch"
    }
    if provider.configure_args then
        args = provider.configure_args(target_os, args)
    elseif target_os == base.host_os() then
        table.insert(args, "--enable-shared")
        table.insert(args, "--enable-threads=posix")
    else
        table.insert(args, "--without-headers")
        table.insert(args, "--disable-shared")
        table.insert(args, "--disable-threads")
    end
    local sigfile = path.join(build, ".xmake-configure")
    local makefile = path.join(build, "Makefile")
    local signature = gccinstall.configure_signature(args, target_os, src, gcctargets.signature_extra(target_os))
    local old_signature = os.isfile(sigfile) and base.trim(io.readfile(sigfile)) or ""
    if os.isfile(makefile) and not managed_toolchains_gcc_configure_makefile_complete(makefile) then
        reset_build_dir(build)
    elseif os.isfile(makefile) and old_signature ~= base.trim(signature) then
        reset_build_dir(build)
    end
    os.mkdir(build)
    if os.isfile(makefile) then
        print("using existing GCC build directory: " .. build)
    else
        ensure_fresh_binary_can_run(build, envs)
        gccsources.run_script(path.join(relsrc, "configure"), args, {curdir = build, envs = envs})
        io.writefile(sigfile, signature)
    end
    return build, envs
end

local function patch_gcc_makefile_for_windows(build, target_os)
    target_os = target_os or settings.configured_target_os()
    if not base.is_windows_host() and target_os ~= "android" then
        return
    end
    local target_triplet = settings.managed_target(target_os)
    local makefile = path.join(build, "Makefile")
    if not os.isfile(makefile) then
        return
    end
    -- the Android target-side patches are woven through this host pass (per
    -- generated makefile and per scanned makefile line), so they arrive as a
    -- per-invocation helper context from the android provider instead of a
    -- single patch_build_tree call; only the android provider defines the
    -- makefile_patch_context hook.
    local provider = gcctargets.provider_of(target_os)
    local android_patches = provider.makefile_patch_context and provider.makefile_patch_context(target_os, build) or nil

    local function patch_assignment(file, label, key, value)
        if not os.isfile(file) then
            return
        end
        value = base.trim(value or "")
        if value == "" then
            return
        end
        local content = io.readfile(file)
        local pattern = "\n(" .. key .. "%s*=)[^\n]*"
        local patched, count = content:gsub(pattern, "\n%1 " .. value, 1)
        if count > 0 and patched ~= content then
            print("patching GCC " .. label .. ": " .. key .. "=" .. value)
            base.writefile_bytes(file, patched)
        end
    end

    local function patch_host_build_flags(file, label)
        patch_assignment(file, label, "CFLAGS", settings.build_cflags())
        patch_assignment(file, label, "CXXFLAGS", settings.build_cxxflags())
    end

    local function patch_install_macros_to_cp(file, label)
        if not os.isfile(file) then
            return
        end
        local content = io.readfile(file)
        local patched = content
        patched = patched:gsub("%$%(INSTALL%)%s+%-d", "mkdir -p")
        patched = patched:gsub("%S*install%.exe %-c %-d", "mkdir -p")
        for _, var in ipairs({"INSTALL", "INSTALL_PROGRAM", "INSTALL_DATA", "INSTALL_SCRIPT", "INSTALL_HEADER"}) do
            patched = patched:gsub("([^\n]*" .. var .. "%s*:?=%s*)%S*install%.exe %-c %-m%s+%d+", "%1cp -f")
            patched = patched:gsub("([^\n]*" .. var .. "%s*:?=%s*)%S*install%.exe %-c", "%1cp -f")
            patched = patched:gsub("%$%(" .. var .. "%)%s+%-m%s+%d+", "cp -f")
            patched = patched:gsub("%$%(" .. var .. "%)", "cp -f")
        end
        patched = patched:gsub("%S*install%.exe %-c %-m%s+%d+", "cp -f")
        patched = patched:gsub("%S*install%.exe %-c", "cp -f")
        patched = patched:gsub("cp %-f%s+%-m%s+%d+", "cp -f")
        patched = patched:gsub("cp %-f%s+%-d", "mkdir -p")
        if patched ~= content then
            print("patching GCC " .. label .. ": avoid install.exe copies")
            base.writefile_bytes(file, patched)
        end
    end

    local function target_bin_tool(name)
        for _, candidate in ipairs({
            path.join(settings.gcc_prefix(target_os), "bin", base.exe(target_triplet .. "-" .. name)),
            path.join(settings.gcc_prefix(target_os), "bin", base.exe(name)),
            path.join(settings.gcc_sysroot(target_os), "bin", base.exe(target_triplet .. "-" .. name)),
            path.join(settings.gcc_sysroot(target_os), "bin", base.exe(name))
        }) do
            if os.isfile(candidate) then
                if name == "readelf" and hostboot.managed_toolchains_is_w64devkit_alias(candidate) then
                    goto continue
                end
                return base.shell_path_entry(candidate)
            end
            ::continue::
        end
        -- windows readelf special case intentionally kept inline: it is
        -- interwoven with the host tool_vars assembly below (Phase R1).
        if name == "readelf" and target_os == "windows" then
            return ""
        end
        return hosttools.shell_host_tool_any({target_triplet .. "-" .. name, name})
    end

    local function build_bin_tool(name)
        if target_os == "windows" then
            return target_bin_tool(name)
        end
        return hosttools.shell_host_tool_any({settings.host_triplet() .. "-" .. name, name})
    end

    local tool_vars = {
        AR = build_bin_tool("ar"),
        AS = build_bin_tool("as"),
        DLLTOOL = build_bin_tool("dlltool"),
        FLEX = hosttools.shell_host_tool_any({"flex", "win_flex"}),
        LD = build_bin_tool("ld"),
        LEX = hosttools.shell_host_tool_any({"flex", "win_flex"}),
        NM = build_bin_tool("nm"),
        OBJCOPY = build_bin_tool("objcopy"),
        OBJDUMP = build_bin_tool("objdump"),
        RANLIB = build_bin_tool("ranlib"),
        READELF = build_bin_tool("readelf"),
        STRIP = build_bin_tool("strip"),
        BISON = hosttools.shell_host_tool_any({"bison", "win_bison"}),
        YACC = hosttools.shell_host_tool_any({"bison", "win_bison"}) .. " -y",
        WINDRES = build_bin_tool("windres"),
        AR_FOR_TARGET = target_bin_tool("ar"),
        AS_FOR_TARGET = target_bin_tool("as"),
        DLLTOOL_FOR_TARGET = target_bin_tool("dlltool"),
        LD_FOR_TARGET = target_bin_tool("ld"),
        NM_FOR_TARGET = target_bin_tool("nm"),
        OBJCOPY_FOR_TARGET = target_bin_tool("objcopy"),
        OBJDUMP_FOR_TARGET = target_bin_tool("objdump"),
        RANLIB_FOR_TARGET = target_bin_tool("ranlib"),
        READELF_FOR_TARGET = target_bin_tool("readelf"),
        STRIP_FOR_TARGET = target_bin_tool("strip"),
        WINDRES_FOR_TARGET = target_bin_tool("windres")
    }

    local function patch_assignment_vars(file, label)
        if not os.isfile(file) then
            return
        end
        local lines = io.readfile(file):split("\n", {plain = true})
        local output = {}
        local patched = false
        for _, line in ipairs(lines) do
            local var = line:match("^([A-Z_]+)%s*=")
            if var and tool_vars[var] then
                table.insert(output, var .. " = " .. tool_vars[var])
                patched = true
            else
                table.insert(output, line)
            end
        end
        if patched then
            print("patching GCC " .. label .. ": use project-local target tools")
            base.writefile_bytes(file, table.concat(output, "\n"))
        end
    end

    local function patch_libtool_tools(file, label)
        if not os.isfile(file) then
            return
        end
        local content = io.readfile(file)
        local patched = content
        local tool_names = {
            ar = "AR",
            ranlib = "RANLIB",
            nm = "NM",
            strip = "STRIP",
            ld = "LD",
            dlltool = "DLLTOOL"
        }
        for name, var in pairs(tool_names) do
            local tool = target_bin_tool(name)
            patched = patched:gsub(base.escape_pattern(hosttools.shell_host_tool_any({target_triplet .. "-" .. name, name})), tool)
            patched = patched:gsub(var .. '="[^"\n]*' .. base.escape_pattern(target_triplet) .. '%-' .. name .. '%.exe%s*"', var .. '="' .. tool .. '"')
        end
        patched = patched:gsub('old_striplib="[^"\n]*' .. base.escape_pattern(target_triplet) .. '%-strip%.exe%s*%-%-strip%-debug"', 'old_striplib="' .. tool_vars.STRIP .. ' --strip-debug"')
        patched = patched:gsub('striplib="[^"\n]*' .. base.escape_pattern(target_triplet) .. '%-strip%.exe%s*%-%-strip%-unneeded"', 'striplib="' .. tool_vars.STRIP .. ' --strip-unneeded"')
        patched = patched:gsub("%S*install%.exe %-c %-m 644", "cp -f")
        patched = patched:gsub("%S*install%.exe %-c", "cp -f")
        if patched ~= content then
            print("patching GCC " .. label .. ": use project-local libtool helpers")
            base.writefile_bytes(file, patched)
        end
    end

    local function patch_libstdcxx_libbacktrace_symlink_rules(file, label)
        local rule_label = "libstdc++-v3/src/libbacktrace/Makefile"
        local normalized_label = tostring(label or ""):gsub("\\", "/")
        if normalized_label:sub(-#rule_label) ~= rule_label or not os.isfile(file) then
            return
        end
        local content = io.readfile(file)
        local patched = base.replace_plain(content,
            "%.c: ../../../libbacktrace/%.c\n" ..
            "\t$(LN_S) $< $@\n",
            "%.c: ../../../libbacktrace/%.c\n" ..
            "\trm -f $@\n" ..
            "\t$(LN_S) $< $@\n")
        patched = base.replace_plain(patched,
            "cp-demangle.c: ../../../libiberty/cp-demangle.c\n" ..
            "\t$(LN_S) $< $@\n",
            "cp-demangle.c: ../../../libiberty/cp-demangle.c\n" ..
            "\trm -f $@\n" ..
            "\t$(LN_S) $< $@\n")
        if patched ~= content then
            print("patching GCC " .. label .. ": make source symlink rules idempotent")
            base.writefile_bytes(file, patched)
        end
    end

    local function patch_generated_makefile(file, label)
        patch_assignment_vars(file, label)
        patch_install_macros_to_cp(file, label)
        if android_patches then
            android_patches.patch_target_flags(file, label)
        end
        patch_libstdcxx_libbacktrace_symlink_rules(file, label)
    end

    local function ensure_fixincl_wrapper(dir, label)
        local exe_path = path.join(dir, base.exe("fixincl"))
        local wrapper = path.join(dir, "fixincl")
        -- emscripten guard intentionally kept inline: it predicts what this
        -- host pass is about to build in this very directory (Phase R1).
        local emscripten_fixincl_will_be_built = target_os == "emscripten"
            and base.is_windows_host() and os.isfile(path.join(dir, "Makefile"))
        if (os.isfile(exe_path) or emscripten_fixincl_will_be_built)
            and not os.isfile(wrapper) then
            print("patching GCC " .. label .. ": add POSIX fixincl wrapper")
            base.writefile_bytes(wrapper, "#!/bin/sh\nexec \"$(dirname \"$0\")/fixincl.exe\" \"$@\"\n")
            os.vrunv(hosttools.preferred_host_tool("chmod"), {"+x", wrapper}, {try = true})
        end
    end

    local function patch_libgcc_build_tree_install(file, label)
        if not os.isfile(file) then
            return
        end
        local content = io.readfile(file)
        local patched = content:gsub(
            "install%-leaf DESTDIR=%$%(gcc_objdir%)%s*\\%s*\n%s+slibdir= libsubdir= MULTIOSDIR=%$%(MULTIDIR%)",
            "install-leaf DESTDIR=$(gcc_objdir) \\\n\t  slibdir= libsubdir= SHLIB_DLLDIR=/ MULTIOSDIR=$(MULTIDIR)")
        if patched ~= content then
            print("patching GCC " .. label .. ": keep libgcc DLL copy inside build tree")
            base.writefile_bytes(file, patched)
        end
    end

    local function ensure_libtool_install_archive(la, lai, label)
        if os.isfile(la) and not os.isfile(lai) then
            print("repairing GCC " .. label .. ": restore missing libtool install archive")
            os.cp(la, lai)
        end
    end

    -- the Android CRT/specs adjustments are host-independent: they patch the
    -- TARGET build tree (bionic startfiles, linker64, generated makefiles);
    -- gating them to non-Windows hosts left Windows-hosted Android builds
    -- linking against glibc-style crt1.o/crti.o and failing libstdc++'s
    -- configure link probes (GCC_NO_EXECUTABLES)
    if android_patches then
        android_patches.patch_generated_makefiles()
        android_patches.patch_gcc_specs()
        android_patches.clean_failed_libstdcxx_configure()
    end
    if not base.is_windows_host() then
        return
    end

    patch_install_macros_to_cp(makefile, "top-level Makefile")
    local content = io.readfile(makefile)
    local no_op_host_targets = {
        ["configure-gettext"] = true,
        ["all-gettext"] = true
    }
    local short_host_components = {
        "gettext",
        "libbacktrace",
        "libcpp",
        "libcody",
        "libdecnumber",
        "libiberty",
        "gmp",
        "mpfr",
        "mpc",
        "isl",
        "fixincludes",
        "zlib",
        "c++tools",
        "gcc"
    }
    local short_build_components = {
        "libiberty",
        "fixincludes",
        "libcpp"
    }
    local short_host_component_map = {}
    for _, component in ipairs(short_host_components) do
        short_host_component_map[component] = true
    end
    local short_build_component_map = {}
    for _, component in ipairs(short_build_components) do
        short_build_component_map[component] = true
    end

    local lines = content:split("\n", {plain = true})
    local output = {}
    local patched = false
    local index = 1
    while index <= #lines do
        local line = lines[index]
        local var = line:match("^([A-Z_]+)%s*=")
        local android_line = android_patches and android_patches.rewrite_toplevel_sysroot_cflags(line) or nil
        if android_line then
            table.insert(output, android_line)
            patched = true
            index = index + 1
        elseif var and tool_vars[var] then
            table.insert(output, var .. " = " .. tool_vars[var])
            patched = true
            index = index + 1
        else
            local target = line:match("^([%w%+%-_]+):")
            if target and no_op_host_targets[target] then
                table.insert(output, line)
                table.insert(output, "\t@:")
                patched = true
                index = index + 1
                while index <= #lines and lines[index]:sub(1, 1) == "\t" do
                    index = index + 1
                end
            else
                local component, configured_component = line:match("^all%-([^:]+):%s+configure%-([^%s]+)$")
                if component and component == configured_component and short_host_component_map[component] then
                    table.insert(output, line)
                    table.insert(output, "\t@$(MAKE) -C $(HOST_SUBDIR)/" .. component .. " all")
                    patched = true
                    index = index + 1
                    while index <= #lines and lines[index]:sub(1, 1) == "\t" do
                        index = index + 1
                    end
                else
                    component, configured_component = line:match("^all%-build%-([^:]+):%s+configure%-build%-([^%s]+)$")
                    if component and component == configured_component and short_build_component_map[component] then
                        table.insert(output, line)
                        table.insert(output, "\t@$(MAKE) -C $(BUILD_SUBDIR)/" .. component .. " all")
                        patched = true
                        index = index + 1
                        while index <= #lines and lines[index]:sub(1, 1) == "\t" do
                            index = index + 1
                        end
                    else
                        table.insert(output, line)
                        index = index + 1
                    end
                end
            end
        end
    end

    if patched then
        print("patching GCC top-level Makefile: avoid Windows shell command-line limits")
        io.writefile(makefile, table.concat(output, "\n"))
    end

    local gcc_makefile = path.join(build, "gcc", "Makefile")
    if os.isfile(gcc_makefile) then
        content = io.readfile(gcc_makefile)
        lines = content:split("\n", {plain = true})
        output = {}
        patched = false
        if content:find("$%(WINDRES%)", 1, false) and not content:find("\nWINDRES%s*=") then
            table.insert(output, "WINDRES = " .. tool_vars.WINDRES)
            patched = true
        end
        index = 1
        while index <= #lines do
            local line = lines[index]
            local var = line:match("^([A-Z_]+)%s*=")
            local android_line = android_patches and android_patches.rewrite_gcc_stmp_fixinc(line) or nil
            if android_line then
                table.insert(output, android_line)
                patched = true
                index = index + 1
            elseif var and tool_vars[var] then
                table.insert(output, var .. " = " .. tool_vars[var])
                patched = true
                index = index + 1
            elseif line:match("^s%-tm%-texi:%s+build/genhooks%$%(build_exeext%)") then
                table.insert(output, line)
                table.insert(output, "\t$(RUN_GEN) build/genhooks$(build_exeext) -d \\")
                table.insert(output, "\t\t\t$(srcdir)/doc/tm.texi.in > tmp-tm.texi")
                table.insert(output, "\tcase `echo X|tr X '\\101'` in \\")
                table.insert(output, "\t  A) tr -d '\\015' < tmp-tm.texi > tmp2-tm.texi ;; \\")
                table.insert(output, "\t  *) tr -d '\\r' < tmp-tm.texi > tmp2-tm.texi ;; \\")
                table.insert(output, "\tesac")
                table.insert(output, "\tmv tmp2-tm.texi tmp-tm.texi")
                table.insert(output, "\t$(SHELL) $(srcdir)/../move-if-change tmp-tm.texi tm.texi")
                table.insert(output, "\tcp tm.texi $(srcdir)/doc/tm.texi")
                table.insert(output, "\t$(STAMP) $@")
                patched = true
                index = index + 1
                while index <= #lines and lines[index]:sub(1, 1) == "\t" do
                    index = index + 1
                end
            elseif line == "libbackend.a: $(OBJS)" then
                table.insert(output, line)
                table.insert(output, "\t-rm -rf libbackend.a")
                table.insert(output, "\t@: $(file >libbackend.objects,$(OBJS))")
                table.insert(output, "ifeq ($(USE_THIN_ARCHIVES),yes)")
                table.insert(output, "\t$(AR) $(AR_FLAGS)T libbackend.a @libbackend.objects")
                table.insert(output, "else")
                table.insert(output, "\t$(AR) $(AR_FLAGS) libbackend.a @libbackend.objects")
                table.insert(output, "\t-$(RANLIB) $(RANLIB_FLAGS) libbackend.a")
                table.insert(output, "endif")
                patched = true
                index = index + 1
                while index <= #lines and not lines[index]:match("^libcommon%-target%.a:") do
                    index = index + 1
                end
            else
                table.insert(output, line)
                index = index + 1
            end
        end
        if patched then
            print("patching GCC gcc/Makefile: use project-local generator tools and local generated docs")
            io.writefile(gcc_makefile, table.concat(output, "\n"))
        end
    end

    local cxx_tools_makefile = path.join(build, "c++tools", "Makefile")
    if os.isfile(cxx_tools_makefile) then
        content = io.readfile(cxx_tools_makefile)
        local patched_content = content
        patched_content = patched_content:gsub("%$%(INSTALL%) %$< %$@", "cp -f $< $@")
        patched_content = patched_content:gsub("%$%(INSTALL_PROGRAM%) g%+%+%-mapper%-server%$%(exeext%) %$%(DESTDIR%)%$%(libexecsubdir%)",
            "cp -f g++-mapper-server$(exeext) $(DESTDIR)$(libexecsubdir)")
        if patched_content ~= content then
            print("patching GCC c++tools/Makefile: avoid install.exe for g++ mapper copies")
            io.writefile(cxx_tools_makefile, patched_content)
        end
    end

    for _, generated in ipairs(os.files(path.join(build, "**", "Makefile"))) do
        patch_install_macros_to_cp(generated, path.relative(generated, build))
    end
    patch_host_build_flags(path.join(build, "gcc", "Makefile"), "gcc/Makefile")
    ensure_fixincl_wrapper(path.join(build, "build-" .. settings.host_triplet(), "fixincludes"), "build fixincludes")
    ensure_fixincl_wrapper(path.join(build, "fixincludes"), "target fixincludes")

    patch_install_macros_to_cp(path.join(settings.gcc_source_dir(target_os), "libgcc", "Makefile.in"), "libgcc/Makefile.in")
    -- windows libgcc build-tree install patches intentionally kept inline:
    -- they share this pass's source/build makefile walk (Phase R1).
    if target_os == "windows" then
        patch_install_macros_to_cp(path.join(settings.gcc_source_dir(target_os), "libgcc", "config", "i386", "t-slibgcc-cygming"), "libgcc/config/i386/t-slibgcc-cygming")
        patch_libgcc_build_tree_install(path.join(settings.gcc_source_dir(target_os), "libgcc", "Makefile.in"), "libgcc/Makefile.in")
    end
    patch_generated_makefile(path.join(build, target_triplet, "libgcc", "Makefile"), "libgcc/Makefile")
    if target_os == "windows" then
        patch_libgcc_build_tree_install(path.join(build, target_triplet, "libgcc", "Makefile"), "libgcc/Makefile")
    end

    local libstdcxx = path.join(build, target_triplet, "libstdc++-v3")
    if os.isdir(libstdcxx) then
        patch_generated_makefile(path.join(libstdcxx, "Makefile"), "libstdc++-v3/Makefile")
        for _, generated in ipairs(os.files(path.join(libstdcxx, "**", "Makefile"))) do
            patch_generated_makefile(generated, "libstdc++-v3/" .. path.relative(generated, libstdcxx))
        end
        patch_libtool_tools(path.join(libstdcxx, "libtool"), "libstdc++-v3/libtool")
        ensure_libtool_install_archive(
            path.join(libstdcxx, "src", "libstdc++.la"),
            path.join(libstdcxx, "src", ".libs", "libstdc++.lai"),
            "libstdc++-v3/src/.libs/libstdc++.lai")
    end
end

-- The per-prefix cross-process install lock file (beside the install stamp).
-- Exposed so the auto-bootstrap wait-gate in cpp/xmake.lua locks the SAME file
-- build_gcc_for does, and thus genuinely waits out a concurrent install instead
-- of racing it on a different lock name.
function install_lock_file(target_os)
    return path.join(path.directory(settings.stamp_file(target_os)), "install.lock")
end

function build_gcc_for(target_os, opt)
    opt = opt or {}
    target_os = layout.ensure_toolchain_platform(target_os)
    settings.validate_config(target_os)
    -- Cross-process install lock (per prefix): serialize concurrent builds of
    -- the same toolchain prefix across independent xmake processes so two runs
    -- never interleave configure/make/install into one prefix. Every path that
    -- builds a toolchain funnels through here (the explicit `xmake toolchains
    -- build/rebuild/install` commands AND the plain-build auto-bootstrap), so
    -- one lock on the funnel serializes them all. Keyed beside the install
    -- stamp (per host/target/arch), so distinct prefixes never contend.
    local lockfile = install_lock_file(target_os)
    return install_lock.guard(lockfile, function ()
    -- Another process may have finished the install while we waited for the
    -- lock; ensure-callers (install / auto-bootstrap) pass skip_if_installed
    -- and re-check under the lock to skip a redundant rebuild, while force
    -- callers (build / rebuild / update) always proceed.
    if opt.skip_if_installed and toolchain_installed(target_os) then
        return settings.gcc_prefix(target_os)
    end
    errors.log("preparing project-local GCC for " .. base.host_os() .. "/" .. target_os .. "/" .. settings.target_arch_folder(target_os))
    hostboot.ensure_windows_host_bootstrap_toolchain(target_os)
    gcctargets.managed_toolchains_preflight_target(target_os)
    return run.run_stage("build project-local GCC", target_os, function ()
    if not settings.macosx_target_supported(target_os) then
        errors.fail("the selected GCC source profile does not support target %s", settings.managed_target(target_os))
    end
    local provider = gcctargets.provider_of(target_os)
    errors.log("syncing GCC source")
    gccsources.sync_gcc_source(target_os, true, false)
    errors.log("preparing target runtime inputs")
    if provider.prepare_runtime_inputs then
        provider.prepare_runtime_inputs(target_os)
    end
    if provider.prepare_backend_tools then
        provider.prepare_backend_tools(target_os)
    elseif managed_toolchains_builds_binutils(target_os) then
        errors.log("building binutils for " .. target_os)
        build_binutils_for(target_os)
    end
    errors.log("staging target tools and linkers")
    if provider.stage_tools then
        provider.stage_tools(target_os)
    end
    errors.log("configuring GCC")
    local build = configure_gcc(target_os)
    local source_dir = settings.gcc_source_dir(target_os)
    local mounted_windows_drive_source = gccsources.managed_toolchains_is_mounted_windows_drive_path(source_dir)
    gccsources.patch_gcc_libcody_revision_makefile(path.join(build, "libcody", "Makefile"), mounted_windows_drive_source)
    gccsources.sync_gcc_generated_sources_to_build(source_dir, build)
    patch_gcc_makefile_for_windows(build, target_os)
    local envs = settings.apply_build_envs(envs.make_envs(path.join(settings.gcc_prefix(target_os), "bin")), target_os)
    if provider.apply_envs then
        envs = provider.apply_envs(target_os, envs)
    end
    envs.MAKEINFO = "true"
    local make = hosttools.preferred_host_tool(settings.value_or("toolchains_make", "make"))
    errors.log("configuring GCC make targets")
    makerunner.run_make_target(make, build, envs, "configure-gcc")
    gccsources.patch_gcc_libcody_revision_makefile(path.join(build, "libcody", "Makefile"), mounted_windows_drive_source)
    gccsources.sync_gcc_generated_sources_to_build(source_dir, build)
    patch_gcc_makefile_for_windows(build, target_os)
    -- provider build plans are step lists: each step optionally logs, runs a
    -- `before` closure, drives its make targets (patching after each one when
    -- `patch` is set: `true` selects the host makefile pass, a function is a
    -- provider-owned patcher), then runs an `after` closure. An empty-string
    -- make target drives the default `make all`.
    local plan_context = {
        build = build,
        patch = function ()
            patch_gcc_makefile_for_windows(build, target_os)
        end
    }
    for _, step in ipairs(provider.build_plan(target_os, plan_context)) do
        if step.log then
            errors.log(step.log)
        end
        if step.before then
            step.before()
        end
        for _, make_target in ipairs(step.targets or {}) do
            makerunner.run_make_target(make, build, envs, make_target)
            if step.patch == true then
                plan_context.patch()
            elseif step.patch then
                step.patch()
            end
        end
        if step.after then
            step.after()
        end
    end
    if provider.smoke then
        provider.smoke(target_os)
    end
    errors.log("finalizing installed GCC toolchain")
    if provider.finalize then
        provider.finalize(target_os)
    end
    strip_installed_toolchain(target_os)
    install_stamp(target_os)
    cleanup_windows_bootstrap_toolchain_after_success(target_os)
    end)
    end)
end
