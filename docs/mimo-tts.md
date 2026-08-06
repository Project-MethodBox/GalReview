# MiMo V2.5 TTS 接入

GalGameService 会在剧情生成完成后，为角色台词调用 `mimo-v2.5-tts`。生成的 WAV 音频作为包级资源保存，前端进入对应台词时自动播放，并在播放期间降低背景音乐音量。

旁白和玩家台词（`旁白`、`你`、`narrator`）不会合成。单句合成失败时会跳过该句，不会导致整个游戏包生成失败。

## 配置

不要把密钥提交到 `appsettings.json`。PowerShell 本地启动前设置：

```powershell
$env:MIMO_API_KEY = '<你的 MiMo API Key>'
dotnet run --project backend/GalGameService/GalGame.GalGameService.csproj
```

使用 Compose 时同样在当前终端设置 `MIMO_API_KEY`，`compose.integration.yaml` 会把它注入 GalGameService。

可选环境变量：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `MIMO_API_KEY` | 空 | MiMo API 密钥；为空时自动跳过语音生成 |
| `GALGAME_VOICE_ENABLED` | `true` | Compose 中启用或关闭角色语音 |
| `MIMO_TTS_ENDPOINT` | `https://api.xiaomimimo.com/v1/chat/completions` | MiMo 兼容接口地址 |
| `MIMO_TTS_MAX_CONCURRENCY` | `2` | 同时合成的台词数 |

`MOONSTONE_MODE=Mock` 时外部 TTS 会被强制关闭，避免测试和演示意外产生调用费用。

## 数据流

1. 服务生成并校验剧情台词。
2. 角色名映射到 MiMo 预置音色，并把台词情绪作为语音上下文。
3. Base64 WAV 解码后保存到内存存储或 MongoDB 的 `game_audio` 集合。
4. 游戏包 `assets` 增加 `AUDIO` 引用，例如 `voice-000-002`。
5. 前端携带用户令牌读取 `/api/v1/game-packages/{packageId}/audio/{assetId}` 并播放。

音频接口沿用游戏包所有权校验；用户只能读取自己游戏包中明确引用的语音资产。
