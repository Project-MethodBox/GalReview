using System.Text.Json;
using System.Text.Json.Serialization;

// ============================================================================
// 游戏包校验器（§7.5 核心交付物）
// 可由 GalGameService 和 RenderService 共同运行，校验 GamePackage 是否符合
// schema 1.0。对应端点：POST /internal/v1/game-package-validations
// ============================================================================

public sealed class GamePackageValidator
{
    /// <summary>场景数量上限</summary>
    public const int MaxScenes = 100;
    /// <summary>单场景对话行上限</summary>
    public const int MaxDialoguePerScene = 200;
    /// <summary>单场景选项上限</summary>
    public const int MaxChoicesPerScene = 6;
    /// <summary>请求体 JSON 最大字节数（防止异常大包攻击）</summary>
    public const int MaxPackageJsonBytes = 2 * 1024 * 1024; // 2 MB

    // ========================================================================
    // 静态缓存：JsonSerializerOptions 只创建一次，避免每次 ComputeChecksum 重复分配
    // ========================================================================

    private static readonly JsonSerializerOptions CanonicalJsonOptions = BuildCanonicalOptions();

    private static JsonSerializerOptions BuildCanonicalOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = false,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        };
        options.Converters.Add(new JsonStringEnumConverter());
        return options;
    }

    /// <summary>
    /// 校验游戏包。返回 <see cref="ValidationResult"/>，包含所有发现的问题。
    /// 单遍扫描：在遍历场景时同时收集 sceneId 集合、questionId 映射等，
    /// 遍历结束后再校验跨场景约束（nextSceneId 引用、孤儿绑定等）。
    /// </summary>
    public ValidationResult Validate(GamePackage package)
    {
        if (package is null)
            return ValidationResult.Fail(new ValidationIssue("$", "NULL_PACKAGE", "游戏包不能为 null"));

        var issues = new List<ValidationIssue>();

        // ---- 顶层标量校验 ----
        ValidateTopLevelFields(package, issues);

        // ---- 场景集合预检 + sceneId 索引 ----
        // 先收集所有 sceneId，因为 choice.nextSceneId 可以指向包内任意场景
        var sceneIds = new HashSet<string>(StringComparer.Ordinal);
        if (package.Scenes is not null)
        {
            foreach (var scene in package.Scenes)
            {
                if (!string.IsNullOrWhiteSpace(scene.SceneId))
                    sceneIds.Add(scene.SceneId);
            }
        }

        // entrySceneId 存在性
        if (string.IsNullOrWhiteSpace(package.EntrySceneId))
            issues.Add(new("entrySceneId", "ENTRY_SCENE_NOT_FOUND", "entrySceneId 不能为空"));
        else if (!sceneIds.Contains(package.EntrySceneId))
            issues.Add(new("entrySceneId", "ENTRY_SCENE_NOT_FOUND",
                $"entrySceneId \"{package.EntrySceneId}\" 在 scenes 中不存在"));

        // ---- 逐场景校验（单遍收集跨场景数据） ----
        var seenSceneIds = new HashSet<string>(StringComparer.Ordinal);
        var questionToPoints = new Dictionary<Guid, Guid>();
        var choiceQuestionIds = new HashSet<Guid>();
        // questionId → (correctCount, sceneIdx, choiceIdx)
        var questionCorrectCounts = new Dictionary<Guid, (int Count, int SceneIdx, int ChoiceIdx)>();
        var bindingQuestionIds = new List<(Guid QuestionId, int SceneIdx, int BindingIdx)>();

        if (package.Scenes is not null)
        {
            for (var i = 0; i < package.Scenes.Length; i++)
            {
                ValidateScene(
                    package.Scenes[i], i, sceneIds,
                    seenSceneIds, questionToPoints, choiceQuestionIds,
                    questionCorrectCounts, bindingQuestionIds,
                    issues);
            }
        }

        // ---- 跨场景后置校验 ----
        // 收集所有 QUESTION 绑定的 questionId（只有这些需要检查正确选项数量）
        var scoringQuestionIds = bindingQuestionIds.Select(b => b.QuestionId).ToHashSet();
        ValidateOrphanBindings(bindingQuestionIds, choiceQuestionIds, issues);
        ValidateQuestionCorrectness(questionCorrectCounts, scoringQuestionIds, issues);

        // ---- assets 校验（独立于 scenes，防止 scenes=null 时 assets 被跳过） ----
        ValidateAssets(package.Assets, issues);

        return issues.Count == 0
            ? ValidationResult.Ok()
            : ValidationResult.Fail(issues.ToArray());
    }

    // ========================================================================
    // 分项校验方法
    // ========================================================================

    private static void ValidateTopLevelFields(GamePackage package, List<ValidationIssue> issues)
    {
        if (package.SchemaVersion != "1.0")
            issues.Add(new("schemaVersion", "INVALID_SCHEMA_VERSION",
                $"schemaVersion 必须为 \"1.0\"，实际为 \"{package.SchemaVersion}\""));

        if (package.PackageId == Guid.Empty)
            issues.Add(new("packageId", "INVALID_PACKAGE_ID", "packageId 不能为空 GUID"));

        if (string.IsNullOrWhiteSpace(package.GeneratorVersion))
            issues.Add(new("generatorVersion", "MISSING_GENERATOR_VERSION", "generatorVersion 不能为空"));

        if (package.ReviewPlanId == Guid.Empty)
            issues.Add(new("reviewPlanId", "INVALID_REVIEW_PLAN_ID", "reviewPlanId 不能为空 GUID"));

        if (string.IsNullOrWhiteSpace(package.SnapshotVersion))
            issues.Add(new("snapshotVersion", "MISSING_SNAPSHOT_VERSION", "snapshotVersion 不能为空"));

        if (package.Scenes is null || package.Scenes.Length == 0)
            issues.Add(new("scenes", "SCENE_COUNT_OUT_OF_RANGE", "scenes 不能为空"));
        else if (package.Scenes.Length > MaxScenes)
            issues.Add(new("scenes", "SCENE_COUNT_OUT_OF_RANGE",
                $"场景数量 {package.Scenes.Length} 超过上限 {MaxScenes}"));
    }

    private static void ValidateScene(
        Scene scene, int index,
        HashSet<string> sceneIds,
        HashSet<string> seenSceneIds,
        Dictionary<Guid, Guid> questionToPoints,
        HashSet<Guid> choiceQuestionIds,
        Dictionary<Guid, (int Count, int SceneIdx, int ChoiceIdx)> questionCorrectCounts,
        List<(Guid QuestionId, int SceneIdx, int BindingIdx)> bindingQuestionIds,
        List<ValidationIssue> issues)
    {
        var scenePath = $"scenes[{index}]";

        // sceneId 非空且唯一
        if (string.IsNullOrWhiteSpace(scene.SceneId))
            issues.Add(new($"{scenePath}.sceneId", "EMPTY_SCENE_ID", "sceneId 不能为空"));
        else if (!seenSceneIds.Add(scene.SceneId))
            issues.Add(new($"{scenePath}.sceneId", "DUPLICATE_SCENE_ID",
                $"sceneId \"{scene.SceneId}\" 重复"));

        // dialogue
        if (scene.Dialogue is null)
            issues.Add(new($"{scenePath}.dialogue", "DIALOGUE_COUNT_OUT_OF_RANGE", "dialogue 不能为 null"));
        else if (scene.Dialogue.Length == 0)
            issues.Add(new($"{scenePath}.dialogue", "DIALOGUE_COUNT_OUT_OF_RANGE", "dialogue 不能为空数组"));
        else if (scene.Dialogue.Length > MaxDialoguePerScene)
            issues.Add(new($"{scenePath}.dialogue", "DIALOGUE_COUNT_OUT_OF_RANGE",
                $"对话数量 {scene.Dialogue.Length} 超过上限 {MaxDialoguePerScene}"));
        else
        {
            for (var d = 0; d < scene.Dialogue.Length; d++)
            {
                var line = scene.Dialogue[d];
                var dPath = $"{scenePath}.dialogue[{d}]";
                if (string.IsNullOrWhiteSpace(line.SpeakerId))
                    issues.Add(new($"{dPath}.speakerId", "EMPTY_DIALOGUE_FIELD", "speakerId 不能为空"));
                if (string.IsNullOrWhiteSpace(line.Text))
                    issues.Add(new($"{dPath}.text", "EMPTY_DIALOGUE_FIELD", "text 不能为空"));
            }
        }

        // choices
        if (scene.Choices is null)
            issues.Add(new($"{scenePath}.choices", "CHOICE_COUNT_OUT_OF_RANGE", "choices 不能为 null"));
        else if (scene.Choices.Length > MaxChoicesPerScene)
            issues.Add(new($"{scenePath}.choices", "CHOICE_COUNT_OUT_OF_RANGE",
                $"选项数量 {scene.Choices.Length} 超过上限 {MaxChoicesPerScene}"));
        else
        {
            var seenChoiceIds = new HashSet<string>(StringComparer.Ordinal);
            for (var c = 0; c < scene.Choices.Length; c++)
            {
                var choice = scene.Choices[c];
                var cPath = $"{scenePath}.choices[{c}]";
                ValidateChoice(
                    choice, cPath, sceneIds,
                    questionToPoints, choiceQuestionIds, questionCorrectCounts,
                    seenChoiceIds, index, c, issues);
            }
        }

        // knowledgeBindings
        if (scene.KnowledgeBindings is not null)
        {
            for (var b = 0; b < scene.KnowledgeBindings.Length; b++)
            {
                var binding = scene.KnowledgeBindings[b];
                var bPath = $"{scenePath}.knowledgeBindings[{b}]";
                if (binding.KnowledgePointId == Guid.Empty)
                    issues.Add(new($"{bPath}.knowledgePointId", "EMPTY_BINDING_FIELD",
                        "knowledgePointId 不能为空 GUID"));

                if (binding.Purpose == KnowledgePurpose.QUESTION)
                {
                    if (binding.QuestionId is null || binding.QuestionId == Guid.Empty)
                        issues.Add(new($"{bPath}.questionId", "QUESTION_BINDING_MISSING_QUESTION_ID",
                            "purpose=QUESTION 的绑定必须提供 questionId"));
                    else
                        bindingQuestionIds.Add((binding.QuestionId.Value, index, b));
                }
            }
        }
    }

    private static void ValidateChoice(
        Choice choice, string path,
        HashSet<string> sceneIds,
        Dictionary<Guid, Guid> questionToPoints,
        HashSet<Guid> choiceQuestionIds,
        Dictionary<Guid, (int Count, int SceneIdx, int ChoiceIdx)> questionCorrectCounts,
        HashSet<string> seenChoiceIds,
        int sceneIdx, int choiceIdx,
        List<ValidationIssue> issues)
    {
        // 字段非空
        if (string.IsNullOrWhiteSpace(choice.ChoiceId))
            issues.Add(new($"{path}.choiceId", "EMPTY_CHOICE_FIELD", "choiceId 不能为空"));
        else if (!seenChoiceIds.Add(choice.ChoiceId))
            issues.Add(new($"{path}.choiceId", "DUPLICATE_CHOICE_ID",
                $"choiceId \"{choice.ChoiceId}\" 在同一场景内重复"));

        if (choice.QuestionId == Guid.Empty)
            issues.Add(new($"{path}.questionId", "EMPTY_CHOICE_FIELD", "questionId 不能为空 GUID"));

        if (string.IsNullOrWhiteSpace(choice.Text))
            issues.Add(new($"{path}.text", "EMPTY_CHOICE_FIELD", "text 不能为空"));

        if (choice.KnowledgePointId == Guid.Empty)
            issues.Add(new($"{path}.knowledgePointId", "EMPTY_CHOICE_FIELD", "knowledgePointId 不能为空 GUID"));

        // ScoreDelta 范围：0（错误）或 1（正确），不允许负数或过大值
        if (choice.ScoreDelta < 0)
            issues.Add(new($"{path}.scoreDelta", "INVALID_SCORE_DELTA",
                $"scoreDelta 不能为负数，实际为 {choice.ScoreDelta}"));
        else if (choice.ScoreDelta > 1)
            issues.Add(new($"{path}.scoreDelta", "INVALID_SCORE_DELTA",
                $"scoreDelta 最大为 1，实际为 {choice.ScoreDelta}"));

        // nextSceneId 引用有效性
        if (!string.IsNullOrWhiteSpace(choice.NextSceneId) && !sceneIds.Contains(choice.NextSceneId))
            issues.Add(new($"{path}.nextSceneId", "INVALID_NEXT_SCENE",
                $"nextSceneId \"{choice.NextSceneId}\" 不指向任何存在的 scene"));

        // questionId 跨场景一致性
        if (choice.QuestionId != Guid.Empty)
        {
            choiceQuestionIds.Add(choice.QuestionId);
            if (questionToPoints.TryGetValue(choice.QuestionId, out var existingPoint))
            {
                if (existingPoint != choice.KnowledgePointId)
                    issues.Add(new($"{path}.questionId", "QUESTION_POINT_MISMATCH",
                        $"questionId {choice.QuestionId} 在不同选项中绑定了不同的 knowledgePointId"));
            }
            else if (choice.KnowledgePointId != Guid.Empty)
            {
                questionToPoints[choice.QuestionId] = choice.KnowledgePointId;
            }

            // 统计每题正确选项数量：先确保 questionId 在字典中（初始 count=0），
            // 这样无正确选项的题目也能被 ValidateQuestionCorrectness 检测到。
            if (!questionCorrectCounts.TryGetValue(choice.QuestionId, out var entry))
                entry = (0, sceneIdx, choiceIdx);

            if (choice.ScoreDelta > 0)
                questionCorrectCounts[choice.QuestionId] = (entry.Count + 1, entry.SceneIdx, entry.ChoiceIdx);
            else
                questionCorrectCounts[choice.QuestionId] = entry;
        }
    }

    /// <summary>校验孤儿绑定：purpose=QUESTION 的 questionId 必须在 choices 中出现</summary>
    private static void ValidateOrphanBindings(
        List<(Guid QuestionId, int SceneIdx, int BindingIdx)> bindingQuestionIds,
        HashSet<Guid> choiceQuestionIds,
        List<ValidationIssue> issues)
    {
        foreach (var (qId, sIdx, bIdx) in bindingQuestionIds)
        {
            if (!choiceQuestionIds.Contains(qId))
                issues.Add(new($"scenes[{sIdx}].knowledgeBindings[{bIdx}].questionId",
                    "ORPHAN_QUESTION_BINDING",
                    $"questionId {qId} 在 QUESTION 绑定中声明，但未在任何 choice 中使用"));
        }
    }

    /// <summary>校验每题恰好一个正确选项（仅检查 QUESTION 绑定的 questionId）</summary>
    private static void ValidateQuestionCorrectness(
        Dictionary<Guid, (int Count, int SceneIdx, int ChoiceIdx)> questionCorrectCounts,
        HashSet<Guid> scoringQuestionIds,
        List<ValidationIssue> issues)
    {
        // 只检查有 QUESTION 绑定的 questionId（导航 choice 不需要正确选项）
        foreach (var qId in scoringQuestionIds)
        {
            if (!questionCorrectCounts.TryGetValue(qId, out var entry))
            {
                // QUESTION 绑定存在但没有任何 choice 使用该 questionId
                // （这会被 ORPHAN_QUESTION_BINDING 捕获，这里不重复报错）
                continue;
            }

            var (count, sIdx, cIdx) = entry;
            if (count == 0)
                issues.Add(new($"scenes[{sIdx}].choices[{cIdx}].questionId",
                    "NO_CORRECT_CHOICE",
                    $"questionId {qId} 没有任何 scoreDelta>0 的正确选项"));
            else if (count > 1)
                issues.Add(new($"scenes[{sIdx}].choices[{cIdx}].questionId",
                    "MULTIPLE_CORRECT_CHOICES",
                    $"questionId {qId} 有 {count} 个 scoreDelta>0 的正确选项，应为 1 个"));
        }
    }

    /// <summary>校验 assets（独立于 scenes，确保 scenes=null 时仍执行）</summary>
    private static void ValidateAssets(AssetRef[]? assets, List<ValidationIssue> issues)
    {
        if (assets is null) return;

        var seenAssetIds = new HashSet<string>(StringComparer.Ordinal);
        for (var a = 0; a < assets.Length; a++)
        {
            var asset = assets[a];
            var aPath = $"assets[{a}]";
            if (string.IsNullOrWhiteSpace(asset.AssetId))
                issues.Add(new($"{aPath}.assetId", "EMPTY_ASSET_FIELD", "assetId 不能为空"));
            else if (!seenAssetIds.Add(asset.AssetId))
                issues.Add(new($"{aPath}.assetId", "DUPLICATE_ASSET_ID",
                    $"assetId \"{asset.AssetId}\" 重复"));
            if (string.IsNullOrWhiteSpace(asset.Uri))
                issues.Add(new($"{aPath}.uri", "EMPTY_ASSET_FIELD", "uri 不能为空"));
        }
    }

    // ========================================================================
    // 序列化与 checksum
    // ========================================================================

    /// <summary>
    /// 将游戏包序列化为规范化的 JSON 字符串，用于计算 checksum。
    /// 规范化：属性名 camelCase、枚举为字符串、无缩进、UTF-8。
    /// 使用静态缓存的 JsonSerializerOptions 避免重复分配。
    /// </summary>
    public static string SerializeCanonical(GamePackage package)
        => JsonSerializer.Serialize(package, CanonicalJsonOptions);

    /// <summary>
    /// 计算游戏包的 SHA-256 checksum。
    /// 使用 stackalloc 减少 GC 压力（SHA-256 输出固定 32 字节）。
    /// </summary>
    public static string ComputeChecksum(GamePackage package)
    {
        var json = SerializeCanonical(package);
        var jsonBytes = System.Text.Encoding.UTF8.GetBytes(json);
        // SHA-256 输出固定 32 字节，用 stackalloc 避免堆分配
        Span<byte> hash = stackalloc byte[32];
        System.Security.Cryptography.SHA256.HashData(jsonBytes, hash);
        // Convert.ToHexString 在 .NET 10 中支持 Span
        return Convert.ToHexString(hash).ToLowerInvariant();
    }
}
