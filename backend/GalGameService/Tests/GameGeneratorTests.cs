using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

// ============================================================================
// 游戏包生成器测试（§7.3.1 + §7.5 交付物验证）
//
// 验证：
// - 3 种 style（CAMPUS/FANTASY/SCIENCE）× 3 种 difficulty（BASIC/STANDARD/ADVANCED）
//   组合均能生成通过校验器的游戏包
// - 生成的 questionId 在包内唯一
// - 仅 questionTarget=true 的节点生成计分题
// - 相同 seed → 相同 questionId（可复现）
// ============================================================================

public class GameGeneratorTests
{
    private readonly GamePackageValidator _validator = new();
    private readonly GameGenerator _generator = new(
        new GamePackageValidator(),
        NullLogger<GameGenerator>.Instance);

    // 与 PlanGraphClient.MockReviewPlanId / MockSnapshotVersion 一致
    private static readonly Guid MockReviewPlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");
    private const string MockSnapshotVersion = "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620";

    // ------------------------------------------------------------------------
    // 测试用 PlanGraph：1 个 TARGET 节点 + 1 个 PREREQUISITE 节点
    // ------------------------------------------------------------------------

    private static readonly Guid TargetPointId = Guid.Parse("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb");
    private static readonly Guid PrereqPointId = Guid.Parse("84f7d873-e573-4689-b18d-6f82c745d1bf");
    private static readonly Guid ChapterId = Guid.Parse("a1b2c3d4-e5f6-7890-abcd-ef1234567890");

    private static PlanGraph CreateMockPlanGraph() => new(
        SchemaVersion: "1.0",
        ReviewPlanId: MockReviewPlanId,
        Type: "ASSESSMENT",
        Status: "OPEN",
        GraphId: Guid.Parse("b45d8f8f-4c55-4f28-9de6-2ad7dbb52dc0"),
        GraphVersion: 1,
        OwnerUserId: Guid.Parse("7bc4918a-9079-4ea2-9e8e-369ad79a9f20"),
        SelectedChapterIds: new[] { ChapterId },
        SnapshotVersion: MockSnapshotVersion,
        AlgorithmVersion: "assessment-planner-v1",
        Nodes: new PlanNode[]
        {
            new(PrereqPointId, ChapterId, "水稻基本生长周期",
                "水稻从播种到成熟的完整生长周期，包括幼苗期、分蘖期、拔节期、抽穗期和成熟期。",
                new[] { "水稻", "生长周期" }, 0, "PREREQUISITE", 0.5,
                "PREREQUISITE_FOR_REQUESTED_TARGET", 0, false, false,
                Array.Empty<Guid>(), new[] { TargetPointId }),
            new(TargetPointId, ChapterId, "水稻分蘖期管理",
                "水稻分蘖期最关键的管理目标是协调群体数量与个体生长，通过水肥调控促进有效分蘖。",
                new[] { "水稻", "分蘖期" }, 0, "TARGET", 0.5,
                "REQUESTED_CHAPTER_FORGETTING_RISK", 1, true, false,
                new[] { TargetPointId }, new[] { TargetPointId }),
        },
        Edges: new PlanEdge[]
        {
            new(PrereqPointId, TargetPointId, "PREREQUISITE", 0.91, 0.91),
        },
        RootPointIds: new[] { TargetPointId },
        EstimatedQuestionCount: 1,
        EstimatedCoverage: 0.82,
        TotalWeight: 1.0,
        CreatedAt: DateTimeOffset.Parse("2026-07-27T08:50:00Z"),
        ExpiresAt: DateTimeOffset.Parse("2026-08-03T08:50:00Z"));

    private static GameGenerationRequest CreateRequest(GameStyle style, Difficulty difficulty, long? seed = null) => new(
        ReviewPlanId: MockReviewPlanId,
        SnapshotVersion: MockSnapshotVersion,
        Style: style,
        Difficulty: difficulty,
        Locale: "zh-CN",
        Seed: seed);

    // ------------------------------------------------------------------------
    // 测试用例
    // ------------------------------------------------------------------------

    [Theory]
    [InlineData(GameStyle.CAMPUS, Difficulty.BASIC)]
    [InlineData(GameStyle.CAMPUS, Difficulty.STANDARD)]
    [InlineData(GameStyle.CAMPUS, Difficulty.ADVANCED)]
    [InlineData(GameStyle.FANTASY, Difficulty.BASIC)]
    [InlineData(GameStyle.FANTASY, Difficulty.STANDARD)]
    [InlineData(GameStyle.FANTASY, Difficulty.ADVANCED)]
    [InlineData(GameStyle.SCIENCE, Difficulty.BASIC)]
    [InlineData(GameStyle.SCIENCE, Difficulty.STANDARD)]
    [InlineData(GameStyle.SCIENCE, Difficulty.ADVANCED)]
    public void Generate_AllStyleDifficultyCombos_PassValidation(GameStyle style, Difficulty difficulty)
    {
        var plan = CreateMockPlanGraph();
        var req = CreateRequest(style, difficulty, seed: 42);
        var ownerUserId = "7bc4918a-9079-4ea2-9e8e-369ad79a9f20";

        var pkg = _generator.Generate(plan, req, ownerUserId);

        // 生成的包必须通过校验器
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid, $"生成的包未通过校验：{string.Join("; ", result.Errors.Select(e => $"{e.Path}:{e.Code}"))}");

        // schemaVersion 必须为 1.0
        Assert.Equal("1.0", pkg.SchemaVersion);
        // entrySceneId 必须指向存在的场景
        Assert.Contains(pkg.Scenes, s => s.SceneId == pkg.EntrySceneId);
        // 场景数量 > 0
        Assert.NotEmpty(pkg.Scenes);
    }

    [Fact]
    public void Generate_OnlyQuestionTargetNodes_BecomeScoredQuestions()
    {
        var plan = CreateMockPlanGraph();
        var req = CreateRequest(GameStyle.CAMPUS, Difficulty.STANDARD, seed: 100);
        var pkg = _generator.Generate(plan, req, "user-1");

        // PlanGraph 中只有 1 个 questionTarget=true 的节点
        // QUESTION 绑定的数量应该等于 target 节点数量
        var questionBindings = pkg.Scenes
            .SelectMany(s => s.KnowledgeBindings)
            .Where(b => b.Purpose == KnowledgePurpose.QUESTION)
            .ToList();
        Assert.Single(questionBindings);

        // 该 questionId 必须在 choices 中出现
        var questionId = questionBindings[0].QuestionId!.Value;
        Assert.Contains(pkg.Scenes.SelectMany(s => s.Choices), c => c.QuestionId == questionId);

        // 正确性和证据类型显式绑定；scoreDelta 只保留游戏计分策略。
        var scoredChoices = pkg.Scenes
            .SelectMany(s => s.Choices)
            .Where(c => c.QuestionId == questionId)
            .ToList();
        Assert.Single(scoredChoices, c => c.Correct is true);
        Assert.All(scoredChoices, c => Assert.Equal(AnswerKind.CHOICE, c.AnswerKind));
        Assert.All(scoredChoices.Where(c => c.Correct is false), c => Assert.Equal(questionId, c.QuestionId));
    }

    [Fact]
    public void Generate_SameSeed_ProducesSameQuestionIds()
    {
        var plan = CreateMockPlanGraph();
        var req1 = CreateRequest(GameStyle.CAMPUS, Difficulty.STANDARD, seed: 999);
        var req2 = CreateRequest(GameStyle.CAMPUS, Difficulty.STANDARD, seed: 999);

        var pkg1 = _generator.Generate(plan, req1, "user-1");
        var pkg2 = _generator.Generate(plan, req2, "user-2");

        // 相同 seed → 相同 questionId（可复现）
        var qids1 = pkg1.Scenes
            .SelectMany(s => s.KnowledgeBindings)
            .Where(b => b.Purpose == KnowledgePurpose.QUESTION && b.QuestionId is not null)
            .Select(b => b.QuestionId!.Value)
            .OrderBy(g => g)
            .ToList();
        var qids2 = pkg2.Scenes
            .SelectMany(s => s.KnowledgeBindings)
            .Where(b => b.Purpose == KnowledgePurpose.QUESTION && b.QuestionId is not null)
            .Select(b => b.QuestionId!.Value)
            .OrderBy(g => g)
            .ToList();

        Assert.Equal(qids1, qids2);
    }

    [Fact]
    public void Generate_DifferentSeed_ProducesDifferentQuestionIds()
    {
        var plan = CreateMockPlanGraph();
        var req1 = CreateRequest(GameStyle.CAMPUS, Difficulty.STANDARD, seed: 1);
        var req2 = CreateRequest(GameStyle.CAMPUS, Difficulty.STANDARD, seed: 2);

        var pkg1 = _generator.Generate(plan, req1, "user-1");
        var pkg2 = _generator.Generate(plan, req2, "user-1");

        var qid1 = pkg1.Scenes
            .SelectMany(s => s.KnowledgeBindings)
            .First(b => b.Purpose == KnowledgePurpose.QUESTION).QuestionId!.Value;
        var qid2 = pkg2.Scenes
            .SelectMany(s => s.KnowledgeBindings)
            .First(b => b.Purpose == KnowledgePurpose.QUESTION).QuestionId!.Value;

        Assert.NotEqual(qid1, qid2);
    }

    [Fact]
    public void Generate_DifficultyAffectsChoiceCount()
    {
        var plan = CreateMockPlanGraph();

        var basicPkg = _generator.Generate(plan, CreateRequest(GameStyle.SCIENCE, Difficulty.BASIC, seed: 1), "u");
        var advancedPkg = _generator.Generate(plan, CreateRequest(GameStyle.SCIENCE, Difficulty.ADVANCED, seed: 1), "u");

        // 题目场景的选项数量：BASIC=4（1正确+3干扰），ADVANCED=3（1正确+2干扰）
        var basicChoices = basicPkg.Scenes
            .Where(s => s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.QUESTION))
            .SelectMany(s => s.Choices)
            .Count();
        var advancedChoices = advancedPkg.Scenes
            .Where(s => s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.QUESTION))
            .SelectMany(s => s.Choices)
            .Count();

        Assert.True(basicChoices > advancedChoices,
            $"BASIC 选项数 ({basicChoices}) 应大于 ADVANCED 选项数 ({advancedChoices})");
    }

    [Fact]
    public void Generate_ScenesAreLinkedViaNextSceneId()
    {
        var plan = CreateMockPlanGraph();
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.FANTASY, Difficulty.STANDARD, seed: 7), "u");

        // 除最后一个场景外，每个有 choice 的场景的 choice.nextSceneId 都应指向存在的场景
        var sceneIds = pkg.Scenes.Select(s => s.SceneId).ToHashSet();
        var choicesWithNext = pkg.Scenes
            .SelectMany(s => s.Choices)
            .Where(c => c.NextSceneId is not null)
            .ToList();

        Assert.NotEmpty(choicesWithNext);
        Assert.All(choicesWithNext, c => Assert.Contains(c.NextSceneId!, sceneIds));
    }

    [Fact]
    public void Generate_NoQuestionTargetNodes_CreatesExplanationOnlyPackage()
    {
        // 构造一个没有 questionTarget=true 节点的 PlanGraph
        var plan = CreateMockPlanGraph() with
        {
            Nodes = new PlanNode[]
            {
                new(PrereqPointId, ChapterId, "前置知识点", "前置内容",
                    new[] { "tag" }, 0, "PREREQUISITE", 1.0,
                    "PREREQUISITE", 0, false, false,
                    Array.Empty<Guid>(), Array.Empty<Guid>()),
            },
        };

        var req = CreateRequest(GameStyle.CAMPUS, Difficulty.BASIC, seed: 1);
        var package = _generator.Generate(plan, req, "u");
        var questionBindings = package.Scenes
            .SelectMany(scene => scene.KnowledgeBindings)
            .Where(binding => binding.Purpose == KnowledgePurpose.QUESTION)
            .ToArray();
        var scoringChoices = package.Scenes
            .SelectMany(scene => scene.Choices)
            .Where(choice => choice.Correct is not null || choice.AnswerKind is not null)
            .ToArray();

        Assert.Empty(questionBindings);
        Assert.Empty(scoringChoices);
        Assert.Contains(package.Scenes.SelectMany(scene => scene.KnowledgeBindings),
            binding => binding.Purpose == KnowledgePurpose.EXPLAIN);
        Assert.True(_validator.Validate(package).Valid);
    }

    [Fact]
    public void Generate_PreservesReviewPlanIdAndSnapshotVersion()
    {
        var plan = CreateMockPlanGraph();
        var req = CreateRequest(GameStyle.SCIENCE, Difficulty.ADVANCED, seed: 314);
        var pkg = _generator.Generate(plan, req, "u");

        Assert.Equal(req.ReviewPlanId, pkg.ReviewPlanId);
        Assert.Equal(req.SnapshotVersion, pkg.SnapshotVersion);
    }

    // ------------------------------------------------------------------------
    // 深度优化后新增测试
    // ------------------------------------------------------------------------

    [Fact]
    public void Generate_NullPlan_ThrowsArgumentNullException()
    {
        var req = CreateRequest(GameStyle.CAMPUS, Difficulty.BASIC, seed: 1);
        Assert.Throws<ArgumentNullException>(() => _generator.Generate(null!, req, "u"));
    }

    [Fact]
    public void Generate_NullRequest_ThrowsArgumentNullException()
    {
        var plan = CreateMockPlanGraph();
        Assert.Throws<ArgumentNullException>(() => _generator.Generate(plan, null!, "u"));
    }

    [Fact]
    public void Generate_EmptyNodesArray_ThrowsArgumentException()
    {
        var plan = CreateMockPlanGraph() with { Nodes = Array.Empty<PlanNode>() };
        var req = CreateRequest(GameStyle.CAMPUS, Difficulty.BASIC, seed: 1);
        Assert.Throws<ArgumentException>(() => _generator.Generate(plan, req, "u"));
    }

    [Fact]
    public void Generate_NullNodesArray_ThrowsArgumentException()
    {
        var plan = CreateMockPlanGraph() with { Nodes = null! };
        var req = CreateRequest(GameStyle.CAMPUS, Difficulty.BASIC, seed: 1);
        Assert.Throws<ArgumentException>(() => _generator.Generate(plan, req, "u"));
    }

    [Fact]
    public void Generate_DistractorsAreUnique()
    {
        var plan = CreateMockPlanGraph();
        var req = CreateRequest(GameStyle.CAMPUS, Difficulty.STANDARD, seed: 42);
        var pkg = _generator.Generate(plan, req, "u");

        // 找到题目场景（有 QUESTION 绑定的场景）
        var questionScene = pkg.Scenes.First(s =>
            s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.QUESTION));

        // 所有选项的 text 应该互不相同（正确答案 + 干扰项不重复）
        var choiceTexts = questionScene.Choices.Select(c => c.Text).ToList();
        var uniqueTexts = choiceTexts.Distinct(StringComparer.Ordinal).ToList();
        Assert.Equal(choiceTexts.Count, uniqueTexts.Count);
    }

    [Fact]
    public void Generate_ChoiceIdsUniqueWithinScene()
    {
        var plan = CreateMockPlanGraph();
        var req = CreateRequest(GameStyle.FANTASY, Difficulty.ADVANCED, seed: 77);
        var pkg = _generator.Generate(plan, req, "u");

        // 每个场景内的 choiceId 应唯一
        foreach (var scene in pkg.Scenes)
        {
            var choiceIds = scene.Choices.Select(c => c.ChoiceId).ToList();
            var uniqueIds = choiceIds.Distinct(StringComparer.Ordinal).ToList();
            Assert.Equal(choiceIds.Count, uniqueIds.Count);
        }
    }

    [Fact]
    public void Generate_ExactlyOneCorrectChoicePerQuestion()
    {
        var plan = CreateMockPlanGraph();
        var req = CreateRequest(GameStyle.SCIENCE, Difficulty.STANDARD, seed: 256);
        var pkg = _generator.Generate(plan, req, "u");

        // 每道题恰好有 1 个 ScoreDelta > 0 的选项
        var questionChoices = pkg.Scenes
            .SelectMany(s => s.Choices)
            .Where(c => c.ScoreDelta > 0)
            .GroupBy(c => c.QuestionId)
            .ToDictionary(g => g.Key, g => g.Count());

        Assert.All(questionChoices, kvp => Assert.Equal(1, kvp.Value));
    }

    [Fact]
    public void Generate_AllScenesHaveDialogue()
    {
        var plan = CreateMockPlanGraph();
        var req = CreateRequest(GameStyle.CAMPUS, Difficulty.BASIC, seed: 11);
        var pkg = _generator.Generate(plan, req, "u");

        // 每个场景至少有 1 条对话
        Assert.All(pkg.Scenes, scene => Assert.NotEmpty(scene.Dialogue));
    }
}
