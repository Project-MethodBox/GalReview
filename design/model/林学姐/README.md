# 林学姐静态素材库

## 目录内容

| 文件 | 用途 | 规格 |
| --- | --- | --- |
| `bg_occult_clubroom_evening_v01.png` | 神秘学研究社活动室·黄昏背景 | 1672×941，RGB PNG |
| `chr_lin_wantang_uniform_default_neutral_v01.png` | 林学姐·疲惫冷淡／常态 | 574×914，RGBA PNG |
| `chr_lin_wantang_uniform_default_gentle-smile_v01.png` | 林学姐·温柔浅笑／递出棒棒糖 | 573×914，RGBA PNG |
| `chr_lin_wantang_uniform_default_alert-serious_v01.png` | 林学姐·警觉严肃／制止手势 | 574×914，RGBA PNG |
| `chr_lin_wantang_uniform_expression-sheet_v01.png` | 林学姐·三表情透明合图 | 1721×914，RGBA PNG |
| `src_lin_wantang_expression_sheet_v01.png` | 三表情生成母版，仅供后续扩展和追溯 | 1721×914，RGB PNG（绿幕） |

## 命名规范

所有文件名只使用小写 ASCII、数字、连字符 `-` 和下划线 `_`，禁止空格、中文、括号及“最终版”等不稳定描述。中文只用于目录名和文档说明。版本号固定为两位数。

### 角色立绘

格式：

```text
chr_<角色ID>_<服装ID>_<姿态ID>_<表情ID>_v<版本>.png
```

字段说明：

- `chr`：角色立绘固定前缀。
- `角色ID`：角色的稳定英文 ID。本角色统一为 `lin_wantang`，不要混用 `lin_xuejie`、拼音缩写或中文名。
- `服装ID`：服装套装，如 `uniform`、`casual`、`festival`。本套为 `uniform`。
- `姿态ID`：身体姿态或构图，如 `default`、`arms-crossed`、`seated`。只换表情、不换主体姿态时保持不变。
- `表情ID`：语义明确的英文短语，如 `neutral`、`gentle-smile`、`alert-serious`。复合词使用连字符。
- `v<版本>`：从 `v01` 开始；同一语义的画面重制或修订依次使用 `v02`、`v03`，不覆盖旧版。

示例：

```text
chr_lin_wantang_uniform_default_neutral_v01.png
chr_lin_wantang_uniform_default_gentle-smile_v02.png
chr_lin_wantang_casual_arms-crossed_displeased_v01.png
```

### 背景

格式：

```text
bg_<地点ID>_<时段或状态ID>_v<版本>.png
```

- `bg`：背景固定前缀。
- `地点ID`：稳定地点标识，如 `occult_clubroom`、`school_rooftop`、`library_aisle3`。
- `时段或状态ID`：如 `morning`、`evening`、`night-rain`、`lights-off`。
- 同一地点改变时间、天气或灯光时，应新建状态文件；只做质量修订时才递增版本号。

示例：

```text
bg_occult_clubroom_evening_v01.png
bg_occult_clubroom_night-rain_v01.png
bg_library_aisle3_lights-off_v02.png
```

### 源文件与中间文件

格式：

```text
src_<角色或地点ID>_<内容说明>_v<版本>.<扩展名>
```

`src_` 文件用于生成追溯、切图或二次编辑，不应由游戏运行时直接加载。临时文件使用 `tmp_` 前缀，并在交付前删除。

## 制作与接入约束

- 角色成品必须为 RGBA PNG，画布边角透明，禁止保留色键背景。
- 同一姿态的表情组应保持人物身份、服装、画布高度、头部位置和缩放比例一致。
- 异色瞳方向按角色自身计算：左眼琥珀金、右眼深海蓝；右眼下方保留泪痣。
- 左鬓细辫、银白星月发夹、左腕旧银铃、领口月牙旧疤属于角色锚点，不应随表情变化。
- 背景不含角色、UI、水印或可读文字；角色图不烘焙场景阴影，便于复用。
- 运行时只引用 `bg_` 与 `chr_` 文件；`src_` 文件建议从正式构建产物中排除。

## 本次生成提示词摘要

- 背景：日系视觉小说风格的青岚私立高中神秘学研究社活动室，黄昏冷蓝与暖琥珀混合光，无人物、无可读文字。
- 角色：日系视觉小说立绘，墨蓝长直发、左鬓细辫与星月发夹、左金右蓝异色瞳、右眼泪痣、校服、左腕银铃；三种状态为疲惫常态、温柔浅笑、警觉严肃。
- 生成方式：内置 ImageGen；角色母版采用纯绿色键背景，随后本地抠图为透明 PNG。
