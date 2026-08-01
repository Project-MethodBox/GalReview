-- AndroidManifest.xml generation for native-only (hasCode=false) packages.
-- The project's deployment model is "the APK carries nothing but .so": a
-- NativeActivity whose android.app.lib_name points at the packaged library,
-- no DEX, no Java. Every knob is an explicit field so callers never hand-edit
-- generated XML; anything not expressible here should become a new field, not
-- a post-edit.

import("errors", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})

local function xml_escape(value)
    return (tostring(value)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local function validate_package_id(id)
    -- aapt2 enforces this too, but its message is cryptic; check up front
    if not tostring(id):match("^[%a_][%w_]*%.[%a_][%w_%.]*$") then
        errors.fail("invalid Android application id: %s (needs at least two dot-separated segments, e.g. com.example.app)", tostring(id))
    end
end

-- opt fields (all strings unless noted):
--   package        application id, e.g. com.whitehope.demo   (required)
--   lib_name       .so base name WITHOUT the lib prefix/.so  (required)
--   label          user-visible app name                      (default: lib_name)
--   version_code   integer string                             (default: "1")
--   version_name                                              (default: "1.0")
--   min_sdk / target_sdk                                      (default: android_api / same)
--   debuggable     boolean                                    (default: false)
--   extract_native_libs boolean                               (default: true; compressed libs, no page-align constraint)
--   extra_application / extra_activity / extra_manifest       raw XML fragments for extension
function generate(opt)
    opt = opt or {}
    if not opt.package then
        errors.fail("manifest.generate: opt.package is required")
    end
    if not opt.lib_name then
        errors.fail("manifest.generate: opt.lib_name is required")
    end
    validate_package_id(opt.package)
    local label = opt.label or opt.lib_name
    local min_sdk = tostring(opt.min_sdk or "26")
    local target_sdk = tostring(opt.target_sdk or min_sdk)
    local extract = opt.extract_native_libs
    if extract == nil then
        extract = true
    end
    -- built with explicit appends: conditional entries inside a table
    -- constructor would leave nil holes that stop ipairs/concat early
    local lines = {}
    local function emit(line)
        if line and line ~= "" then
            table.insert(lines, line)
        end
    end
    emit('<?xml version="1.0" encoding="utf-8"?>')
    emit('<manifest xmlns:android="http://schemas.android.com/apk/res/android"')
    emit('    package="' .. xml_escape(opt.package) .. '"')
    emit('    android:versionCode="' .. xml_escape(opt.version_code or "1") .. '"')
    emit('    android:versionName="' .. xml_escape(opt.version_name or "1.0") .. '">')
    emit('    <uses-sdk android:minSdkVersion="' .. xml_escape(min_sdk) .. '"')
    emit('        android:targetSdkVersion="' .. xml_escape(target_sdk) .. '"/>')
    emit(opt.extra_manifest)
    emit('    <application')
    emit('        android:label="' .. xml_escape(label) .. '"')
    emit('        android:hasCode="false"')
    emit('        android:extractNativeLibs="' .. tostring(extract) .. '"')
    if opt.debuggable then
        emit('        android:debuggable="true"')
    end

    emit('        >')
    emit(opt.extra_application)
    emit('        <activity android:name="android.app.NativeActivity"')
    emit('            android:exported="true"')
    emit('            android:configChanges="orientation|keyboardHidden|screenSize">')
    emit('            <meta-data android:name="android.app.lib_name"')
    emit('                android:value="' .. xml_escape(opt.lib_name) .. '"/>')
    emit(opt.extra_activity)
    emit('            <intent-filter>')
    emit('                <action android:name="android.intent.action.MAIN"/>')
    emit('                <category android:name="android.intent.category.LAUNCHER"/>')
    emit('            </intent-filter>')
    emit('        </activity>')
    emit('    </application>')
    emit('</manifest>')
    return table.concat(lines, "\n") .. "\n"
end

function write(file, opt)
    local content = generate(opt)
    os.mkdir(path.directory(file))
    io.writefile(file, content)
    return file
end
