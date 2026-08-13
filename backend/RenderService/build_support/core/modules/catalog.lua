-- Chinese translations for the toolchains family (core + languages/cpp +
-- languages/rust runtime messages). Keys are the EXACT English format
-- strings at the call sites (gettext-shaped, see i18n.lua); importing this
-- module once at an entry point registers everything, and unregistered
-- messages simply stay English. Concatenation-built log lines (e.g.
-- "installing rust-std for " .. target) cannot be catalogued by full-string
-- key and intentionally stay English until their call sites move to format
-- style.
--
-- The android command family keeps its own catalog (android/modules).

import("i18n")

i18n.register({
    -- platform lanes
    ["xmake lane requires a platform lane, e.g. `xmake lane wasm build` (windows|linux|macosx|ios|android|wasm|wasm64)"] =
        "xmake lane 需要指定平台 lane,例如 `xmake lane wasm build`(windows|linux|macosx|ios|android|wasm|wasm64)",
    ["unknown lane action '%s' (use config|build|rebuild|run|clean|show)"] =
        "未知的 lane 动作 '%s'(可用 config|build|rebuild|run|clean|show)",
    ["lane %s: failed to launch the child xmake (%s): %s"] =
        "lane %s:无法启动子 xmake(%s):%s",
    ["lane %s: child `xmake %s` exited with status %d%s -- its diagnostics are in the output above%s"] =
        "lane %s:子命令 `xmake %s` 以状态 %d 退出%s——其诊断信息见上方输出%s",

    -- run/staging framework
    ["%s failed"] = "%s 失败",
    ["%s failed; fix the reported cause and rerun the same xmake command"] =
        "%s 失败;请修复上方报告的原因后重跑同一条 xmake 命令",
    ["make step failed; the build directory is kept for incremental reruns after the cause is fixed"] =
        "make 步骤失败;构建目录已保留,修复原因后可增量续跑",
    ["make failed; retrying once in case a transient file lock (antivirus or indexer) broke a build step"] =
        "make 失败;可能是瞬时文件锁(杀毒或索引器)破坏了构建步骤,自动重试一次",
    ["script step failed; fix the reported prerequisite/source issue and rerun the same xmake command"] =
        "脚本步骤失败;请修复上方报告的先决条件/源码问题后重跑同一条 xmake 命令",

    -- stage logs
    ["syncing GCC source"] = "正在同步 GCC 源码",
    ["patching GCC configure metadata"] = "正在修补 GCC configure 元数据",
    ["patching GCC source"] = "正在修补 GCC 源码",
    ["ensuring GCC generated sources"] = "正在准备 GCC 生成源文件",
    ["installing GCC prerequisites with xmake-managed downloads"] = "正在通过 xmake 托管下载安装 GCC 先决库",
    ["preparing target runtime inputs"] = "正在准备目标运行时输入",
    ["staging target tools and linkers"] = "正在暂存目标工具与链接器",
    ["configuring GCC"] = "正在配置 GCC",
    ["configuring GCC make targets"] = "正在配置 GCC make 目标",
    ["building native GCC toolchain"] = "正在构建本机 GCC 工具链",
    ["building native Windows GCC compiler pieces"] = "正在构建本机 Windows GCC 编译器组件",
    ["building cross Windows GCC compiler pieces"] = "正在构建交叉 Windows GCC 编译器组件",
    ["building cross GCC compiler and target runtime"] = "正在构建交叉 GCC 编译器与目标运行时",
    ["building Android GCC compiler and target runtime"] = "正在构建 Android GCC 编译器与目标运行时",
    ["building Linux musl GCC compiler and target runtime"] = "正在构建 Linux musl GCC 编译器与目标运行时",
    ["building macOS GCC compiler and target runtime"] = "正在构建 macOS GCC 编译器与目标运行时",
    ["finalizing installed GCC toolchain"] = "正在收尾已安装的 GCC 工具链",
    ["finalizing existing project-local GCC toolchain"] = "正在收尾既有的项目本地 GCC 工具链",

    -- source sync / prerequisites
    ["GCC git checkout did not contain a GCC source tree"] = "GCC git 检出内容不包含 GCC 源码树",
    ["GCC mainline source is missing gcc/gengtype-lex.cc; install flex or allow xmake to bootstrap project-local generator tools"] =
        "GCC 主线源码缺少 gcc/gengtype-lex.cc;请安装 flex,或允许 xmake 自举项目本地生成器工具",
    ["GCC source patches are current (stamp marker and fingerprints verified); skipping re-patch"] =
        "GCC 源码补丁已是最新(标记与各补丁落地特征均已校验);跳过重打",
    ["restoring the pristine GCC source checkout before patching"] =
        "打补丁前先把 GCC 源码还原为干净检出",
    ["full GCC fetch failed (attempt %d/%d); retrying after a short delay"] =
        "GCC 全量拉取失败(第 %d/%d 次);稍后自动重试",
    -- %s 是传输方式名(shallow / blob-filtered shallow),保留原文
    ["%s GCC fetch failed (attempt %d/%d); retrying after a short delay"] =
        "%s 方式的 GCC 拉取失败(第 %d/%d 次);稍后自动重试",
    ["git command failed: git %s"] = "git 命令失败:git %s",
    ["no synced GCC source tree to bundle; run `xmake toolchains fetch %s` first"] =
        "没有可打包的已同步 GCC 源码树;请先运行 `xmake toolchains fetch %s`",
    ["cannot determine the GCC source revision to bundle: %s"] = "无法确定要打包的 GCC 源码修订:%s",
    ["cannot determine the WABT source revision to bundle: %s"] = "无法确定要打包的 WABT 源码修订:%s",
    ["bundling revision %s while the configured ref is %s; fresh syncs only consume a bundle matching their pinned ref"] =
        "正在打包修订 %s,但配置的 ref 是 %s;全新同步只会使用与钉住 ref 完全匹配的 bundle",
    ["local source bundle could not be read; falling back to a normal fetch: %s"] =
        "本地源码 bundle 无法读取;回退到常规拉取:%s",
    ["could not resolve the upstream tracking branch %s; the pinned revision stays %s"] =
        "无法解析上游跟踪分支 %s;钉住的修订保持 %s 不变",
    ["GCC source patches did not fully apply: %d postcondition(s) unmet"] =
        "GCC 源码补丁未完全生效:%d 个后置校验未满足",
    ["cross binutils has no recorded snapshot identity (%s); rebuilding once to establish one"] =
        "交叉 binutils 没有记录快照身份(%s);重建一次以建立身份",
    ["cxxmodule.branch_layers declares branch(es) with no matching module in the tree (typo? unranks the real branch): %s"] =
        "cxxmodule.branch_layers 声明了树中没有对应模块的分支(拼写错误?会使真实分支失去层级):%s",
    ["cxxmodule.branch_layers omits real branch(es), leaving them unranked and direction-unguarded: %s"] =
        "cxxmodule.branch_layers 遗漏了真实分支,使其没有层级、方向也不受约束:%s",
    ["GCC prerequisite archive did not contain the expected package directory: %s"] =
        "GCC 先决库归档中没有预期的包目录:%s",
    ["GCC prerequisite archive is missing before verification: %s"] = "校验前 GCC 先决库归档缺失:%s",
    ["GCC prerequisite archive name contains a newline: %s"] = "GCC 先决库归档名包含换行符:%s",
    ["GCC prerequisite archive variable is missing in %s: %s"] = "%s 中缺少 GCC 先决库归档变量:%s",
    ["GCC prerequisite checksum entry is malformed for %s"] = "%s 的 GCC 先决库校验和条目格式错误",
    ["GCC prerequisite checksum file is missing: %s"] = "GCC 先决库校验和文件缺失:%s",
    ["GCC prerequisite checksum line is missing for %s in %s"] = "%s 的校验和行在 %s 中缺失",
    ["GCC prerequisite script is missing: %s"] = "GCC 先决库脚本缺失:%s",
    ["timestamp-preserving prerequisite copy failed; falling back to xmake copy and generated timestamp refresh"] =
        "保时间戳的先决库拷贝失败;回退到 xmake 拷贝并刷新生成文件时间戳",
    ["win_bison was not found in downloaded winflexbison archive"] = "下载的 winflexbison 归档中未找到 win_bison",
    ["win_flex was not found in downloaded winflexbison archive"] = "下载的 winflexbison 归档中未找到 win_flex",

    -- downloads / archives
    ["download failed (attempt %d/%d); retrying after a short delay: %s"] =
        "下载失败(第 %d/%d 次);稍后自动重试:%s",
    ["failed to download %s after %d attempts; certificate verification is enforced, so if a TLS-inspecting proxy is in the way, trust its root CA in the system store, or place the file at %s by hand (it is still digest-checked)"] =
        "下载 %s 失败(已重试 %d 次);证书校验已强制开启,若有拆解 TLS 的代理挡路,请把其根证书装入系统信任库,或手动把文件放到 %s(仍会做哈希校验)",
    ["archive integrity check failed: %s"] = "归档完整性校验失败:%s",
    ["trust-on-first-use integrity check failed: %s"] = "首次信任(TOFU)完整性校验失败:%s",
    ["cannot compute SHA-512 for %s: no sha512sum or certutil is available"] =
        "无法为 %s 计算 SHA-512:找不到 sha512sum 或 certutil",
    ["unknown checksum algorithm %s registered for %s"] = "为 %s 登记了未知的校验算法 %s",
    ["failed to extract %s after redownloading; removed the cached archive so the next run starts cleanly"] =
        "重新下载后解包 %s 仍失败;已删除缓存归档,下次运行将从干净状态开始",
    ["failed to extract archive: %s"] = "解包归档失败:%s",
    ["cannot move extracted archive cache into place: %s"] = "无法把解包后的归档缓存移动到位:%s",
    ["redownloaded archive still fails its integrity check: %s"] = "重新下载的归档仍未通过完整性校验:%s",
    ["downloaded archive did not contain a configure-based source tree"] = "下载的归档不包含 configure 式源码树",
    ["downloaded binutils archive did not contain a binutils source tree"] = "下载的 binutils 归档不包含 binutils 源码树",
    ["downloaded musl archive did not contain a musl source tree"] = "下载的 musl 归档不包含 musl 源码树",
    ["downloaded MinGW-w64 archive did not contain generated configure scripts"] =
        "下载的 MinGW-w64 归档不包含预生成的 configure 脚本",

    -- host bootstrap / host tools
    ["cannot locate the host MinGW sysroot from %s; install a MinGW-style host compiler or put it in PATH"] =
        "无法从 %s 定位宿主 MinGW sysroot;请安装 MinGW 系宿主编译器或将其加入 PATH",
    ["configured toolchains_bootstrap_path is not usable: %s"] = "配置的 toolchains_bootstrap_path 不可用:%s",
    ["could not resolve a matching w64devkit asset from GitHub latest release metadata; set --toolchains_bootstrap_url=<archive-url> to use an explicit portable MinGW archive"] =
        "无法从 GitHub 最新 release 元数据解析匹配的 w64devkit 资产;请设置 --toolchains_bootstrap_url=<归档地址> 指定便携 MinGW 归档",
    ["could not resolve the latest w64devkit release (GitHub API unreachable or rate-limited); using the pinned fallback: %s"] =
        "无法解析最新 w64devkit release(GitHub API 不可达或被限流);使用钉住的回退版本:%s",
    ["no default Windows bootstrap asset is known for host architecture: %s"] =
        "宿主架构 %s 没有已知的默认 Windows 自举资产",
    ["failed to remove temporary Windows bootstrap files; they can be deleted from .toolchains/.cache/windows/bootstrap manually"] =
        "删除临时 Windows 自举文件失败;可手动清理 .toolchains/.cache/windows/bootstrap",
    ["keeping temporary Windows bootstrap files because the project-local GCC install is not fully usable yet"] =
        "项目本地 GCC 安装尚不完全可用,保留临时 Windows 自举文件",
    ["host compiler failed the compile/link/run smoke test and will not be used: %s"] =
        "宿主编译器未通过编译/链接/运行冒烟测试,不会被使用:%s",
    ["host compiler failed the smoke test: %s. It is likely a shim or wrapper (opam/DKML, package-manager launcher); rerun with --toolchains_bootstrap=portable to force a project-private bootstrap toolchain, or put a real MinGW distribution such as w64devkit or MSYS2/UCRT64 first in PATH"] =
        "宿主编译器未通过冒烟测试:%s。它很可能是垫片或包装器(opam/DKML、包管理器启动器);请用 --toolchains_bootstrap=portable 强制项目私有自举工具链,或把 w64devkit、MSYS2/UCRT64 这类真实 MinGW 发行版放到 PATH 最前",
    ["Windows bootstrap toolchain at %s is missing its %s backend (the driver resolves it to '%s'). Likely an interrupted extraction or an antivirus quarantine; ignoring this copy so a fresh bootstrap can be provisioned"] =
        "位于 %s 的 Windows 自举工具链缺失 %s 后端(驱动器将其解析为'%s')。很可能是解压中断或被杀毒软件隔离;已忽略该副本,以便重新提取新的自举工具链",
    ["host compiler failed the smoke test: %s. Reinstall the native build tools (gcc/g++ or clang with libstdc++/libc++ development headers) with your platform package manager"] =
        "宿主编译器未通过冒烟测试:%s。请用平台包管理器重装本机构建工具(gcc/g++ 或带 libstdc++/libc++ 开发头的 clang)",
    ["missing POSIX shell for GCC configure. Use a MinGW distribution that provides sh.exe"] =
        "缺少 GCC configure 所需的 POSIX shell;请使用附带 sh.exe 的 MinGW 发行版",
    ["using the system proxy %s for downloads and build child processes (export HTTP_PROXY/ALL_PROXY to override it, or turn the system proxy off)"] =
        "已自动采用系统代理 %s 用于下载与构建子进程(可用 HTTP_PROXY/ALL_PROXY 环境变量覆盖,或关闭系统代理)",
    ["the configure-stage C compiler %s cannot compile a trivial probe under %s; the bootstrap toolchain is broken or quarantined -- fix or reinstall it, then rerun the same xmake command%s"] =
        "configure 阶段的 C 编译器 %s 在 %s 下连最小探针程序都编译不了;引导工具链已损坏或被杀毒软件隔离——请修复或重装它,然后重跑同一条 xmake 命令%s",
    ["a freshly compiled test program cannot run or write a file inside the build tree %s, so GCC configure is bound to fail with its opaque \"cannot run C compiled programs\". This is almost always security software distrusting brand-new unsigned executables: on Windows check the Defender operational log for event 1123 (Controlled Folder Access), move the project out of the protected-folder list or pause the interference, then rerun the same xmake command"] =
        "刚编译出的测试程序无法在构建目录 %s 内运行或写文件,GCC configure 必然会以晦涩的 \"cannot run C compiled programs\" 失败。这几乎总是安全软件在拦截全新的未签名可执行文件:Windows 上请查看 Defender 操作日志中的 1123 事件(受控文件夹访问),把项目目录移出受保护文件夹列表或暂停拦截,然后重跑同一条 xmake 命令",
    ["missing required MinGW bootstrap tools: %s. A bare gcc.exe is not enough; use a MinGW distribution that includes POSIX build tools, such as w64devkit or MSYS2/UCRT64"] =
        "缺少必需的 MinGW 自举工具:%s。只有 gcc.exe 是不够的;请使用附带 POSIX 构建工具的 MinGW 发行版,例如 w64devkit 或 MSYS2/UCRT64",
    ["missing required host build tools: %s"] = "缺少必需的宿主构建工具:%s",
    ["cannot pass a value with cmd.exe metacharacters to cmd safely: %s"] =
        "无法把含 cmd.exe 元字符的值安全传给 cmd:%s",

    -- build / install
    ["existing toolchain stamp has no recorded build-config signature (%s); treating it as out of date and rebuilding once to establish one"] =
        "既有工具链 stamp 未记录构建配置签名(%s);按过期处理并重建一次以建立签名",
    ["failed to install project-local %s at %s"] = "安装项目本地 %s 到 %s 失败",
    ["refusing to remove path outside toolchains home: %s"] = "拒绝删除 toolchains 家目录之外的路径:%s",
    ["refusing to remove unexpected GCC build directory: %s"] = "拒绝删除意料之外的 GCC 构建目录:%s",
    ["cannot remove or quarantine cache path: %s"] = "无法删除或隔离缓存路径:%s",
    ["skipping unstrippable installed file: %s"] = "跳过无法 strip 的已安装文件:%s",
    ["unsupported toolchain platform folder: %s; supported folders are windows, linux, android, macosx, ios, emscripten"] =
        "不支持的工具链平台目录:%s;支持的目录为 windows、linux、android、macosx、ios、emscripten",
    ["invalid ios_deployment_target '%s'; expected a version such as %s"] =
        "无效的 ios_deployment_target '%s';应为 %s 这类版本号",
    ["ios_deployment_target should look like %s; current value is '%s'."] =
        "ios_deployment_target 应形如 %s;当前值为 '%s'。",

    -- target sysroots / per-OS
    ["cannot locate Android NDK LLVM bin directory; set android_ndk or ANDROID_NDK_HOME"] =
        "无法定位 Android NDK 的 LLVM bin 目录;请设置 android_ndk 或 ANDROID_NDK_HOME",
    -- androidndk.lua (shared SDK/NDK resolver; the android command family
    -- registers the same keys in android/modules/catalog.lua)
    ["android_sdk points to a path that is not a directory: %s"] =
        "android_sdk 指向的路径不是目录:%s",
    ["android_ndk points to a path that is not a directory: %s"] =
        "android_ndk 指向的路径不是目录:%s",
    ["android_ndk_version %s is not installed; installed: %s\nRun `xmake android ndk install %s` or `xmake android ndk list`"] =
        "NDK 版本 %s 未安装;已安装:%s\n请运行 `xmake android ndk install %s` 安装,或用 `xmake android ndk list` 查看",
    ["cannot locate Android NDK ld.lld: %s"] = "无法定位 Android NDK 的 ld.lld:%s",
    ["failed to write Android GCC/NDK compatibility header: %s"] = "写出 Android GCC/NDK 兼容头失败:%s",
    ["android_api must be numeric; current value is '%s'."] = "android_api 必须是数字;当前值为 '%s'。",
    ["invalid android_api '%s'; expected a numeric Android API level"] =
        "无效的 android_api '%s';应为数字形式的 Android API 级别",
    ["Linux GNU target requires a complete glibc sysroot with headers and libc. Set linux_sysroot/LINUX_SYSROOT to a usable sysroot, or use linux_libc=musl."] =
        "Linux GNU 目标需要带头文件与 libc 的完整 glibc sysroot。请把 linux_sysroot/LINUX_SYSROOT 指向可用 sysroot,或改用 linux_libc=musl。",
    ["Linux cross target requires a sysroot. Set linux_libc=musl for project-managed musl, or set linux_sysroot/LINUX_SYSROOT for GNU libc."] =
        "Linux 交叉目标需要 sysroot。项目托管的 musl 用 linux_libc=musl;GNU libc 请设置 linux_sysroot/LINUX_SYSROOT。",
    ["Linux musl bootstrap did not install libgcc.a before libc"] = "Linux musl 自举未在 libc 之前安装 libgcc.a",
    ["invalid linux_libc '%s'; expected auto, gnu, or musl"] = "无效的 linux_libc '%s';应为 auto、gnu 或 musl",
    ["linux_libc must be auto, gnu, or musl; current value is '%s'."] =
        "linux_libc 必须是 auto、gnu 或 musl;当前值为 '%s'。",
    -- managed glibc sysroot (languages/cpp/modules/gccglibc.lua)
    ["linux_glibc_version must be auto or a glibc version such as 2.43; current value is '%s'."] =
        "linux_glibc_version 必须是 auto 或形如 2.43 的 glibc 版本号;当前值为 '%s'。",
    ["invalid linux_glibc_version '%s'; expected auto or a glibc version such as 2.43"] =
        "无效的 linux_glibc_version '%s';应为 auto 或形如 2.43 的 glibc 版本号",
    ["cannot resolve the managed glibc version: %s"] = "无法解析受管 glibc 版本:%s",
    ["the managed glibc sysroot can only be built on a Linux host; use linux_libc=musl, set linux_sysroot to an existing glibc sysroot, or build the managed sysroot on a Linux host and copy it here"] =
        "受管 glibc sysroot 只能在 Linux 宿主上现场构建;请改用 linux_libc=musl,或把 linux_sysroot 指向既有 glibc sysroot,或先在 Linux 宿主构建受管 sysroot 后拷贝到本机使用",
    ["host glibc %s has no exact managed match; following with the closest supported version %s (set --linux_glibc_version to override)"] =
        "宿主 glibc %s 在受管版本表中没有精确匹配;就近跟随受支持版本 %s(可用 --linux_glibc_version 覆盖)",
    ["host glibc %s is older than every supported managed glibc version; using the oldest supported version %s"] =
        "宿主 glibc %s 低于所有受支持的受管 glibc 版本;使用最老的受支持版本 %s",
    ["downloaded glibc archive did not contain a glibc source tree"] =
        "下载的 glibc 归档不包含 glibc 源码树",
    ["downloaded Linux kernel archive did not contain a Linux kernel source tree"] =
        "下载的 Linux 内核归档不包含内核源码树",
    ["Linux kernel headers install is incomplete: %s"] = "Linux 内核头文件安装不完整:%s",
    ["stage1 GCC for the managed glibc sysroot is incomplete: %s"] =
        "受管 glibc sysroot 的 stage1 GCC 不完整:%s",
    ["managed glibc sysroot install is incomplete: %s"] = "受管 glibc sysroot 安装不完整:%s",
    ["unsupported linux_libc value: %s; expected auto, gnu, or musl"] =
        "不支持的 linux_libc 值:%s;应为 auto、gnu 或 musl",
    ["musl does not provide headers for architecture '%s' from triplet '%s'"] =
        "musl 不为架构 '%s'(来自三元组 '%s')提供头文件",
    ["musl headers install is incomplete: %s"] = "musl 头文件安装不完整:%s",
    ["musl runtime install is incomplete: %s"] = "musl 运行时安装不完整:%s",
    ["musl runtime requires the stage GCC compiler to be installed first"] =
        "musl 运行时要求先安装阶段 GCC 编译器",
    ["replacing the absolute musl loader symlink with a sysroot-local copy: %s"] =
        "把绝对路径的 musl 加载器符号链接替换为 sysroot 内本地副本:%s",
    ["could not remove the musl loader symlink; refusing to copy through it: %s"] =
        "无法移除 musl 加载器符号链接;拒绝透过它复制:%s",
    ["MinGW-w64 CRT install is incomplete: %s"] = "MinGW-w64 CRT 安装不完整:%s",
    ["MinGW-w64 CRT requires the stage GCC compiler to be installed first"] =
        "MinGW-w64 CRT 要求先安装阶段 GCC 编译器",
    ["MinGW-w64 headers install is incomplete: %s"] = "MinGW-w64 头文件安装不完整:%s",
    ["MinGW-w64 winpthreads install is incomplete: %s"] = "MinGW-w64 winpthreads 安装不完整:%s",
    ["cannot copy MinGW headers from %s"] = "无法从 %s 拷贝 MinGW 头文件",
    ["cannot copy MinGW libraries from %s"] = "无法从 %s 拷贝 MinGW 库",
    ["copied MinGW sysroot is incomplete: %s"] = "拷贝的 MinGW sysroot 不完整:%s",
    ["invalid macosx_deployment_target '%s'; expected a version such as 11.0"] =
        "无效的 macosx_deployment_target '%s';应为 11.0 这类版本号",
    ["macosx_deployment_target should look like 11.0; current value is '%s'."] =
        "macosx_deployment_target 应形如 11.0;当前值为 '%s'。",

    -- build-config option validation
    ["invalid toolchains_build_debug '%s'; expected auto, true, or false"] =
        "无效的 toolchains_build_debug '%s';应为 auto、true 或 false",
    ["invalid toolchains_build_optimize '%s'; use a single GCC -O suffix such as 0, 1, 2, 3, g, s, or fast"] =
        "无效的 toolchains_build_optimize '%s';请使用单个 GCC -O 后缀,如 0、1、2、3、g、s 或 fast",
    ["invalid toolchains_build_type '%s'; expected release, debug, relwithdebinfo, minsizerel, or size"] =
        "无效的 toolchains_build_type '%s';应为 release、debug、relwithdebinfo、minsizerel 或 size",
    ["invalid toolchains_jobs value '%s'; expected a positive integer"] =
        "无效的 toolchains_jobs 值 '%s';应为正整数",
    ["invalid toolchains_strip '%s'; expected auto, true, or false"] =
        "无效的 toolchains_strip '%s';应为 auto、true 或 false",
    ["toolchains_build_debug must be auto/true/false; current value is '%s'."] =
        "toolchains_build_debug 必须为 auto/true/false;当前值为 '%s'。",
    ["toolchains_build_optimize must be one GCC optimization suffix, not a flag list: %s."] =
        "toolchains_build_optimize 必须是单个 GCC 优化后缀而非标志列表:%s。",
    ["toolchains_build_type is not recognized: %s."] = "无法识别的 toolchains_build_type:%s。",
    ["toolchains_jobs must be a positive integer; current value is '%s'."] =
        "toolchains_jobs 必须为正整数;当前值为 '%s'。",
    ["toolchains_strip must be auto/true/false; current value is '%s'."] =
        "toolchains_strip 必须为 auto/true/false;当前值为 '%s'。",

    -- CLI dispatch / sentinels
    ["GCC features are xmake.lua/config settings, not a toolchains command; run `xmake toolchains help`"] =
        "GCC features 属于 xmake.lua/配置项,不是 toolchains 命令;请运行 `xmake toolchains help`",
    ["unknown toolchains command: %s; run `xmake toolchains help`"] =
        "未知的 toolchains 命令:%s;请运行 `xmake toolchains help`",
    ["unknown matrix subject: %s; use windows, linux, android, macosx, ios, emscripten, rust, or host"] =
        "未知的 matrix 主题:%s;可用 windows、linux、android、macosx、ios、emscripten、rust 或 host",
    ["unsupported rust toolchain command: %s; use status, install, or update"] =
        "不支持的 rust 工具链命令:%s;可用 status、install 或 update",
    ["cannot pin: no stored configuration found; run `xmake f -p <plat> -a <arch> -m <mode>` first"] =
        "无法 pin:没有已存储的配置;请先运行 `xmake f -p <plat> -a <arch> -m <mode>`",
    ["active configuration %s/%s/%s differs from the pinned %s/%s/%s -- a bare `xmake f` or an implicit reconfigure reset it; restore with `xmake f -p %s -a %s -m %s -y` (or repin via `xmake toolchains pin`)"] =
        "当前配置 %s/%s/%s 与钉住的 %s/%s/%s 不一致——裸 `xmake f` 或隐式重配置重置了它;用 `xmake f -p %s -a %s -m %s -y` 恢复(或用 `xmake toolchains pin` 重新钉住)",
    ["build_support default constants have drifted between options.lua and core/modules/defaults.lua:\n  %s"] =
        "build_support 默认常量在 options.lua 与 core/modules/defaults.lua 之间发生漂移:\n  %s",
    ["defaults consistency check could not read %s"] = "默认常量一致性检查无法读取 %s",

    -- managed emscripten toolset (languages/cpp/modules/gccemsdk.lua)
    ["managed Emscripten toolset install failed; falling back to emcc/node/wasm-ld from explicit configuration, PATH, or EMSDK: %s"] =
        "受管 Emscripten 工具族安装失败;emcc/node/wasm-ld 回退到显式配置、PATH 或 EMSDK 环境:%s",
    ["using %s from the external EMSDK environment (%s); the managed Emscripten toolset is missing, so toolchain identity depends on that external install"] =
        "正在使用外部 EMSDK 环境中的 %s(%s);受管 Emscripten 工具族缺失,工具链身份此时取决于该外部安装",
    ["no pinned Emscripten archive set is defined for host %s/%s; the managed toolset is unavailable and emcc/node/wasm-ld fall back to explicit configuration or PATH"] =
        "宿主 %s/%s 没有定义钉住的 Emscripten 归档集;受管工具族不可用,emcc/node/wasm-ld 回退到显式配置或 PATH",
    ["downloaded %s did not contain the expected content layout under %s"] =
        "下载的 %s 在 %s 下不包含预期的内容布局",
    ["managed Emscripten toolset install finished but is still not detected as complete: %s"] =
        "受管 Emscripten 工具族安装结束但仍未被检测为完整:%s",

    -- wasm build-quality smoke assertions (languages/cpp/modules/gccwasm.lua)
    ["wasm64 parameterless main probe emitted no __main_argc_argv signature: %s"] =
        "wasm64 无参 main 探测未产出 __main_argc_argv 签名:%s",
    ["wasm64 gives a parameterless main a 32-bit argv (%s); every wasm64 program with a parameterless main would trap before main runs"] =
        "wasm64 给无参 main 的 argv 是 32 位的(%s);任何无参 main 的 wasm64 程序都会在进入 main 之前陷入陷阱",
    ["installed GCC WebAssembly compiler knows no wasm64 multilib (-print-multi-lib reported %s); the toolchain was configured without --enable-multilib"] =
        "已安装的 GCC WebAssembly 编译器不认识 wasm64 multilib(-print-multi-lib 报告 %s);该工具链配置时未加 --enable-multilib",
    ["the wasm64 multilib libstdc++ is not installed: -mwasm64 -print-file-name=libstdc++.a resolved to %s"] =
        "wasm64 multilib 的 libstdc++ 未安装:-mwasm64 -print-file-name=libstdc++.a 解析到 %s",
    ["GCC wasm debug-channel probe found a .debug_line section without -g; debug output must stay opt-in"] =
        "GCC wasm 调试通道探针在未开 -g 时发现了 .debug_line 段;调试输出必须保持按需开启",
    ["GCC wasm debug-channel probe found no .debug_line section under -g: the line-number debug channel regressed; revisit the pending toolchain snapshot in patches/wasm.lua"] =
        "GCC wasm 调试通道探针在 -g 下未发现 .debug_line 段:行号调试通道已回归失效;请复查 patches/wasm.lua 的 pending 工具链快照",
    ["linked wasm lost the GCC-side function name %s from its name section; emcc -g2 no longer provides the function-name debugging baseline"] =
        "链接产物 wasm 的 name 节丢失了 GCC 侧函数名 %s;emcc -g2 不再提供函数名级调试底线",
    ["linked wasm %s lost the reachable smoke data marker %s; the emcc link dropped live GCC data"] =
        "链接产物 wasm %s 丢失了可达的冒烟数据标记 %s;emcc 链接丢弃了存活的 GCC 数据",
    ["linked wasm %s still contains the unreachable smoke data marker %s; symbol-granular dead-code GC regressed in the emcc link"] =
        "链接产物 wasm %s 仍包含不可达的冒烟数据标记 %s;emcc 链接的符号粒度死代码 GC 已回退",
    ["optimized wasm smoke artifact is not significantly smaller than the unoptimized one (%d vs %d bytes); the emcc -O3 wasm-opt pipeline did not take effect"] =
        "优化档 wasm 冒烟产物没有显著小于非优化档(%d 对 %d 字节);emcc -O3 的 wasm-opt 管线未生效",
    ["wasm -fexceptions smoke never reached its throw site (missing pre-throw marker); transcript: %s"] =
        "wasm -fexceptions 冒烟未到达 throw 点(缺少 throw 前标记);运行记录:%s",
    ["wasm -fexceptions smoke no longer completes the throw/catch round trip (exit %s): native wasm exception handling regressed; revisit docs/developer/wasm_exception_policy.md and the pending toolchain snapshot in patches/wasm.lua; transcript: %s"] =
        "wasm -fexceptions 冒烟不再完成 throw/catch 往返(退出码 %s):原生 wasm 异常处理已回归失效;请重审 docs/developer/wasm_exception_policy.md 与 patches/wasm.lua 里的 pending 工具链快照;运行记录:%s",
    ["wasm smoke artifact %s size drifted past the one-tenth tolerance under an unchanged smoke signature (baseline %d bytes, now %d bytes); baseline refreshed -- investigate if no smoke-source change explains it"] =
        "wasm 冒烟产物 %s 在冒烟签名未变的情况下体积漂移超过十分之一容差(基线 %d 字节,当前 %d 字节);基线已刷新——若没有冒烟源变更可以解释,请排查",

    -- rust toolchain / crates
    ["Rust toolchain install finished but rustc is still missing: %s"] =
        "Rust 工具链安装结束但 rustc 仍缺失:%s",
    ["cannot parse the nightly date from %s"] = "无法从 %s 解析 nightly 日期",
    ["first Rust toolchain install: resolved the newest published nightly %s"] =
        "首次安装 Rust 工具链:已解析最新发布的 nightly %s",
    ["dist component layout unexpected: %s does not exist"] = "dist 组件布局异常:%s 不存在",
    ["downloaded %s for %s did not contain a %s-nightly-* folder under %s"] =
        "为 %s 下载的 %s 在 %s 下没有 %s-nightly-* 目录",
    ["downloaded rust-src did not contain a rust-src-nightly* folder under %s"] =
        "下载的 rust-src 在 %s 下没有 rust-src-nightly* 目录",
    ["rust-src was installed but %s still does not exist; the dist component layout may have changed"] =
        "rust-src 已安装但 %s 仍不存在;dist 组件布局可能已变更",
    ["Rust toolchain install finished but rustc's self-contained rust-objcopy is still missing: %s (cargo build-std of compiler_builtins needs it)"] =
        "Rust 工具链安装已完成,但 rustc 自带的 rust-objcopy 仍然缺失:%s(cargo build-std 编译 compiler_builtins 需要它)",
    ["Rust toolchain install finished but clippy-driver is still missing: %s"] =
        "Rust 工具链安装已完成,但 clippy-driver 仍然缺失:%s",
    ["rust-std for %s was installed but %s still does not exist; the dist component layout may have changed"] =
        "%s 的 rust-std 已安装但 %s 仍不存在;dist 组件布局可能已变更",
    ["no rustc target mapping for GCC triplet %s; extend RUST_TARGETS in languages/rust/modules/toolchain.lua"] =
        "GCC 三元组 %s 没有对应的 rustc 目标映射;请扩展 languages/rust/modules/toolchain.lua 的 RUST_TARGETS",
    ["add_rustfiles/add_rustmanifest requires add_rules(\"rust.cargo\") on target %s"] =
        "目标 %s 使用 add_rustfiles/add_rustmanifest 前必须先挂载 add_rules(\"rust.cargo\")",
    ["rust.cargo on target %s requires exactly one add_rustfiles(\"<rootdir>\") declaration; found %d"] =
        "目标 %s 的 rust.cargo 需要且只允许一个 add_rustfiles(\"<rootdir>\") 声明;实际有 %d 个",
    ["add_rustfiles root on target %s must be a non-empty path string"] =
        "目标 %s 的 add_rustfiles 根目录必须是非空路径字符串",
    ["rust.cargo on target %s requires exactly one add_rustmanifest(\"<Cargo.toml>\") declaration; found %d"] =
        "目标 %s 的 rust.cargo 需要且只允许一个 add_rustmanifest(\"<Cargo.toml>\") 声明;实际有 %d 个",
    ["add_rustmanifest path on target %s must be a non-empty path string"] =
        "目标 %s 的 add_rustmanifest 路径必须是非空字符串",
    ["rust crate root %s does not exist; the crate root must be lib.rs directly under the add_rustfiles root and the Cargo manifest's [lib] path must point at it"] =
        "rust crate 根 %s 不存在;crate 根必须是 add_rustfiles 根目录正下方的 lib.rs,且 Cargo 清单的 [lib] path 必须指向它",
    ["no usable MinGW host GCC; skipping the Cargo [host] linker override (only build scripts/proc-macros need it)"] =
        "没有可用的 MinGW 宿主 GCC;跳过 Cargo [host] 链接器覆盖(仅 build script/proc-macro 需要它)",
    ["could not decode %s JSON emitted by Cargo: %s"] =
        "无法解码 Cargo 输出的 %s JSON:%s",
    ["Rust dependency %s requests native linker inputs (%s); Cargo dependencies currently accept pure-Rust/no_std crates only because GCC owns the final link"] =
        "Rust 依赖 %s 请求了原生链接输入(%s);GCC 掌管最终链接,当前 Cargo 依赖只接收纯 Rust/no_std crate",
    ["Rust crate manifest does not exist: %s"] =
        "Rust crate 清单不存在:%s",
    ["project-local nightly Cargo is required to build the Rust crate; run `xmake toolchains install rust`"] =
        "构建 Rust crate 需要项目本地 nightly Cargo;请运行 `xmake toolchains install rust`",
    ["Cargo build succeeded but produced no staticlib artifact for %s"] =
        "Cargo 构建成功但没有为 %s 产出 staticlib 产物",
    ["compiling Rust crate"] =
        "正在编译 Rust crate",
    ["Rust link export cannot find target %s in this project"] =
        "Rust 链接导出在本项目中找不到目标 %s",
    ["Rust link export found no C++ objects on target %s"] =
        "Rust 链接导出在目标 %s 上没有发现 C++ 对象",
    ["Rust link export requires built C++ objects; run `xmake build %s` first (%d missing, e.g. %s)"] =
        "Rust 链接导出需要已构建的 C++ 对象;请先运行 `xmake build %s`(缺 %d 个,例如 %s)",
    ["Rust link export cannot find the project g++ linker driver: %s; run `xmake toolchains install %s`"] =
        "Rust 链接导出找不到项目 g++ 链接器驱动:%s;请运行 `xmake toolchains install %s`",
    ["exported C++ link contract for the Rust entry"] =
        "已导出 Rust 入口的 C++ 链接契约",
    ["unknown xmake rust action %s; available actions: export-link"] =
        "未知的 xmake rust 动作 %s;可用动作:export-link",
    ["checking Rust crate with clippy"] =
        "正在用 clippy 检查 Rust crate",
    ["refusing to replace Rust dependency object cache outside its owner: %s (owner %s)"] =
        "拒绝替换所有者目录之外的 Rust 依赖对象缓存:%s(所有者 %s)",
    ["rust crate validation failed:\n  %s"] = "rust crate 校验失败:\n  %s",

    -- source sync retries / revision identity
    ["git probe did not complete (failure or lost process-exit wakeup); retrying once: git %s"] =
        "git 短探针未完成(失败,或子进程退出通知丢失);重试一次:git %s",
    ["shallow GCC fetch exhausted on every transport; falling back to a heavy full-history fetch"] =
        "各种浅拉取方式均已用尽;回退到重量级的全历史拉取",
    ["GCC source checkout failed (attempt %d/%d); retrying after a short delay"] =
        "GCC 源码检出失败(第 %d/%d 次);稍后自动重试",
    ["GCC object batch %d/%d failed (attempt %d/%d); retrying after a short delay"] =
        "GCC 对象批次 %d/%d 失败(第 %d/%d 次);稍后自动重试",
    ["GCC object materialization completed with %d promised objects still missing"] =
        "GCC 对象物化完成,但仍缺 %d 个承诺对象",
    ["GCC checkout revision mismatch: expected %s, got %s"] =
        "GCC 检出修订不匹配:预期 %s,实际 %s",
    ["cached GCC source identity does not match its source stamp; resynchronizing %s"] =
        "缓存的 GCC 源码身份与其源码标记不符;正在重新同步 %s",

    -- patch framework (patches/shared.lua and family files)
    ["cannot apply %s: source file is missing: %s"] = "无法应用 %s:源文件缺失:%s",
    ["cannot apply %s: the pinned upstream anchor drifted in %s"] =
        "无法应用 %s:钉住的上游锚点在 %s 中已漂移",
    ["cannot apply %s: the upstream anchor is ambiguous in %s"] =
        "无法应用 %s:上游锚点在 %s 中存在歧义",
    ["cannot apply %s: an upstream file already exists with different content: %s"] =
        "无法应用 %s:上游已存在内容不同的文件:%s",
    ["this configuration overrides %s to %s, shadowing the project default %s -- the override lives in this config store only, so its siblings (the root, each lane under build/<plat>, the test subproject) may be building different sources; drop it with `xmake f --%s= -y` to follow the project default again"] =
        "当前配置把 %s 覆盖成了 %s,遮住项目默认值 %s——该覆盖只存在于这一份配置里,它的同伴(根配置、build/<plat> 下的每条 lane、测试子工程)可能在用不同的源码;若不是有意为之,用 `xmake f --%s= -y` 去掉覆盖,重新跟随项目默认值",
    ["no source patch stamp registered for profile '%s'"] =
        "源码档案 '%s' 没有登记补丁标记版本",
    ["cannot migrate %s: source file is missing: %s"] = "无法迁移 %s:源文件缺失:%s",
    ["cannot migrate %s: the project-owned patch is ambiguous in %s"] =
        "无法迁移 %s:项目所有的补丁在 %s 中存在歧义",
    ["cannot update %s: an unowned file exists at %s"] =
        "无法更新 %s:%s 处存在非本管理器所有的文件",

    -- WABT fork build
    ["CMake is required to build the GCC WebAssembly WABT fork"] =
        "构建 GCC WebAssembly 的 WABT fork 需要 CMake",
    ["WABT submodule third_party/picosha2 is still missing after sync: %s"] =
        "同步后 WABT 子模块 third_party/picosha2 仍然缺失:%s",
    ["WABT checkout revision mismatch: expected %s, got %s"] =
        "WABT 检出修订不匹配:预期 %s,实际 %s",
    ["WABT checkout did not contain CMakeLists.txt: %s"] =
        "WABT 检出内容不包含 CMakeLists.txt:%s",
    ["the pinned WABT fork checkout is missing %s (%s); the pin does not carry the fork's own changes"] =
        "钉住的 WABT fork 检出缺少 %s(%s);该 pin 未携带 fork 自身的改动",
    ["WABT build completed without producing wat2wasm: %s"] =
        "WABT 构建完成但未产出 wat2wasm:%s",
    ["discarding the WABT build directory: the build tool CMake recorded no longer exists (%s)"] =
        "丢弃 WABT 构建目录:CMake 记录的构建工具已不存在(%s)",
    ["a WebAssembly-compatible %s tool was not found; install LLVM tools"] =
        "未找到兼容 WebAssembly 的 %s 工具;请安装 LLVM 工具",

    -- experimental GCC WebAssembly install/smoke probes
    ["experimental GCC WebAssembly C compiler is not installed"] =
        "实验性 GCC WebAssembly C 编译器未安装",
    ["experimental GCC WebAssembly C++ compiler is not installed"] =
        "实验性 GCC WebAssembly C++ 编译器未安装",
    ["installed GCC WebAssembly archive tools are incomplete"] =
        "已安装的 GCC WebAssembly 归档工具不完整",
    ["expected exactly one installed GCC WebAssembly libgcc archive, found %d"] =
        "预期恰有一个已安装的 GCC WebAssembly libgcc 归档,实际 %d 个",
    ["expected exactly one installed libstdc++ std module source, found %d"] =
        "预期恰有一个已安装的 libstdc++ std 模块源文件,实际 %d 个",
    ["installed GCC WebAssembly freestanding libstdc++ archive was not found: %s"] =
        "未找到已安装的 GCC WebAssembly freestanding libstdc++ 归档:%s",
    ["installed GCC WebAssembly experimental libstdc++ archive was not found under: %s"] =
        "已安装的 GCC WebAssembly 实验性 libstdc++ 归档未在此目录下找到:%s",
    ["GCC WebAssembly smoke test only supports the emscripten target"] =
        "GCC WebAssembly 冒烟测试仅支持 emscripten 目标",
    ["GCC WebAssembly compiler did not produce an object file: %s"] =
        "GCC WebAssembly 编译器未产出对象文件:%s",
    ["GCC WebAssembly WAT did not contain ABI probe function: %s"] =
        "GCC WebAssembly WAT 中没有 ABI 探针函数:%s",
    ["GCC WebAssembly WAT function signature was not terminated as expected: %s"] =
        "GCC WebAssembly WAT 函数签名未按预期终止:%s",
    ["GCC WebAssembly Basic C ABI signature mismatch for %s: expected %s, got %s"] =
        "GCC WebAssembly Basic C ABI 签名不匹配(%s):预期 %s,实际 %s",
    ["GCC WebAssembly WAT did not contain __int128 truncation probe: %s"] =
        "GCC WebAssembly WAT 中没有 __int128 截断探针:%s",
    ["GCC WebAssembly WAT did not terminate __int128 truncation probe: %s"] =
        "GCC WebAssembly WAT 未正常终止 __int128 截断探针:%s",
    ["GCC WebAssembly __int128 truncation probe did not lower through i32.wrap_i64: %s"] =
        "GCC WebAssembly __int128 截断探针未经 i32.wrap_i64 降级:%s",
    ["GCC WebAssembly atomic compare-exchange probe regressed to the libatomic import call"] =
        "GCC WebAssembly 原子比较交换探针回退成了 libatomic 导入调用",
    ["GCC WebAssembly atomic compare-exchange probe did not lower to the native cmpxchg instruction"] =
        "GCC WebAssembly 原子比较交换探针未下降为原生 cmpxchg 指令",
    ["GCC WebAssembly C++ __int128 ABI probe did not exercise an indirect call"] =
        "GCC WebAssembly C++ __int128 ABI 探针未覆盖间接调用",
    ["GCC WebAssembly __int128 runtime probe did not emit expected libcall: %s"] =
        "GCC WebAssembly __int128 运行时探针未生成预期 libcall:%s",
    ["GCC WebAssembly __int128 runtime probe leaked canonical Emscripten/Rust libcall name: %s"] =
        "GCC WebAssembly __int128 运行时探针泄漏了 Emscripten/Rust 规范 libcall 名:%s",
    ["GCC WebAssembly GC-rooted libcall probe did not emit __gnu_udivti3"] =
        "GCC WebAssembly GC 根锚定 libcall 探针未生成 __gnu_udivti3",
    ["emcc and its initialized sysroot are required for the hosted GCC WebAssembly runtime smoke"] =
        "hosted GCC WebAssembly 运行时冒烟需要 emcc 及其已初始化的 sysroot",
    ["running experimental GCC WebAssembly C/C++ runtime smoke tests"] =
        "正在运行实验性 GCC WebAssembly C/C++ 运行时冒烟测试",
    ["preparing experimental GCC WebAssembly assembler and linker"] =
        "正在准备实验性 GCC WebAssembly 汇编器与链接器",

    -- Mach-O cross tool family and static smoke (macosx provider)
    ["preparing Mach-O cross linker and binary tools"] =
        "正在准备 Mach-O 交叉链接器与二进制工具",
    ["no host C compiler was found to build the Mach-O tool shim: %s"] =
        "未找到用于构建 Mach-O 工具 shim 的宿主 C 编译器:%s",
    ["a Mach-O capable %s tool was not found (%s); install the managed Emscripten toolset or a host LLVM"] =
        "未找到支持 Mach-O 的 %s 工具(%s);请安装受管 Emscripten 工具集或宿主 LLVM",
    ["no LLD darwin linker (ld64.lld) was found; install the managed Emscripten toolset or a host LLVM"] =
        "未找到 LLD darwin 链接器(ld64.lld);请安装受管 Emscripten 工具集或宿主 LLVM",
    ["no host clang with the %s backend was found for the Apple assembler wrapper; install an LLVM whose `clang -print-targets` lists %s"] =
        "未找到带 %s 后端的宿主 clang 用作 Apple 汇编器包装;请安装 `clang -print-targets` 中列出 %s 的 LLVM",
    ["managed Emscripten toolset install failed; falling back to host LLVM tools from PATH for the Mach-O tool family: %s"] =
        "受管 Emscripten 工具集安装失败;Mach-O 工具族回退到 PATH 中的宿主 LLVM 工具:%s",
    ["the macOS cross compilers are not installed; run `xmake toolchains install macosx` first"] =
        "macOS 交叉编译器未安装;请先运行 `xmake toolchains install macosx`",
    ["running Mach-O cross-compile static smoke"] = "正在运行 Mach-O 交叉编译静态冒烟",
    ["running Mach-O link smoke (executable + dylib static assertions)"] =
        "正在运行 Mach-O 链接冒烟(可执行文件 + dylib 静态断言)",
    ["no Mach-O inspection tool (llvm-readobj or otool) was found for the smoke assertions"] =
        "未找到用于冒烟断言的 Mach-O 检查工具(llvm-readobj 或 otool)",
    ["no Mach-O symbol lister (llvm-nm or nm) was found for the smoke assertions"] =
        "未找到用于冒烟断言的 Mach-O 符号列举工具(llvm-nm 或 nm)",
    ["could not inspect the Mach-O smoke artifact: %s"] = "无法检查 Mach-O 冒烟产物:%s",
    ["Mach-O smoke artifact has the wrong container format: %s"] =
        "Mach-O 冒烟产物的容器格式错误:%s",
    ["Mach-O smoke artifact has file type other than %s: %s"] =
        "Mach-O 冒烟产物的文件类型不是 %s:%s",
    ["Mach-O smoke artifact is not arm64: %s"] = "Mach-O 冒烟产物不是 arm64:%s",
    ["expected Mach-O symbol %s was not found in %s"] =
        "预期的 Mach-O 符号 %s 未在 %s 中找到",

    -- linux provider
    ["replacing the absolute musl loader symlink with a sysroot-local copy: %s"] =
        "正在把绝对路径的 musl loader 符号链接替换为 sysroot 本地副本:%s",
    ["could not remove the musl loader symlink; refusing to copy through it: %s"] =
        "无法移除 musl loader 符号链接;拒绝穿透其写入:%s",
    ["install stamp predates the current provider identity keys; adopting the current identity so drift detection starts now: %s"] =
        "安装 stamp 早于当前 provider 身份键;采纳当前身份,漂移检测自此生效:%s",
    ["existing toolchain stamp has no recorded source identity (%s); treating it as out of date and rebuilding once to establish one"] =
        "既有工具链 stamp 未记录源码身份(%s);按过期处理,重建一次以建立身份记录",
    ["removed stale cross-plat C++ module caches (reusing them across a plat switch fails with \"Unknown Error (3)\"; the affected plat re-scans on its next build): %s"] =
        "已移除陈旧的跨 plat C++ 模块缓存(跨 plat 切换复用它们会以「Unknown Error (3)」失败;受影响的 plat 在下次构建时重新扫描):%s",
    ["discarded C++ module cache generated by a different compiler frontend: %s"] =
        "检测到 C++ 编译器前端身份变化,已丢弃其生成的模块缓存:%s",
    ["discarded %d stale GCC module mapper file(s) for build root %s"] =
        "已丢弃 %d 个属于构建根目录 %s 的陈旧 GCC 模块映射文件",
    ["normalized %d relative C++ module cache path(s) for target %s"] =
        "已归一化 %d 个相对 C++ 模块缓存路径(目标:%s)",
    ["stale C++ module files generated by a different compiler frontend could not be removed; stop other xmake processes and delete them before retrying: %s"] =
        "无法移除由其他 C++ 编译器前端生成的陈旧模块文件;请停止其他 xmake 进程并删除这些文件后重试:%s",
    ["stale GCC module mapper files could not be removed; stop other xmake processes and retry: %s"] =
        "无法移除陈旧的 GCC 模块映射文件;请停止其他 xmake 进程后重试:%s",
    ["stale cross-plat C++ module caches could not be fully removed (files may be locked); delete them manually before building, or run a clean `xmake f -c` + full rebuild: %s"] =
        "陈旧的跨 plat C++ 模块缓存未能完全移除(文件可能被占用);请在构建前手动删除,或执行干净的 `xmake f -c` + 全量重建:%s",
    ["Apple project builds need the configured arch to match the managed toolchain arch %s, but the configuration says %s; rerun the full configure: xmake f -p %s -a arm64 -m <mode>"] =
        "Apple 工程构建要求配置的 arch 与受管工具链 arch %s 一致,但当前配置为 %s;请重新执行完整配置:xmake f -p %s -a arm64 -m <模式>",

    -- toolchain commands and feature settings
    ["the selected GCC source profile does not support target %s"] =
        "所选 GCC 源码 profile 不支持目标 %s",
    ["the smoke toolchain command currently supports only targets with dedicated smoke hooks: emscripten, macosx"] =
        "smoke 命令目前仅支持带专用冒烟钩子的目标:emscripten、macosx",
    ["GCC features are xmake.lua/config settings, not a toolchains command; run `xmake toolchains help features`"] =
        "GCC 特性是 xmake.lua/配置设置,不是 toolchains 命令;请运行 `xmake toolchains help features`",
    ["unknown managed GCC feature: %s"] = "未知的受管 GCC 特性:%s",
    ["unknown toolchains command for help: %s"] = "help 未知的 toolchains 命令:%s",

    -- rust toolchain / crates / wasm runtime
    ["bootstrapping missing project-local Rust toolchain"] =
        "正在自举缺失的项目本地 Rust 工具链",
    ["project-local Rust toolchain is not installed; run `xmake toolchains install rust`"] =
        "项目本地 Rust 工具链未安装;请运行 `xmake toolchains install rust`",
    ["Rust toolchain install finished but Cargo is still missing: %s"] =
        "Rust 工具链安装已完成,但 Cargo 仍缺失:%s",
    ["project-local nightly Cargo is required to build the threaded Rust WebAssembly runtime; run `xmake toolchains install rust`"] =
        "构建带线程的 Rust WebAssembly 运行时需要项目本地 nightly Cargo;请运行 `xmake toolchains install rust`",
    ["rust-src is required to build the threaded Rust WebAssembly runtime; run `xmake toolchains install rust`"] =
        "构建带线程的 Rust WebAssembly 运行时需要 rust-src;请运行 `xmake toolchains install rust`",
    ["no usable MinGW host GCC for Cargo build-std; run `xmake toolchains install windows` or install a real MinGW GCC (a PATH shim that cannot locate its libgcc.a is rejected)"] =
        "没有可用于 Cargo build-std 的 MinGW 宿主 GCC;请运行 `xmake toolchains install windows` 或安装真实的 MinGW GCC(定位不了自身 libgcc.a 的 PATH 垫片会被拒绝)",
    ["Rust WebAssembly atomic runtime expected one lib%s rlib under %s, found %d"] =
        "Rust WebAssembly 原子运行时预期 lib%s rlib 在 %s 下恰有一个,实际找到 %d 个",
    ["refusing to remove %s outside its owning directory: %s (owner %s)"] =
        "拒绝移除所属目录之外的 %s:%s(所有者 %s)",
    ["cannot inject Rust objects: target archive does not exist: %s"] =
        "无法注入 Rust 对象:目标静态库不存在:%s",
    ["no Unix-compatible archiver for the Rust objects on target %s (the MSVC link/lib fallback cannot process GNU archives); install the project GCC toolchain: `xmake toolchains install %s`"] =
        "目标 %s 上没有 Unix 兼容的归档器可处理 Rust 对象(MSVC link/lib 回退无法处理 GNU 归档);请安装项目 GCC 工具链:`xmake toolchains install %s`",
    ["cannot read ar archive: %s"] =
        "无法读取 ar 归档:%s",
    ["thin ar archives are not supported for Rust staticlib absorption: %s"] =
        "Rust staticlib 吸收不支持 thin ar 归档:%s",
    ["not an ar archive (bad global magic): %s"] =
        "不是 ar 归档(全局魔数损坏):%s",
    ["corrupt ar member header at byte %d: %s"] =
        "第 %d 字节处的 ar 成员头损坏:%s",
    ["truncated ar member at byte %d: %s"] =
        "第 %d 字节处的 ar 成员被截断:%s",
    ["ar long-name reference %s has no name table entry: %s"] =
        "ar 长名引用 %s 没有对应的名字表条目:%s",
    ["Rust staticlib contains no object members to absorb: %s"] =
        "Rust staticlib 中没有可吸收的对象成员:%s",

    -- preflight guidance (warnings/actions/titles routed through errors.format)
    ["Windows host MinGW settings are incomplete"] = "Windows 宿主 MinGW 设置不完整",
    ["Linux target sysroot settings are incomplete"] = "Linux 目标 sysroot 设置不完整",
    ["Android toolchain settings are incomplete"] = "Android 工具链设置不完整",
    ["macOS target settings are incomplete"] = "macOS 目标设置不完整",
    ["iOS target settings are incomplete"] = "iOS 目标设置不完整",
    ["experimental GCC WebAssembly prerequisites are incomplete"] =
        "实验性 GCC WebAssembly 先决条件不完整",
    ["The host GCC does not expose a usable MinGW-w64 sysroot."] =
        "宿主 GCC 未暴露可用的 MinGW-w64 sysroot。",
    ["Keep the default --toolchains_bootstrap=auto so xmake can fetch a temporary latest w64devkit bootstrap toolchain."] =
        "保持默认 --toolchains_bootstrap=auto,让 xmake 拉取临时的最新 w64devkit 自举工具链。",
    ["Or use a MinGW-w64 distribution with headers, libraries, and POSIX build tools in PATH, such as MSYS2 UCRT64 or w64devkit."] =
        "或使用 PATH 中带头文件、库与 POSIX 构建工具的 MinGW-w64 发行版,例如 MSYS2 UCRT64 或 w64devkit。",
    ["Set --toolchains_bootstrap_path=<path> to an existing portable MinGW root/bin directory, or --toolchains_bootstrap=none to require a system toolchain."] =
        "将 --toolchains_bootstrap_path=<path> 指向既有便携 MinGW 根/bin 目录,或用 --toolchains_bootstrap=none 强制要求系统工具链。",
    ["A bare gcc.exe is not enough for a native Windows GCC bootstrap."] =
        "仅有 gcc.exe 不足以完成本机 Windows GCC 自举。",
    ["Then rerun plain `xmake` or `xmake toolchains install windows`."] =
        "然后重跑普通 `xmake` 或 `xmake toolchains install windows`。",
    ["GNU/Linux cross target is selected, but linux_sysroot is not configured."] =
        "已选择 GNU/Linux 交叉目标,但未配置 linux_sysroot。",
    ["linux_sysroot does not exist or is not a directory: %s"] =
        "linux_sysroot 不存在或不是目录:%s",
    ["linux_sysroot does not contain usable C headers: %s"] =
        "linux_sysroot 中没有可用的 C 头文件:%s",
    ["linux_sysroot does not contain libc.so or libc.a: %s"] =
        "linux_sysroot 中没有 libc.so 或 libc.a:%s",
    ["For a project-managed Linux cross runtime, use: xmake f -p linux -a <arch> --linux_libc=musl"] =
        "使用项目受管 Linux 交叉运行时:xmake f -p linux -a <arch> --linux_libc=musl",
    ["For GNU/glibc targets, set a complete sysroot: xmake f -p linux -a <arch> --linux_libc=gnu --linux_sysroot=<sysroot>"] =
        "GNU/glibc 目标需设置完整 sysroot:xmake f -p linux -a <arch> --linux_libc=gnu --linux_sysroot=<sysroot>",
    ["The GNU sysroot must contain C headers and libc, for example usr/include/stdio.h and libc.so or libc.a."] =
        "GNU sysroot 必须包含 C 头文件与 libc,例如 usr/include/stdio.h 与 libc.so 或 libc.a。",
    ["linux_libc=gnu without linux_sysroot selects the project-managed glibc sysroot, which is only built on Linux hosts (current host: %s)."] =
        "linux_libc=gnu 且未设 linux_sysroot 时选择项目受管 glibc sysroot,它仅能在 Linux 宿主上构建(当前宿主:%s)。",
    ["Use the project-managed musl runtime instead: xmake f -p linux -a <arch> --linux_libc=musl"] =
        "改用项目受管 musl 运行时:xmake f -p linux -a <arch> --linux_libc=musl",
    ["Or point linux_sysroot at an existing glibc sysroot: xmake f -p linux -a <arch> --linux_libc=gnu --linux_sysroot=<sysroot>"] =
        "或将 linux_sysroot 指向既有 glibc sysroot:xmake f -p linux -a <arch> --linux_libc=gnu --linux_sysroot=<sysroot>",
    ["Or run `xmake toolchains install linux` on a Linux host to build the managed glibc sysroot, copy it over, and set --linux_sysroot to the copy."] =
        "或在 Linux 宿主上运行 `xmake toolchains install linux` 构建受管 glibc sysroot,拷贝过来后把 --linux_sysroot 指向该副本。",
    ["Supported managed glibc versions: %s (set with `xmake f --linux_glibc_version=<version>`)."] =
        "受支持的受管 glibc 版本:%s(用 `xmake f --linux_glibc_version=<version>` 设置)。",
    ["the managed glibc sysroot build needs host tools that are missing from PATH: %s"] =
        "构建受管 glibc sysroot 需要的宿主工具在 PATH 中缺失:%s",
    ["Install the missing tools with the distribution package manager, then rerun the same xmake command."] =
        "用发行版包管理器安装缺失工具,然后重跑同一条 xmake 命令。",
    ["Set an NDK explicitly: xmake f -p android -a arm64-v8a --android_ndk=<ndk-root> --android_api=26"] =
        "显式设置 NDK:xmake f -p android -a arm64-v8a --android_ndk=<ndk-root> --android_api=26",
    ["Or export ANDROID_NDK_HOME/ANDROID_NDK_ROOT/NDK_HOME before running xmake."] =
        "或在运行 xmake 前导出 ANDROID_NDK_HOME/ANDROID_NDK_ROOT/NDK_HOME。",
    ["Or install one into the Android SDK: xmake android ndk install r27c (SDK-installed NDKs are discovered automatically)."] =
        "或安装一个进 Android SDK:xmake android ndk install r27c(SDK 内安装的 NDK 会被自动发现)。",
    ["Run `xmake toolchains status android` to re-check the detected paths."] =
        "运行 `xmake toolchains status android` 复查探测到的路径。",
    ["android_api is not numeric: %s"] = "android_api 不是数字:%s",
    ["android_api=%s is too old for the managed Android libstdc++/<meta> runtime; use 26 or newer."] =
        "android_api=%s 对受管 Android libstdc++/<meta> 运行时来说过旧;请使用 26 或更新。",
    ["Android NDK is not configured. The manager cannot provide Android headers, libc stubs, or ld.lld without it."] =
        "未配置 Android NDK。缺少它,本管理器无法提供 Android 头文件、libc 桩库或 ld.lld。",
    ["No Android NDK prebuilt host tag is known for this host: %s"] =
        "此宿主没有已知的 Android NDK 预编译 host tag:%s",
    ["The Android NDK does not contain the expected LLVM prebuilt directory: toolchains/llvm/prebuilt/%s"] =
        "Android NDK 中没有预期的 LLVM 预编译目录:toolchains/llvm/prebuilt/%s",
    ["The Android NDK LLVM bin directory was not found under: %s"] =
        "在 %s 下未找到 Android NDK 的 LLVM bin 目录",
    ["The Android NDK linker ld.lld was not found in: %s"] =
        "在 %s 中未找到 Android NDK 链接器 ld.lld",
    ["The Android NDK sysroot was not found under: %s"] =
        "在 %s 下未找到 Android NDK sysroot",
    ["The Android NDK common include directory is missing: %s"] =
        "Android NDK 公共 include 目录缺失:%s",
    ["The Android NDK target include directory is missing for %s."] =
        "%s 的 Android NDK 目标 include 目录缺失。",
    ["The Android NDK target library root is missing for %s."] =
        "%s 的 Android NDK 目标库根目录缺失。",
    ["The Android NDK does not provide stub libraries for android_api=%s at: %s"] =
        "Android NDK 未提供 android_api=%s 的桩库,期望位置:%s",
    ["Build macOS targets from a macOS host with Apple Command Line Tools installed."] =
        "从装有 Apple Command Line Tools 的 macOS 宿主构建 macOS 目标。",
    ["Check the SDK with: xcrun --sdk macosx --show-sdk-path"] =
        "用命令检查 SDK:xcrun --sdk macosx --show-sdk-path",
    ["Darwin Arm64 automatically uses the project Darwin Arm64 GCC source profile; inspect it with `xmake toolchains status macosx`."] =
        "Darwin Arm64 自动使用项目 Darwin Arm64 GCC 源码 profile;用 `xmake toolchains status macosx` 查看。",
    ["Apple macOS SDK was not found through xcrun."] = "经 xcrun 未找到 Apple macOS SDK。",
    ["The selected GCC source profile does not support the macOS target: %s"] =
        "所选 GCC 源码 profile 不支持 macOS 目标:%s",
    ["macOS targets are aarch64-only in this manager (darwin-arm64 profile); the overridden target %s selects an unvalidated configuration."] =
        "本管理器的 macOS 目标仅支持 aarch64(darwin-arm64 profile);覆盖后的目标 %s 选择了未实证的形态。",
    ["Provide a macOS SDK copied from your own Mac via --apple_sdk=<path> or APPLE_SDK; Apple's license terms do not allow this manager to download one."] =
        "经 --apple_sdk=<path> 或 APPLE_SDK 提供从你自己的 Mac 拷贝的 macOS SDK;Apple 许可条款不允许本管理器代为下载。",
    ["Copy the SDK with symlinks materialized, e.g. on the Mac: tar -C \"$(dirname \"$(xcrun --sdk macosx --show-sdk-path)\")\" -chzf MacOSX.sdk.tar.gz MacOSX.sdk"] =
        "拷贝 SDK 时需物化符号链接,例如在 Mac 上:tar -C \"$(dirname \"$(xcrun --sdk macosx --show-sdk-path)\")\" -chzf MacOSX.sdk.tar.gz MacOSX.sdk",
    ["The ld64.lld linker and the llvm-ar/ranlib/strip/nm family come from the managed Emscripten toolset (installed automatically on demand) or a host LLVM install."] =
        "ld64.lld 链接器与 llvm-ar/ranlib/strip/nm 工具族来自受管 Emscripten 工具集(按需自动安装)或宿主 LLVM 安装。",
    ["The arm64 assembler wraps a host clang: install an LLVM whose `clang -print-targets` lists aarch64 (the managed Emscripten clang has no AArch64 backend)."] =
        "arm64 汇编器包装宿主 clang:请安装 `clang -print-targets` 中列出 aarch64 的 LLVM(受管 Emscripten 的 clang 没有 AArch64 后端)。",
    ["Run `xmake toolchains status macosx` to inspect every detected path."] =
        "运行 `xmake toolchains status macosx` 查看全部探测到的路径。",
    ["No Apple macOS SDK is configured; pass --apple_sdk=<path> or set APPLE_SDK to a MacOSX.sdk copied from your own Mac."] =
        "未配置 Apple macOS SDK;请传 --apple_sdk=<path> 或将 APPLE_SDK 指向从你自己的 Mac 拷贝的 MacOSX.sdk。",
    ["the configured Apple SDK root does not exist: %s"] =
        "配置的 Apple SDK 根目录不存在:%s",
    ["the Apple SDK has no SDKSettings.plist/SDKSettings.json; point --apple_sdk at the MacOSX.sdk root itself: %s"] =
        "Apple SDK 中没有 SDKSettings.plist/SDKSettings.json;请把 --apple_sdk 指向 MacOSX.sdk 根目录本身:%s",
    ["the Apple SDK is missing usr/include/stdio.h; copy the SDK with symlinks materialized (tar -h) so the header tree is complete: %s"] =
        "Apple SDK 缺少 usr/include/stdio.h;拷贝时请物化符号链接(tar -h)保证头文件树完整:%s",
    ["the Apple SDK is missing usr/lib/libSystem.tbd; the darwin linker needs the SDK's text-based stub libraries: %s"] =
        "Apple SDK 缺少 usr/lib/libSystem.tbd;darwin 链接器需要 SDK 的文本桩库:%s",
    ["the Apple SDK is missing System/Library/Frameworks/CoreFoundation.framework; the framework tree looks incomplete: %s"] =
        "Apple SDK 缺少 System/Library/Frameworks/CoreFoundation.framework;framework 树看起来不完整:%s",
    ["The LLD darwin linker (ld64.lld) was not found: the managed Emscripten toolset is missing and PATH provides no lld."] =
        "未找到 LLD darwin 链接器(ld64.lld):受管 Emscripten 工具集缺失且 PATH 未提供 lld。",
    ["Required Mach-O binary tool was not found: %s"] =
        "未找到必需的 Mach-O 二进制工具:%s",
    ["No host clang with the %s backend was found; the Apple assembler tier needs an LLVM whose `clang -print-targets` lists %s."] =
        "未找到带 %s 后端的宿主 clang;Apple 汇编器层需要 `clang -print-targets` 中列出 %s 的 LLVM。",
    ["Required Apple command-line tool was not found in PATH: %s"] =
        "PATH 中未找到必需的 Apple 命令行工具:%s",
    ["Build iOS targets from a macOS host with Xcode (the iPhoneOS SDK) installed."] =
        "从装有 Xcode(含 iPhoneOS SDK)的 macOS 宿主构建 iOS 目标。",
    ["Check the SDK with: xcrun --sdk iphoneos --show-sdk-path (this manager retries with DEVELOPER_DIR=%s when xcode-select points at the Command Line Tools)."] =
        "用命令检查 SDK:xcrun --sdk iphoneos --show-sdk-path(当 xcode-select 指向 Command Line Tools 时,本管理器会以 DEVELOPER_DIR=%s 重试)。",
    ["iOS shares the project Darwin Arm64 GCC source profile; inspect it with `xmake toolchains status ios`."] =
        "iOS 共享项目 Darwin Arm64 GCC 源码 profile;用 `xmake toolchains status ios` 查看。",
    ["The selected GCC source profile does not support the iOS target: %s"] =
        "所选 GCC 源码 profile 不支持 iOS 目标:%s",
    ["iOS device targets are aarch64-only (phase E1); the configured arch %s selects a GCC source profile without iOS support."] =
        "iOS 真机目标仅支持 aarch64(阶段 E1);配置的 arch %s 选择了不含 iOS 支持的 GCC 源码 profile。",
    ["iOS simulator triplets are not supported yet (phase E2): %s"] =
        "iOS 模拟器三元组尚未支持(阶段 E2):%s",
    ["iOS target builds currently need a macOS host with Xcode and the Apple command-line tools; building from a %s host waits for the shared Mach-O tool family (phase C2)."] =
        "iOS 目标构建目前需要装有 Xcode 与 Apple 命令行工具的 macOS 宿主;从 %s 宿主构建有待共享 Mach-O 工具族(阶段 C2)。",
    ["Apple iPhoneOS SDK was not found (checked --ios_sdk/IOS_SDK and xcrun --sdk iphoneos, including the Xcode.app DEVELOPER_DIR retry)."] =
        "未找到 Apple iPhoneOS SDK(已检查 --ios_sdk/IOS_SDK 与 xcrun --sdk iphoneos,含 Xcode.app DEVELOPER_DIR 重试)。",
    ["Install CMake and a native C++ compiler to build the pinned WABT fork."] =
        "安装 CMake 与本机 C++ 编译器以构建钉住的 WABT fork。",
    ["The pinned Emscripten toolset (emcc, LLVM binary tools, Node.js) installs automatically under .toolchains; fix any reported download failure and rerun, or seed the pinned archives into .toolchains/.cache/<host>/downloads."] =
        "钉住的 Emscripten 工具集(emcc、LLVM 二进制工具、Node.js)会自动安装到 .toolchains 下;修复报告的下载失败后重跑,或把钉住归档播种到 .toolchains/.cache/<host>/downloads。",
    ["Override single tools with --emscripten_emcc=<path>, --wasm_ld=<path>, or --wasm_node=<path> only when a non-managed install must be used."] =
        "仅在必须使用非受管安装时,用 --emscripten_emcc=<path>、--wasm_ld=<path> 或 --wasm_node=<path> 覆盖单个工具。",
    ["Run `xmake toolchains status emscripten` to inspect every detected path."] =
        "运行 `xmake toolchains status emscripten` 查看全部探测到的路径。",
    ["Required GCC WebAssembly build tool was not found in PATH: %s"] =
        "PATH 中未找到必需的 GCC WebAssembly 构建工具:%s",
    ["python3 was not found in PATH; emcc needs a host python3 on this platform."] =
        "PATH 中未找到 python3;此平台上 emcc 需要宿主 python3。",
    ["Required WebAssembly binary tool was not found: %s"] =
        "未找到必需的 WebAssembly 二进制工具:%s",
    ["Node.js was not found: the managed Emscripten toolset is missing and neither --wasm_node nor PATH provides node."] =
        "未找到 Node.js:受管 Emscripten 工具集缺失,且 --wasm_node 与 PATH 均未提供 node。",
    ["emcc was not found: the managed Emscripten toolset is missing and neither --emscripten_emcc nor PATH provides emcc."] =
        "未找到 emcc:受管 Emscripten 工具集缺失,且 --emscripten_emcc 与 PATH 均未提供 emcc。",
    ["the emcc sysroot is incomplete or missing pthread.h; initialize the Emscripten system cache."] =
        "emcc sysroot 不完整或缺少 pthread.h;请初始化 Emscripten 系统缓存。",

    -- toolchains help: frame labels
    ["commands:"] = "命令:",
    ["subjects:"] = "对象:",
    ["options:"] = "选项:",
    ["configuration:"] = "配置:",
    ["common xmake options:"] = "常用 xmake 选项:",
    ["xmake.lua helpers:"] = "xmake.lua 辅助接口:",
    ["groups:"] = "特性组:",
    ["features:"] = "特性:",
    ["aliases: %s"] = "别名:%s",
    ["(aliases: %s)"] = "(别名:%s)",
    ["Manage the project-local GCC toolchains (mainline, Darwin arm64, and experimental wasm source profiles)."] =
        "管理项目本地 GCC 工具链(mainline、Darwin arm64 与实验性 wasm 三个源码 profile)。",
    ["Use `xmake toolchains help <command>` for command-specific help."] =
        "运行 `xmake toolchains help <command>` 查看单条命令的帮助。",
    ["These are xmake configuration options, not `xmake toolchains` positional arguments."] =
        "这些是 xmake 配置选项,不是 `xmake toolchains` 的位置参数。",
    ["Set them with `xmake f --name=value`, then run `xmake toolchains ...` or plain `xmake`."] =
        "用 `xmake f --name=value` 设置后,再运行 `xmake toolchains ...` 或普通 `xmake`。",
    ["Allow toolchains.auto to install project-local GCC toolsets."] =
        "允许 toolchains.auto 安装项目本地 GCC 工具集。",
    ["Bypass GCC auto toolset setup and gcc.features."] =
        "绕开 GCC 自动工具集接线与 gcc.features。",
    ["Select xmake platform, for example mingw, linux, or android."] =
        "选择 xmake 平台,例如 mingw、linux 或 android。",
    ["Select target architecture when needed."] = "按需选择目标架构。",
    ["Set manager options with `xmake f --name=value`."] =
        "用 `xmake f --name=value` 设置管理器选项。",
    ["Run `xmake toolchains help options` for the full --option list."] =
        "运行 `xmake toolchains help options` 查看完整 --option 列表。",
    ["Run `xmake toolchains help options` for --option=value settings."] =
        "运行 `xmake toolchains help options` 查看 --option=value 设置。",
    ["Compiler-build defaults are release, optimized, debug-info off, and strip on."] =
        "编译器构建默认为 release、开优化、关调试信息、开 strip。",
    ["Tune them with --toolchains_build_type/optimize/debug/cflags/cxxflags/ldflags and --toolchains_strip."] =
        "用 --toolchains_build_type/optimize/debug/cflags/cxxflags/ldflags 与 --toolchains_strip 调节。",
    ["On Windows, missing host MinGW tools are bootstrapped from latest w64devkit unless toolchains_bootstrap says otherwise."] =
        "Windows 上缺失的宿主 MinGW 工具默认从最新 w64devkit 自举,除非 toolchains_bootstrap 另有指定。",
    [".toolchains uses .cache plus host folders such as windows/linux/android/macosx."] =
        ".toolchains 由 .cache 加 windows/linux/android/macosx 等宿主文件夹组成。",
    ["Installed compilers live in .toolchains/<host>/<target>/<arch>."] =
        "已安装编译器位于 .toolchains/<host>/<target>/<arch>。",
    ["Plain `xmake` bootstraps the selected project-local GCC toolchain when toolchains_auto is enabled."] =
        "toolchains_auto 开启时,普通 `xmake` 会自举所选的项目本地 GCC 工具链。",
    ["toolchains.auto points target toolsets to .toolchains/<host>/<target>/<arch>/bin."] =
        "toolchains.auto 把目标工具集指向 .toolchains/<host>/<target>/<arch>/bin。",
    ["gcc/mingw toolchains automatically get gcc.features=all."] =
        "gcc/mingw 工具链自动获得 gcc.features=all。",
    ["add_gcc_features(...) and set_gcc_features(...) append/replace per-target GCC feature settings."] =
        "add_gcc_features(...) 与 set_gcc_features(...) 追加/替换按目标的 GCC 特性设置。",
    ["xmake f --gcc_features=... appends project-wide GCC feature settings."] =
        "xmake f --gcc_features=... 追加项目级 GCC 特性设置。",

    -- toolchains help: subjects
    ["windows   manage the Windows target compiler for the current host"] =
        "windows   管理当前宿主的 Windows 目标编译器",
    ["linux     manage the Linux target compiler for the current host"] =
        "linux     管理当前宿主的 Linux 目标编译器",
    ["android   manage the Android target compiler for the current host"] =
        "android   管理当前宿主的 Android 目标编译器",
    ["macosx    manage the macOS target compiler for the current host"] =
        "macosx    管理当前宿主的 macOS 目标编译器",
    ["ios       manage the iOS target compiler for the current host"] =
        "ios       管理当前宿主的 iOS 目标编译器",
    ["emscripten manage the experimental GCC WebAssembly C/C++ toolchain"] =
        "emscripten 管理实验性 GCC WebAssembly C/C++ 工具链",
    ["host      alias for the current host target"] =
        "host      当前宿主目标的别名",

    -- toolchains help: command summaries
    ["Show toolchain manager help."] = "显示工具链管理器帮助。",
    ["Print paths, target triplet, installation state, source URL, and proxy state."] =
        "打印路径、目标三元组、安装状态、源码 URL 与代理状态。",
    ["Print a one-line-per-target overview of every managed toolchain on this host."] =
        "以每目标一行的形式总览本宿主上的全部受管工具链。",
    ["Clone, fetch, or reuse the GCC source profile selected for the subject target."] =
        "克隆、拉取或复用对象目标所选的 GCC 源码 profile。",
    ["Ensure the project-local GCC toolchain is installed for the selected target."] =
        "确保所选目标的项目本地 GCC 工具链已安装。",
    ["List pinned-digest coverage and this host's trust-on-first-use records."] =
        "列出钉住摘要的覆盖情况与本宿主的首次信任(TOFU)记录。",
    ["Pin the current plat/arch/mode; any later drift warns on every configure."] =
        "钉住当前 plat/arch/mode;之后任何漂移都会在每次配置时告警。",
    ["Refresh the selected GCC source profile and rebuild an already installed selected toolchain."] =
        "刷新所选 GCC 源码 profile,并重建已安装的所选工具链。",
    ["Create an offline git bundle of the synced GCC source profile."] =
        "为已同步的 GCC 源码 profile 制作离线 git bundle。",
    ["Compatibility alias for installing a project-local toolchain."] =
        "安装项目本地工具链的兼容别名。",
    ["Compile, link, and statically assert the target-specific toolchain capability probes."] =
        "编译、链接并静态断言目标专属的工具链能力探针。",
    ["Discard the cached GCC build directory and recompile the toolchain from source."] =
        "丢弃缓存的 GCC 构建目录,从源码重新编译工具链。",

    -- toolchains help: command details
    ["Without a command, prints the command list."] = "不带命令时打印命令列表。",
    ["With a command, prints command-specific usage and behavior."] =
        "带命令时打印该命令的用法与行为。",
    ["Use `xmake toolchains help options` to list xmake configuration options that start with --."] =
        "用 `xmake toolchains help options` 列出以 -- 开头的 xmake 配置选项。",
    ["Use `xmake toolchains help features` to list the managed GCC feature switches and groups."] =
        "用 `xmake toolchains help features` 列出受管 GCC 特性开关与分组。",
    ["`xmake toolchains --help` and `xmake toolchains -h` are accepted as help aliases when passed through by xmake."] =
        "xmake 透传时,`xmake toolchains --help` 与 `xmake toolchains -h` 也作为帮助别名接受。",
    ["This command is read-only."] = "此命令只读。",
    ["If no subject is provided, it uses xmake's configured platform."] =
        "未给对象时使用 xmake 已配置的平台。",
    ["This command is read-only: its probes never download, configure, or build anything."] =
        "此命令只读:其探针从不下载、配置或构建任何东西。",
    ["Without a subject it prints every target OS row plus a rust summary row; with one it prints that row only."] =
        "不带对象时打印全部目标 OS 行外加一行 rust 摘要;带对象时只打印该行。",
    ["Columns: triplet/arch (as configured), source profile and pinned ref, source synced, toolchain installed, smoke state (emscripten backend smoke and macosx cross Mach-O smoke; other targets use the engine test suites), verified (static registry of real-machine build+smoke evidence for this host), and the first missing prerequisite from the preflight probe."] =
        "列:三元组/架构(按配置)、源码 profile 与钉住 ref、源码已同步、工具链已安装、冒烟状态(emscripten 后端冒烟与 macosx 交叉 Mach-O 冒烟;其余目标以引擎测试套件为冒烟)、verified(本宿主真机构建+冒烟证据的静态登记)、以及预检探针给出的首个缺失先决条件。",
    ["Values come from the same probes `xmake toolchains status <subject>` uses, so the two commands cannot disagree."] =
        "取值与 `xmake toolchains status <subject>` 同源,两条命令不可能不一致。",
    ["The Windows row queries the host compiler for its sysroot once; read-only but second-scale."] =
        "Windows 行会向宿主编译器查询一次 sysroot;只读但秒级耗时。",
    ["This prepares GCC source files, GCC prerequisites, and generator tools, and applies the registered source patches (verified by hard postconditions before the patch stamp is written)."] =
        "此命令准备 GCC 源码、先决库与生成器工具,并应用已登记的源码补丁(写补丁 stamp 前经硬后置校验)。",
    ["Pinned revisions restore from a matching offline bundle under .toolchains/.cache/bundles before any remote is tried (see `xmake toolchains bundle`)."] =
        "钉住修订会先从 .toolchains/.cache/bundles 下匹配的离线 bundle 恢复,再尝试任何远端(见 `xmake toolchains bundle`)。",
    ["macosx and ios share one pinned Darwin arm64 source tree; fetching either subject also carries the additive iOS patch layer."] =
        "macosx 与 ios 共享同一棵钉住的 Darwin arm64 源码树;fetch 任一对象都会携带附加的 iOS 补丁层。",
    ["For emscripten it also downloads and digest-checks the pinned managed Emscripten toolset archives (emcc/LLVM, Node.js, Windows python)."] =
        "对 emscripten 还会下载并校验钉住的受管 Emscripten 工具集归档(emcc/LLVM、Node.js、Windows python)。",
    ["It does not build or install a compiler."] = "它不构建也不安装编译器。",
    ["The compiler is installed under the project-local .toolchains directory."] =
        "编译器安装在项目本地 .toolchains 目录下。",
    ["If the selected toolchain is already installed, this command reuses it."] =
        "所选工具链已安装时,此命令直接复用。",
    ["Use `xmake toolchains build` for an explicit rebuild."] =
        "需要显式重建时用 `xmake toolchains build`。",
    ["Installed toolchains use .toolchains/<host>/<target>/<arch>."] =
        "已安装工具链位于 .toolchains/<host>/<target>/<arch>。",
    ["GCC source uses a target-selected shared cache under .toolchains/.cache/src."] =
        "GCC 源码使用 .toolchains/.cache/src 下按目标选择的共享缓存。",
    ["Host-local downloads, build, tools, and state files use .toolchains/.cache/<host>."] =
        "宿主本地的下载、构建、工具与状态文件位于 .toolchains/.cache/<host>。",
    ["Plain xmake builds call this automatically when toolchains_auto is enabled and the selected toolchain is missing."] =
        "toolchains_auto 开启且所选工具链缺失时,普通 xmake 构建会自动调用此命令。",
    ["Read-only: prints how many archives carry pinned digests plus every TOFU record this host has accumulated."] =
        "只读:打印带钉住摘要的归档数量,以及本宿主累计的全部 TOFU 记录。",
    ["TOFU records live in the host-local cache and die with it (a cold CI host re-trusts from zero), so digests worth keeping should graduate into the pinned registry."] =
        "TOFU 记录存于宿主本地缓存并随之消亡(冷启动的 CI 宿主会从零重新信任),值得保留的摘要应升格进钉住注册表。",
    ["Each record is printed as a paste-ready core/modules/checksums.lua entry; re-establish the digest first-hand (upstream signature, official manifest, or multi-source cross-check) before pinning it."] =
        "每条记录都以可直接粘贴的 core/modules/checksums.lua 条目形态打印;钉住前请先第一手复证摘要(上游签名、官方清单或多源交叉核对)。",
    ["xmake treats unspecified `xmake f` options as defaults, and description-file"] =
        "xmake 会把未指定的 `xmake f` 选项当作默认值,而描述文件",
    ["changes trigger implicit reconfigures with those defaults -- both can silently"] =
        "变更会以这些默认值触发隐式重配——两者都可能悄悄",
    ["reset plat/arch/mode. Pinning records the intended configuration under"] =
        "重置 plat/arch/mode。pin 会把预期配置记录到",
    [".toolchains/<host>-config.pin; `xmake toolchains pin clear` removes it."] =
        ".toolchains/<host>-config.pin;`xmake toolchains pin clear` 删除它。",
    ["Without a pin the sentinel stays silent (CI is unaffected)."] =
        "未 pin 时哨兵保持沉默(CI 不受影响)。",
    ["GCC source updates use git fetch --depth=1 for the selected ref."] =
        "GCC 源码更新对所选 ref 使用 git fetch --depth=1。",
    ["If shallow fetch is not usable, the manager falls back to a full git fetch."] =
        "浅拉取不可用时,管理器回退到全量 git fetch。",
    ["Existing source prerequisites and build directories are kept so GCC can reuse build cache where possible."] =
        "既有的源码先决库与构建目录会保留,让 GCC 尽可能复用构建缓存。",
    ["If the fetched GCC commit is unchanged, no compiler rebuild is started."] =
        "拉取到的 GCC 提交未变时,不会启动编译器重建。",
    ["If the selected compiler is not installed yet, this updates source only."] =
        "所选编译器尚未安装时,此命令只更新源码。",
    ["Use install after update when bootstrapping a new target."] =
        "自举新目标时,update 之后再执行 install。",
    ["The bundle lands under .toolchains/.cache/bundles, keyed by source cache name and revision."] =
        "bundle 落在 .toolchains/.cache/bundles 下,按源码缓存名与修订键名。",
    ["A fresh sync of the same pinned revision restores from the bundle before trying any remote."] =
        "同一钉住修订的全新同步会先从 bundle 恢复,再尝试任何远端。",
    ["This is the durable escape when a rebased upstream branch no longer carries the pinned revision."] =
        "上游 rebase 分支不再携带钉住修订时,这是持久的逃生通道。",
    ["For emscripten this also bundles the pinned WABT fork sources."] =
        "对 emscripten 还会连带打包钉住的 WABT fork 源码。",
    ["Copy bundle files into another machine's .toolchains/.cache/bundles to seed it offline."] =
        "把 bundle 文件拷入另一台机器的 .toolchains/.cache/bundles 即可离线播种。",
    ["Build outputs are still produced by plain xmake."] =
        "构建产物仍由普通 xmake 产出。",
    ["This command only builds the compiler toolchain."] =
        "此命令只构建编译器工具链。",
    ["The source object is always produced by GCC; Clang is never used as the target source compiler."] =
        "源码对象始终由 GCC 产出;Clang 从不用作目标源码编译器。",
    ["emscripten: the mandatory path validates C/C++26, Basic C ABI, __int128/libgcc, freestanding libstdc++, the pinned WABT fork, wasm-ld, and Node.js."] =
        "emscripten:必经路径校验 C/C++26、Basic C ABI、__int128/libgcc、freestanding libstdc++、钉住的 WABT fork、wasm-ld 与 Node.js。",
    ["emscripten: if emcc is configured, it receives only the GCC-produced object for an additional link-only compatibility probe."] =
        "emscripten:配置了 emcc 时,它只接收 GCC 产出的对象做一次仅链接的兼容性探针。",
    ["macosx (cross builds only): compiles C and C++ probes, links an executable and a dylib, and statically asserts Mach-O file types plus expected symbols via readobj/otool; run the artifacts on a real mac to extend the evidence."] =
        "macosx(仅交叉构建):编译 C 与 C++ 探针,链接可执行文件与 dylib,经 readobj/otool 静态断言 Mach-O 文件类型与预期符号;把产物拿到真 Mac 上运行可延伸证据。",
    ["macosx (native macOS hosts): the engine test suites are the smoke; this command has nothing extra to add there."] =
        "macosx(原生 macOS 宿主):引擎测试套件即冒烟;此命令在该场景无额外动作。",
    ["This does not claim a target libc, hosted libstdc++, exceptions, the complete Emscripten ABI, or full Engine support."] =
        "这不代表目标 libc、hosted libstdc++、异常、完整 Emscripten ABI 或完整引擎支持。",
    ["Unlike update, this ignores the git revision check and always recompiles."] =
        "与 update 不同,此命令忽略 git 修订检查,总是重新编译。",
    ["Use it after changing the registered GCC source patches (gccpatches.patch_gcc_source),"] =
        "在改动已登记的 GCC 源码补丁(gccpatches.patch_gcc_source)之后使用,",
    ["or when the cached build directory references a bootstrap toolchain that no longer exists."] =
        "或在缓存构建目录引用的自举工具链已不存在时使用。",
    ["The GCC source is re-synced and re-patched, the build directory is reset, and GCC is rebuilt from scratch."] =
        "GCC 源码会重新同步并重打补丁,构建目录重置,GCC 从零重建。",
    ["A full GCC recompile is expensive; expect a long run."] =
        "GCC 全量重编代价高;预期长时间运行。",

    -- gcc features help: frame lines
    ["When the configured toolchain is gcc/mingw or the target has project-local GCC toolsets, gcc.features is applied automatically."] =
        "配置的工具链为 gcc/mingw,或目标使用项目本地 GCC 工具集时,gcc.features 自动生效。",
    ["For other toolchains, all GCC feature settings are ignored."] =
        "其他工具链下,全部 GCC 特性设置被忽略。",
    ["`all` enables positive GCC C++ frontend/runtime features in this manager."] =
        "`all` 启用本管理器中正向的 GCC C++ 前端/运行时特性。",
    ["no_*/off/ignore disabling switches, mutually exclusive ABI choices, special emission modes,"] =
        "no_*/off/ignore 类关闭开关、互斥的 ABI 选择、特殊发射模式,",
    ["and OpenMP/OpenACC runtime switches are closed by default and stay opt-in."] =
        "以及 OpenMP/OpenACC 运行时开关默认关闭,保持显式选入。",
    ["With set_policy(\"build.c++.modules\", true), xmake compiles the std module itself; compile_std_module stays opt-in."] =
        "启用 set_policy(\"build.c++.modules\", true) 时 xmake 自行编译 std 模块;compile_std_module 保持选入。",

    -- toolchains help: --option descriptions
    ["Enable or disable automatic bootstrap/use of the project-local GCC toolchain during plain xmake builds."] =
        "开启或关闭普通 xmake 构建期间项目本地 GCC 工具链的自动自举/使用。",
    ["Override the inferred GNU target triplet."] = "覆盖推导出的 GNU 目标三元组。",
    ["Comma/space separated feature names appended globally through gcc.features."] =
        "逗号/空格分隔的特性名,经 gcc.features 全局追加。",
    ["GCC git repository URL."] = "GCC git 仓库 URL。",
    ["GCC branch, tag, or commit label used by the manager."] =
        "管理器使用的 GCC 分支、标签或提交标识。",
    ["Darwin Arm64 GCC git repository URL."] = "Darwin Arm64 GCC git 仓库 URL。",
    ["Darwin Arm64 GCC branch, tag, or commit label used by the manager."] =
        "管理器使用的 Darwin Arm64 GCC 分支、标签或提交标识。",
    ["Experimental GCC WebAssembly backend repository URL."] =
        "实验性 GCC WebAssembly 后端仓库 URL。",
    ["Pinned experimental GCC WebAssembly backend commit."] =
        "钉住的实验性 GCC WebAssembly 后端提交。",
    ["Annotated-WAT WABT fork repository required by the GCC backend."] =
        "GCC 后端所需的带注解 WAT 的 WABT fork 仓库。",
    ["Pinned WABT fork commit."] = "钉住的 WABT fork 提交。",
    ["wasm-ld override for WebAssembly linking; the managed Emscripten toolset LLVM is used when unset."] =
        "WebAssembly 链接的 wasm-ld 覆盖;未设时使用受管 Emscripten 工具集的 LLVM。",
    ["Node.js override for running WebAssembly modules; the managed Emscripten toolset Node is used when unset."] =
        "运行 WebAssembly 模块的 Node.js 覆盖;未设时使用受管 Emscripten 工具集的 Node。",
    ["Tear down the Emscripten runtime when main returns (default on; set false for long-lived browser targets)."] =
        "main 返回时拆除 Emscripten 运行时(默认开;浏览器长驻目标设为 false)。",
    ["emcc override used only to link GCC-produced objects; the pinned managed Emscripten toolset is used when unset."] =
        "仅用于链接 GCC 产出对象的 emcc 覆盖;未设时使用钉住的受管 Emscripten 工具集。",
    ["GNU binutils archive URL for cross targets."] = "交叉目标的 GNU binutils 归档 URL。",
    ["MinGW-w64 runtime and header archive URL for Windows targets."] =
        "Windows 目标的 MinGW-w64 运行时与头文件归档 URL。",
    ["musl libc archive URL for Linux musl cross sysroots."] =
        "Linux musl 交叉 sysroot 的 musl libc 归档 URL。",
    ["Linux target C library selection; gnu cross targets without linux_sysroot use the project-managed glibc sysroot (built on Linux hosts)."] =
        "Linux 目标 C 库选择;未设 linux_sysroot 的 gnu 交叉目标使用项目受管 glibc sysroot(在 Linux 宿主构建)。",
    ["Existing GNU/Linux sysroot path when linux_libc is gnu; empty selects the project-managed glibc sysroot."] =
        "linux_libc 为 gnu 时的既有 GNU/Linux sysroot 路径;留空选择项目受管 glibc sysroot。",
    ["Managed glibc version for gnu Linux cross targets; auto follows the Linux host glibc (closest supported) and uses the default supported version on other hosts."] =
        "gnu Linux 交叉目标的受管 glibc 版本;auto 在 Linux 宿主跟随宿主 glibc(最接近的受支持版本),其他宿主用默认受支持版本。",
    ["glibc source archive URL override for the project-managed glibc sysroot."] =
        "项目受管 glibc sysroot 的源码归档 URL 覆盖。",
    ["MinGW-w64 default C runtime name, for example msvcrt or ucrt."] =
        "MinGW-w64 默认 C 运行时名,例如 msvcrt 或 ucrt。",
    ["Android NDK root used as the Android target sysroot. Resolution order: option, then ANDROID_NDK_HOME/ANDROID_NDK_ROOT/NDK_HOME, then SDK ndk/<android_ndk_version>, then the newest SDK ndk; the toolchains and android command families share one resolver."] =
        "作为 Android 目标 sysroot 的 NDK 根。解析顺序:选项,然后 ANDROID_NDK_HOME/ANDROID_NDK_ROOT/NDK_HOME,然后 SDK ndk/<android_ndk_version>,最后 SDK 内最新 ndk;toolchains 与 android 两族命令共用同一解析器。",
    ["Android API level used for Android target libraries."] =
        "Android 目标库使用的 API 级别。",
    ["macOS deployment minimum for Darwin GCC target runtimes AND project builds (injected as an explicit driver flag, so the configured value outranks any ambient MACOSX_DEPLOYMENT_TARGET; empty falls back to that environment variable, then 11.0)."] =
        "Darwin GCC 目标运行时与工程构建共同的 macOS 部署下限(以显式驱动旗标注入,配置值压过任何环境中的 MACOSX_DEPLOYMENT_TARGET;留空回退该环境变量,再回退 11.0)。",
    ["User-provided macOS SDK root for Darwin cross targets on non-macOS hosts (copy one from your own Mac/Xcode; Apple's license forbids downloading it here); empty uses xcrun on macOS hosts. APPLE_SDK env is the fallback."] =
        "非 macOS 宿主上 Darwin 交叉目标的用户自备 macOS SDK 根(从你自己的 Mac/Xcode 拷贝;Apple 许可禁止在此代为下载);macOS 宿主留空则用 xcrun。APPLE_SDK 环境变量为兜底。",
    ["iOS deployment minimum for iOS GCC target runtimes and project builds (default 15.0; the toolchain's compiled-in default is baked at patch time, and a differing configured value reaches project builds as an explicit driver flag)."] =
        "iOS GCC 目标运行时与工程构建的 iOS 部署下限(默认 15.0;工具链的编译内默认在打补丁时烤入,配置值不同时以显式驱动旗标作用于工程构建)。",
    ["iOS SDK (iPhoneOS.sdk) root for iOS targets; empty resolves through xcrun --sdk iphoneos on macOS hosts. IOS_SDK env is the fallback."] =
        "iOS 目标的 SDK(iPhoneOS.sdk)根;macOS 宿主留空经 xcrun --sdk iphoneos 解析。IOS_SDK 环境变量为兜底。",
    ["Parallel job count used by GCC and runtime builds."] =
        "GCC 与运行时构建使用的并行任务数。",
    ["Build type used for compiler binaries; release is the default."] =
        "编译器二进制的构建类型;默认 release。",
    ["Optimization level used for compiler binaries; empty follows toolchains_build_type."] =
        "编译器二进制的优化级别;留空跟随 toolchains_build_type。",
    ["Keep debug information in compiler binaries; auto is false for release/minsizerel."] =
        "编译器二进制是否保留调试信息;auto 在 release/minsizerel 下为 false。",
    ["Extra CFLAGS used when building compiler binaries and helper tools."] =
        "构建编译器二进制与辅助工具时的额外 CFLAGS。",
    ["Extra CXXFLAGS used when building compiler binaries and helper tools."] =
        "构建编译器二进制与辅助工具时的额外 CXXFLAGS。",
    ["Extra LDFLAGS used when building compiler binaries and helper tools."] =
        "构建编译器二进制与辅助工具时的额外 LDFLAGS。",
    ["Extra target CFLAGS used when building GCC target runtime libraries."] =
        "构建 GCC 目标运行时库时的额外目标 CFLAGS。",
    ["Extra target CXXFLAGS used when building GCC target runtime libraries."] =
        "构建 GCC 目标运行时库时的额外目标 CXXFLAGS。",
    ["Strip installed compiler binaries and target runtime debug data after release builds; auto follows toolchains_build_type."] =
        "release 构建后 strip 已安装编译器二进制与目标运行时调试数据;auto 跟随 toolchains_build_type。",
    ["GNU make compatible command."] = "GNU make 兼容命令。",
    ["Allow xmake to install missing user-level helper tools when supported."] =
        "允许 xmake 在受支持时安装缺失的用户级辅助工具。",
    ["Package manager used for missing helper tools; auto only uses Scoop on Windows."] =
        "缺失辅助工具使用的包管理器;auto 仅在 Windows 上使用 Scoop。",
    ["Windows host bootstrap provider used when no complete MinGW sysroot/tools are found."] =
        "找不到完整 MinGW sysroot/工具时使用的 Windows 宿主自举提供者。",
    ["Portable Windows MinGW bootstrap archive. latest resolves the newest w64devkit release."] =
        "便携 Windows MinGW 自举归档。latest 解析为最新 w64devkit 发布。",
    ["Existing portable Windows MinGW root or bin directory used when toolchains_bootstrap=path or as an auto candidate."] =
        "toolchains_bootstrap=path 时或作为 auto 候选使用的既有便携 MinGW 根/bin 目录。"
})
