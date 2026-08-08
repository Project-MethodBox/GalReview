# ReciteHelper 迁移来源说明

PracticeService 的题型、答题规范化、相似度判分、quality 模型输入、智能选题、随机组卷及兼容包设计源自：

- 项目：`ArabidopsisDev/ReciteHelper`
- 审计提交：`21288821229eb8a1da7f5a38d248fdfd10104f80`
- 许可证：GNU Affero General Public License v3.0
- 完整本机资产源：`D:\Projects\ReciteHelper\ReciteHelper.Wpf\bin\Debug\net10.0-windows7.0\Resources`

迁移不是 WPF 源码的逐文件复制：UI 已按 GalReview Web 设计语言重构，视觉小说动态 C# 编译已由 GalGame/Render 契约替代，mastery/SM-2 写入仍归 KnowledgeService。具体差异见 `docs/recitehelper-migration.md`。

模型和词典从 OSCA 私有储桶恢复，不进入 Git。开发或部署前必须运行仓库内的 `scripts/download-practice-resources.ps1` 并通过 `resources.manifest.json` 的全量哈希校验；脚本内置凭据仅能读取和列举 `20277-gal-res`，不能访问其他储桶或写入对象，因此随下载器受版本控制。`scripts/import-recitehelper-assets.ps1` 仅作为受信本机的离线回退，并负责把原项目 `LICENSE` 复制到 `THIRD_PARTY_LICENSES/ReciteHelper.LICENSE`。
