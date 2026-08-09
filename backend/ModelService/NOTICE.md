# ModelService 模型来源说明

ModelService 独占本地模型、tokenizer、词典、资产完整性校验与推理运行时。PracticeService 只通过 Gateway
内部契约提交答案和必要事实，不读取模型文件，也不引用 ONNX Runtime。

主观题逐事实蕴含判定使用 `MoritzLaurer/multilingual-MiniLMv2-L6-mnli-xnli`：

- 固定修订：`0a71e92a985b6e1ad1828cf67ce9c459639c1dca`
- 上游模型卡：https://huggingface.co/MoritzLaurer/multilingual-MiniLMv2-L6-mnli-xnli
- 许可证：MIT，全文见 `THIRD_PARTY_LICENSES/MultilingualMiniLMNli.LICENSE`
- ONNX SHA-256：`79f8cda2b1230585a95ea0514a6f1bd21c5c986ba0529bb3261213a3e195fa6e`

兼容诊断资产 `sbert.onnx`、`vocab.txt` 及其他 ReciteHelper 运行时资源来自
`ArabidopsisDev/ReciteHelper` 审计提交 `21288821229eb8a1da7f5a38d248fdfd10104f80`，许可证为
AGPL-3.0，全文见 `THIRD_PARTY_LICENSES/ReciteHelper.LICENSE`。这些旧资产不参与当前 correct、quality
或 SM-2。

模型资源不进入 Git。OSCA `20277-gal-res` 当前按 `Resources` 同构目录保存完整 NLI 目录；开发、测试和
部署前运行 `scripts/download-model-resources.ps1`，由 manifest 固定来源、长度和 SHA-256。OSCA 不可用
时允许使用受信离线副本，以及分别固定到上游 revision/commit 的 NLI、旧模型、tokenizer、词典与词表灾备；
全部来源失败或最终校验不一致必须阻止 ModelService 就绪，不得降级为编辑距离判分。
