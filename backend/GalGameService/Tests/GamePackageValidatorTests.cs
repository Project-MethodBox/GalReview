using Xunit;

// ============================================================================
// 游戏包校验器测试（§7.5 交付物验证）
//
// 黄金包 → valid=true
// 错误包 → valid=false，包含多个违规
// 各类单项违规检测
// ============================================================================

public class GamePackageValidatorTests
{
    private readonly GamePackageValidator _validator = new();

    // ------------------------------------------------------------------------
    // 测试数据：黄金游戏包（contract.md §7.4 Mock，符合 schema 1.0）
    // ------------------------------------------------------------------------

    private static readonly Guid GoldenPackageId = Guid.Parse("f2561bb2-b88c-47ef-b0ae-8f283ff64f1b");
    private static readonly Guid GoldenQuestionId = Guid.Parse("6428a20a-66dd-44c9-944f-d7b36fa9c95a");
    private static readonly Guid GoldenPointId = Guid.Parse("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb");
    private static readonly Guid GoldenReviewPlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");

    private static GamePackage CreateGoldenPackage() => new(
        SchemaVersion: "1.0",
        PackageId: GoldenPackageId,
        GeneratorVersion: "gala-0.1.0",
        ReviewPlanId: GoldenReviewPlanId,
        SnapshotVersion: "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
        EntrySceneId: "scene-001",
        Scenes: new Scene[]
        {
            new(
                SceneId: "scene-001",
                Title: null,
                Dialogue: new DialogueLine[]
                {
                    new("heroine", "水稻分蘖期最关键的管理目标是什么？", "curious"),
                },
                Choices: new Choice[]
                {
                    new("c1", GoldenQuestionId, "协调群体数量与个体生长", null, 1, GoldenPointId,
                        AnswerKind.CHOICE, Correct: true),
                },
                KnowledgeBindings: new KnowledgeBinding[]
                {
                    new(GoldenPointId, GoldenQuestionId, KnowledgePurpose.QUESTION),
                }),
        },
        Assets: Array.Empty<AssetRef>());

    // ------------------------------------------------------------------------
    // 测试数据：故意错误的游戏包（包含 5+ 处违规）
    // ------------------------------------------------------------------------

    private static GamePackage CreateBadPackage() => new(
        SchemaVersion: "2.0", // 违规 1：schemaVersion 错误
        PackageId: GoldenPackageId,
        GeneratorVersion: "gala-0.1.0",
        ReviewPlanId: GoldenReviewPlanId,
        SnapshotVersion: "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
        EntrySceneId: "non-existent-scene", // 违规 2：entrySceneId 不存在
        Scenes: new Scene[]
        {
            new(
                SceneId: "scene-001",
                Title: null,
                Dialogue: new DialogueLine[]
                {
                    new("", "对话内容", null), // 违规 3：speakerId 为空
                },
                Choices: new Choice[]
                {
                    new("c1", GoldenQuestionId, "选项A", null, 1, GoldenPointId,
                        AnswerKind.CHOICE, Correct: true),
                    new("c2", GoldenQuestionId, "选项B", null, 0,
                        Guid.Parse("00000000-0000-4000-8000-0000000000aa"),
                        AnswerKind.CHOICE, Correct: false), // 违规 4：同 questionId 不同 knowledgePointId
                },
                KnowledgeBindings: new KnowledgeBinding[]
                {
                    new(GoldenPointId, null, KnowledgePurpose.QUESTION), // 违规 5：QUESTION 绑定无 questionId
                }),
        },
        Assets: Array.Empty<AssetRef>());

    // ------------------------------------------------------------------------
    // 测试用例
    // ------------------------------------------------------------------------

    [Fact]
    public void GoldenPackage_PassesValidation()
    {
        var pkg = CreateGoldenPackage();
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid, formatErrors(result));
        Assert.Empty(result.Errors);
    }

    [Fact]
    public void BadPackage_FailsValidation_WithMultipleErrors()
    {
        var pkg = CreateBadPackage();
        var result = _validator.Validate(pkg);
        Assert.False(result.Valid);
        Assert.True(result.Errors.Length >= 3, $"期望至少 3 个错误，实际 {result.Errors.Length}：{formatErrors(result)}");
    }

    [Fact]
    public void InvalidSchemaVersion_Detected()
    {
        var pkg = CreateGoldenPackage() with { SchemaVersion = "2.0" };
        var result = _validator.Validate(pkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "INVALID_SCHEMA_VERSION");
    }

    [Fact]
    public void EmptyPackageId_Detected()
    {
        var pkg = CreateGoldenPackage() with { PackageId = Guid.Empty };
        var result = _validator.Validate(pkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "INVALID_PACKAGE_ID");
    }

    [Fact]
    public void MissingEntryScene_Detected()
    {
        var pkg = CreateGoldenPackage() with { EntrySceneId = "non-existent" };
        var result = _validator.Validate(pkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "ENTRY_SCENE_NOT_FOUND");
    }

    [Fact]
    public void EmptyScenes_Detected()
    {
        var pkg = CreateGoldenPackage() with { Scenes = Array.Empty<Scene>() };
        var result = _validator.Validate(pkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "SCENE_COUNT_OUT_OF_RANGE");
    }

    [Fact]
    public void EmptyDialogueSpeaker_Detected()
    {
        var pkg = CreateGoldenPackage();
        var firstScene = pkg.Scenes[0];
        var badDialogue = firstScene.Dialogue[0] with { SpeakerId = "" };
        var badScene = firstScene with { Dialogue = new[] { badDialogue } };
        var badPkg = pkg with { Scenes = new[] { badScene } };
        var result = _validator.Validate(badPkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "EMPTY_DIALOGUE_FIELD");
    }

    [Fact]
    public void QuestionBindingMissingQuestionId_Detected()
    {
        var pkg = CreateGoldenPackage();
        var firstScene = pkg.Scenes[0];
        var badBinding = new KnowledgeBinding(GoldenPointId, null, KnowledgePurpose.QUESTION);
        var badScene = firstScene with { KnowledgeBindings = new[] { badBinding } };
        var badPkg = pkg with { Scenes = new[] { badScene } };
        var result = _validator.Validate(badPkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "QUESTION_BINDING_MISSING_QUESTION_ID");
    }

    [Fact]
    public void QuestionPointMismatch_Detected()
    {
        var otherPointId = Guid.Parse("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee");
        var pkg = CreateGoldenPackage();
        var firstScene = pkg.Scenes[0];
        // 两个 choice 用相同 questionId 但不同 knowledgePointId
        var badChoices = new[]
        {
            firstScene.Choices[0],
            new Choice("c2", GoldenQuestionId, "选项B", null, 0, otherPointId,
                AnswerKind.CHOICE, Correct: false),
        };
        var badScene = firstScene with { Choices = badChoices };
        var badPkg = pkg with { Scenes = new[] { badScene } };
        var result = _validator.Validate(badPkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "QUESTION_POINT_MISMATCH");
    }

    [Fact]
    public void InvalidNextScene_Detected()
    {
        var pkg = CreateGoldenPackage();
        var firstScene = pkg.Scenes[0];
        var badChoice = firstScene.Choices[0] with { NextSceneId = "non-existent" };
        var badScene = firstScene with { Choices = new[] { badChoice } };
        var badPkg = pkg with { Scenes = new[] { badScene } };
        var result = _validator.Validate(badPkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "INVALID_NEXT_SCENE");
    }

    [Fact]
    public void OrphanQuestionBinding_Detected()
    {
        var orphanQuestionId = Guid.Parse("11111111-2222-4333-8444-555555555555");
        var pkg = CreateGoldenPackage();
        var firstScene = pkg.Scenes[0];
        // 添加一个 QUESTION 绑定，但其 questionId 不在任何 choice 中
        var bindings = firstScene.KnowledgeBindings.Append(
            new KnowledgeBinding(GoldenPointId, orphanQuestionId, KnowledgePurpose.QUESTION)).ToArray();
        var badScene = firstScene with { KnowledgeBindings = bindings };
        var badPkg = pkg with { Scenes = new[] { badScene } };
        var result = _validator.Validate(badPkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "ORPHAN_QUESTION_BINDING");
    }

    [Fact]
    public void DuplicateSceneId_Detected()
    {
        var pkg = CreateGoldenPackage();
        var dupScene = pkg.Scenes[0] with { SceneId = "scene-001" };
        var badPkg = pkg with { Scenes = new[] { pkg.Scenes[0], dupScene } };
        var result = _validator.Validate(badPkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "DUPLICATE_SCENE_ID");
    }

    [Fact]
    public void DuplicateAssetId_Detected()
    {
        var pkg = CreateGoldenPackage();
        var assets = new AssetRef[]
        {
            new("bg-1", AssetType.BACKGROUND, "/assets/bg1.png"),
            new("bg-1", AssetType.BACKGROUND, "/assets/bg2.png"), // 重复 assetId
        };
        var badPkg = pkg with { Assets = assets };
        var result = _validator.Validate(badPkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "DUPLICATE_ASSET_ID");
    }

    [Fact]
    public void ComputeChecksum_IsStable()
    {
        var pkg = CreateGoldenPackage();
        var hash1 = GamePackageValidator.ComputeChecksum(pkg);
        var hash2 = GamePackageValidator.ComputeChecksum(pkg);
        Assert.Equal(hash1, hash2);
        Assert.Equal(64, hash1.Length); // SHA-256 = 64 hex chars
    }

    // ------------------------------------------------------------------------
    // 新增校验规则测试（深度优化后添加）
    // ------------------------------------------------------------------------

    [Fact]
    public void NullPackage_ReturnsError()
    {
        var result = _validator.Validate(null!);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "NULL_PACKAGE");
    }

    [Fact]
    public void NegativeScoreDelta_DoesNotDetermineCorrectness()
    {
        var pkg = CreateGoldenPackage();
        var firstScene = pkg.Scenes[0];
        var gameChoice = firstScene.Choices[0] with { ScoreDelta = -1, Correct = true };
        var scene = firstScene with { Choices = new[] { gameChoice } };
        var result = _validator.Validate(pkg with { Scenes = new[] { scene } });
        Assert.True(result.Valid, formatErrors(result));
    }

    [Fact]
    public void LargeScoreDelta_DoesNotDetermineCorrectness()
    {
        var pkg = CreateGoldenPackage();
        var firstScene = pkg.Scenes[0];
        var gameChoice = firstScene.Choices[0] with { ScoreDelta = 100, Correct = true };
        var scene = firstScene with { Choices = new[] { gameChoice } };
        var result = _validator.Validate(pkg with { Scenes = new[] { scene } });
        Assert.True(result.Valid, formatErrors(result));
    }

    [Fact]
    public void MultipleCorrectChoices_AreRepresentableWithoutScoreInference()
    {
        var pkg = CreateGoldenPackage();
        var firstScene = pkg.Scenes[0];
        // correctness 明确标记两个正确选项；scoreDelta 不参与判定。
        var badChoices = new[]
        {
            firstScene.Choices[0] with { ScoreDelta = -10, Correct = true },
            new Choice("c2", GoldenQuestionId, "另一个正确选项", null, 0, GoldenPointId,
                AnswerKind.CHOICE, Correct: true),
        };
        var scene = firstScene with { Choices = badChoices };
        var result = _validator.Validate(pkg with { Scenes = new[] { scene } });
        Assert.True(result.Valid, formatErrors(result));
    }

    [Fact]
    public void NoCorrectChoice_Detected()
    {
        var pkg = CreateGoldenPackage();
        var firstScene = pkg.Scenes[0];
        // 即便游戏分数为正，只要 correct=false，仍然没有正确答案。
        var badChoice = firstScene.Choices[0] with { ScoreDelta = 100, Correct = false };
        var badScene = firstScene with { Choices = new[] { badChoice } };
        var badPkg = pkg with { Scenes = new[] { badScene } };
        var result = _validator.Validate(badPkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "NO_CORRECT_CHOICE");
    }

    [Fact]
    public void DuplicateChoiceId_Detected()
    {
        var pkg = CreateGoldenPackage();
        var firstScene = pkg.Scenes[0];
        // 两个 choice 相同 choiceId
        var badChoices = new[]
        {
            firstScene.Choices[0],
            new Choice("c1", GoldenQuestionId, "重复 ID 的选项", null, 0, GoldenPointId,
                AnswerKind.CHOICE, Correct: false),
        };
        var badScene = firstScene with { Choices = badChoices };
        var badPkg = pkg with { Scenes = new[] { badScene } };
        var result = _validator.Validate(badPkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "DUPLICATE_CHOICE_ID");
    }

    [Fact]
    public void EmptyDialogueArray_Detected()
    {
        var pkg = CreateGoldenPackage();
        var firstScene = pkg.Scenes[0];
        var badScene = firstScene with { Dialogue = Array.Empty<DialogueLine>() };
        var badPkg = pkg with { Scenes = new[] { badScene } };
        var result = _validator.Validate(badPkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "DIALOGUE_COUNT_OUT_OF_RANGE");
    }

    [Fact]
    public void QuestionBindingAndChoicesInDifferentScenes_Detected()
    {
        var pkg = CreateGoldenPackage();
        var questionScene = pkg.Scenes[0] with { Choices = Array.Empty<Choice>() };
        var detachedChoiceScene = pkg.Scenes[0] with
        {
            SceneId = "scene-002",
            Choices = pkg.Scenes[0].Choices,
            KnowledgeBindings = Array.Empty<KnowledgeBinding>()
        };

        var result = _validator.Validate(pkg with { Scenes = new[] { questionScene, detachedChoiceScene } });
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, issue => issue.Code == "ORPHAN_QUESTION_BINDING");
    }

    [Fact]
    public void MultipleQuestionBindingsInOneScene_Detected()
    {
        var pkg = CreateGoldenPackage();
        var secondQuestionId = Guid.Parse("e83ad3b6-d00f-47ee-a930-38735714c93f");
        var scene = pkg.Scenes[0] with
        {
            Choices = pkg.Scenes[0].Choices.Append(
                new Choice("c2", secondQuestionId, "第二题选项", null, 0, GoldenPointId,
                    AnswerKind.CHOICE, Correct: true)).ToArray(),
            KnowledgeBindings = pkg.Scenes[0].KnowledgeBindings.Append(
                new KnowledgeBinding(GoldenPointId, secondQuestionId, KnowledgePurpose.QUESTION)).ToArray()
        };

        var result = _validator.Validate(pkg with { Scenes = new[] { scene } });
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, issue => issue.Code == "MULTIPLE_QUESTIONS_IN_SCENE");
    }

    [Fact]
    public void UnreachableQuestionScene_Detected()
    {
        var pkg = CreateGoldenPackage();
        var navigationQuestionId = Guid.Parse("f9b43f17-4b97-45c1-ae5a-3506b8889012");
        var entryScene = pkg.Scenes[0] with
        {
            SceneId = "entry",
            Choices = new[]
            {
                new Choice("continue", navigationQuestionId, "结束", null, 0, GoldenPointId)
            },
            KnowledgeBindings = new[]
            {
                new KnowledgeBinding(GoldenPointId, navigationQuestionId, KnowledgePurpose.FEEDBACK)
            }
        };
        var questionScene = pkg.Scenes[0] with { SceneId = "question" };

        var result = _validator.Validate(pkg with
        {
            EntrySceneId = entryScene.SceneId,
            Scenes = new[] { entryScene, questionScene }
        });
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, issue => issue.Code == "UNREACHABLE_QUESTION_SCENE");
    }

    [Fact]
    public void AssetsValidated_WhenScenesAreNull()
    {
        // scenes=null 时 assets 仍然应该被校验
        var pkg = CreateGoldenPackage() with
        {
            Scenes = null!,
            Assets = new AssetRef[]
            {
                new("", AssetType.BACKGROUND, "/assets/bg1.png"), // 空 assetId
            },
        };
        var result = _validator.Validate(pkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "EMPTY_ASSET_FIELD");
    }

    [Fact]
    public void ComputeChecksum_StableAcrossCalls()
    {
        // 验证静态 JsonSerializerOptions 不会因多次调用产生不同结果
        var pkg = CreateGoldenPackage();
        var hashes = new HashSet<string>();
        for (var i = 0; i < 100; i++)
        {
            hashes.Add(GamePackageValidator.ComputeChecksum(pkg));
        }
        Assert.Single(hashes); // 100 次调用结果完全一致
    }

    private static string formatErrors(ValidationResult r) =>
        r.Errors.Length == 0 ? "(no errors)" : string.Join("; ", r.Errors.Select(e => $"{e.Path}:{e.Code}"));
}
