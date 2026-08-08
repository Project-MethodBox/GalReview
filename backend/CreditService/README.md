# CreditService

千知万理 credits 的唯一事实所有者。服务采用 API、Application、Domain、Persistence 四层结构，Application 通过 MediatR 实现 CQRS。

职责包括初始额度、余额、生成预授权、实际结算、兑换码兑换、管理员批量创建与撤销。注册邀请码不再属于准入流程。

用户接口只返回 credits 数值，不返回内部 token 换算或原始计量单位。生成服务通过受信内部接口提交预估和实际使用量；预授权不足返回 `402 CREDITS_INSUFFICIENT`。

## 分层

- `CreditService.API`：Gateway 信任边界、HTTP DTO、错误信封，只通过 MediatR 发送请求。
- `CreditService.Application`：账户、兑换码与预授权的 Command/Query 和 Handler。
- `CreditService.Domain`：整数计量、账户、兑换码、预授权状态与领域错误。
- `CreditService.Persistence`：MySQL repository、事务、兑换码摘要和不可变账本；测试/本地可切换 Memory。

默认端口为 `5108`，生产数据库为独立 MySQL `qzwl_credit`。配置项：

```text
Gateway__ServiceKey
CreditStore__Provider=MySQL
ConnectionStrings__CreditDatabase
```

用户接口为 `GET /api/v1/credits/balance`、`POST /api/v1/credits/redemptions`；管理员通过
`/api/v1/admin/credit-codes` 列表、批量创建与撤销。完整兑换码只在创建响应出现一次，数据库
只保存 SHA-256 摘要与末尾字符。AuthService 可幂等创建初始账户；PracticeService 与
GalGameService 可调用 INTERNAL 预授权、结算和释放。全部跨服务流量必须经过 Gateway。

现有老用户不要求离线跨库扫描：首次余额、兑换或预授权请求会幂等创建账户并发放一次初始
credits。用户 UI 不得展示服务端内部换算常量，具体语义以 `docs/contract.md` 第 15 节为准。

验证：

```powershell
dotnet test .\CreditService.slnx
docker build -t qzwl-credit-service .
```
