# OCRService

OCRService 是 FileService 使用的本地文字识别服务，基于 PaddleOCR 和 FastAPI 构建，默认仅监听本机回环地址：

```text
http://127.0.0.1:5110
```

它用于识别扫描版 PDF、JPG、JPEG 和 PNG 中的文字。服务不会保存上传文件：每次识别均在临时目录完成，任务结束后临时文件会自动删除。

## 1. 能力范围

| 文件类型 | 处理方式 | 是否需要勾选 OCR |
| --- | --- | --- |
| 扫描版 PDF | 按页渲染成图片后逐页识别 | 是 |
| 文本型 PDF | FileService 优先直接提取内嵌文字；为空时才调用 OCR | 是（作为兜底） |
| JPG / JPEG / PNG | 直接图片识别 | 是 |
| TXT / Markdown / HTML / DOCX | 由 FileService 直接解析 | 否，OCR 不参与 |

单个 OCR 请求最大为 **10 MB**

## 2. 前置条件

- Windows 10/11
- Python **3.9 至 3.12**（推荐 Python 3.12）
- 可访问清华 PyPI 镜像；首次识别时还需要下载 PaddleOCR 模型

`setup.ps1` 会优先自动从系统 PATH 中的 `python` 或 Windows 的 `py` 启动器寻找兼容版本，因此通常不需要手动配置 Python 路径。

## 3. 首次安装

在项目根目录打开 PowerShell：

```powershell
cd .\OCRService
.\setup.ps1
```

脚本会完成以下工作：

1. 自动检测 Python 3.9–3.12；
2. 在 `OCRService\.venv` 创建独立虚拟环境；
3. 使用清华 PyPI 镜像 `https://pypi.tuna.tsinghua.edu.cn/simple` 安装依赖；
4. 安装 FastAPI、Uvicorn、PyMuPDF、PaddlePaddle 和 PaddleOCR。

如果 Python 不在 PATH 中，可以显式指定路径：

```powershell
.\setup.ps1 -Python "D:\\Programs\\Python312\\python.exe"
```

> 不要将 `.venv` 从一台电脑直接复制到另一台电脑。请在新机器上重新运行 `setup.ps1`。

## 4. 启动与停止

安装完成后执行：

```powershell
cd .\OCRService
.\start.ps1
```

成功启动后可访问：

```text
http://127.0.0.1:5110/healthz
```

预期响应：

```json
{ "status": "live" }
```

`start.ps1` 可以双击运行。若 5110 端口已有 OCRService 进程，它会提示进程 ID，不会重复启动。要停止前台服务，在服务窗口按 `Ctrl+C`。

## 5. OCR 模式

前端勾选“使用 OCR”后可选择模式。模式会随任务传递到 FileService，再由 FileService 通过 `X-Ocr-Mode` 请求头传给本服务。

| 模式 | 模型与页面渲染 | 适用场景 |
| --- | --- | --- |
| `quick`（快速） | `PP-OCRv6_small_det` + `PP-OCRv6_small_rec`；PDF 以 1.5× 分辨率渲染 | 清晰的讲义、普通印刷体、优先速度 |
| `standard`（标准，默认） | PaddleOCR 默认 PP-OCRv6 medium 方案；PDF 以 2× 分辨率渲染 | 小字号、模糊扫描、公式周边文字、优先准确度 |

快速模式通常会比标准模式快约 1.5～3 倍；实际差异取决于页数、文字密度、扫描质量和 CPU 性能。首次使用某一模式时模型下载与加载会额外耗时，不能代表后续速度。

## 6. 与 FileService 的调用关系

```text
浏览器
  -> Gateway
  -> FileService (localhost:5103)
  -> OCRService (127.0.0.1:5110)
```

浏览器不会直接访问 OCRService。FileService 仅在需要 OCR 的图片或扫描版 PDF 时调用它，并会传入：

- `X-Ocr-Job-Id`：FileService 的解析任务 ID，用于查询逐页进度；
- `X-Ocr-Mode`：`quick` 或 `standard`；
- `multipart/form-data` 中名为 `file` 的文件字段。

OCRService 默认不依赖 Gateway，也不校验浏览器令牌；因此必须只监听 `127.0.0.1` 或受信任的内网地址，**不要直接暴露到公网**。

## 7. 前端接入

### OCRService 不需要、也不应接入 Gateway

OCRService 是 FileService 的**内部本地依赖**，不需要注册 Gateway 路由、不需要浏览器 Access Token，也不需要在前端配置 `5110` 地址。

前端的正确调用链是：

```text
前端（携带 Bearer Token）
  -> Gateway 的 /api/v1/materials/... 接口
  -> FileService
  -> OCRService（仅 FileService 调用）
```

因此前端**禁止**直接请求 `http://127.0.0.1:5110/v1/ocr`。直接调用会绕过用户鉴权，且部署后浏览器所在机器与服务所在机器未必相同。

### 前端创建 OCR 解析任务

文件先上传到 FileService。上传完成后，如用户勾选 OCR，前端应调用 FileService 的解析任务接口，而不是 OCRService：

```javascript
await fetch(`/api/v1/materials/${materialId}/ingestion-jobs`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    Authorization: `Bearer ${session.token}`
  },
  body: JSON.stringify({
    parserVersion: "files-ocr-v1",
    force: false,
    enableOcr: true,
    ocrMode: "standard" // 或 "quick"
  })
});
```

FileService 会自行判断：文本型 PDF 优先直接提取；扫描版 PDF 或图片才实际调用 OCRService。

### 快速与标准模式的前端选择

| 前端值 | 展示名称 | 实际模型 | 推荐使用场景 |
| --- | --- | --- | --- |
| `quick` | 快速 | `PP-OCRv6_small_det` + `PP-OCRv6_small_rec` | 清晰资料、预览测试、优先速度 |
| `standard` | 标准（默认） | PP-OCRv6 medium 检测与识别模型 | 小字、模糊扫描、正式资料、优先准确度 |

建议的页面逻辑：

1. OCR 复选框未选中时，禁用模式下拉框；
2. 勾选后默认选择 `standard`；
3. 用户明确优先速度时才选择 `quick`；
4. 将 `enableOcr` 和 `ocrMode` 一起提交给 FileService；
5. 从 FileService 查询任务状态和进度，显示“正在使用快速 OCR”或“正在使用标准 OCR”；完成后以任务返回的 `ocrUsed` 判断是否真的执行过 OCR。

示例控件：

```html
<label><input type="checkbox" name="enableOcr"> 使用 OCR</label>
<select name="ocrMode" disabled>
  <option value="quick">快速（响应更快）</option>
  <option value="standard" selected>标准（识别更精确）</option>
</select>
```

```javascript
enableOcr.onchange = () => {
  ocrMode.disabled = !enableOcr.checked;
};
```

## 8. 接口说明

### 存活检查

```http
GET /healthz
```

返回服务进程是否正常运行。

### 创建识别请求

```http
POST /v1/ocr
Content-Type: multipart/form-data
X-Ocr-Job-Id: <可选任务 ID>
X-Ocr-Mode: quick | standard
```

成功示例：

```json
{
  "pages": [
    {
      "pageNumber": 1,
      "lines": ["第一行文字", "第二行文字"]
    }
  ]
}
```

支持 PDF、JPG、JPEG、PNG。未传 `X-Ocr-Mode` 时使用 `standard`。传入其他值会返回 `400`；不支持的文件格式返回 `415`；文件超过 10 MB 返回 `413`。

### 查询逐页进度

```http
GET /v1/ocr/jobs/{jobId}
```

响应示例：

```json
{
  "status": "RUNNING",
  "currentPage": 3,
  "totalPages": 9,
  "phase": "RECOGNIZING",
  "mode": "standard"
}
```

状态可能为 `RUNNING`、`SUCCEEDED`、`FAILED` 或 `UNKNOWN`。进度只保存在 OCRService 内存中；重启服务后旧任务的进度不会保留，FileService 的任务状态仍是最终依据。

## 9. 日志

所有日志统一存放在：

```text
OcrService/logs/
```

| 文件名模式 | 内容 |
| --- | --- |
| `setup-时间戳.log` | 依赖安装、Python 检测与 pip 输出 |
| `service-时间戳.log` | 通过 `start.ps1` 启动的 Uvicorn 服务输出 |
| `install.log`、`service.log`、`verify.log` 等 | 旧日志，已归档到此目录 |

排查失败时优先查看最新的 `service-*.log`，再查看 FileService 日志中的 OCR 调用错误。

## 10. 目录说明

```text
OcrService/
├─ app.py             # FastAPI 与 PaddleOCR 适配逻辑
├─ requirements.txt   # Python 依赖
├─ setup.ps1          # 创建虚拟环境并从清华源安装依赖
├─ start.ps1          # 启动本地 OCR 服务
├─ verify.py          # 简单识别验证脚本
├─ logs/              # 安装与服务日志
└─ .venv/             # 本机生成的 Python 虚拟环境，不提交、不复制
```
