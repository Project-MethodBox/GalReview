# ReciteHelper 迁移来源说明

PracticeService 的题型、答题规范化、智能选题、随机组卷及兼容包设计参考自：

- 项目：`ArabidopsisDev/ReciteHelper`
- 审计提交：`21288821229eb8a1da7f5a38d248fdfd10104f80`
- 许可证：GNU Affero General Public License v3.0
- 完整本机资产源：`D:\Projects\ReciteHelper\ReciteHelper.Wpf\bin\Debug\net10.0-windows7.0\Resources`

迁移不是 WPF 源码的逐文件复制：UI 已按 GalReview Web 设计语言重构，视觉小说动态 C# 编译已由 GalGame/Render 契约替代，mastery/SM-2 写入仍归 KnowledgeService。具体差异见 `docs/recitehelper-migration.md`。

ReciteHelper 原有的 SBERT/Jaccard 混合相似度、XGBoost quality 预测和仅更新 EF 的复习启发式已经过审计并退出生产判分链；它们不构成当前答案判定与 SM-2 调度的有效性依据。

主观题模型、tokenizer、词典、许可证与资产下载现由独立 `backend/ModelService` 持有；
PracticeService 仅通过 Gateway 消费逐事实 verdict。模型来源、固定修订与 SHA-256 见
`backend/ModelService/NOTICE.md`，不得在 PracticeService 重新复制模型运行时。
