# ReciteHelper 迁移来源说明

PracticeService 的题型、答题规范化、相似度判分、quality 模型输入、智能选题、随机组卷及兼容包设计源自：

- 项目：`ArabidopsisDev/ReciteHelper`
- 审计提交：`21288821229eb8a1da7f5a38d248fdfd10104f80`
- 许可证：GNU Affero General Public License v3.0
- 完整本机资产源：`D:\Projects\ReciteHelper\ReciteHelper.Wpf\bin\Debug\net10.0-windows7.0\Resources`

迁移不是 WPF 源码的逐文件复制：UI 已按 GalReview Web 设计语言重构，视觉小说动态 C# 编译已由 GalGame/Render 契约替代，mastery/SM-2 写入仍归 KnowledgeService。具体差异见 `docs/recitehelper-migration.md`。

运行 `scripts/import-recitehelper-assets.ps1` 会在校验哈希后复制运行时模型/词典，并把原项目 `LICENSE` 复制到 `THIRD_PARTY_LICENSES/ReciteHelper.LICENSE`。
