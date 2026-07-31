<p align="center">
  <img src="./design/banner.png" alt="千知万理：GalGame × 多学科智能学习">
</p>

# 千知万理

> 把自己的复习资料，变成一场会记住学习进度的 GalGame。

千知万理（GalReview）是一款游戏化复习应用。你可以上传课程讲义、题库或其他资料，
选择准备复习的章节，然后通过剧情、对话和选择完成这一轮学习。

它并不只是给普通题目换一层游戏外观。每次游戏结束后，系统都会记住哪些内容已经
掌握、哪些内容仍然生疏，并据此调整之后的复习。不同课程使用各自的资料生成内容，
不需要被限制在预先制作好的固定题库中。

知识图谱只在幕后工作。它帮助系统理解章节和知识点之间的关系，判断游戏里应该先出现
什么、哪些内容可以一起复习，以及怎样用更少的题目覆盖本轮目标。玩家最终看到的是
连贯的游戏体验，而不是节点、权重和算法参数。

## 你可以用它做什么

- 上传自己的讲义、题库和课程资料
- 选择章节，开始一轮围绕真实学习内容生成的 GalGame
- 在剧情和交互中完成测试与复习
- 让系统记住学习结果，逐步调整后续内容
- 在不同学科之间保留各自独立的知识结构和进度

## 项目状态

千知万理仍在开发中。资料整理、学习进度和复习内容选择已经有了可运行的基础，
GalGame 内容生成与完整交互体验仍在继续整合。

## 开发者运行

当前仓库提供后端联调环境，需要 Docker Desktop 和 Docker Compose v2：

```powershell
docker compose -f compose.integration.yaml up -d --build --wait
```

停止环境：

```powershell
docker compose -f compose.integration.yaml down
```

## 目录

```text
GalReview/
├─ backend/                  # 后端服务
├─ gateway/                  # API Gateway
├─ frontend/                 # 前端预留目录
├─ design/                   # 项目图片
├─ docs/                     # 契约与测试记录
└─ compose.integration.yaml  # 本地集成环境
```

服务配置、接口和验证记录不在本页展开：

- [接口规范与数据契约](./docs/contract.md)
- [集成测试报告](./docs/test_report.md)
- [Gateway 开发说明](./gateway/README.md)
- [KnowledgeService 开发说明](./backend/KnowledgeService/README.md)

其他服务的运行方式见各自目录中的 README。
