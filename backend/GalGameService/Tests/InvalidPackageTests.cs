using System.Text.Json;
using System.Text.Json.Serialization;
using Xunit;

// ============================================================================
// 故意错误的游戏包 — 负向测试
//
// 对应契约 §7.5 / §12.1：F15EX 必须交付"黄金包、错误包、校验器"三件套。
// 本文件用 backend/GalGameService/mocks/invalid-*.json 六个静态错误包，配合
// GamePackageValidator 断言每个目标错误码被精确触发（subset 语义：期望码必须出现在
// errors 中，且 valid=false）；另用程序化构造覆盖数量超限与 null 场景（避免巨型 JSON）。
//
// 断言粒度（与负责人确认）：精确码断言 —— Assert.Contains(expectedCode, codes) + valid=false。
// ============================================================================

public class InvalidPackageTests
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

    /// <summary>提取校验结果中的全部错误码集合</summary>
    private static HashSet<string> Codes(ValidationResult r) => r.Errors.Select(e => e.Code).ToHashSet();

    /// <summary>断言校验失败且至少有一个错误</summary>
    private static void AssertInvalid(ValidationResult r)
    {
        Assert.False(r.Valid);
        Assert.NotEmpty(r.Errors);
    }

    // ========================================================================
    // 静态错误包：从 mocks/invalid-*.json 加载，断言精确错误码
    // ========================================================================

    // ---- invalid-toplevel.json：顶层标量字段 ----
    [Fact]
    public void InvalidTopLevel_TriggersFiveTopLevelCodes()
    {
        var r = new GamePackageValidator().Validate(LoadMockPackage("invalid-toplevel.json"));
        AssertInvalid(r);
        var codes = Codes(r);
        Assert.Contains("INVALID_SCHEMA_VERSION", codes);
        Assert.Contains("INVALID_PACKAGE_ID", codes);
        Assert.Contains("MISSING_GENERATOR_VERSION", codes);
        Assert.Contains("INVALID_REVIEW_PLAN_ID", codes);
        Assert.Contains("MISSING_SNAPSHOT_VERSION", codes);
        // 顶层错误不应级联到场景内部
        Assert.DoesNotContain("EMPTY_SCENE_ID", codes);
        Assert.DoesNotContain("ENTRY_SCENE_NOT_FOUND", codes);
    }

    // ---- invalid-scene-structure.json：场景结构与入口 ----
    [Fact]
    public void InvalidSceneStructure_TriggersSceneStructuralCodes()
    {
        var r = new GamePackageValidator().Validate(LoadMockPackage("invalid-scene-structure.json"));
        AssertInvalid(r);
        var codes = Codes(r);
        Assert.Contains("DUPLICATE_SCENE_ID", codes);
        Assert.Contains("EMPTY_SCENE_ID", codes);
        Assert.Contains("ENTRY_SCENE_NOT_FOUND", codes);
    }

    // ---- invalid-dialogue.json：对话行 ----
    [Fact]
    public void InvalidDialogue_TriggersDialogueCodes()
    {
        var r = new GamePackageValidator().Validate(LoadMockPackage("invalid-dialogue.json"));
        AssertInvalid(r);
        var codes = Codes(r);
        // 两处 EMPTY_DIALOGUE_FIELD（speakerId 与 text）
        Assert.Contains("EMPTY_DIALOGUE_FIELD", codes);
        var emptyFieldCount = r.Errors.Count(e => e.Code == "EMPTY_DIALOGUE_FIELD");
        Assert.True(emptyFieldCount >= 2, $"期望至少 2 个 EMPTY_DIALOGUE_FIELD，实际 {emptyFieldCount}");
        // 一处 NULL_ELEMENT（null 对话行）
        Assert.Contains("NULL_ELEMENT", codes);
    }

    // ---- invalid-choice.json：选项与导航 ----
    [Fact]
    public void InvalidChoice_TriggersChoiceCodes()
    {
        var r = new GamePackageValidator().Validate(LoadMockPackage("invalid-choice.json"));
        AssertInvalid(r);
        var codes = Codes(r);
        Assert.Contains("DUPLICATE_CHOICE_ID", codes);
        Assert.Contains("INVALID_SCORE_DELTA", codes);
        Assert.Contains("EMPTY_CHOICE_FIELD", codes);
        Assert.Contains("INVALID_NEXT_SCENE", codes);
        Assert.Contains("NULL_ELEMENT", codes);
        // 负分与过大分值是两条不同 issue
        var scoreDeltaCount = r.Errors.Count(e => e.Code == "INVALID_SCORE_DELTA");
        Assert.True(scoreDeltaCount >= 2, $"期望至少 2 个 INVALID_SCORE_DELTA，实际 {scoreDeltaCount}");
        // Q1 恰有一个正确选项，不应级联出题目正确性错误
        Assert.DoesNotContain("NO_CORRECT_CHOICE", codes);
        Assert.DoesNotContain("MULTIPLE_CORRECT_CHOICES", codes);
    }

    // ---- invalid-question-binding.json：题目/知识点绑定（跨服务证据核心）----
    [Fact]
    public void InvalidQuestionBinding_TriggersAllSevenBindingCodes()
    {
        var r = new GamePackageValidator().Validate(LoadMockPackage("invalid-question-binding.json"));
        AssertInvalid(r);
        var codes = Codes(r);
        Assert.Contains("MULTIPLE_CORRECT_CHOICES", codes);   // Q1 两个正确
        Assert.Contains("NO_CORRECT_CHOICE", codes);          // Q2 无正确
        Assert.Contains("ORPHAN_QUESTION_BINDING", codes);     // Q3 绑定无 choice
        Assert.Contains("QUESTION_POINT_MISMATCH", codes);     // Q4 选项 pointId 不一致
        Assert.Contains("QUESTION_BINDING_MISSING_QUESTION_ID", codes); // B1 questionId=null
        Assert.Contains("EMPTY_BINDING_FIELD", codes);         // B2 knowledgePointId 空
        Assert.Contains("NULL_ELEMENT", codes);                // B3 null 绑定
    }

    // ---- invalid-assets.json：资源引用 ----
    [Fact]
    public void InvalidAssets_TriggersAssetCodes()
    {
        var r = new GamePackageValidator().Validate(LoadMockPackage("invalid-assets.json"));
        AssertInvalid(r);
        var codes = Codes(r);
        Assert.Contains("DUPLICATE_ASSET_ID", codes);
        Assert.Contains("EMPTY_ASSET_FIELD", codes);
        Assert.Contains("NULL_ELEMENT", codes);
        // 场景本身合法，不应级联场景错误
        Assert.DoesNotContain("EMPTY_SCENE_ID", codes);
        Assert.DoesNotContain("DIALOGUE_COUNT_OUT_OF_RANGE", codes);
    }

    // ========================================================================
    // 程序化构造：数量超限与 null 场景（不入静态 JSON，避免巨型文件）
    // ========================================================================

    /// <summary>构造一个完全合法的最小包，供超限用例裁改</summary>
    private static GamePackage BuildValidPackage() => new(
        "1.0",
        Guid.Parse("11111111-1111-1111-1111-111111111111"),
        "gala-0.1.0",
        Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2"),
        "plan-graph-1.0:3da5f48f",
        "scene-000",
        new[] { BuildValidScene("scene-000") },
        Array.Empty<AssetRef>());

    private static Scene BuildValidScene(string id) => new(
        id, null,
        new[] { new DialogueLine("heroine", "测试对话", null) },
        Array.Empty<Choice>(),
        Array.Empty<KnowledgeBinding>());

    [Fact]
    public void Scenes_OverMax_TriggersSceneCountOutOfRange()
    {
        var scenes = Enumerable.Range(0, GamePackageValidator.MaxScenes + 1)
            .Select(i => BuildValidScene($"scene-{i:000}"))
            .ToArray();
        var pkg = BuildValidPackage() with { Scenes = scenes };
        var r = new GamePackageValidator().Validate(pkg);
        AssertInvalid(r);
        Assert.Contains("SCENE_COUNT_OUT_OF_RANGE", Codes(r));
    }

    [Fact]
    public void Scenes_Empty_TriggersSceneCountOutOfRange()
    {
        var pkg = BuildValidPackage() with { Scenes = Array.Empty<Scene>() };
        var r = new GamePackageValidator().Validate(pkg);
        AssertInvalid(r);
        Assert.Contains("SCENE_COUNT_OUT_OF_RANGE", Codes(r));
    }

    [Fact]
    public void Dialogue_OverMax_TriggersDialogueCountOutOfRange()
    {
        var dialogue = Enumerable.Range(0, GamePackageValidator.MaxDialoguePerScene + 1)
            .Select(_ => new DialogueLine("heroine", "t", null))
            .ToArray();
        var pkg = BuildValidPackage() with
        {
            Scenes = new[] { BuildValidScene("scene-000") with { Dialogue = dialogue } }
        };
        var r = new GamePackageValidator().Validate(pkg);
        AssertInvalid(r);
        Assert.Contains("DIALOGUE_COUNT_OUT_OF_RANGE", Codes(r));
    }

    [Fact]
    public void Dialogue_Null_TriggersDialogueCountOutOfRange()
    {
        var pkg = BuildValidPackage() with
        {
            Scenes = new[] { BuildValidScene("scene-000") with { Dialogue = null! } }
        };
        var r = new GamePackageValidator().Validate(pkg);
        AssertInvalid(r);
        Assert.Contains("DIALOGUE_COUNT_OUT_OF_RANGE", Codes(r));
    }

    [Fact]
    public void Choices_OverMax_TriggersChoiceCountOutOfRange()
    {
        // 7 个选项均无 QUESTION 绑定（导航选项），避免级联题目正确性错误
        var choices = Enumerable.Range(0, GamePackageValidator.MaxChoicesPerScene + 1)
            .Select(i => new Choice($"c{i}", Guid.NewGuid(), "t", null, 0, Guid.NewGuid()))
            .ToArray();
        var pkg = BuildValidPackage() with
        {
            Scenes = new[] { BuildValidScene("scene-000") with { Choices = choices } }
        };
        var r = new GamePackageValidator().Validate(pkg);
        AssertInvalid(r);
        Assert.Contains("CHOICE_COUNT_OUT_OF_RANGE", Codes(r));
    }

    [Fact]
    public void Choices_Null_TriggersChoiceCountOutOfRange()
    {
        var pkg = BuildValidPackage() with
        {
            Scenes = new[] { BuildValidScene("scene-000") with { Choices = null! } }
        };
        var r = new GamePackageValidator().Validate(pkg);
        AssertInvalid(r);
        Assert.Contains("CHOICE_COUNT_OUT_OF_RANGE", Codes(r));
    }

    [Fact]
    public void NullPackage_TriggersNullPackage()
    {
        var r = new GamePackageValidator().Validate(null!);
        AssertInvalid(r);
        Assert.Contains("NULL_PACKAGE", Codes(r));
    }

    // ========================================================================
    // 正向对照：黄金包与 3 风格包仍应通过校验（确保负向夹具未污染正向数据）
    // ========================================================================

    [Theory]
    [InlineData("golden.json")]
    [InlineData("campus-standard.json")]
    [InlineData("fantasy-advanced.json")]
    [InlineData("science-basic.json")]
    public void ValidPackages_StillPass_AfterAddingInvalidFixtures(string fileName)
    {
        var r = new GamePackageValidator().Validate(LoadMockPackage(fileName));
        Assert.True(r.Valid, $"{fileName} 应通过校验，但发现：{string.Join(", ", r.Errors.Select(e => e.Code))}");
    }
}
