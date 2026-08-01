-- APK assembly for native-only packages: manifest -> aapt2 link -> add
-- lib/<abi>/*.so -> zipalign -> apksigner. Each stage validates its output
-- before the next one runs; a missing tool or artifact stops the pipeline
-- with the exact component name instead of a downstream zip error.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("sdk")
import("manifest")
import("signing")

local KNOWN_ABIS = {
    ["arm64-v8a"] = true,
    ["armeabi-v7a"] = true,
    ["x86_64"] = true,
    ["x86"] = true
}

local function required_tool(getter, name, guidance)
    local tool = getter()
    if not tool then
        errors.fail("cannot locate %s; %s", name, guidance or "run `xmake android status` to inspect the detected SDK")
    end
    return tool
end

-- Maps an ELF machine to the APK lib/<abi>/ folder so packaging can never
-- file a library under the wrong ABI. Handles both GNU ("AArch64") and llvm
-- ("EM_AARCH64") readelf spellings; returns nil when no readelf is around,
-- letting the caller demand an explicit ABI instead of guessing.
function detect_abi(so)
    local readelf = sdk.ndk_tool("llvm-readelf")
    if not readelf then
        return nil
    end
    local header = (os.iorunv(readelf, {"-h", so}) or ""):upper()
    local machine = header:match("MACHINE:%s*([^\r\n]+)") or ""
    if machine:find("AARCH64", 1, true) then
        return "arm64-v8a"
    elseif machine:find("X86%-64") or machine:find("X86_64", 1, true) then
        return "x86_64"
    elseif machine:find("386", 1, true) then
        return "x86"
    elseif machine:find("ARM", 1, true) then
        return "armeabi-v7a"
    end
end

-- opt:
--   name          output base name (required, e.g. "whitehope_demo")
--   package       application id (required)
--   lib_name      android.app.lib_name (required; .so base name without lib/.so)
--   libs          { ["arm64-v8a"] = { "path/to/libfoo.so", ... }, ... } (required, non-empty)
--   workdir       staging directory (required)
--   outdir        final APK directory (required)
--   min_sdk / target_sdk / label / version_code / version_name / debuggable /
--   extract_native_libs / extra_* : forwarded to manifest.generate
--   signing       optional signing config override (signing.signing_config shape)
-- returns the signed APK path
function build_apk(opt)
    opt = opt or {}
    for _, field in ipairs({"name", "package", "lib_name", "libs", "workdir", "outdir"}) do
        if not opt[field] then
            errors.fail("package.build_apk: opt.%s is required", field)
        end
    end
    local has_lib = false
    for abi, files in pairs(opt.libs) do
        if not KNOWN_ABIS[abi] then
            errors.fail("unknown Android ABI folder: %s (expected arm64-v8a, armeabi-v7a, x86_64 or x86)", tostring(abi))
        end
        for _, file in ipairs(files) do
            if not os.isfile(file) then
                errors.fail("native library does not exist: %s", file)
            end
            has_lib = true
        end
    end
    if not has_lib then
        errors.fail("package.build_apk: opt.libs contains no libraries; a native-only APK without .so is unusable")
    end
    -- android.app.lib_name=foo makes the loader dlopen lib<foo>.so from the
    -- APK; catch a name/payload mismatch here instead of on the device
    local wanted_so = "lib" .. opt.lib_name .. ".so"
    local lib_name_matches = false
    for _, files in pairs(opt.libs) do
        for _, file in ipairs(files) do
            if path.filename(file) == wanted_so then
                lib_name_matches = true
            end
        end
    end
    if not lib_name_matches then
        errors.fail("lib_name %s expects %s inside the APK, but no packaged library has that file name", opt.lib_name, wanted_so)
    end

    local api = tostring(settings.value_or("android_api", "26"))
    local aapt2 = required_tool(function () return sdk.build_tool("aapt2") end, "aapt2 (build-tools)")
    local aapt = required_tool(function () return sdk.build_tool("aapt") end, "aapt (build-tools)")
    local zipalign = required_tool(function () return sdk.build_tool("zipalign") end, "zipalign (build-tools)")
    local android_jar = required_tool(function () return sdk.platform_jar(opt.min_sdk or api) end,
        "platforms/android.jar", "install an Android platform through the SDK manager")

    local staging = opt.workdir
    if os.isdir(staging) then
        os.rmdir(staging)
    end
    os.mkdir(staging)

    local manifest_file = path.join(staging, "AndroidManifest.xml")
    manifest.write(manifest_file, {
        package = opt.package,
        lib_name = opt.lib_name,
        label = opt.label,
        version_code = opt.version_code,
        version_name = opt.version_name,
        min_sdk = opt.min_sdk or api,
        target_sdk = opt.target_sdk,
        debuggable = opt.debuggable,
        extract_native_libs = opt.extract_native_libs,
        extra_manifest = opt.extra_manifest,
        extra_application = opt.extra_application,
        extra_activity = opt.extra_activity
    })

    errors.log("aapt2 link: packaging manifest against " .. path.filename(path.directory(android_jar)))
    local unaligned = path.join(staging, opt.name .. ".unaligned.apk")
    os.execv(aapt2, {"link", "-o", unaligned, "--manifest", manifest_file, "-I", android_jar})
    if not base.file_nonempty(unaligned) then
        errors.fail("aapt2 link did not produce an APK: %s", unaligned)
    end

    -- aapt add stores entries under the path given on the command line, so
    -- stage lib/<abi>/ inside the working directory and run from there
    for abi, files in pairs(opt.libs) do
        local abi_dir = path.join(staging, "lib", abi)
        os.mkdir(abi_dir)
        for _, file in ipairs(files) do
            os.cp(file, path.join(abi_dir, path.filename(file)))
            local entry = "lib/" .. abi .. "/" .. path.filename(file)
            errors.log("adding " .. entry)
            os.execv(aapt, {"add", unaligned, entry}, {curdir = staging})
        end
    end

    local aligned = path.join(staging, opt.name .. ".aligned.apk")
    os.execv(zipalign, {"-f", "4", unaligned, aligned})
    if not base.file_nonempty(aligned) then
        errors.fail("zipalign did not produce an APK: %s", aligned)
    end

    os.mkdir(opt.outdir)
    local signed = path.join(opt.outdir, opt.name .. ".apk")
    signing.sign(aligned, signed, opt.signing)
    signing.verify(signed)
    return signed
end

-- ---------------------------------------------------------------------------
-- configuration-driven entry points (the task shell stays a thin dispatcher)
-- ---------------------------------------------------------------------------

function output_dir()
    return path.join(layout.owner_root(), "build", "android")
end

local function split_list(text)
    local list = {}
    for item in tostring(text or ""):gmatch("[^;,]+") do
        item = base.trim(item)
        if item ~= "" then
            table.insert(list, item)
        end
    end
    return list
end

-- Groups the configured .so files by ABI. The libraries themselves come from
-- the cpp build layer; this pipeline only consumes them.
local function resolve_libs()
    local files = split_list(settings.value_or("apk_libs", ""))
    if #files == 0 then
        errors.fail(table.concat({
            "no native libraries configured: pass --apk_libs=<path;path...> or export APK_LIBS.",
            "The .so files are produced by the cpp build layer (project GCC android toolchain);",
            "this command only packages what that build emits."
        }, "\n"))
    end
    local libs = {}
    local first_lib_name
    local forced_abi = tostring(settings.value_or("apk_abi", ""))
    for _, file in ipairs(files) do
        file = path.absolute(file)
        if not os.isfile(file) then
            errors.fail("native library does not exist: %s", file)
        end
        local abi = forced_abi
        if abi == "" then
            abi = detect_abi(file)
        end
        if not abi or abi == "" then
            errors.fail("cannot determine the ABI of %s (NDK llvm-readelf unavailable); pass --apk_abi=arm64-v8a explicitly", file)
        end
        libs[abi] = libs[abi] or {}
        table.insert(libs[abi], file)
        if not first_lib_name then
            first_lib_name = path.filename(file):match("^lib(.+)%.so$")
        end
    end
    return libs, first_lib_name
end

local function configured_name(lib_name)
    local name = tostring(settings.value_or("apk_name", ""))
    if name ~= "" then
        return name
    end
    return lib_name
end

-- Builds the APK entirely from apk_* options/environment; returns its path.
function build_apk_from_config()
    local libs, derived_lib_name = resolve_libs()
    local lib_name = tostring(settings.value_or("apk_lib", ""))
    if lib_name == "" then
        lib_name = derived_lib_name
    end
    if not lib_name or lib_name == "" then
        errors.fail("cannot derive android.app.lib_name (first library is not named lib<name>.so); set --apk_lib=<name>")
    end
    local name = configured_name(lib_name)
    return build_apk({
        name = name,
        package = tostring(settings.value_or("apk_id", "com.whitehope.app")),
        lib_name = lib_name,
        libs = libs,
        workdir = path.join(output_dir(), ".staging", name),
        outdir = output_dir(),
        label = (function ()
            local label = tostring(settings.value_or("apk_label", ""))
            return label ~= "" and label or nil
        end)(),
        version_code = tostring(settings.value_or("apk_version_code", "1")),
        version_name = tostring(settings.value_or("apk_version_name", "1.0")),
        min_sdk = tostring(settings.value_or("android_api", "26")),
        debuggable = settings.config_bool("apk_debuggable", false)
    })
end

-- The APK `install`/`run`/`verify` default to the configured name; when only
-- one APK exists in the output directory it is picked up without options.
function default_apk_path()
    local lib_name = tostring(settings.value_or("apk_lib", ""))
    local name = tostring(settings.value_or("apk_name", ""))
    if name == "" and lib_name ~= "" then
        name = lib_name
    end
    if name ~= "" then
        local apk = path.join(output_dir(), name .. ".apk")
        if os.isfile(apk) then
            return apk
        end
        errors.fail("APK not built yet: %s; run `xmake android apk` first", apk)
    end
    local apks = os.files(path.join(output_dir(), "*.apk"))
    if #apks == 1 then
        return apks[1]
    elseif #apks == 0 then
        errors.fail("no APK in %s; run `xmake android apk` first", output_dir())
    end
    errors.fail("multiple APKs in %s; select one with --apk_name=<name>", output_dir())
end
