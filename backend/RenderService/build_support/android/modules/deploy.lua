-- Device/emulator interaction through adb: enumerate, install, launch,
-- capture logs. Every entry point works with an explicit serial when several
-- devices are attached and picks the single connected one otherwise.

import("base", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})
import("sdk")

local function adb_or_fail()
    local adb = sdk.adb()
    if not adb then
        errors.fail("cannot locate adb; install Android platform-tools or set --android_sdk")
    end
    return adb
end

function devices()
    local adb = adb_or_fail()
    local output = os.iorunv(adb, {"devices"}) or ""
    local list = {}
    for line in output:gmatch("[^\r\n]+") do
        local serial, state = line:match("^(%S+)%s+(%S+)$")
        if serial and serial ~= "List" and state == "device" then
            table.insert(list, serial)
        end
    end
    return list
end

local function pick_device(serial)
    if serial and serial ~= "" then
        return serial
    end
    local list = devices()
    if #list == 0 then
        errors.fail("no connected Android device or running emulator; start one with `xmake android emulator [avd]` or plug in a device")
    end
    if #list > 1 then
        errors.fail("multiple devices connected (%s); pass the serial explicitly", table.concat(list, ", "))
    end
    return list[1]
end

function install(apk, serial)
    if not os.isfile(apk) then
        errors.fail("APK does not exist: %s", apk)
    end
    local adb = adb_or_fail()
    local target = pick_device(serial)
    errors.log("installing " .. path.filename(apk) .. " on " .. target)
    os.execv(adb, {"-s", target, "install", "-r", apk})
    return target
end

function launch(package_id, serial)
    local adb = adb_or_fail()
    local target = pick_device(serial)
    errors.log("launching " .. package_id .. " on " .. target)
    os.execv(adb, {"-s", target, "shell", "am", "start", "-n", package_id .. "/android.app.NativeActivity"})
    return target
end

function uninstall(package_id, serial)
    local adb = adb_or_fail()
    local target = pick_device(serial)
    os.execv(adb, {"-s", target, "uninstall", package_id})
end

-- Recent log lines, optionally filtered to one tag (-s tag:*); used by the
-- run subcommand to show the app's first output without streaming forever.
function logcat_dump(tag, serial)
    local adb = adb_or_fail()
    local target = pick_device(serial)
    local args = {"-s", target, "logcat", "-d"}
    if tag and tag ~= "" then
        table.join2(args, {"-s", tag .. ":*"})
    end
    return os.iorunv(adb, args) or ""
end

function logcat_clear(serial)
    local adb = adb_or_fail()
    local target = pick_device(serial)
    os.execv(adb, {"-s", target, "logcat", "-c"})
end

function avds()
    local emulator = sdk.emulator()
    if not emulator then
        return {}
    end
    local output = os.iorunv(emulator, {"-list-avds"}) or ""
    local list = {}
    for line in output:gmatch("[^\r\n]+") do
        local name = base.trim(line)
        -- the emulator prints informational lines (INFO | ...) among names
        if name ~= "" and not name:find("|", 1, true) then
            table.insert(list, name)
        end
    end
    return list
end

-- Boots an AVD detached and waits until adb reports the device; the caller
-- decides how long a boot is acceptable (cold emulator starts are slow).
function emulator_start(avd, wait_seconds)
    local emulator = sdk.emulator()
    if not emulator then
        errors.fail("cannot locate the Android emulator; install it through the SDK manager")
    end
    local known = avds()
    if not avd or avd == "" then
        if #known == 0 then
            errors.fail("no AVD exists; create one in Android Studio first")
        end
        avd = known[1]
    end
    local found = false
    for _, name in ipairs(known) do
        if name == avd then
            found = true
            break
        end
    end
    if not found then
        errors.fail("unknown AVD: %s (available: %s)", avd, table.concat(known, ", "))
    end
    local before = devices()
    errors.log("starting emulator AVD " .. avd)
    os.execv(emulator, {"-avd", avd}, {detach = true})
    local deadline = os.time() + (tonumber(wait_seconds) or 180)
    while os.time() < deadline do
        local now = devices()
        if #now > #before then
            for _, serial in ipairs(now) do
                local seen = false
                for _, old in ipairs(before) do
                    if old == serial then
                        seen = true
                        break
                    end
                end
                if not seen then
                    errors.log("emulator online: " .. serial)
                    return serial
                end
            end
        end
        errors.sleep(3)
    end
    errors.fail("emulator %s did not come online within the wait window; check it manually with `adb devices`", avd)
end
