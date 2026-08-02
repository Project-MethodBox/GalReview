# 青岚私立高中主角静态素材库

本目录包含 3 位主角，每位主角提供 3 张互相独立、可直接加载的透明动作立绘。背景素材暂存于林学姐目录，后续可迁移到统一的 `design/background/`。

## 角色索引

| 目录 | 角色 ID | 人物 | 成品数量 |
| --- | --- | --- | --- |
| `林学姐/` | `lin_wantang` | 林晚棠，神秘学研究社社长 | 3 |
| `苏学姐/` | `su_wanqing` | 苏晚晴，新闻社副社长 | 3 |
| `陆学长/` | `lu_chen` | 陆沉，学生会副会长／物理社社长 | 3 |

> 资料中的陆沉为男性，因此作为第三位主角收录于 `陆学长/`，不按“女主”标签改变人物设定。

## 正式角色文件命名规范

```text
chr_<character-id>_<costume-id>_<action-id>_<expression-id>_v<NN>.png
```

字段要求：

| 字段 | 含义 | 规则与示例 |
| --- | --- | --- |
| `chr` | 资源类型 | 角色成品固定使用 `chr` |
| `character-id` | 稳定角色 ID | 小写蛇形命名，如 `lin_wantang`；一经接入不得更改 |
| `costume-id` | 服装套装 | `uniform`、`casual`、`festival` 等 |
| `action-id` | 身体动作／道具交互 | 使用可观察动作，如 `anomaly-scan`，复合词用连字符 |
| `expression-id` | 面部情绪 | 如 `neutral`、`excited`、`uneasy`；不可用 `default`、`other` 等含糊词 |
| `v<NN>` | 两位版本号 | 初版 `v01`；重绘或明显画面修订递增为 `v02`，不得覆盖旧版 |

命名示例：

```text
chr_lin_wantang_uniform_stop-warning_alert-serious_v01.png
chr_su_wanqing_uniform_dash-investigation_excited_v01.png
chr_lu_chen_uniform_anomaly-scan_serious_v01.png
```

## 动作与表情的划分

- `action-id` 描述轮廓、身体姿势或道具交互；即使面部相同，只要姿势发生明显变化，也应使用新的动作 ID。
- `expression-id` 只描述面部状态。相同动作仅改变表情时，保留动作 ID，修改表情 ID。
- 禁止将序号作为动作语义，例如 `pose1`、`action02`。顺序应由剧情配置决定，而非文件名。
- 同一角色的动作 ID 不复用为不同含义；跨角色可使用同名动作，只要语义确实相同。

## 源文件与中间文件

生成母版采用：

```text
src_<character-id>_action-sheet_v<NN>.png
```

- `src_` 是生成追溯和重新切图用母版，禁止游戏运行时直接引用。
- `tmp_` 仅供处理中间文件使用，交付前必须删除。
- 正式构建只收集 `chr_*.png`；`src_*.png` 和 README 应从发行包排除。

## 图像规格与一致性要求

- 正式立绘必须为 RGBA PNG，透明角像素的 alpha 值必须为 `0`。
- 每张文件只允许出现一个角色和一个动作，不得保留三联图、面板线、文字或色键背景。
- 同一角色必须保持脸型、发色、瞳色、发饰、制服设计和标志性道具一致。
- 动作不得裁掉头部或关键手势；角色周围保留透明留白，方便引擎定位。
- 不烘焙场景阴影、UI、对白、水印或可读文字。
- 长发和细小道具抠图需启用柔边、去色溢，并检查深色与浅色背景下的边缘。

## 背景命名规范

```text
bg_<location-id>_<time-or-state-id>_v<NN>.png
```

示例：`bg_occult_clubroom_evening_v01.png`。地点变化应更换 `location-id`；时间、天气或开灯状态变化应更换 `time-or-state-id`；仅画质修订才递增版本号。

## 本批动作清单

| 角色 | 动作 1 | 动作 2 | 动作 3 |
| --- | --- | --- | --- |
| 林晚棠 | 棒棒糖休息 | 递出棒棒糖 | 抬手警告 |
| 苏晚晴 | 记者采访记录 | 冲刺调查 | 站立遮眼 |
| 陆沉 | 理性记录 | 异常扫描 | 黑暗警戒 |

生成方式：内置 ImageGen 生成绿幕动作母版，再使用本地色键抠除、柔边、去绿边和 1 像素边缘收缩得到正式透明 PNG。
