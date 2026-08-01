# build_support 校验器与补丁 fixture 回归

把此前只存在于人工负例记录/一次性脚本(`recheck.lua`、phase 验证脚本)里的
校验行为固化为可重复回归。所有 fixture 由用例自建临时输入(位于
`os.tmpdir()` 下的独立沙盒),绝不写真实源码树或真实 `.toolchains` 缓存;
只读引用真实树的用例(pinned 正例)直接读真实下载缓存,读不到则 SKIP。

## 运行方式

在仓库根目录执行:

```
xmake lua build_support/tests/run_all.lua
```

只跑单个套件(开发期定位用):

```
xmake lua build_support/tests/run_all.lua gccmodulecheck
xmake lua build_support/tests/run_all.lua gccmodulecache
xmake lua build_support/tests/run_all.lua checksums
xmake lua build_support/tests/run_all.lua rust_validate
xmake lua build_support/tests/run_all.lua rust_cargo
xmake lua build_support/tests/run_all.lua rust_toolchain
xmake lua build_support/tests/run_all.lua androidndk
xmake lua build_support/tests/run_all.lua gccglibc
xmake lua build_support/tests/run_all.lua install_lock
```

逐项输出 `[PASS]/[FAIL]/[SKIP]`,末尾汇总;任一失败时保留 fixture 沙盒目录
供诊断,并以非零退出码结束(CI 可直接作为一个 step 接入)。断言匹配英文
诊断文本,入口已强制 `TOOLCHAINS_LANG=en`,中文 locale 主机行为一致。

## 覆盖面

| 套件 | 被测模块 | 正例 | 负例 |
| --- | --- | --- | --- |
| layers | `core/modules/layers.lua`(通用模块分层器) | from_manual 分层与同层并列;同名同层重复容忍;from_module_graph 分组策略**自动探测**(单模块+分区→partition-prefix、多模块→module)、亦可显式指定;拓扑序与跨模块环检测;impl 分区跨分支 import 计入;根级分区(Version)不算节点 | from_manual 拒绝同名两层、level≤0、格式错误;from_module_graph 拒绝未知分组策略名 |
| gccmodulecheck | `languages/cpp/modules/gccmodulecheck.lua` | 健康分区树零 problems;`#if` 门控 import 不计入环;未分层分支不受约束;`is_interface_unit` 三态;自动模式分支环检测与叶子豁免 | 聚合缺 re-export、stale re-export、internal 泄漏、分区名/路径不符、聚合位置错误、无条件 import 环、向上/同层跨分支 import(手动模式)、自动模式分支环、`run()` 聚合报错 |
| gccmodulecache | `languages/cpp/modules/gccmodulecache.lua` | `-P` 相对生成路径归一到真实 build root;绝对路径保持幂等;当前 mapper 与外部工程 mapper 保留 | 旧 build root mapper 被剔除;编译器前端指纹变化时 localcache 与对应平台 CMI 一并失效 |
| checksums | `core/modules/checksums.lua` | registry 覆盖 defaults.lua 全部 pinned URL leaf(含 glibc 集);真实缓存中已存在的 pinned 归档校验通过(只读,缺则 SKIP);TOFU 首见记录、复用通过 | pinned sha256/sha512 leaf 内容被篡改拒绝;TOFU 字节变化拒绝;并断言真实缓存未被写入任何 TOFU 记录 |
| rust_validate | `languages/rust/modules/validate.lua`(单 crate:root_file+sources 显式驱动) | 健康 crate 树校验干净;`// rust.cargo: allow-orphan` 逃生口生效;文件模块(`name.rs`)在 `name/` 下的子模块可达(现代布局);ABI 白名单豁免 `rust_eh_personality` | mod.rs 孤儿(建议行按目录名)、缺 `#![no_std]`、`#[unsafe(no_mangle)]` 无 `whe_` 前缀 |
| rust_cargo | `languages/rust/modules/cargo.lua`(`parse_build_messages` Cargo 构建消息解析) | staticlib 产物从消息流中定位 | 目标侧 rlib 依赖的 build script 原生链接请求被上报;仅宿主侧包(host rlib,无三元组段)的 build script 豁免 |
| rust_toolchain | `languages/rust/modules/toolchain.lua`(`rust_target_for` GCC 三元组→rustc target 映射) | iOS 设备三元组 `aarch64-apple-ios` 映射正确;表内三元组解析(android);版本后缀 darwin 三元组回退且保留 arch | 未映射的 apple 三元组(模拟器/catalyst)响亮失败、绝不误落设备 target;完全未知三元组响亮失败 |
| androidndk | `core/modules/androidndk.lua` | option 胜 env/SDK;env 顺序(`ANDROID_NDK_ROOT` > `NDK_HOME`);`android_ndk_version` 松散前缀匹配;无版本时取最新 SDK ndk/ | option 指向不存在路径(problems + `root_or_fail` 响亮失败);请求的版本未安装 |
| gccglibc | `languages/cpp/modules/gccglibc.lua` | auto 在非 Linux 宿主走 default 分支(Linux 宿主走 host 跟随族);显式受支持版本 source=option;`glibc_snapshot_url` 覆盖生效;supported 集有序 | 非版本文本、不在受管集合内的版本(均为 problems,不猜测) |
| gccfeatures | `languages/cpp/modules/gccfeatures.lua` | gcc/mingw/project_gcc 识别;g++ 工具集与 envs+gcc 组合;受管默认回退;mingw 平台回退;全局 toolchain 配置优先 | 显式 msvc/clang 声明不落受管默认(G4 锚点);非 GCC 工具集=external;envs 单独声明不算显式身份;toolchains_auto 关闭时无身份 |
| settings | `core/modules/settings.lua` | macosx/ios 缺省三元组钳制 aarch64;`TOOLCHAINS_TARGET` 显式覆盖仍被尊重;windows/linux 三元组不受钳制影响 | 残留 x64 配置下 profile 不再静默落 mainline |
| gcctargets | `languages/cpp/modules/gcctargets.lua`(provider_contract + build_plan) | 六个 provider 满足契约:必需钩子全在位、全部导出均已声明(必需/可选/族内白名单);build_plan 结构不变式 + ios 计划金样 | 契约表自身完整性;未声明的导出=拼写错的可选钩子不再静默失联;金样漂移即败 |
| patches_shared | `languages/cpp/modules/patches/shared.lua` | strict_replace/migrated/write_new/write_owned 在合成文件上正常应用且幂等;retire 语义 | 锚点漂移、锚点歧义、非所有文件冲突、迁移歧义全部响亮失败 |
| stamps | `targets/{ios,linux}.lua` installed_extra + `gccbuild.lua` 签名/迁移 | 缺 stamp 放行;匹配 stamp 精确放行(musl 与受管 glibc 两形态均为 `== true` 断言);pre-key stamp grandfather;匹配的 build-config 签名放行;finalize 对 pre-key stamp 一次性采纳当前身份 | iOS SDK/版本/部署目标漂移、linux libc 口味漂移、受管 glibc 版本漂移、被篡改/缺失签名块全部击穿外层门 |
| hostboot | `hostboot.lua` bootstrap_backend_missing 后端探针(2026-07-18 现场事故:驱动器健在而 cc1 被杀软隔离/解压中断,旧检查全部漏过) | 健康套件(解析为绝对路径且在盘)放行 | cc1 被隔离(解析路径不在盘)、裸名回显(驱动器一无所获)、cc1plus 单独缺失、驱动器不可运行,全部拒绝 |
| patch_families | `languages/cpp/modules/patches/{darwin,ios}.lua` | 合成锚点树上按门面顺序整族应用;postcondition 全满足;二次应用字节级幂等;v66 蹦床块 retire 后重铺 | ios 族在非 darwin-arm64 profile 下保持惰性(mainline/wasm 族体量大,整族应用由真树电池覆盖,见 §维护要点) |
| install_lock | `core/modules/install_lock.lua`(跨进程安装锁 `guard`) | 返回体结果透传;按需建锁文件父目录;body raise 后仍释放锁(可再次获取、不泄漏);同一锁文件顺序加锁不自死锁 | 跨进程真并发无法单进程夹具化,由汇入 `guard` 的真实工具链安装路径(GCC/Rust)覆盖 |

## 沙盒设计(为什么不会污染真实缓存)

- `gccmodulecheck.collect_problems` 与 rust 校验本身无状态,直接以内存
  content 表 / 临时 crate 树驱动真实树里的模块。
- `checksums.verify` 会经 `layout.toolchains_cache_dir()` 写 TOFU 记录,而
  `layout.lua` 从自身脚本位置向上找最近的 `build_support` 目录自举 owner
  root。因此 testkit 把 `core/modules`(必要时加 `languages/cpp/modules`)
  按原目录形状复制进临时沙盒再 import,整棵 `.toolchains` 缓存树随之落进
  沙盒;有专门用例断言真实缓存零写入。
- `androidndk.resolve` / `gccglibc.resolve_version` 带进程级缓存,每个场景
  都从独立副本 import 全新模块实例(新实例=新缓存),解析链完全由
  `settings.value_or` 的大写环境变量回退(`ANDROID_NDK`、
  `LINUX_GLIBC_VERSION` 等)驱动,每个场景显式钉住整条链的所有环境变量,
  宿主机真实 SDK/NDK 不可能漏入。

## 维护提示

- checksums 套件的 `PINNED_URL_KEYS` 列表与 `core/modules/defaults.lua`
  的 pinned URL 字段一一对应;defaults.lua 里改名/增删 pinned 字段时同步
  更新该列表(用例失败信息会直接指出缺的 key)。
- 新校验器落地时:在 `cases/` 加一个 `<name>_cases.lua`(暴露 `run(t)`),
  并在 `run_all.lua` 的 `SUITES` 表登记即可。
