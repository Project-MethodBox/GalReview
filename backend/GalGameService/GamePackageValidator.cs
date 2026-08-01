using System.Text.Json;
using System.Text.Json.Serialization;

// ============================================================================
// 游戏包校验器（§7.5 核心交付物）
// 可由 GalGameService 和 RenderService 共同运行，校验 GamePackage 是否符合
// schema 1.0。对应端点：POST /internal/v1/game-package-validations
// ============================================================================

public sealed class GamePackageValidator
{
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
            DefaultIgnoreCondition = JsonIgnoreCondition.Never,
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
                if (scene is not null && !string.IsNullOrWhiteSpace(scene.SceneId))
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
        var allChoices = new List<(Choice Choice, string Path, int SceneIdx)>();
        var questionBindings = new List<(Guid QuestionId, Guid PointId, int SceneIdx, int BindingIdx)>();

        if (package.Scenes is not null)
        {
            for (var i = 0; i < package.Scenes.Length; i++)
            {
                ValidateScene(
                    package.Scenes[i], i, sceneIds,
                    seenSceneIds, questionToPoints,
                    allChoices, questionBindings,
                    issues);
            }
        }

        // ---- 跨场景后置校验 ----
        // 收集所有 QUESTION 绑定的 questionId（只有这些需要检查正确选项数量）
        var scoringQuestionKeys = questionBindings
            .Select(binding => (binding.SceneIdx, binding.QuestionId))
            .ToHashSet();
        ValidateQuestionBindings(questionBindings, allChoices, issues);
        ValidateScoringChoices(allChoices, scoringQuestionKeys, issues);
        ValidateQuestionCorrectness(allChoices, scoringQuestionKeys, issues);
        ValidateQuestionSceneReachability(package, questionBindings, issues);

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
        else if (!IsUuidV4(package.PackageId))
            issues.Add(new("packageId", "INVALID_UUID_VERSION", "packageId 必须为 UUID v4"));

        if (string.IsNullOrWhiteSpace(package.GeneratorVersion))
            issues.Add(new("generatorVersion", "MISSING_GENERATOR_VERSION", "generatorVersion 不能为空"));

        if (package.ReviewPlanId == Guid.Empty)
            issues.Add(new("reviewPlanId", "INVALID_REVIEW_PLAN_ID", "reviewPlanId 不能为空 GUID"));
        else if (!IsUuidV4(package.ReviewPlanId))
            issues.Add(new("reviewPlanId", "INVALID_UUID_VERSION", "reviewPlanId 必须为 UUID v4"));

        if (string.IsNullOrWhiteSpace(package.SnapshotVersion))
            issues.Add(new("snapshotVersion", "MISSING_SNAPSHOT_VERSION", "snapshotVersion 不能为空"));

        if (package.Scenes is null || package.Scenes.Length == 0)
            issues.Add(new("scenes", "SCENE_COUNT_OUT_OF_RANGE", "scenes 不能为空"));
    }

    private static void ValidateScene(
        Scene scene, int index,
        HashSet<string> sceneIds,
        HashSet<string> seenSceneIds,
        Dictionary<Guid, Guid> questionToPoints,
        List<(Choice Choice, string Path, int SceneIdx)> allChoices,
        List<(Guid QuestionId, Guid PointId, int SceneIdx, int BindingIdx)> questionBindings,
        List<ValidationIssue> issues)
    {
        var scenePath = $"scenes[{index}]";

        if (scene is null)
        {
            issues.Add(new(scenePath, "NULL_ELEMENT", "场景元素不能为 null"));
            return;
        }

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
        else
        {
            for (var d = 0; d < scene.Dialogue.Length; d++)
            {
                var line = scene.Dialogue[d];
                var dPath = $"{scenePath}.dialogue[{d}]";
                if (line is null)
                {
                    issues.Add(new(dPath, "NULL_ELEMENT", "对话行元素不能为 null"));
                    continue;
                }
                if (string.IsNullOrWhiteSpace(line.SpeakerId))
                    issues.Add(new($"{dPath}.speakerId", "EMPTY_DIALOGUE_FIELD", "speakerId 不能为空"));
                if (string.IsNullOrWhiteSpace(line.Text))
                    issues.Add(new($"{dPath}.text", "EMPTY_DIALOGUE_FIELD", "text 不能为空"));
            }
        }

        // choices
        if (scene.Choices is null)
            issues.Add(new($"{scenePath}.choices", "CHOICE_COUNT_OUT_OF_RANGE", "choices 不能为 null"));
        else
        {
            var seenChoiceIds = new HashSet<string>(StringComparer.Ordinal);
            for (var c = 0; c < scene.Choices.Length; c++)
            {
                var choice = scene.Choices[c];
                var cPath = $"{scenePath}.choices[{c}]";
                if (choice is null)
                {
                    issues.Add(new(cPath, "NULL_ELEMENT", "选项元素不能为 null"));
                    continue;
                }
                ValidateChoice(
                    choice, cPath, sceneIds,
                    questionToPoints,
                    allChoices, seenChoiceIds, index, issues);
            }
        }

        // knowledgeBindings
        if (scene.KnowledgeBindings is null)
        {
            issues.Add(new($"{scenePath}.knowledgeBindings", "MISSING_KNOWLEDGE_BINDINGS",
                "knowledgeBindings 不能为 null"));
        }
        else
        {
            for (var b = 0; b < scene.KnowledgeBindings.Length; b++)
            {
                var binding = scene.KnowledgeBindings[b];
                var bPath = $"{scenePath}.knowledgeBindings[{b}]";
                if (binding is null)
                {
                    issues.Add(new(bPath, "NULL_ELEMENT", "知识绑定元素不能为 null"));
                    continue;
                }
                if (binding.KnowledgePointId == Guid.Empty)
                    issues.Add(new($"{bPath}.knowledgePointId", "EMPTY_BINDING_FIELD",
                        "knowledgePointId 不能为空 GUID"));
                else if (!IsUuidV4(binding.KnowledgePointId))
                    issues.Add(new($"{bPath}.knowledgePointId", "INVALID_UUID_VERSION",
                        "knowledgePointId 必须为 UUID v4"));

                if (binding.Purpose is null)
                {
                    issues.Add(new($"{bPath}.purpose", "MISSING_BINDING_PURPOSE",
                        "purpose 不能为空"));
                }
                else if (binding.Purpose == KnowledgePurpose.QUESTION)
                {
                    if (binding.QuestionId is null || binding.QuestionId == Guid.Empty)
                        issues.Add(new($"{bPath}.questionId", "QUESTION_BINDING_MISSING_QUESTION_ID",
                            "purpose=QUESTION 的绑定必须提供 questionId"));
                    else if (!IsUuidV4(binding.QuestionId.Value))
                        issues.Add(new($"{bPath}.questionId", "INVALID_UUID_VERSION",
                            "questionId 必须为 UUID v4"));
                    else
                        questionBindings.Add((binding.QuestionId.Value, binding.KnowledgePointId, index, b));
                }
            }
        }
    }

    private static void ValidateChoice(
        Choice choice, string path,
        HashSet<string> sceneIds,
        Dictionary<Guid, Guid> questionToPoints,
        List<(Choice Choice, string Path, int SceneIdx)> allChoices,
        HashSet<string> seenChoiceIds,
        int sceneIdx,
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
        else if (!IsUuidV4(choice.QuestionId))
            issues.Add(new($"{path}.questionId", "INVALID_UUID_VERSION", "questionId 必须为 UUID v4"));

        if (string.IsNullOrWhiteSpace(choice.Text))
            issues.Add(new($"{path}.text", "EMPTY_CHOICE_FIELD", "text 不能为空"));

        if (choice.KnowledgePointId == Guid.Empty)
            issues.Add(new($"{path}.knowledgePointId", "EMPTY_CHOICE_FIELD", "knowledgePointId 不能为空 GUID"));
        else if (!IsUuidV4(choice.KnowledgePointId))
            issues.Add(new($"{path}.knowledgePointId", "INVALID_UUID_VERSION",
                "knowledgePointId 必须为 UUID v4"));

        allChoices.Add((choice, path, sceneIdx));

        // nextSceneId 引用有效性
        if (!string.IsNullOrWhiteSpace(choice.NextSceneId) && !sceneIds.Contains(choice.NextSceneId))
            issues.Add(new($"{path}.nextSceneId", "INVALID_NEXT_SCENE",
                $"nextSceneId \"{choice.NextSceneId}\" 不指向任何存在的 scene"));

        // questionId 跨场景一致性
        if (choice.QuestionId != Guid.Empty)
        {
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

        }
    }

    /// <summary>校验 QUESTION 绑定唯一性、choice 存在性及 pointId 双向一致性。</summary>
    private static void ValidateQuestionBindings(
        List<(Guid QuestionId, Guid PointId, int SceneIdx, int BindingIdx)> bindings,
        List<(Choice Choice, string Path, int SceneIdx)> choices,
        List<ValidationIssue> issues)
    {
        var seen = new HashSet<Guid>();
        foreach (var sceneGroup in bindings.GroupBy(binding => binding.SceneIdx))
        {
            if (sceneGroup.Count() > 1)
            {
                var duplicate = sceneGroup.Skip(1).First();
                issues.Add(new(
                    $"scenes[{duplicate.SceneIdx}].knowledgeBindings[{duplicate.BindingIdx}]",
                    "MULTIPLE_QUESTIONS_IN_SCENE",
                    "一个场景只能声明一个 QUESTION knowledgeBinding"));
            }
        }

        foreach (var (qId, pointId, sIdx, bIdx) in bindings)
        {
            var path = $"scenes[{sIdx}].knowledgeBindings[{bIdx}].questionId";
            if (!seen.Add(qId))
                issues.Add(new(path, "DUPLICATE_QUESTION_BINDING",
                    $"questionId {qId} 在包内声明了多个 QUESTION 绑定"));

            var matchingChoices = choices
                .Where(item => item.SceneIdx == sIdx && item.Choice.QuestionId == qId)
                .ToArray();
            if (matchingChoices.Length == 0)
            {
                issues.Add(new(path, "ORPHAN_QUESTION_BINDING",
                    $"questionId {qId} 在 QUESTION 绑定所在场景中没有对应 choice"));
            }
            else if (matchingChoices.Any(item => item.Choice.KnowledgePointId != pointId))
            {
                issues.Add(new(path, "QUESTION_BINDING_POINT_MISMATCH",
                    $"QUESTION 绑定的 knowledgePointId {pointId} 与同场景 choice 不一致"));
            }

            foreach (var item in choices.Where(item => item.SceneIdx == sIdx && item.Choice.QuestionId != qId))
            {
                issues.Add(new(item.Path, "QUESTION_SCENE_CHOICE_MISMATCH",
                    $"QUESTION 场景中的所有 choice 必须使用 questionId {qId}"));
            }
        }
    }

    /// <summary>计分题必须显式携带 Render 可直接使用的 answerKind 与正确性。</summary>
    private static void ValidateScoringChoices(
        List<(Choice Choice, string Path, int SceneIdx)> choices,
        HashSet<(int SceneIdx, Guid QuestionId)> scoringQuestionKeys,
        List<ValidationIssue> issues)
    {
        foreach (var (choice, path, sceneIdx) in choices)
        {
            var isScoring = scoringQuestionKeys.Contains((sceneIdx, choice.QuestionId));
            if (!isScoring && (choice.Correct is not null || choice.AnswerKind is not null))
            {
                issues.Add(new(path, "SCORING_CHOICE_WITHOUT_QUESTION_BINDING",
                    "带 answerKind/correct 的 choice 必须具有同场景 QUESTION knowledgeBinding"));
                continue;
            }

            if (!isScoring)
                continue;

            if (choice.AnswerKind is null)
                issues.Add(new($"{path}.answerKind", "MISSING_ANSWER_KIND",
                    "QUESTION choice 必须提供 answerKind"));
            else if (choice.AnswerKind != AnswerKind.CHOICE)
                issues.Add(new($"{path}.answerKind", "ANSWER_KIND_MISMATCH",
                    "当前 Choice schema 的 answerKind 必须为 CHOICE"));

            if (choice.Correct is null)
                issues.Add(new($"{path}.correct", "MISSING_CORRECTNESS",
                    "QUESTION choice 必须明确 correct"));
        }
    }

    /// <summary>校验每题至少有一个正确选项。</summary>
    private static void ValidateQuestionCorrectness(
        List<(Choice Choice, string Path, int SceneIdx)> choices,
        HashSet<(int SceneIdx, Guid QuestionId)> scoringQuestionKeys,
        List<ValidationIssue> issues)
    {
        foreach (var (sceneIdx, questionId) in scoringQuestionKeys)
        {
            var matchingChoices = choices
                .Where(item => item.SceneIdx == sceneIdx && item.Choice.QuestionId == questionId)
                .ToArray();
            if (matchingChoices.Length > 0 && matchingChoices.All(item => item.Choice.Correct is not true))
                issues.Add(new(matchingChoices[0].Path + ".questionId",
                    "NO_CORRECT_CHOICE",
                    $"questionId {questionId} 没有 correct=true 的选项"));
        }
    }

    private static void ValidateQuestionSceneReachability(
        GamePackage package,
        List<(Guid QuestionId, Guid PointId, int SceneIdx, int BindingIdx)> bindings,
        List<ValidationIssue> issues)
    {
        if (package.Scenes is null || package.Scenes.Length == 0
            || string.IsNullOrWhiteSpace(package.EntrySceneId))
            return;

        var scenesById = package.Scenes
            .Where(scene => scene is not null && !string.IsNullOrWhiteSpace(scene.SceneId))
            .GroupBy(scene => scene.SceneId, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);
        if (!scenesById.ContainsKey(package.EntrySceneId))
            return;

        var reachable = new HashSet<string>(StringComparer.Ordinal) { package.EntrySceneId };
        var pending = new Queue<string>();
        pending.Enqueue(package.EntrySceneId);
        while (pending.TryDequeue(out var sceneId))
        {
            var scene = scenesById[sceneId];
            foreach (var nextSceneId in (scene.Choices ?? Array.Empty<Choice>())
                         .Select(choice => choice?.NextSceneId)
                         .Where(next => !string.IsNullOrWhiteSpace(next)))
            {
                if (nextSceneId is not null && scenesById.ContainsKey(nextSceneId) && reachable.Add(nextSceneId))
                    pending.Enqueue(nextSceneId);
            }
        }

        foreach (var binding in bindings)
        {
            var scene = package.Scenes[binding.SceneIdx];
            if (scene is not null && !reachable.Contains(scene.SceneId))
            {
                issues.Add(new(
                    $"scenes[{binding.SceneIdx}].knowledgeBindings[{binding.BindingIdx}]",
                    "UNREACHABLE_QUESTION_SCENE",
                    "QUESTION 场景必须能从 entrySceneId 到达"));
            }
        }
    }

    /// <summary>校验 assets（独立于 scenes，确保 scenes=null 时仍执行）</summary>
    private static void ValidateAssets(AssetRef[]? assets, List<ValidationIssue> issues)
    {
        if (assets is null)
        {
            issues.Add(new("assets", "MISSING_ASSETS", "assets 不能为 null"));
            return;
        }

        var seenAssetIds = new HashSet<string>(StringComparer.Ordinal);
        for (var a = 0; a < assets.Length; a++)
        {
            var asset = assets[a];
            var aPath = $"assets[{a}]";
            if (asset is null)
            {
                issues.Add(new(aPath, "NULL_ELEMENT", "资源元素不能为 null"));
                continue;
            }
            if (string.IsNullOrWhiteSpace(asset.AssetId))
                issues.Add(new($"{aPath}.assetId", "EMPTY_ASSET_FIELD", "assetId 不能为空"));
            else if (!seenAssetIds.Add(asset.AssetId))
                issues.Add(new($"{aPath}.assetId", "DUPLICATE_ASSET_ID",
                    $"assetId \"{asset.AssetId}\" 重复"));
            if (string.IsNullOrWhiteSpace(asset.Uri))
                issues.Add(new($"{aPath}.uri", "EMPTY_ASSET_FIELD", "uri 不能为空"));
            if (asset.Type is null)
                issues.Add(new($"{aPath}.type", "MISSING_ASSET_TYPE", "type 不能为空"));
        }
    }

    private static bool IsUuidV4(Guid value)
        => value != Guid.Empty
           && value.ToString("D")[14] == '4'
           && value.ToString("D")[19] is '8' or '9' or 'a' or 'b';

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
