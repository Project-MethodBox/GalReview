using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;

internal static class NarrativeTestData
{
    internal static readonly Guid ReviewPlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");
    internal static readonly Guid OwnerUserId = Guid.Parse("7bc4918a-9079-4ea2-9e8e-369ad79a9f20");
    internal static readonly Guid ChapterId = Guid.Parse("a1b2c3d4-e5f6-4890-abcd-ef1234567890");
    internal static readonly Guid PrerequisiteId = Guid.Parse("84f7d873-e573-4689-b18d-6f82c745d1bf");
    internal static readonly Guid TargetId = Guid.Parse("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb");
    internal const string SnapshotVersion = "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620";

    internal static PlanGraph CreatePlan(string? prerequisiteSummary = null) => new(
        SchemaVersion: "1.0",
        ReviewPlanId: ReviewPlanId,
        Type: "ASSESSMENT",
        Status: "OPEN",
        GraphId: Guid.Parse("b45d8f8f-4c55-4f28-9de6-2ad7dbb52dc0"),
        GraphVersion: 1,
        OwnerUserId: OwnerUserId,
        SelectedChapterIds: new[] { ChapterId },
        SnapshotVersion: SnapshotVersion,
        AlgorithmVersion: "assessment-planner-v1",
        Nodes: new[]
        {
            new PlanNode(
                PrerequisiteId,
                ChapterId,
                "水稻基本生长周期",
                prerequisiteSummary ?? "水稻从播种到成熟会经历幼苗期、分蘖期、拔节期、抽穗期和成熟期。",
                new[] { "水稻", "生长周期" },
                0.93,
                "PREREQUISITE",
                0.125,
                "PREREQUISITE_FOR_REQUESTED_TARGET",
                0,
                false,
                false,
                Array.Empty<Guid>(),
                new[] { TargetId }),
            new PlanNode(
                TargetId,
                ChapterId,
                "水稻分蘖期管理",
                "水稻分蘖期最关键的管理目标是协调群体数量与个体生长，通过水肥调控促进有效分蘖。",
                new[] { "水稻", "分蘖期" },
                0.12,
                "TARGET",
                0.875,
                "REQUESTED_CHAPTER_FORGETTING_RISK",
                1,
                true,
                false,
                new[] { TargetId },
                new[] { TargetId }),
        },
        Edges: new[] { new PlanEdge(PrerequisiteId, TargetId, "PREREQUISITE", 0.91, 0.91) },
        RootPointIds: new[] { TargetId },
        EstimatedQuestionCount: 1,
        EstimatedCoverage: 0.82,
        TotalWeight: 1,
        CreatedAt: DateTimeOffset.Parse("2026-07-27T08:50:00Z"),
        ExpiresAt: DateTimeOffset.Parse("2026-08-03T08:50:00Z"));

    internal static GameGenerationRequest CreateRequest(GameStyle style = GameStyle.CAMPUS) => new(
        ReviewPlanId,
        SnapshotVersion,
        style,
        Difficulty.STANDARD,
        "zh-CN",
        42);

    internal static GamePackage CreateSkeleton(PlanGraph? plan = null, GameGenerationRequest? request = null)
    {
        var generator = new GameGenerator(
            new GamePackageValidator(),
            NullLogger<GameGenerator>.Instance);
        return generator.Generate(
            plan ?? CreatePlan(),
            request ?? CreateRequest(),
            OwnerUserId.ToString());
    }

    internal static string CreateValidDraftJson(
        GamePackage skeleton,
        string promptVersion = "galgame-narrative-v2")
    {
        var scenes = skeleton.Scenes.Select((scene, sceneIndex) => new
        {
            sceneId = scene.SceneId,
            title = sceneIndex switch
            {
                0 => "雨停前的温室记录",
                1 => "被打乱的生长日志",
                2 => "十分钟的取舍",
                _ => "灯亮起来以后",
            },
            dialogue = new[]
            {
                new
                {
                    speakerId = sceneIndex % 2 == 0 ? "林澈" : "周岚",
                    text = sceneIndex switch
                    {
                        0 => "温室的自动灌溉还有十分钟启动，可这份记录少了决定性的那一页。",
                        1 => "先按生长阶段还原顺序；顺序错了，后面的判断都会失去依据。",
                        2 => "流量阀只能调一次。你会依据哪条记录做决定？",
                        _ => "水声落下前，缺失的记录终于回到了它该在的位置。",
                    },
                    emotion = sceneIndex == 2 ? "tense" : "focused",
                },
                new
                {
                    speakerId = "你",
                    text = sceneIndex switch
                    {
                        0 => "先别猜，我们把现有线索一条条对上。",
                        1 => "幼苗期之后进入分蘖期，这一段正是日志的断口。",
                        2 => "我会让分蘖期的判断和记录中的管理目标一致。",
                        _ => "这次不是背出一句话，而是让它真的解决了问题。",
                    },
                    emotion = "calm",
                },
            },
            groundingQuotes = scene.KnowledgeBindings.Any(binding => binding.Purpose == KnowledgePurpose.EXPLAIN)
                ? new[] { "幼苗期" }
                : scene.KnowledgeBindings.Any(binding => binding.Purpose == KnowledgePurpose.QUESTION)
                    ? new[] { "管理目标" }
                    : Array.Empty<string>(),
            knowledgeUse = scene.KnowledgeBindings.Any(binding => binding.Purpose == KnowledgePurpose.EXPLAIN)
                ? "用生长阶段顺序定位日志缺页"
                : scene.KnowledgeBindings.Any(binding => binding.Purpose == KnowledgePurpose.QUESTION)
                    ? "用管理目标决定一次性的水肥调整"
                    : null,
            choices = scene.Choices.Select((choice, choiceIndex) => new
            {
                choiceId = choice.ChoiceId,
                text = scene.KnowledgeBindings.Any(binding => binding.Purpose == KnowledgePurpose.QUESTION)
                    ? choice.Correct is true
                        ? "协调群体数量与个体生长，再调整水肥"
                        : $"只处理单一指标，暂不核对其余条件（方案 {choiceIndex + 1}）"
                    : sceneIndex == 0 ? "从缺页前后的记录开始查" : "把这条线索带到下一步",
                groundingQuote = scene.KnowledgeBindings.Any(binding => binding.Purpose == KnowledgePurpose.QUESTION)
                    ? "协调群体数量与个体生长"
                    : null,
            }),
        });

        return JsonSerializer.Serialize(new { promptVersion, scenes }, new JsonSerializerOptions(JsonSerializerDefaults.Web));
    }
}
