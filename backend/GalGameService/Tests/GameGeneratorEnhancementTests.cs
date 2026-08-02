using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

// ============================================================================
// 生成器增强功能测试（P3：干扰项质量 + EXPLAIN 深度 + 资源引用 + LEARNING 支持）
//
// 验证：
// - P3.1 干扰项质量：语义化干扰项不再是纯 Title，通用干扰项含领域知识
// - P3.2 EXPLAIN 深度：BASIC=2 行 / STANDARD=3 行 / ADVANCED=4 行
// - P3.3 资源引用：生成的包含非空 Assets 数组，包含背景/角色/音频
// - P3.4 LEARNING 支持：LEARNING 类型 PlanGraph 生成学习验收场景
// ============================================================================

public class GameGeneratorEnhancementTests
{
    private readonly GamePackageValidator _validator = new();
    private readonly GameGenerator _generator = new(
        new GamePackageValidator(),
        NullLogger<GameGenerator>.Instance);

    private static readonly Guid MockReviewPlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");
    private const string MockSnapshotVersion = "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620";

    private static readonly Guid TargetPointId = Guid.Parse("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb");
    private static readonly Guid PrereqPointId = Guid.Parse("84f7d873-e573-4689-b18d-6f82c745d1bf");
    private static readonly Guid ChapterId = Guid.Parse("a1b2c3d4-e5f6-7890-abcd-ef1234567890");

    // -----------------------------------------------------------------------
    // 测试用 PlanGraph：1 个 TARGET + 1 个 PREREQUISITE（ASSESSMENT 类型）
    // -----------------------------------------------------------------------

    private static PlanGraph CreateMockPlanGraph(string type = "ASSESSMENT") => new(
        SchemaVersion: "1.0",
        ReviewPlanId: MockReviewPlanId,
        Type: type,
        Status: "OPEN",
        GraphId: Guid.Parse("b45d8f8f-4c55-4f28-9de6-2ad7dbb52dc0"),
        GraphVersion: 1,
        OwnerUserId: Guid.Parse("7bc4918a-9079-4ea2-9e8e-369ad79a9f20"),
        SelectedChapterIds: new[] { ChapterId },
        SnapshotVersion: MockSnapshotVersion,
        AlgorithmVersion: type == "LEARNING" ? "learning-planner-v1" : "assessment-planner-v1",
        Nodes: new PlanNode[]
        {
            new(PrereqPointId, ChapterId, "水稻基本生长周期",
                "水稻从播种到成熟的完整生长周期，包括幼苗期、分蘖期、拔节期、抽穗期和成熟期。各阶段的时长受温度和光照影响显著。",
                new[] { "水稻", "生长周期" }, 0, "PREREQUISITE", 0.5,
                "PREREQUISITE_FOR_REQUESTED_TARGET", 1, false, false,
                Array.Empty<Guid>(), new[] { TargetPointId }),
            new(TargetPointId, ChapterId, "水稻分蘖期管理",
                "水稻分蘖期最关键的管理目标是协调群体数量与个体生长，通过水肥调控促进有效分蘖。",
                new[] { "水稻", "分蘖期" }, 0, "TARGET", 0.5,
                "REQUESTED_CHAPTER_FORGETTING_RISK", 0, true, false,
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

    // ========================================================================
    // P3.1 干扰项质量提升
    // ========================================================================

    [Theory]
    [InlineData(GameStyle.CAMPUS, Difficulty.BASIC)]
    [InlineData(GameStyle.FANTASY, Difficulty.STANDARD)]
    [InlineData(GameStyle.SCIENCE, Difficulty.ADVANCED)]
    public void Generate_DistractorsAreSemanticallyMeaningful(GameStyle style, Difficulty difficulty)
    {
        var plan = CreateMockPlanGraph();
        var pkg = _generator.Generate(plan, CreateRequest(style, difficulty, seed: 42), "u");

        // 找到题目场景
        var questionScene = pkg.Scenes.First(s =>
            s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.QUESTION));

        // 干扰项文本不应为纯知识点标题（旧实现的行为）
        var distractors = questionScene.Choices.Where(c => c.Correct is false).ToList();
        Assert.NotEmpty(distractors);

        // 干扰项不应与任何 PlanNode 的 Title 完全相同（旧实现直接用 Title 做干扰项）
        var allTitles = plan.Nodes!.Select(n => n.Title).ToHashSet();
        foreach (var d in distractors)
        {
            Assert.False(allTitles.Contains(d.Text),
                $"干扰项「{d.Text}」不应与知识点标题完全相同");
        }
    }

    [Fact]
    public void Generate_DistractorsDoNotContainGenericPlaceholderText()
    {
        var plan = CreateMockPlanGraph();
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.CAMPUS, Difficulty.BASIC, seed: 1), "u");

        var questionScene = pkg.Scenes.First(s =>
            s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.QUESTION));

        // 旧实现的通用干扰项文本不应出现
        var oldGenericTexts = new[] { "以上都不对", "与题目无关的选项", "需要更多信息才能判断",
            "部分正确但不完整", "方向相反的结论", "条件不足无法确定",
            "看似合理但存在关键缺陷", "仅适用于特殊情况" };

        foreach (var choice in questionScene.Choices)
        {
            Assert.False(oldGenericTexts.Contains(choice.Text),
                $"选项「{choice.Text}」不应使用旧版通用占位文本");
        }
    }

    [Fact]
    public void Generate_DistractorsFromMultiSentenceSummary()
    {
        // 构造 Summary 含多句的节点，验证干扰项从第二句提取
        var plan = CreateMockPlanGraph() with
        {
            Nodes = new PlanNode[]
            {
                new(PrereqPointId, ChapterId, "水稻基本生长周期",
                    "水稻从播种到成熟的完整生长周期包括五个阶段。每个阶段对温度和水分的需求各不相同。",
                    new[] { "水稻" }, 0, "PREREQUISITE", 0.5,
                    "PREREQUISITE", 1, false, false,
                    Array.Empty<Guid>(), new[] { TargetPointId }),
                new(TargetPointId, ChapterId, "水稻分蘖期管理",
                    "分蘖期是水稻生长的关键时期。",
                    new[] { "水稻", "分蘖期" }, 0, "TARGET", 0.5,
                    "REQUESTED_CHAPTER_FORGETTING_RISK", 0, true, false,
                    new[] { TargetPointId }, new[] { TargetPointId }),
            },
        };

        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.SCIENCE, Difficulty.STANDARD, seed: 99), "u");

        // 前置节点的 Summary 有第二句，应被提取为干扰项
        var questionScene = pkg.Scenes.First(s =>
            s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.QUESTION));
        var distractors = questionScene.Choices.Where(c => c.Correct is false).ToList();

        // 至少有一个干扰项包含前置节点第二句的内容
        Assert.Contains(distractors, d => d.Text.Contains("每个阶段对温度"));
    }

    // ========================================================================
    // P3.2 EXPLAIN 场景对话深度增强
    // ========================================================================

    [Theory]
    [InlineData(Difficulty.BASIC, 2)]
    [InlineData(Difficulty.STANDARD, 3)]
    [InlineData(Difficulty.ADVANCED, 4)]
    public void Generate_ExplainSceneDialogueDepthScalesWithDifficulty(Difficulty difficulty, int expectedMinLines)
    {
        var plan = CreateMockPlanGraph();
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.CAMPUS, difficulty, seed: 42), "u");

        // 找到 EXPLAIN 场景（PREREQUISITE 节点的讲解）
        var explainScenes = pkg.Scenes
            .Where(s => s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.EXPLAIN))
            .ToList();

        Assert.NotEmpty(explainScenes);
        foreach (var scene in explainScenes)
        {
            Assert.True(scene.Dialogue.Length >= expectedMinLines,
                $"EXPLAIN 场景「{scene.Title}」对话行数 {scene.Dialogue.Length} < 预期最小 {expectedMinLines}");
        }
    }

    [Fact]
    public void Generate_AdvancedExplainSceneContainsDependencyInfo()
    {
        var plan = CreateMockPlanGraph();
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.FANTASY, Difficulty.ADVANCED, seed: 7), "u");

        var explainScene = pkg.Scenes.First(s =>
            s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.EXPLAIN));

        // ADVANCED 难度的 EXPLAIN 场景最后一行应包含权重信息
        var lastLine = explainScene.Dialogue[^1];
        Assert.Contains("权重", lastLine.Text);
    }

    [Fact]
    public void Generate_StandardExplainSceneContainsTagHint()
    {
        var plan = CreateMockPlanGraph();
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.SCIENCE, Difficulty.STANDARD, seed: 33), "u");

        var explainScene = pkg.Scenes.First(s =>
            s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.EXPLAIN));

        // STANDARD 难度的 EXPLAIN 场景应包含 Tags 相关内容
        var allText = string.Join("", explainScene.Dialogue.Select(d => d.Text));
        Assert.Contains("关键标签", allText);
    }

    [Fact]
    public void Generate_BasicExplainSceneDoesNotHaveExtraDepth()
    {
        var plan = CreateMockPlanGraph();
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.CAMPUS, Difficulty.BASIC, seed: 5), "u");

        var explainScene = pkg.Scenes.First(s =>
            s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.EXPLAIN));

        // BASIC 难度只有基础 2 行，不含额外深度内容
        Assert.Equal(2, explainScene.Dialogue.Length);
        Assert.DoesNotContain("权重", explainScene.Dialogue[^1].Text);
    }

    // ========================================================================
    // P3.3 资源引用生成
    // ========================================================================

    [Theory]
    [InlineData(GameStyle.CAMPUS)]
    [InlineData(GameStyle.FANTASY)]
    [InlineData(GameStyle.SCIENCE)]
    public void Generate_PackageContainsNonEmptyAssets(GameStyle style)
    {
        var plan = CreateMockPlanGraph();
        var pkg = _generator.Generate(plan, CreateRequest(style, Difficulty.STANDARD, seed: 1), "u");

        Assert.NotEmpty(pkg.Assets);

        // 必须包含 BACKGROUND、CHARACTER、AUDIO 三种类型
        var types = pkg.Assets.Select(a => a.Type).Distinct().ToHashSet();
        Assert.Contains(AssetType.BACKGROUND, types);
        Assert.Contains(AssetType.CHARACTER, types);
        Assert.Contains(AssetType.AUDIO, types);
    }

    [Fact]
    public void Generate_AssetIdsAreUnique()
    {
        var plan = CreateMockPlanGraph();
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.FANTASY, Difficulty.ADVANCED, seed: 42), "u");

        var assetIds = pkg.Assets.Select(a => a.AssetId).ToList();
        var uniqueIds = assetIds.Distinct(StringComparer.Ordinal).ToList();
        Assert.Equal(assetIds.Count, uniqueIds.Count);
    }

    [Fact]
    public void Generate_AssetUrisFollowStyleConvention()
    {
        var plan = CreateMockPlanGraph();
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.SCIENCE, Difficulty.BASIC, seed: 88), "u");

        // 所有 URI 应以 assets/science/ 开头
        Assert.All(pkg.Assets, a =>
            Assert.StartsWith("assets/science/", a.Uri));
    }

    [Fact]
    public void Generate_AssetsPassValidator()
    {
        var plan = CreateMockPlanGraph();
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.CAMPUS, Difficulty.STANDARD, seed: 77), "u");

        var result = _validator.Validate(pkg);
        Assert.True(result.Valid, $"含资源引用的包未通过校验：{string.Join("; ", result.Errors.Select(e => $"{e.Path}:{e.Code}"))}");
    }

    [Fact]
    public void Generate_AtLeastThreeBackgroundsPerStyle()
    {
        var plan = CreateMockPlanGraph();
        foreach (var style in new[] { GameStyle.CAMPUS, GameStyle.FANTASY, GameStyle.SCIENCE })
        {
            var pkg = _generator.Generate(plan, CreateRequest(style, Difficulty.STANDARD, seed: 1), "u");
            var bgCount = pkg.Assets.Count(a => a.Type == AssetType.BACKGROUND);
            Assert.True(bgCount >= 3, $"风格 {style} 的背景资源数 {bgCount} < 3");
        }
    }

    // ========================================================================
    // P3.4 LEARNING 计划支持
    // ========================================================================

    [Fact]
    public void Generate_LearningPlanProducesValidPackage()
    {
        var plan = CreateMockPlanGraph(type: "LEARNING");
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.CAMPUS, Difficulty.STANDARD, seed: 42), "u");

        var result = _validator.Validate(pkg);
        Assert.True(result.Valid, $"LEARNING 计划的包未通过校验：{string.Join("; ", result.Errors.Select(e => $"{e.Path}:{e.Code}"))}");
    }

    [Fact]
    public void Generate_LearningPlanEntrySceneUsesLearningWording()
    {
        var plan = CreateMockPlanGraph(type: "LEARNING");
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.FANTASY, Difficulty.BASIC, seed: 10), "u");

        var entryScene = pkg.Scenes.First(s => s.SceneId == pkg.EntrySceneId);
        var allText = string.Join("", entryScene.Dialogue.Select(d => d.Text));
        Assert.Contains("学习", allText);
        Assert.DoesNotContain("复习", allText);
    }

    [Fact]
    public void Generate_LearningPlanEndingSceneUsesLearningWording()
    {
        var plan = CreateMockPlanGraph(type: "LEARNING");
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.SCIENCE, Difficulty.ADVANCED, seed: 20), "u");

        var endingScene = pkg.Scenes[^1];
        var allText = string.Join("", endingScene.Dialogue.Select(d => d.Text));
        Assert.Contains("学习", allText);
    }

    [Fact]
    public void Generate_LearningPlanQuestionIntroUsesLearningWording()
    {
        var plan = CreateMockPlanGraph(type: "LEARNING");
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.CAMPUS, Difficulty.STANDARD, seed: 30), "u");

        var questionScene = pkg.Scenes.FirstOrDefault(s =>
            s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.QUESTION));
        Assert.NotNull(questionScene);

        var introLine = questionScene!.Dialogue[0];
        Assert.Contains("学习", introLine.Text);
        Assert.Contains("验收", introLine.Text);
    }

    [Fact]
    public void Generate_AssessmentPlanQuestionIntroUsesAssessmentWording()
    {
        var plan = CreateMockPlanGraph(type: "ASSESSMENT");
        var pkg = _generator.Generate(plan, CreateRequest(GameStyle.CAMPUS, Difficulty.STANDARD, seed: 40), "u");

        var questionScene = pkg.Scenes.FirstOrDefault(s =>
            s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.QUESTION));
        Assert.NotNull(questionScene);

        // ASSESSMENT 计划使用模板默认的 QuestionIntro
        var introLine = questionScene!.Dialogue[0];
        Assert.DoesNotContain("验收", introLine.Text);
    }

    // ========================================================================
    // 综合回归：3 风格 × 3 难度 × LEARNING 类型全组合
    // ========================================================================

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
    public void Generate_LearningPlan_AllStyleDifficultyCombos_PassValidation(GameStyle style, Difficulty difficulty)
    {
        var plan = CreateMockPlanGraph(type: "LEARNING");
        var pkg = _generator.Generate(plan, CreateRequest(style, difficulty, seed: 42), "u");

        var result = _validator.Validate(pkg);
        Assert.True(result.Valid, $"LEARNING + {style} + {difficulty} 未通过校验：{string.Join("; ", result.Errors.Select(e => $"{e.Path}:{e.Code}"))}");
        Assert.NotEmpty(pkg.Assets);
    }
}
