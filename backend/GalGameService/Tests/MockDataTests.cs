using System.Text.Json;
using System.Text.Json.Serialization;
using Xunit;

// ============================================================================
// Mock 数据文件单元测试
//
// 验证 mocks/ 目录下 4 个游戏包 JSON 文件的：
//   1. 场景逻辑：入口可达、场景唯一、引用有效、无死端、结束场景正确
//   2. 计分规则：scoreDelta 仅 0/1、每题恰 1 个正确选项、导航选项不计分、总分正确
//   3. 难度差异：BASIC/STANDARD 4 选项，ADVANCED 3 选项
//   4. 跨包一致性：共享 reviewPlanId / snapshotVersion / schemaVersion
//   5. 校验器集成：每个 mock 包通过 GamePackageValidator
//
// 测试数据来源：backend/GalGameService/mocks/*.json（通过 csproj CopyToOutputDirectory 复制）
// ============================================================================

public class MockDataTests
{
    // ------------------------------------------------------------------------
    // JSON 反序列化配置（与 GamePackageValidator.CanonicalJsonOptions 一致）
    // ------------------------------------------------------------------------

    private static readonly JsonSerializerOptions JsonOptions = BuildOptions();

    private static JsonSerializerOptions BuildOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        };
        options.Converters.Add(new JsonStringEnumConverter());
        return options;
    }

    /// <summary>从测试输出目录加载 mock JSON 并反序列化为 GamePackage</summary>
    private static GamePackage LoadMockPackage(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "mocks", fileName);
        if (!File.Exists(path))
            throw new FileNotFoundException($"Mock 数据文件未找到：{path}。请确认 csproj 已配置 CopyToOutputDirectory。", path);

        var json = File.ReadAllText(path);
        var pkg = JsonSerializer.Deserialize<GamePackage>(json, JsonOptions);
        Assert.NotNull(pkg);
        return pkg!;
    }

    // ------------------------------------------------------------------------
    // Theory 数据：全部 4 个 mock 文件
    // ------------------------------------------------------------------------

    public static IEnumerable<object[]> AllMockFiles => new[]
    {
        new object[] { "golden.json" },
        new object[] { "campus-standard.json" },
        new object[] { "fantasy-advanced.json" },
        new object[] { "science-basic.json" },
    };

    /// <summary>3 个完整风格包（排除 golden 最小化包）</summary>
    public static IEnumerable<object[]> StyledMockFiles => new[]
    {
        new object[] { "campus-standard.json" },
        new object[] { "fantasy-advanced.json" },
        new object[] { "science-basic.json" },
    };

    // ========================================================================
    // 1. 场景逻辑测试
    // ========================================================================

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void EntryScene_ExistsInScenes(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var sceneIds = pkg.Scenes.Select(s => s.SceneId).ToHashSet();
        Assert.Contains(pkg.EntrySceneId, sceneIds);
    }

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void SceneIds_Unique(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var sceneIds = pkg.Scenes.Select(s => s.SceneId).ToList();
        var uniqueCount = sceneIds.Distinct().Count();
        Assert.Equal(sceneIds.Count, uniqueCount);
    }

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void AllScenes_ReachableFromEntry(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var sceneMap = pkg.Scenes.ToDictionary(s => s.SceneId);

        // BFS 从 entrySceneId 出发，沿 choice.nextSceneId 遍历
        var visited = new HashSet<string>();
        var queue = new Queue<string>();
        queue.Enqueue(pkg.EntrySceneId);
        visited.Add(pkg.EntrySceneId);

        while (queue.Count > 0)
        {
            var currentId = queue.Dequeue();
            if (!sceneMap.TryGetValue(currentId, out var scene))
                continue;

            foreach (var choice in scene.Choices)
            {
                if (!string.IsNullOrWhiteSpace(choice.NextSceneId)
                    && visited.Add(choice.NextSceneId))
                {
                    queue.Enqueue(choice.NextSceneId);
                }
            }
        }

        // 所有场景都应从入口可达
        var unreachable = pkg.Scenes
            .Where(s => !visited.Contains(s.SceneId))
            .Select(s => s.SceneId)
            .ToList();
        Assert.Empty(unreachable);
    }

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void NextSceneIds_AllValid(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var sceneIds = pkg.Scenes.Select(s => s.SceneId).ToHashSet();

        foreach (var scene in pkg.Scenes)
        {
            foreach (var choice in scene.Choices)
            {
                if (!string.IsNullOrWhiteSpace(choice.NextSceneId))
                {
                    Assert.Contains(choice.NextSceneId, sceneIds);
                }
            }
        }
    }

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void HasAtLeastOneEndingScene(string fileName)
    {
        var pkg = LoadMockPackage(fileName);

        // 结束场景：无选项，或所有选项 nextSceneId 均为 null
        var hasEnding = pkg.Scenes.Any(IsEndingScene);
        Assert.True(hasEnding, "游戏包至少需要一个结束场景（无选项或所有选项 nextSceneId=null）");
    }

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void NoDeadEndScenes_AllChoicesLeadSomewhere(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var sceneIds = pkg.Scenes.Select(s => s.SceneId).ToHashSet();

        foreach (var scene in pkg.Scenes)
        {
            if (IsEndingScene(scene))
                continue;

            // 非结束场景的每个选项必须指向有效场景或 null（结束）
            foreach (var choice in scene.Choices)
            {
                if (string.IsNullOrWhiteSpace(choice.NextSceneId))
                    continue; // null = 直接结束，合法

                Assert.Contains(choice.NextSceneId, sceneIds);
            }
        }
    }

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void SceneGraph_NoCycles(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var sceneMap = pkg.Scenes.ToDictionary(s => s.SceneId);

        // DFS 检测环：从入口出发，跟踪当前路径
        var visiting = new HashSet<string>();
        var visited = new HashSet<string>();
        AssertNoCycle(pkg.EntrySceneId, sceneMap, visiting, visited);
    }

    private static void AssertNoCycle(
        string sceneId,
        Dictionary<string, Scene> sceneMap,
        HashSet<string> visiting,
        HashSet<string> visited)
    {
        if (visited.Contains(sceneId))
            return;
        if (!visiting.Add(sceneId))
            throw new Xunit.Sdk.XunitException($"检测到场景图环：场景 {sceneId} 在当前路径中重复出现");

        if (sceneMap.TryGetValue(sceneId, out var scene))
        {
            foreach (var choice in scene.Choices)
            {
                if (!string.IsNullOrWhiteSpace(choice.NextSceneId))
                    AssertNoCycle(choice.NextSceneId, sceneMap, visiting, visited);
            }
        }

        visiting.Remove(sceneId);
        visited.Add(sceneId);
    }

    [Theory]
    [MemberData(nameof(StyledMockFiles))]
    public void StyledPackage_Has4Scenes_InEntryExplainQuestionEndingOrder(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        Assert.Equal(4, pkg.Scenes.Length);

        // scene-001: FEEDBACK（导航）
        Assert.Equal("FEEDBACK", pkg.Scenes[0].KnowledgeBindings[0].Purpose.ToString());
        // scene-002: EXPLAIN（讲解）
        Assert.Equal("EXPLAIN", pkg.Scenes[1].KnowledgeBindings[0].Purpose.ToString());
        // scene-003: QUESTION（计分题）
        Assert.Equal("QUESTION", pkg.Scenes[2].KnowledgeBindings[0].Purpose.ToString());
        // scene-004: 结束（无绑定）
        Assert.Empty(pkg.Scenes[3].KnowledgeBindings);
        Assert.Empty(pkg.Scenes[3].Choices);
    }

    // ========================================================================
    // 2. 计分规则测试
    // ========================================================================

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void ScoreDelta_OnlyZeroOrOne(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        foreach (var scene in pkg.Scenes)
        {
            foreach (var choice in scene.Choices)
            {
                Assert.True(choice.ScoreDelta == 0 || choice.ScoreDelta == 1,
                    $"{fileName}: 场景 {scene.SceneId} 选项 {choice.ChoiceId} 的 scoreDelta={choice.ScoreDelta}，应为 0 或 1");
            }
        }
    }

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void EachQuestion_HasExactlyOneCorrectChoice(string fileName)
    {
        var pkg = LoadMockPackage(fileName);

        // 收集所有 QUESTION 绑定的 questionId
        var questionIds = pkg.Scenes
            .SelectMany(s => s.KnowledgeBindings)
            .Where(b => b.Purpose == KnowledgePurpose.QUESTION)
            .Select(b => b.QuestionId)
            .Where(q => q.HasValue)
            .Select(q => q!.Value)
            .ToHashSet();

        Assert.NotEmpty(questionIds);

        foreach (var qId in questionIds)
        {
            var correctCount = pkg.Scenes
                .SelectMany(s => s.Choices)
                .Count(c => c.QuestionId == qId && c.ScoreDelta > 0);

            Assert.Equal(1, correctCount);
        }
    }

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void NonQuestionChoices_HaveZeroScore(string fileName)
    {
        var pkg = LoadMockPackage(fileName);

        // 收集 QUESTION 绑定的 questionId
        var questionIds = pkg.Scenes
            .SelectMany(s => s.KnowledgeBindings)
            .Where(b => b.Purpose == KnowledgePurpose.QUESTION)
            .Select(b => b.QuestionId)
            .Where(q => q.HasValue)
            .Select(q => q!.Value)
            .ToHashSet();

        // 非 QUESTION 场景的选项 scoreDelta 必须为 0
        foreach (var scene in pkg.Scenes)
        {
            var scenePurpose = scene.KnowledgeBindings.FirstOrDefault()?.Purpose;
            if (scenePurpose != KnowledgePurpose.QUESTION)
            {
                foreach (var choice in scene.Choices)
                {
                    Assert.Equal(0, choice.ScoreDelta);
                }
            }
        }
    }

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void TotalScore_EqualsQuestionCount(string fileName)
    {
        var pkg = LoadMockPackage(fileName);

        var questionCount = pkg.Scenes
            .SelectMany(s => s.KnowledgeBindings)
            .Count(b => b.Purpose == KnowledgePurpose.QUESTION);

        var totalScore = pkg.Scenes
            .SelectMany(s => s.Choices)
            .Where(c => c.ScoreDelta > 0)
            .Sum(c => c.ScoreDelta);

        // 每道 QUESTION 恰好 1 分
        Assert.Equal(questionCount, totalScore);
    }

    [Theory]
    [MemberData(nameof(StyledMockFiles))]
    public void DistractorChoices_HaveZeroScore(string fileName)
    {
        var pkg = LoadMockPackage(fileName);

        // 对每个 QUESTION 场景：正确选项 1 个，干扰项 scoreDelta=0
        foreach (var scene in pkg.Scenes)
        {
            var isQuestion = scene.KnowledgeBindings
                .Any(b => b.Purpose == KnowledgePurpose.QUESTION);
            if (!isQuestion)
                continue;

            var correctCount = scene.Choices.Count(c => c.ScoreDelta > 0);
            var distractorCount = scene.Choices.Count(c => c.ScoreDelta == 0);

            Assert.Equal(1, correctCount);
            Assert.True(distractorCount >= 2,
                $"{fileName}: 场景 {scene.SceneId} 的干扰项数量 {distractorCount} 应 >= 2");
        }
    }

    // ========================================================================
    // 3. 难度差异测试
    // ========================================================================

    [Fact]
    public void CampusStandard_QuestionScene_Has4Choices()
    {
        var pkg = LoadMockPackage("campus-standard.json");
        var questionScene = GetQuestionScene(pkg);
        Assert.Equal(4, questionScene.Choices.Length); // 1 正确 + 3 干扰项
    }

    [Fact]
    public void FantasyAdvanced_QuestionScene_Has3Choices()
    {
        var pkg = LoadMockPackage("fantasy-advanced.json");
        var questionScene = GetQuestionScene(pkg);
        Assert.Equal(3, questionScene.Choices.Length); // 1 正确 + 2 干扰项
    }

    [Fact]
    public void ScienceBasic_QuestionScene_Has4Choices()
    {
        var pkg = LoadMockPackage("science-basic.json");
        var questionScene = GetQuestionScene(pkg);
        Assert.Equal(4, questionScene.Choices.Length); // 1 正确 + 3 干扰项
    }

    // ========================================================================
    // 4. 风格差异测试
    // ========================================================================

    [Fact]
    public void Campus_UsesLinxuejie_AsSpeaker()
    {
        var pkg = LoadMockPackage("campus-standard.json");
        var speakers = pkg.Scenes.SelectMany(s => s.Dialogue).Select(d => d.SpeakerId).Distinct();
        Assert.Contains("林学姐", speakers);
    }

    [Fact]
    public void Fantasy_UsesAiliya_AsSpeaker()
    {
        var pkg = LoadMockPackage("fantasy-advanced.json");
        var speakers = pkg.Scenes.SelectMany(s => s.Dialogue).Select(d => d.SpeakerId).Distinct();
        Assert.Contains("精灵导师艾莉娅", speakers);
    }

    [Fact]
    public void Science_UsesNEXUS_AsSpeaker()
    {
        var pkg = LoadMockPackage("science-basic.json");
        var speakers = pkg.Scenes.SelectMany(s => s.Dialogue).Select(d => d.SpeakerId).Distinct();
        Assert.Contains("NEXUS", speakers);
    }

    // ========================================================================
    // 5. 跨包一致性测试
    // ========================================================================

    [Fact]
    public void AllPackages_ShareSameReviewPlanId()
    {
        var ids = AllMockFiles
            .Select(data => LoadMockPackage((string)data[0]).ReviewPlanId)
            .Distinct()
            .ToList();
        Assert.Single(ids);
    }

    [Fact]
    public void AllPackages_ShareSameSnapshotVersion()
    {
        var versions = AllMockFiles
            .Select(data => LoadMockPackage((string)data[0]).SnapshotVersion)
            .Distinct()
            .ToList();
        Assert.Single(versions);
    }

    [Fact]
    public void AllPackages_SchemaVersionIs10()
    {
        foreach (var data in AllMockFiles)
        {
            var pkg = LoadMockPackage((string)data[0]);
            Assert.Equal("1.0", pkg.SchemaVersion);
        }
    }

    [Fact]
    public void AllPackages_GeneratorVersionIsGala010()
    {
        foreach (var data in AllMockFiles)
        {
            var pkg = LoadMockPackage((string)data[0]);
            Assert.Equal("gala-0.1.0", pkg.GeneratorVersion);
        }
    }

    // ========================================================================
    // 6. 校验器集成测试
    // ========================================================================

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void MockPackage_PassesValidator(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var validator = new GamePackageValidator();
        var result = validator.Validate(pkg);
        Assert.True(result.Valid,
            $"{fileName} 校验失败：{string.Join("; ", result.Errors.Select(e => $"{e.Path}:{e.Code}"))}");
    }

    // ========================================================================
    // 辅助方法
    // ========================================================================

    /// <summary>判断是否为结束场景：无选项，或所有选项 nextSceneId 均为 null</summary>
    private static bool IsEndingScene(Scene scene)
    {
        if (scene.Choices is null || scene.Choices.Length == 0)
            return true;
        return scene.Choices.All(c => string.IsNullOrWhiteSpace(c.NextSceneId));
    }

    /// <summary>获取包含 QUESTION 绑定的场景（计分场景）</summary>
    private static Scene GetQuestionScene(GamePackage pkg)
    {
        return pkg.Scenes.First(s =>
            s.KnowledgeBindings.Any(b => b.Purpose == KnowledgePurpose.QUESTION));
    }
}
