-- Android packaging support: description-scope shell only. All logic lives
-- in import()-modules under modules/ (sdk discovery + NDK version management,
-- manifest generation, APK assembly, signing, deployment). The native .so
-- payload is produced by the cpp build layer; nothing here compiles code.

-- captured at description load: os.scriptdir() is not trustworthy inside
-- callbacks executed later (it reflects the caller's script by then)
local ANDROID_MODULES_DIR = path.join(os.scriptdir(), "modules")
local CORE_MODULES_DIR = path.join(os.scriptdir(), "..", "core", "modules")

-- ---------------------------------------------------------------------------
-- options (android_ndk / android_api already live in cpp/options.lua and are
-- shared with the toolchain layer; value_or() gives every option below an
-- automatic UPPERCASE environment-variable fallback at resolution time)
-- ---------------------------------------------------------------------------

option("android_sdk")
    set_default("")
    set_showmenu(true)
    set_description("Android SDK root (default: ANDROID_HOME/ANDROID_SDK_ROOT or the conventional install location)")
option_end()

option("android_ndk_version")
    set_default("")
    set_showmenu(true)
    set_description("Preferred NDK version folder under <sdk>/ndk, e.g. 27.0.12077973; empty picks the newest installed")
option_end()

option("android_build_tools")
    set_default("")
    set_showmenu(true)
    set_description("Android build-tools version, e.g. 35.0.1; empty picks the newest installed")
option_end()

option("apk_libs")
    set_default("")
    set_showmenu(true)
    set_description("Native libraries to package, ';'-separated .so paths (built by the cpp layer)")
option_end()

option("apk_abi")
    set_default("")
    set_showmenu(true)
    set_description("Force the APK ABI folder (arm64-v8a, armeabi-v7a, x86_64, x86); empty detects from each ELF header")
option_end()

-- deliberately empty defaults: option values freeze into the config cache at
-- configure time, and value_or() only reaches the runtime environment when
-- the cached value is empty -- a non-empty default here would permanently
-- mask APK_ID/APK_VERSION_*. Effective defaults live at the consumers
-- (packaging.lua value_or fallbacks).
option("apk_id")
    set_default("")
    set_showmenu(true)
    set_description("Android application id (default com.whitehope.app; APK_ID overrides at run time)")
option_end()

option("apk_lib")
    set_default("")
    set_showmenu(true)
    set_description("android.app.lib_name (.so base name without lib prefix/.so suffix); empty derives from the first library")
option_end()

option("apk_name")
    set_default("")
    set_showmenu(true)
    set_description("Output APK base name; empty follows apk_lib")
option_end()

option("apk_label")
    set_default("")
    set_showmenu(true)
    set_description("User-visible application label; empty follows the library name")
option_end()

option("apk_version_code")
    set_default("")
    set_showmenu(true)
    set_description("APK versionCode (integer, default 1; APK_VERSION_CODE overrides at run time)")
option_end()

option("apk_version_name")
    set_default("")
    set_showmenu(true)
    set_description("APK versionName (default 1.0; APK_VERSION_NAME overrides at run time)")
option_end()

option("apk_debuggable")
    set_default("")
    set_showmenu(true)
    set_description("Mark the APK debuggable: true/false (default false)")
option_end()

option("apk_keystore")
    set_default("")
    set_showmenu(true)
    set_description("Release keystore path; empty uses the debug keystore. Passwords come only from APK_KEYSTORE_PASS/APK_KEY_PASS")
option_end()

option("apk_key_alias")
    set_default("")
    set_showmenu(true)
    set_description("Release key alias inside apk_keystore")
option_end()

-- ---------------------------------------------------------------------------
-- xmake android <action> [subject] [extra]
-- ---------------------------------------------------------------------------

local function android_help()
    print("usage: xmake android <command> [arguments]")
    print("")
    print("commands:")
    print("  status                      Report SDK/NDK/build-tools/JDK/device detection.")
    print("  ndk list                    List installed NDK versions and the active resolution.")
    print("  ndk install <version>       Install an NDK (sdkmanager version, or r-name for the official archive).")
    print("  apk                         Package --apk_libs into a signed APK under build/android.")
    print("  verify [apk]                apksigner-verify an APK (default: the built one).")
    print("  install [serial]            adb install the built APK.")
    print("  run [serial]                Install and launch the NativeActivity.")
    print("  uninstall [serial]          Remove the application from the device.")
    print("  emulator [avd]              Boot an AVD and wait for it to come online.")
    print("")
    print("The .so payload comes from the cpp build layer (project GCC Android toolchain);")
    print("`xmake toolchains install android` manages that toolchain.")
end

task("android")
    set_category("plugin")
    on_run(function ()
        local option = import("core.base.option")
        local action = option.get("action") or "status"
        local subject = option.get("subject") or ""
        local extra = option.get("extra") or ""
        import("catalog", {rootdir = ANDROID_MODULES_DIR})
        local sdk = import("sdk", {rootdir = ANDROID_MODULES_DIR})
        local packaging = import("packaging", {rootdir = ANDROID_MODULES_DIR})
        local signing = import("signing", {rootdir = ANDROID_MODULES_DIR})
        local deploy = import("deploy", {rootdir = ANDROID_MODULES_DIR})
        local errors = import("errors", {rootdir = CORE_MODULES_DIR})
        errors.friendly_guard("xmake android " .. action, {
            "run `xmake android status` to inspect the detected SDK/NDK/devices",
            "run `xmake android help` for command usage"
        }, function ()
        if action == "help" then
            android_help()
        elseif action == "status" then
            sdk.status()
            local config = signing.signing_config()
            print(string.format("%-14s %s (%s)", "signing:", config.keystore, config.kind))
            print(string.format("%-14s %s", "apk outdir:", packaging.output_dir()))
            local list = deploy.devices()
            print(string.format("%-14s %s", "devices:", #list > 0 and table.concat(list, ", ") or "(none)"))
        elseif action == "ndk" then
            if subject == "install" then
                local installed = sdk.ndk_install(extra)
                print("installed NDK: " .. installed)
            else
                local versions = sdk.installed_ndk_versions()
                print("installed: " .. (#versions > 0 and table.concat(versions, ", ") or "(none)"))
                local active = sdk.ndk_root()
                print("active:    " .. (active or "(none)"))
                if active then
                    print("revision:  " .. (sdk.ndk_version_of(active) or "?"))
                end
            end
        elseif action == "apk" then
            local apk = packaging.build_apk_from_config()
            print("APK ready: " .. apk)
        elseif action == "verify" then
            local apk = subject ~= "" and subject or packaging.default_apk_path()
            signing.verify(apk)
        elseif action == "install" then
            deploy.install(packaging.default_apk_path(), subject)
        elseif action == "run" then
            local apk_id = import("settings", {rootdir = CORE_MODULES_DIR}).value_or("apk_id", "com.whitehope.app")
            deploy.install(packaging.default_apk_path(), subject)
            deploy.launch(apk_id, subject)
            print("launched " .. apk_id .. "; watch output with: adb logcat")
        elseif action == "uninstall" then
            local apk_id = import("settings", {rootdir = CORE_MODULES_DIR}).value_or("apk_id", "com.whitehope.app")
            deploy.uninstall(apk_id, subject)
        elseif action == "emulator" then
            deploy.emulator_start(subject ~= "" and subject or nil)
        else
            errors.fail("unknown android command: %s; run `xmake android help`", tostring(action))
        end
        end)
    end)
    set_menu {
        usage = "xmake android [status|ndk|apk|verify|install|run|uninstall|emulator|help] [subject] [extra]",
        description = "Package and deploy native-only Android APKs from cpp-layer .so builds",
        options = {
            {nil, "action", "v", "status", "status, ndk, apk, verify, install, run, uninstall, emulator, or help"},
            {nil, "subject", "v", "", "command argument: ndk subcommand, APK path, device serial, or AVD name"},
            {nil, "extra", "v", "", "second argument, e.g. the NDK version for `ndk install`"}
        }
    }
