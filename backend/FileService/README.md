# FileService

FileService 是 千知万理 的资料文件服务，负责保存用户上传文件、记录文件元数据与 SHA-256 校验值，并异步解析出可供知识库使用的纯文本和结构化内容。

开发环境地址：`http://localhost:5103`。

## 已实现能力

- 上传、查询、删除资料文件；资料按 `OwnerUserId` 隔离。
- 将文件二进制存入 MongoDB GridFS，元数据与解析任务存入 MongoDB 集合。
- 计算并保存原文件 SHA-256 checksum。
- 异步解析任务：任务完成后资料才会标记为 `READY`。
- 支持 TXT、Markdown、HTML、DOCX、文本型 PDF，以及通过本机 OCR 解析扫描版 PDF、JPG、JPEG、PNG（图片仅支持这三种格式）。
- 文本统一采用 UTF-8、NFC 规范化与 LF 换行保存。
- DOCX 解析标题、列表、表格；Markdown/HTML 转换为纯文本，同时写入结构化 `blocks`。

扫描版 PDF 没有内嵌文字层时，服务会调用本机 [OcrService](../OcrService/README.md)。请先启动 OcrService；若它未运行，此类文件的解析任务会明确标记为失败，不会产生伪造的文本结果。

## 启动

先确保本机 MongoDB 已运行，然后在仓库根目录执行：

```powershell
dotnet run --project .\FileService\GalGame.FileService.csproj
```

启动配置位于 [Properties/launchSettings.json](Properties/launchSettings.json)，默认监听 `http://localhost:5103`。

健康检查：

```text
GET http://localhost:5103/healthz
GET http://localhost:5103/readyz
```

其中 `readyz` 会同时检查 MongoDB 是否可用。

## MongoDB 存储

开发环境默认连接：

```text
mongodb://127.0.0.1:27017/qzwl_file
```

数据库 `qzwl_file` 中的集合：

| 集合 | 用途 |
| --- | --- |
| `materials` | 文件元数据、所属用户、状态及解析结果 |
| `ingestion_jobs` | 异步解析任务及进度、错误信息 |
| `material_content.files` | GridFS 文件索引和元数据 |
| `material_content.chunks` | GridFS 的实际二进制分块 |

可通过环境变量覆盖连接信息：`ConnectionStrings__FileDatabase`、`MongoDb__Database`。生产环境应通过密钥管理系统注入连接字符串，不要将密码提交到仓库。

## 资料状态与解析流程

```text
上传文件 → UPLOADED → 创建解析任务 → PROCESSING → READY / FAILED
```

- `UPLOADED`：文件已安全写入 GridFS，尚未开始解析。
- `PROCESSING`：解析任务正在执行，不能删除。
- `READY`：已同时保存完整解析文本和结构化 blocks，可供读取。
- `FAILED`：解析失败，可查看任务错误后重新发起解析。

`READY` 状态仅会在解析文本写入成功后发布，因此前端不会读到“已完成但没有内容”的资料。

## API 概览

浏览器侧 API 需要网关注入以下请求头：

```text
X-Gateway-Key: <服务密钥>
X-User-Id: <UUID 用户 ID>
```

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| `POST` | `/api/v1/materials` | 上传文件（multipart/form-data） |
| `GET` | `/api/v1/materials` | 分页查询当前用户资料 |
| `GET` | `/api/v1/materials/{materialId}` | 获取资料元数据 |
| `DELETE` | `/api/v1/materials/{materialId}` | 删除资料与 GridFS 二进制 |
| `POST` | `/api/v1/materials/{materialId}/ingestion-jobs` | 创建或强制重跑解析任务 |
| `GET` | `/api/v1/ingestion-jobs/{jobId}` | 查询解析进度和错误 |
| `GET` | `/api/v1/materials/{materialId}/extracted-text-preview` | 获取已解析的文本和结构化 blocks |

内部服务读取接口位于 `/internal/v1/materials/...`，除 `X-Gateway-Key` 外还必须由网关注入非空的 `X-Service-Name`。生产环境不要让浏览器直接访问 FileService。

## 解析结果格式

解析结果中的 `text` 是供检索、向量化使用的纯文本；`blocks` 是供前端展示或后续处理使用的结构化块。每个块包含：

- `kind`：如 `HEADING`、`PARAGRAPH`、`LIST_ITEM`、`TABLE`、`CODE`、`QUOTE`。
- `level`：标题层级，仅标题块有值。
- `text`：该块的规范化文本。
- `source`：在完整 `text` 中的起止位置，以及 PDF 页码或 DOCX 段落序号等来源信息。

## Mock 数据

`mocks` 目录存放的是前端联调、接口测试和单元测试可复用的**静态响应样例**；生产服务不会自动读取这些 JSON 文件。

| 文件 | 模拟场景 | 对应接口 |
| --- | --- | --- |
| `mocks/materials/success.json` | 文件上传成功，资料状态为 `UPLOADED` | `POST /api/v1/materials` |
| `mocks/extracted-text/processing.json` | 解析尚未完成，接口返回 `409 MATERIAL_TEXT_NOT_READY` | `GET /api/v1/materials/{materialId}/extracted-text-preview` |
| `mocks/extracted-text/success.json` | 解析完成，返回 `text`、`sourceMap` 和 `blocks` | 同上 |

前端本地联调时，可在请求封装层根据 URL 直接返回对应 JSON；例如“查看解析内容”在解析中返回 `processing.json`，在完成后返回 `success.json`。接口测试工具（Postman、Apifox）也可以将这些文件作为 Mock Response 导入。真实联调时则直接请求 `http://localhost:5103`，无需 mock。
