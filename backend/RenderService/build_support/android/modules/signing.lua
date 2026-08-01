-- APK signing: debug keystore lifecycle plus configurable release signing,
-- both through apksigner's jar (JDK-invoked; no .bat launcher indirection).
--
-- Key material policy: passwords never land in config files or the build
-- tree. The debug keystore uses the well-known Android debug convention
-- (storepass/keypass "android"); release signing reads passwords exclusively
-- from APK_KEYSTORE_PASS / APK_KEY_PASS environment variables.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("settings", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("layout", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("sdk")

local DEBUG_ALIAS = "androiddebugkey"
local DEBUG_PASS = "android"

-- Reuse the user-global Android debug keystore when one exists (devices
-- already trust updates signed with it from Studio installs); otherwise
-- generate a project-local one under .toolchains so CI and fresh machines
-- work without a Studio history.
function debug_keystore()
    local home = os.getenv(base.is_windows_host() and "USERPROFILE" or "HOME") or ""
    local user_store = path.join(home, ".android", "debug.keystore")
    if os.isfile(user_store) then
        return user_store
    end
    local project_store = path.join(layout.toolchains_home(), "android", "debug.keystore")
    if os.isfile(project_store) then
        return project_store
    end
    local keytool = sdk.keytool()
    if not keytool then
        errors.fail("cannot generate a debug keystore: no keytool found (set JAVA_HOME or install a JDK)")
    end
    errors.log("generating project-local Android debug keystore: " .. project_store)
    os.mkdir(path.directory(project_store))
    os.execv(keytool, {
        "-genkeypair", "-keystore", project_store,
        "-alias", DEBUG_ALIAS,
        "-storepass", DEBUG_PASS, "-keypass", DEBUG_PASS,
        "-dname", "CN=Android Debug,O=Android,C=US",
        "-keyalg", "RSA", "-keysize", "2048", "-validity", "10950"
    })
    if not os.isfile(project_store) then
        errors.fail("keytool reported success but the keystore was not created: %s", project_store)
    end
    return project_store
end

-- Resolves the effective signing configuration. Release mode activates as
-- soon as apk_keystore is configured; everything else stays debug-signed.
function signing_config()
    local keystore = tostring(settings.value_or("apk_keystore", ""))
    if keystore ~= "" then
        if not os.isfile(keystore) then
            errors.fail("apk_keystore points to a missing file: %s", keystore)
        end
        local store_pass = os.getenv("APK_KEYSTORE_PASS")
        if not store_pass or store_pass == "" then
            errors.fail("apk_keystore is set but APK_KEYSTORE_PASS is not exported; refusing to guess release credentials")
        end
        return {
            keystore = keystore,
            alias = tostring(settings.value_or("apk_key_alias", "")),
            store_pass = store_pass,
            key_pass = os.getenv("APK_KEY_PASS") or store_pass,
            kind = "release"
        }
    end
    return {
        keystore = debug_keystore(),
        alias = DEBUG_ALIAS,
        store_pass = DEBUG_PASS,
        key_pass = DEBUG_PASS,
        kind = "debug"
    }
end

local function apksigner_argv(subcommand)
    local java = sdk.java()
    local jar = sdk.apksigner_jar()
    if not java then
        errors.fail("cannot run apksigner: no JDK java found (set JAVA_HOME)")
    end
    if not jar then
        errors.fail("cannot run apksigner: build-tools lib/apksigner.jar not found (install Android build-tools)")
    end
    return java, {"-jar", jar, subcommand}
end

function sign(unsigned_apk, signed_apk, config)
    config = config or signing_config()
    local java, args = apksigner_argv("sign")
    table.join2(args, {
        "--ks", config.keystore,
        "--ks-pass", "pass:" .. config.store_pass,
        "--key-pass", "pass:" .. config.key_pass
    })
    if config.alias and config.alias ~= "" then
        table.join2(args, {"--ks-key-alias", config.alias})
    end
    table.join2(args, {"--out", signed_apk, unsigned_apk})
    errors.log("signing APK (" .. config.kind .. "): " .. path.filename(signed_apk))
    os.execv(java, args)
    if not os.isfile(signed_apk) then
        errors.fail("apksigner did not produce the signed APK: %s", signed_apk)
    end
    return signed_apk
end

function verify(apk)
    local java, args = apksigner_argv("verify")
    table.join2(args, {"--print-certs", apk})
    os.execv(java, args)
end
