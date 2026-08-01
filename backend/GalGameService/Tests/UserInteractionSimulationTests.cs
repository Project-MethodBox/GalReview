using System.Text.Json;
using System.Text.Json.Serialization;
using Xunit;

// ============================================================================
// 模拟用户交互遍历测试
//
// 通过 GamePlaythroughSimulator 状态机模拟前端 preview.html 的真实交互流程：
//   DIALOGUE → 逐行推进对话（模拟用户点击"继续"）
//   CHOICES  → 选项出现，用户选择一个
//   ENDING   → 游戏结束，结算得分
//
// 测试策略：
//   1. AlwaysCorrect — 每道计分题选正确答案 → 满分
//   2. AlwaysWrong   — 每道计分题选错误答案 → 零分
//   3. PickFirst     — 始终选第一个选项 → 一定终止
//   4. MixedStrategy — 部分选对部分选错 → 得分 = 选对数
//   5. 对话完整性   — 所有对话行文本非空
//   6. 交互日志     — 记录完整操作链供调试
// ============================================================================

public class UserInteractionSimulationTests
{
    // ------------------------------------------------------------------------
    // JSON 反序列化配置
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
            throw new FileNotFoundException($"Mock 数据文件未找到：{path}", path);
        var json = File.ReadAllText(path);
        var pkg = JsonSerializer.Deserialize<GamePackage>(json, JsonOptions);
        Assert.NotNull(pkg);
        return pkg!;
    }

    // ------------------------------------------------------------------------
    // Theory 数据
    // ------------------------------------------------------------------------

    public static IEnumerable<object[]> AllMockFiles => new[]
    {
        new object[] { "golden.json" },
        new object[] { "campus-standard.json" },
        new object[] { "fantasy-advanced.json" },
        new object[] { "science-basic.json" },
    };

    public static IEnumerable<object[]> StyledMockFiles => new[]
    {
        new object[] { "campus-standard.json" },
        new object[] { "fantasy-advanced.json" },
        new object[] { "science-basic.json" },
    };

    // ========================================================================
    // 1. 全选正确答案 → 满分
    // ========================================================================

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void Playthrough_AlwaysCorrect_AchievesFullScore(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var result = GamePlaythroughSimulator.Run(pkg, ChoiceStrategy.AlwaysCorrect);

        var expectedScore = pkg.Scenes
            .SelectMany(s => s.Choices)
            .Sum(c => c.ScoreDelta);

        Assert.True(result.Completed, FormatLog(fileName, "游戏未正常结束", result));
        Assert.Equal(expectedScore, result.FinalScore);
        Assert.Equal(expectedScore, result.CorrectAnswers);
    }

    // ========================================================================
    // 2. 全选错误答案 → 零分
    // ========================================================================

    [Theory]
    [MemberData(nameof(StyledMockFiles))]
    public void Playthrough_AlwaysWrong_GetsZeroScore(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var result = GamePlaythroughSimulator.Run(pkg, ChoiceStrategy.AlwaysWrong);

        Assert.True(result.Completed, FormatLog(fileName, "游戏未正常结束", result));
        Assert.Equal(0, result.FinalScore);
        Assert.Equal(0, result.CorrectAnswers);
        Assert.True(result.QuestionsAnswered > 0, "至少回答了 1 道题");
    }

    // ========================================================================
    // 3. 始终选第一个选项 → 一定终止
    // ========================================================================

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void Playthrough_PickFirstChoice_AlwaysTerminates(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var result = GamePlaythroughSimulator.Run(pkg, ChoiceStrategy.PickFirst);

        Assert.True(result.Completed, FormatLog(fileName, "选第一个选项的路径未终止", result));
        Assert.True(result.VisitedScenes.Count > 0, "至少访问了 1 个场景");
    }

    // ========================================================================
    // 4. 混合策略：第 N 题选对，其余选错
    // ========================================================================

    [Theory]
    [MemberData(nameof(StyledMockFiles))]
    public void Playthrough_MixedStrategy_ScoreMatchesCorrectPicks(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var totalQuestions = pkg.Scenes
            .SelectMany(s => s.KnowledgeBindings)
            .Count(b => b.Purpose == KnowledgePurpose.QUESTION);

        // 对每道题分别测试：只选对第 i 题，其余选错
        for (var targetQuestion = 0; targetQuestion < totalQuestions; targetQuestion++)
        {
            var result = GamePlaythroughSimulator.Run(
                pkg, ChoiceStrategy.CorrectOnlyAt(targetQuestion));

            Assert.True(result.Completed,
                FormatLog(fileName, $"第 {targetQuestion} 题选对的路径未终止", result));
            Assert.Equal(1, result.FinalScore);
            Assert.Equal(1, result.CorrectAnswers);
        }
    }

    // ========================================================================
    // 5. 对话完整性：所有对话行文本非空
    // ========================================================================

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void Playthrough_AllDialogueLinesHaveText(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var result = GamePlaythroughSimulator.Run(pkg, ChoiceStrategy.AlwaysCorrect);

        Assert.True(result.Completed, FormatLog(fileName, "游戏未正常结束", result));
        Assert.NotEmpty(result.DialogueLog);

        foreach (var entry in result.DialogueLog)
        {
            Assert.False(string.IsNullOrWhiteSpace(entry.Text),
                $"存在空对话行：{entry.Text}");
            Assert.False(string.IsNullOrWhiteSpace(entry.SpeakerId),
                $"存在空说话人：场景 {entry.SceneId}");
        }
    }

    // ========================================================================
    // 6. 场景访问顺序验证
    // ========================================================================

    [Theory]
    [MemberData(nameof(StyledMockFiles))]
    public void Playthrough_VisitsScenesInOrder(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var result = GamePlaythroughSimulator.Run(pkg, ChoiceStrategy.AlwaysCorrect);

        Assert.True(result.Completed, FormatLog(fileName, "游戏未正常结束", result));
        // 风格包应依次访问 4 个场景：scene-001 → scene-002 → scene-003 → scene-004
        Assert.Equal(4, result.VisitedScenes.Count);
        Assert.Equal("scene-001", result.VisitedScenes[0]);
        Assert.Equal("scene-004", result.VisitedScenes[^1]);
    }

    [Fact]
    public void Playthrough_GoldenPackage_SingleSceneSingleChoice()
    {
        var pkg = LoadMockPackage("golden.json");
        var result = GamePlaythroughSimulator.Run(pkg, ChoiceStrategy.AlwaysCorrect);

        Assert.True(result.Completed, FormatLog("golden.json", "游戏未正常结束", result));
        Assert.Single(result.VisitedScenes);
        Assert.Equal(1, result.FinalScore);
        Assert.Equal(1, result.QuestionsAnswered);
    }

    // ========================================================================
    // 7. 得分一致性：不同策略的得分总和正确
    // ========================================================================

    [Theory]
    [MemberData(nameof(StyledMockFiles))]
    public void Playthrough_ScoreNeverExceedsTotal(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var totalScore = pkg.Scenes
            .SelectMany(s => s.Choices)
            .Sum(c => c.ScoreDelta);

        // 测试所有策略的得分都不超过总分
        var strategies = new[]
        {
            (ChoiceStrategy.AlwaysCorrect, "AlwaysCorrect"),
            (ChoiceStrategy.AlwaysWrong, "AlwaysWrong"),
            (ChoiceStrategy.PickFirst, "PickFirst"),
        };

        foreach (var (strategy, name) in strategies)
        {
            var result = GamePlaythroughSimulator.Run(pkg, strategy);
            Assert.True(result.Completed,
                FormatLog(fileName, $"{name} 策略未终止", result));
            Assert.True(result.FinalScore >= 0,
                $"{name}: 得分 {result.FinalScore} 不应为负");
            Assert.True(result.FinalScore <= totalScore,
                $"{name}: 得分 {result.FinalScore} 超过总分 {totalScore}");
        }
    }

    // ========================================================================
    // 8. 交互日志完整性：每次选择都有记录
    // ========================================================================

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void Playthrough_ChoiceLogRecordsAllDecisions(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var result = GamePlaythroughSimulator.Run(pkg, ChoiceStrategy.AlwaysCorrect);

        Assert.True(result.Completed, FormatLog(fileName, "游戏未正常结束", result));
        // 每个被访问场景的选项选择都应记录在 ChoiceLog 中
        // （结束场景无选项，不计）
        var scenesWithChoices = result.VisitedScenes
            .Select(id => pkg.Scenes.First(s => s.SceneId == id))
            .Where(s => s.Choices.Length > 0)
            .Count();

        Assert.Equal(scenesWithChoices, result.ChoiceLog.Count);
    }

    // ========================================================================
    // 9. JSON 日志格式验证：确保输出可被自动化解析
    // ========================================================================

    [Theory]
    [MemberData(nameof(AllMockFiles))]
    public void Playthrough_ToJson_ProducesValidJson(string fileName)
    {
        var pkg = LoadMockPackage(fileName);
        var result = GamePlaythroughSimulator.Run(pkg, ChoiceStrategy.AlwaysCorrect);

        var json = result.ToJson();
        Assert.False(string.IsNullOrWhiteSpace(json));

        // 验证 JSON 可被反序列化回来
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        Assert.Equal(result.Completed, root.GetProperty("completed").GetBoolean());
        Assert.Equal(result.FinalScore, root.GetProperty("finalScore").GetInt32());
        Assert.Equal(result.QuestionsAnswered, root.GetProperty("questionsAnswered").GetInt32());
        Assert.Equal(result.CorrectAnswers, root.GetProperty("correctAnswers").GetInt32());

        // 验证结构化日志字段存在
        var dialogueLog = root.GetProperty("dialogueLog");
        Assert.Equal(result.DialogueLog.Count, dialogueLog.GetArrayLength());
        if (dialogueLog.GetArrayLength() > 0)
        {
            var first = dialogueLog[0];
            Assert.True(first.TryGetProperty("sceneId", out _));
            Assert.True(first.TryGetProperty("speakerId", out _));
            Assert.True(first.TryGetProperty("text", out _));
        }

        var choiceLog = root.GetProperty("choiceLog");
        Assert.Equal(result.ChoiceLog.Count, choiceLog.GetArrayLength());
        if (choiceLog.GetArrayLength() > 0)
        {
            var first = choiceLog[0];
            Assert.True(first.TryGetProperty("sceneId", out _));
            Assert.True(first.TryGetProperty("choiceType", out _));
            Assert.True(first.TryGetProperty("choiceText", out _));
            Assert.True(first.TryGetProperty("scoreDelta", out _));
            Assert.True(first.TryGetProperty("isCorrect", out _));
        }
    }

    // ========================================================================
    // 辅助方法
    // ========================================================================

    private static readonly JsonSerializerOptions LogJsonOptions = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>
    /// 以 JSON 格式输出交互日志，方便后续自动化分析。
    /// 结构：{ fileName, message, completed, finalScore, questionsAnswered,
    ///         correctAnswers, visitedScenes, dialogueLog[], choiceLog[] }
    /// </summary>
    private static string FormatLog(string fileName, string message, PlaythroughResult result)
    {
        var logObj = new
        {
            fileName,
            message,
            timestamp = DateTimeOffset.UtcNow.ToString("o"),
            result = new
            {
                completed = result.Completed,
                finalScore = result.FinalScore,
                questionsAnswered = result.QuestionsAnswered,
                correctAnswers = result.CorrectAnswers,
                visitedScenes = result.VisitedScenes,
                dialogueLog = result.DialogueLog,
                choiceLog = result.ChoiceLog,
            },
        };
        return "\n" + JsonSerializer.Serialize(logObj, LogJsonOptions);
    }
}

// ============================================================================
// 用户交互模拟器（状态机）
//
// 模拟前端 preview.html 的交互逻辑：
//   状态流转: DIALOGUE → CHOICES → DIALOGUE/ENDING → ...
//   每个 DIALOGUE 状态逐行推进对话
//   每个 CHOICES 状态根据策略选择一个选项
//   到达 ENDING 状态时结算得分
// ========================================================================

public enum PlaythroughState
{
    DIALOGUE,
    CHOICES,
    ENDING,
}

/// <summary>选项选择策略</summary>
public abstract class ChoiceStrategy
{
    /// <summary>始终选正确答案（scoreDelta > 0）</summary>
    public static readonly ChoiceStrategy AlwaysCorrect = new AlwaysCorrectStrategy();

    /// <summary>始终选错误答案（scoreDelta = 0）</summary>
    public static readonly ChoiceStrategy AlwaysWrong = new AlwaysWrongStrategy();

    /// <summary>始终选第一个选项</summary>
    public static readonly ChoiceStrategy PickFirst = new PickFirstStrategy();

    /// <summary>只在第 index 道题选对，其余选错</summary>
    public static ChoiceStrategy CorrectOnlyAt(int index) => new CorrectOnlyAtStrategy(index);

    /// <summary>从选项列表中选择一个</summary>
    /// <param name="choices">当前场景的选项</param>
    /// <param name="questionIndex">当前是第几道计分题（从 0 开始）</param>
    public abstract Choice Select(Choice[] choices, int questionIndex);

    private sealed class AlwaysCorrectStrategy : ChoiceStrategy
    {
        public override Choice Select(Choice[] choices, int questionIndex) =>
            choices.FirstOrDefault(c => c.ScoreDelta > 0) ?? choices[0];
    }

    private sealed class AlwaysWrongStrategy : ChoiceStrategy
    {
        public override Choice Select(Choice[] choices, int questionIndex) =>
            choices.FirstOrDefault(c => c.ScoreDelta == 0) ?? choices[0];
    }

    private sealed class PickFirstStrategy : ChoiceStrategy
    {
        public override Choice Select(Choice[] choices, int questionIndex) => choices[0];
    }

    private sealed class CorrectOnlyAtStrategy : ChoiceStrategy
    {
        private readonly int _targetIndex;
        public CorrectOnlyAtStrategy(int targetIndex) => _targetIndex = targetIndex;

        public override Choice Select(Choice[] choices, int questionIndex)
        {
            if (questionIndex == _targetIndex)
                return choices.FirstOrDefault(c => c.ScoreDelta > 0) ?? choices[0];
            return choices.FirstOrDefault(c => c.ScoreDelta == 0) ?? choices[0];
        }
    }
}

/// <summary>结构化对话日志条目（JSON 友好）</summary>
public sealed record DialogueLogEntry(
    string SceneId,
    string SpeakerId,
    string Text,
    string? Emotion);

/// <summary>结构化选项日志条目（JSON 友好）</summary>
public sealed record ChoiceLogEntry(
    string SceneId,
    string ChoiceType,      // "NAVIGATION" | "QUESTION"
    int QuestionIndex,      // 计分题序号（导航场景为 -1）
    string ChoiceId,
    string ChoiceText,
    int ScoreDelta,
    bool IsCorrect,
    string? NextSceneId);

/// <summary>模拟一次游戏通关的结果</summary>
public class PlaythroughResult
{
    public bool Completed { get; init; }
    public int FinalScore { get; init; }
    public int QuestionsAnswered { get; init; }
    public int CorrectAnswers { get; init; }
    public List<string> VisitedScenes { get; init; } = new();
    public List<DialogueLogEntry> DialogueLog { get; init; } = new();
    public List<ChoiceLogEntry> ChoiceLog { get; init; } = new();

    /// <summary>将完整交互日志序列化为 JSON 字符串（camelCase，便于自动化解析）</summary>
    public string ToJson(JsonSerializerOptions? options = null) =>
        JsonSerializer.Serialize(this, options ?? new JsonSerializerOptions
        {
            WriteIndented = true,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
}

/// <summary>游戏通关模拟器</summary>
public static class GamePlaythroughSimulator
{
    /// <summary>最大场景跳转次数，防止无限循环</summary>
    private const int MaxTransitions = 200;

    /// <summary>
    /// 模拟用户从头到尾玩一遍游戏包。
    /// 按状态机推进：进入场景 → 逐行推进对话 → 显示选项 → 选择 → 跳转 → ...
    /// </summary>
    public static PlaythroughResult Run(GamePackage package, ChoiceStrategy strategy)
    {
        var sceneMap = package.Scenes.ToDictionary(s => s.SceneId);
        var visitedScenes = new List<string>();
        var dialogueLog = new List<DialogueLogEntry>();
        var choiceLog = new List<ChoiceLogEntry>();
        var score = 0;
        var questionsAnswered = 0;
        var correctAnswers = 0;
        var questionIndex = 0;
        var transitions = 0;
        var completed = false;

        var currentSceneId = package.EntrySceneId;
        var state = PlaythroughState.DIALOGUE;

        while (transitions < MaxTransitions)
        {
            transitions++;

            switch (state)
            {
                case PlaythroughState.DIALOGUE:
                {
                    if (!sceneMap.TryGetValue(currentSceneId, out var scene))
                    {
                        // 场景不存在，异常终止
                        goto done;
                    }

                    visitedScenes.Add(scene.SceneId);

                    // 逐行推进对话（模拟用户点击"继续"）
                    foreach (var line in scene.Dialogue)
                    {
                        dialogueLog.Add(new DialogueLogEntry(
                            scene.SceneId, line.SpeakerId, line.Text, line.Emotion));
                    }

                    // 对话结束后，根据是否有选项切换状态
                    if (scene.Choices is null || scene.Choices.Length == 0)
                    {
                        state = PlaythroughState.ENDING;
                    }
                    else
                    {
                        state = PlaythroughState.CHOICES;
                    }
                    break;
                }

                case PlaythroughState.CHOICES:
                {
                    if (!sceneMap.TryGetValue(currentSceneId, out var scene))
                        goto done;

                    // 判断是否是计分题
                    var isQuestion = scene.KnowledgeBindings
                        .Any(b => b.Purpose == KnowledgePurpose.QUESTION);

                    // 根据策略选择
                    var choice = strategy.Select(scene.Choices, questionIndex);
                    choiceLog.Add(new ChoiceLogEntry(
                        SceneId: scene.SceneId,
                        ChoiceType: isQuestion ? "QUESTION" : "NAVIGATION",
                        QuestionIndex: isQuestion ? questionIndex : -1,
                        ChoiceId: choice.ChoiceId,
                        ChoiceText: choice.Text,
                        ScoreDelta: choice.ScoreDelta,
                        IsCorrect: choice.ScoreDelta > 0,
                        NextSceneId: choice.NextSceneId));

                    if (isQuestion)
                    {
                        questionsAnswered++;
                        questionIndex++;
                        if (choice.ScoreDelta > 0)
                        {
                            score += choice.ScoreDelta;
                            correctAnswers++;
                        }
                    }

                    // 跳转
                    if (!string.IsNullOrWhiteSpace(choice.NextSceneId))
                    {
                        currentSceneId = choice.NextSceneId;
                        state = PlaythroughState.DIALOGUE;
                    }
                    else
                    {
                        state = PlaythroughState.ENDING;
                    }
                    break;
                }

                case PlaythroughState.ENDING:
                {
                    completed = true;
                    goto done;
                }
            }
        }

    done:
        return new PlaythroughResult
        {
            Completed = completed,
            FinalScore = score,
            QuestionsAnswered = questionsAnswered,
            CorrectAnswers = correctAnswers,
            VisitedScenes = visitedScenes,
            DialogueLog = dialogueLog,
            ChoiceLog = choiceLog,
        };
    }
}
