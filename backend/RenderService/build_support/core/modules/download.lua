-- Network downloads with a multi-tool fallback chain and retries, archive
-- extraction, and the download+verify+extract composite with stale-cache
-- recovery.

import("base")
import("errors")
import("layout")
import("hosttools")
import("envs")
import("run")
import("settings")
import("checksums")

local network_attempts = 3

local function ps_quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function download_proxy_for_url(url)
    local https = tostring(url):lower():find("^https:") ~= nil
    local keys
    if https then
        keys = {"HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"}
    else
        keys = {"HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"}
    end
    for _, key in ipairs(keys) do
        local value = os.getenv(key)
        if value and value ~= "" then
            return value
        end
    end
    -- No explicit variable: follow the detected OS proxy configuration, same
    -- fallback the child-process environments use (envs.proxy_envs).
    local detected = envs.system_proxy()
    if detected then
        return https and detected.https or detected.http
    end
end

function download_file(url, outputfile, force)
    if os.isfile(outputfile) and not force then
        return
    end
    os.mkdir(path.directory(outputfile))
    -- Per-process staging path (never a shared "<out>.part"): two concurrent
    -- downloads of the same URL must not interleave their bytes into one file,
    -- and one process must not delete another's in-flight download. Mirrors the
    -- unique path the extraction stage already uses (layout.unique_cache_path).
    local tmpfile = layout.unique_cache_path(outputfile, "download-part")
    os.mkdir(path.directory(tmpfile))
    if force and os.exists(outputfile) then
        layout.remove_toolchains_path(outputfile)
    end

    local function finish_download(file)
        if not os.isfile(file) then
            return false
        end
        if os.filesize and os.filesize(file) == 0 then
            return false
        end
        if os.exists(outputfile) then
            layout.remove_toolchains_path(outputfile)
        end
        os.mv(file, outputfile)
        return os.isfile(outputfile)
    end

    local function discard_tmpfile()
        if os.exists(tmpfile) then
            layout.remove_toolchains_path(tmpfile)
        end
    end

    local function try_download_once()
        local curl = hosttools.find_tool_path("curl")
        if curl then
            local argv = {"-L", "--fail", "--retry", "5", "--retry-delay", "2", "--connect-timeout", "30"}
            if base.is_windows_host() then
                table.insert(argv, "--ssl-no-revoke")
            end
            local proxy = download_proxy_for_url(url)
            if proxy and proxy ~= "" then
                table.insert(argv, "--proxy")
                table.insert(argv, proxy)
            end
            table.insert(argv, "-o")
            table.insert(argv, tmpfile)
            table.insert(argv, url)
            local ok = errors.trycall(function ()
                os.vrunv(curl, argv, {envs = envs.proxy_envs()})
                return true
            end)
            if ok and finish_download(tmpfile) then
                return true
            end
            discard_tmpfile()
        end

        local wget = hosttools.find_tool_path("wget")
        if wget then
            local argv = {"-O", tmpfile}
            if hosttools.wget_is_gnu(wget) then
                table.insert(argv, "--tries=3")
                table.insert(argv, "--timeout=60")
            end
            local proxy = download_proxy_for_url(url)
            if proxy and proxy ~= "" then
                table.insert(argv, "-e")
                table.insert(argv, "use_proxy=yes")
                if tostring(url):lower():find("^https:") then
                    table.insert(argv, "-e")
                    table.insert(argv, "https_proxy=" .. proxy)
                else
                    table.insert(argv, "-e")
                    table.insert(argv, "http_proxy=" .. proxy)
                end
            end
            table.insert(argv, url)
            local ok = errors.trycall(function ()
                os.vrunv(wget, argv, {envs = envs.proxy_envs()})
                return true
            end)
            if ok and finish_download(tmpfile) then
                return true
            end
            discard_tmpfile()
        end

        if base.is_windows_host() then
            local ps = hosttools.find_tool_path("pwsh") or hosttools.find_tool_path("powershell")
            if ps then
                local script = table.concat({
                    "$ErrorActionPreference='Stop'",
                    "$ProgressPreference='SilentlyContinue'",
                    "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12",
                    "$u=" .. ps_quote(url),
                    "$o=" .. ps_quote(tmpfile),
                    "$p=$env:HTTPS_PROXY",
                    "if(-not $p){$p=$env:HTTP_PROXY}",
                    "if(-not $p){$p=$env:ALL_PROXY}",
                    "$a=@{Uri=$u;OutFile=$o;UseBasicParsing=$true;TimeoutSec=900}",
                    "if($p){$a.Proxy=$p}",
                    "Invoke-WebRequest @a"
                }, "; ")
                local ok = errors.trycall(function ()
                    os.vrunv(ps, {"-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script}, {envs = envs.proxy_envs()})
                    return true
                end)
                if ok and finish_download(tmpfile) then
                    return true
                end
                discard_tmpfile()
            end
        end

        local ok, downloaded = errors.trycall(function ()
            local http_download = import("net.http.download")
            -- certificate verification stays ON for this last-resort path too;
            -- integrity is then re-confirmed by the digest check downstream, so
            -- no download path is allowed to accept unverified bytes
            http_download.main(url, tmpfile, {continue = false, timeout = 60})
            return true
        end)
        if ok and downloaded and finish_download(tmpfile) then
            return true
        end
        discard_tmpfile()
        return false
    end

    print("downloading " .. url)
    for attempt = 1, network_attempts do
        if try_download_once() then
            return
        end
        if attempt < network_attempts then
            errors.warn("download failed (attempt %d/%d); retrying after a short delay: %s", attempt, network_attempts, url)
            errors.sleep(3 * attempt)
        end
    end
    errors.fail("failed to download %s after %d attempts; certificate verification is enforced, so if a TLS-inspecting proxy is in the way, trust its root CA in the system store, or place the file at %s by hand (it is still digest-checked)", url, network_attempts, outputfile)
end

function extract_archive(archivefile, outputdir)
    os.mkdir(outputdir)
    if base.is_windows_host() and tostring(archivefile):lower():find("%.exe$") then
        -- A self-extracting archive is still a plain archive to libarchive:
        -- Windows' bundled bsdtar (System32\tar.exe, 7z-capable) extracts
        -- the payload synchronously, sidestepping the stub entirely. That
        -- matters because some SFX stubs (w64devkit's among them) hand the
        -- work to a detached child and exit before extraction completes, so
        -- running them races every downstream consumer of the tree. (The
        -- generic PATH tar further below may be GNU tar, which cannot read
        -- 7z payloads; only the System32 bsdtar is trusted here.)
        local systemroot = os.getenv("SystemRoot")
        local bsdtar = systemroot and path.join(systemroot, "System32", "tar.exe")
        if bsdtar and os.isfile(bsdtar) then
            local ok = errors.trycall(function ()
                os.vrunv(bsdtar, {"-xf", archivefile, "-C", outputdir})
                return true
            end)
            if ok then
                return
            end
        end
        for _, argv in ipairs({
            {"-y", "-o" .. outputdir},
            {"-o" .. outputdir, "-y"}
        }) do
            local ok = errors.trycall(function ()
                os.vrunv(archivefile, argv)
                return true
            end)
            if ok then
                -- Some self-extractor stubs (w64devkit's among them) hand the
                -- work to a detached child and exit before extraction is
                -- complete, so a successful return here says nothing about
                -- the tree being whole -- the commit-move below would race
                -- the still-running writer and validation would probe a
                -- half-written toolchain (observed as an empty/partial tree
                -- that "completes itself" seconds later). Wait for
                -- quiescence: the recursive entry count must be nonzero and
                -- hold still across consecutive one-second samples.
                -- errors.sleep forwards to os.sleep, which takes
                -- MILLISECONDS: sample every 500ms and demand two seconds
                -- of complete stillness (4 consecutive equal samples).
                local last = -1
                local stable = 0
                for _ = 1, 600 do
                    local entries = #os.files(path.join(outputdir, "**"))
                    if entries > 0 and entries == last then
                        stable = stable + 1
                        if stable >= 4 then
                            break
                        end
                    else
                        stable = 0
                    end
                    last = entries
                    errors.sleep(500)
                end
                return
            end
        end
    end
    if base.is_windows_host() and tostring(archivefile):lower():find("%.zip$") then
        local ps = hosttools.find_tool_path("pwsh") or hosttools.find_tool_path("powershell")
        if ps then
            local script = table.concat({
                "$ErrorActionPreference='Stop'",
                "$a=" .. ps_quote(archivefile),
                "$o=" .. ps_quote(outputdir),
                "Expand-Archive -LiteralPath $a -DestinationPath $o -Force"
            }, "; ")
            local ok = errors.trycall(function ()
                os.vrunv(ps, {"-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script})
                return true
            end)
            if ok then
                return
            end
        end
    end
    local tar = hosttools.find_tool_path("tar")
    if tar then
        local archive_arg = base.is_windows_host() and base.shpath(archivefile) or archivefile
        local output_arg = base.is_windows_host() and base.shpath(outputdir) or outputdir
        local attempts = {}
        if base.is_windows_host() and hosttools.tar_supports_force_local(tar) then
            table.insert(attempts, {"--force-local", "-xf", archive_arg, "-C", output_arg})
        end
        table.insert(attempts, {"-xf", archive_arg, "-C", output_arg})
        for _, argv in ipairs(attempts) do
            local ok = errors.trycall(function ()
                os.vrunv(tar, argv)
                return true
            end)
            if ok then
                return
            end
        end
    end
    local ok = errors.trycall(function ()
        local extract = import("utils.archive.extract")
        extract.main(archivefile, outputdir)
    end)
    if not ok then
        run.print_error_context("archive extract", settings.configured_target_os(), {
            {"archive", archivefile},
            {"output directory", outputdir}
        })
        errors.fail("failed to extract archive: %s", archivefile)
    end
end

function download_and_extract_archive(url, archive, extracted, force, verify)
    -- every archive is integrity-checked before it is extracted or executed;
    -- callers with a bespoke check (e.g. the GCC prerequisites) pass their own
    verify = verify or checksums.verify
    local pending_extract
    local function remove_existing_extract()
        for attempt = 1, 3 do
            local ok = errors.trycall(function ()
                layout.remove_toolchains_path(extracted)
                return true
            end)
            if ok or not os.exists(extracted) then
                return true
            end
            if attempt < 3 then
                errors.sleep(1)
            end
        end
        return false
    end
    local function commit_extract()
        local parent = path.directory(extracted)
        for attempt = 1, 3 do
            if remove_existing_extract() then
                os.mkdir(parent)
                local moved = errors.trycall(function ()
                    os.mv(pending_extract, extracted)
                    return true
                end)
                if moved then
                    pending_extract = nil
                    return true
                end
                if os.exists(extracted) then
                    local cleaned = errors.trycall(function ()
                        layout.remove_toolchains_path(pending_extract)
                        pending_extract = nil
                        return true
                    end)
                    if cleaned then
                        print("warning: another process prepared the extracted cache first; reusing: " .. extracted)
                        return true
                    end
                end
            end
            if attempt < 3 then
                errors.sleep(1)
            end
        end
        run.print_error_context("archive extract commit", settings.configured_target_os(), {
            {"archive", archive},
            {"temporary extract", pending_extract},
            {"final extract", extracted},
            {"hint", "close concurrent xmake processes and tools scanning .toolchains/.cache, then rerun the same command"}
        })
        return false
    end
    local function verify_archive()
        if not verify then
            return true
        end
        return errors.trycall(function ()
            verify(archive)
            return true
        end)
    end
    local function extract_once()
        pending_extract = layout.unique_cache_path(extracted, "extract")
        layout.remove_toolchains_path(pending_extract)
        os.mkdir(pending_extract)
        extract_archive(archive, pending_extract)
        if not commit_extract() then
            errors.fail("cannot move extracted archive cache into place: %s", extracted)
        end
    end
    local leaf = path.filename(archive)
    -- Whether a trust-on-first-use anchor for this leaf already existed BEFORE
    -- this run touched it. The unusable-archive recovery below may drop the
    -- TOFU record so a corrupt first download does not reject the good
    -- re-download forever -- but it must only discard a record THIS run just
    -- established, never a pre-existing anchor. Otherwise a transient
    -- extraction failure (disk, lock, AV) on bytes that matched an established
    -- anchor would silently re-trust whatever the retry pulls down, turning an
    -- environmental hiccup into a trust-anchor reset oracle.
    local tofu_preexisting = verify == checksums.verify
        and not checksums.is_pinned(leaf) and checksums.has_tofu_record(leaf)
    if force or not os.isfile(archive) then
        download_file(url, archive, force)
    elseif verify == checksums.verify and not checksums.is_pinned(leaf) and not checksums.has_tofu_record(leaf) then
        -- A pre-existing un-pinned archive with no first-use record must not
        -- have trust frozen on opaque cache bytes (hand-placed, restored from a
        -- persistent cache, or left by another process). Re-fetch over
        -- cert-verified TLS so the recorded first-use digest comes from a real
        -- download rather than whatever happened to be on disk.
        download_file(url, archive, true)
    end
    if not verify_archive() then
        print("cached archive failed integrity check; deleting and downloading again: " .. archive)
        if os.exists(archive) then
            layout.remove_toolchains_path(archive)
        end
        download_file(url, archive, true)
        if verify then
            local verified = errors.trycall(function ()
                verify(archive)
                return true
            end)
            if not verified then
                errors.fail("redownloaded archive still fails its integrity check: %s", archive)
            end
        end
    end
    local ok = errors.trycall(extract_once)
    if ok then
        return
    end
    if pending_extract and os.exists(pending_extract) then
        layout.remove_toolchains_path(pending_extract)
        pending_extract = nil
    end
    print("cached archive is unusable; deleting and downloading again: " .. archive)
    if os.exists(extracted) then
        layout.remove_toolchains_path(extracted)
    end
    if os.exists(archive) then
        layout.remove_toolchains_path(archive)
    end
    -- A first download that was corrupt-but-recorded (un-pinned/TOFU) would
    -- otherwise reject this good re-download forever with a digest mismatch;
    -- drop the record so the retry can re-establish trust -- but ONLY when this
    -- run established it. A record that pre-dated this run is a real trust
    -- anchor: a transient extraction failure must leave it intact (the retry
    -- then re-verifies the re-download against the SAME anchor), not silently
    -- replace it.
    if verify == checksums.verify and not checksums.is_pinned(leaf) and not tofu_preexisting then
        checksums.clear_tofu_record(leaf)
    end
    download_file(url, archive, true)
    if verify then
        local verified = errors.trycall(function ()
            verify(archive)
            return true
        end)
        if not verified then
            errors.fail("redownloaded archive still fails its integrity check: %s", archive)
        end
    end
    local retry_ok = errors.trycall(extract_once)
    if retry_ok then
        return
    end
    if pending_extract and os.exists(pending_extract) then
        layout.remove_toolchains_path(pending_extract)
    end
    if os.exists(extracted) then
        layout.remove_toolchains_path(extracted)
    end
    if os.exists(archive) then
        layout.remove_toolchains_path(archive)
    end
    errors.fail("failed to extract %s after redownloading; removed the cached archive so the next run starts cleanly", archive)
end
