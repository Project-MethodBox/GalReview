# ModelService

ModelService 是千知万理的内部模型推理边界，当前承载本地多语种 NLI。它不拥有研习册、题目、答案、
知识图谱、掌握度或 SM-2 状态，也不直接面向浏览器。

## 四层与 CQRS

- `ModelService.API`：内部 HTTP 契约、Gateway 身份校验、健康与就绪端点，只向 MediatR 发送命令/查询。
- `ModelService.Application`：`AdjudicateFacetsCommand`、readiness query 与推理端口。
- `ModelService.Domain`：输入边界、NLI verdict、资产状态和错误语义；无基础设施依赖。
- `ModelService.Persistence`：ONNX Runtime、SentencePiece、严格同义词词典和资产 SHA-256 校验；无数据库。

唯一生产推理入口为：

```text
POST /internal/v1/model-inference/facet-adjudications
X-Service-Name: PracticeService
```

调用必须经过 Gateway。ModelService 只返回每个必要事实的
`ENTAILED/OMITTED/CONTRADICTED/INDETERMINATE` 与概率诊断；它不产生 correct、quality、分数或 SM-2
结果。聚合状态机仍归 Practice Domain。

## 开发前资源恢复

```powershell
$env:OSCA_ACCESS_KEY_ID = '<read-only access key>'
$env:OSCA_SECRET_ACCESS_KEY = '<read-only secret key>'
.\scripts\download-model-resources.ps1
Remove-Item Env:OSCA_ACCESS_KEY_ID, Env:OSCA_SECRET_ACCESS_KEY
```

默认目标为 `backend/ModelService/Resources`，manifest 为
`backend/ModelService/resources.manifest.json`。OSCA 对象目录树与 `Resources` 一致，当前 NLI 目录已完整
镜像。下载器先复用已校验缓存，再尝试 OSCA；OSCA 不可用或文件损坏时，可通过 `-FallbackSourcePath`
使用同构离线副本，并对 NLI、旧 `sbert.onnx`、tokenizer、词典及 `vocab.txt` 使用 manifest 中的固定提交
灾备。全部 19 个文件最终仍须通过大小及 SHA-256 校验。
