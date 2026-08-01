-- Chinese translations for the android command family's user-facing
-- messages. Keys are the EXACT English format strings used at the call
-- sites (gettext-shaped; see core/modules/i18n.lua). Importing this module
-- once at task entry registers everything; unregistered messages simply
-- stay English, so partial coverage is always safe.

import("i18n", {rootdir = path.join(os.scriptdir(), "..", "..", "core", "modules")})

i18n.register({
    -- sdk.lua
    ["android_sdk points to a path that is not a directory: %s"] =
        "android_sdk 指向的路径不是目录:%s",
    ["cannot locate an Android SDK; set --android_sdk=<path> or export ANDROID_HOME"] =
        "找不到 Android SDK;请设置 --android_sdk=<路径> 或导出 ANDROID_HOME 环境变量",
    ["android_ndk points to a path that is not a directory: %s"] =
        "android_ndk 指向的路径不是目录:%s",
    ["android_ndk_version %s is not installed; installed: %s\nRun `xmake android ndk install %s` or `xmake android ndk list`"] =
        "NDK 版本 %s 未安装;已安装:%s\n请运行 `xmake android ndk install %s` 安装,或用 `xmake android ndk list` 查看",
    ["usage: xmake android ndk install <version>; e.g. 27.0.12077973 (sdkmanager) or r27c (official archive)"] =
        "用法:xmake android ndk install <版本>;例如 27.0.12077973(走 sdkmanager)或 r27c(走官方归档)",
    ["sdkmanager could not install ndk;%s; falling back to the official archive needs a release name like r27c"] =
        "sdkmanager 未能安装 ndk;%s;回退到官方归档需要 r27c 这样的发行名",
    ["cannot install NDK %s: sdkmanager unavailable or failed; retry with a release name (e.g. r27c) to pull the official archive"] =
        "无法安装 NDK %s:sdkmanager 不可用或失败;请改用发行名(如 r27c)以拉取官方归档",
    ["downloaded NDK archive did not contain an android-ndk-* folder: %s"] =
        "下载的 NDK 归档中没有 android-ndk-* 目录:%s",
    ["android_build_tools %s is not installed; installed: %s"] =
        "build-tools 版本 %s 未安装;已安装:%s",
    ["platforms/android-%s is not installed; linking against %s instead"] =
        "platforms/android-%s 未安装;改用 %s 进行链接",

    -- manifest.lua
    ["invalid Android application id: %s (needs at least two dot-separated segments, e.g. com.example.app)"] =
        "无效的 Android 应用 id:%s(需要至少两段点分名称,例如 com.example.app)",
    ["manifest.generate: opt.package is required"] =
        "manifest.generate:缺少必填项 opt.package",
    ["manifest.generate: opt.lib_name is required"] =
        "manifest.generate:缺少必填项 opt.lib_name",

    -- signing.lua
    ["cannot generate a debug keystore: no keytool found (set JAVA_HOME or install a JDK)"] =
        "无法生成 debug keystore:找不到 keytool(请设置 JAVA_HOME 或安装 JDK)",
    ["keytool reported success but the keystore was not created: %s"] =
        "keytool 显示成功但 keystore 并未生成:%s",
    ["apk_keystore points to a missing file: %s"] =
        "apk_keystore 指向的文件不存在:%s",
    ["apk_keystore is set but APK_KEYSTORE_PASS is not exported; refusing to guess release credentials"] =
        "设置了 apk_keystore 但未导出 APK_KEYSTORE_PASS 环境变量;拒绝猜测 release 签名凭据",
    ["cannot run apksigner: no JDK java found (set JAVA_HOME)"] =
        "无法运行 apksigner:找不到 JDK 的 java(请设置 JAVA_HOME)",
    ["cannot run apksigner: build-tools lib/apksigner.jar not found (install Android build-tools)"] =
        "无法运行 apksigner:找不到 build-tools 的 lib/apksigner.jar(请安装 Android build-tools)",
    ["apksigner did not produce the signed APK: %s"] =
        "apksigner 未产出已签名的 APK:%s",

    -- packaging.lua
    ["cannot locate %s; %s"] =
        "找不到 %s;%s",
    ["run `xmake android status` to inspect the detected SDK"] =
        "请运行 `xmake android status` 检查探测到的 SDK",
    ["install an Android platform through the SDK manager"] =
        "请通过 SDK 管理器安装一个 Android platform",
    ["package.build_apk: opt.%s is required"] =
        "package.build_apk:缺少必填项 opt.%s",
    ["unknown Android ABI folder: %s (expected arm64-v8a, armeabi-v7a, x86_64 or x86)"] =
        "未知的 Android ABI 目录:%s(应为 arm64-v8a、armeabi-v7a、x86_64 或 x86)",
    ["native library does not exist: %s"] =
        "原生库文件不存在:%s",
    ["package.build_apk: opt.libs contains no libraries; a native-only APK without .so is unusable"] =
        "package.build_apk:opt.libs 中没有任何库;纯原生 APK 没有 .so 无法使用",
    ["lib_name %s expects %s inside the APK, but no packaged library has that file name"] =
        "lib_name %s 要求 APK 内存在 %s,但没有任何被打包的库叫这个文件名",
    ["aapt2 link did not produce an APK: %s"] =
        "aapt2 link 未产出 APK:%s",
    ["zipalign did not produce an APK: %s"] =
        "zipalign 未产出 APK:%s",
    ["no native libraries configured: pass --apk_libs=<path;path...> or export APK_LIBS.\nThe .so files are produced by the cpp build layer (project GCC android toolchain);\nthis command only packages what that build emits."] =
        "未配置任何原生库:请传 --apk_libs=<路径;路径...> 或导出 APK_LIBS 环境变量。\n.so 文件由 cpp 构建层产出(项目自建 GCC Android 工具链);\n本命令只负责打包该构建的产物。",
    ["cannot determine the ABI of %s (NDK llvm-readelf unavailable); pass --apk_abi=arm64-v8a explicitly"] =
        "无法判断 %s 的 ABI(NDK 的 llvm-readelf 不可用);请显式传 --apk_abi=arm64-v8a",
    ["cannot derive android.app.lib_name (first library is not named lib<name>.so); set --apk_lib=<name>"] =
        "无法推导 android.app.lib_name(第一个库不是 lib<名称>.so 命名);请设置 --apk_lib=<名称>",
    ["APK not built yet: %s; run `xmake android apk` first"] =
        "APK 尚未构建:%s;请先运行 `xmake android apk`",
    ["no APK in %s; run `xmake android apk` first"] =
        "%s 中没有 APK;请先运行 `xmake android apk`",
    ["multiple APKs in %s; select one with --apk_name=<name>"] =
        "%s 中有多个 APK;请用 --apk_name=<名称> 指定其一",

    -- deploy.lua
    ["cannot locate adb; install Android platform-tools or set --android_sdk"] =
        "找不到 adb;请安装 Android platform-tools 或设置 --android_sdk",
    ["no connected Android device or running emulator; start one with `xmake android emulator [avd]` or plug in a device"] =
        "没有已连接的 Android 设备或运行中的模拟器;请用 `xmake android emulator [avd]` 启动一个或接入设备",
    ["multiple devices connected (%s); pass the serial explicitly"] =
        "连接了多台设备(%s);请显式传入序列号",
    ["APK does not exist: %s"] =
        "APK 文件不存在:%s",
    ["cannot locate the Android emulator; install it through the SDK manager"] =
        "找不到 Android 模拟器;请通过 SDK 管理器安装",
    ["no AVD exists; create one in Android Studio first"] =
        "不存在任何 AVD;请先在 Android Studio 中创建一个",
    ["unknown AVD: %s (available: %s)"] =
        "未知的 AVD:%s(可用:%s)",
    ["emulator %s did not come online within the wait window; check it manually with `adb devices`"] =
        "模拟器 %s 未在等待窗口内上线;请用 `adb devices` 手动检查",

    -- android/xmake.lua shell
    ["unknown android command: %s; run `xmake android help`"] =
        "未知的 android 命令:%s;请运行 `xmake android help`",
    ["run `xmake android status` to inspect the detected SDK/NDK/devices"] =
        "运行 `xmake android status` 检查探测到的 SDK/NDK/设备",
    ["run `xmake android help` for command usage"] =
        "运行 `xmake android help` 查看命令用法"
})
