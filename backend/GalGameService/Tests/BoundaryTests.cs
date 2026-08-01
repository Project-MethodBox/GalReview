using System.Text.Json;
using System.Text.Json.Serialization;
using Xunit;

// ============================================================================
// 边界测试：验证对话文本包含特殊字符或超长文本时的系统表现
//
// 覆盖场景：
//   1. Emoji 与特殊符号
//   2. 引号与转义字符
//   3. 换行符与制表符
//   4. HTML / XSS 载荷
//   5. SQL 注入载荷
//   6. 多语言 Unicode（中日韩、阿拉伯语、俄语）
//   7. 超长文本（10K / 100K 字符）
//   8. 空白字符边缘情况
//   9. Null / 特殊 emotion 值
//
// 验证维度：
//   - 校验器：特殊字符不触发误报
//   - 序列化：文本完整保留（往返一致）
//   - 模拟器：不崩溃、日志完整
//   - Checksum：稳定且不因编码异常
// ============================================================================

public class BoundaryTests
{
    private readonly GamePackageValidator _validator = new();

    // ------------------------------------------------------------------------
    // 基础构造：从黄金包派生，替换对话文本
    // ------------------------------------------------------------------------

    private static readonly Guid PkgId = Guid.Parse("f2561bb2-b88c-47ef-b0ae-8f283ff64f1b");
    private static readonly Guid QId = Guid.Parse("6428a20a-66dd-44c9-944f-d7b36fa9c95a");
    private static readonly Guid PointId = Guid.Parse("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb");
    private static readonly Guid PlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");

    private static GamePackage BuildPackageWithDialogue(string dialogueText, string? emotion = "curious") =>
        new(
            SchemaVersion: "1.0",
            PackageId: PkgId,
            GeneratorVersion: "gala-0.1.0",
            ReviewPlanId: PlanId,
            SnapshotVersion: "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
            EntrySceneId: "scene-001",
            Scenes: new Scene[]
            {
                new(
                    SceneId: "scene-001",
                    Title: null,
                    Dialogue: new DialogueLine[]
                    {
                        new("heroine", dialogueText, emotion),
                    },
                    Choices: new Choice[]
                    {
                        new("c1", QId, "协调群体数量与个体生长", null, 1, PointId,
                            AnswerKind.CHOICE, Correct: true),
                    },
                    KnowledgeBindings: new KnowledgeBinding[]
                    {
                        new(PointId, QId, KnowledgePurpose.QUESTION),
                    }),
            },
            Assets: Array.Empty<AssetRef>());

    // ========================================================================
    // 1. Emoji 与特殊符号
    // ========================================================================

    [Theory]
    [InlineData("水稻分蘖期管理 🌾✨🎯 这道题你会吗？")]
    [InlineData("🎉🎊🎈 恭喜通关！★☆※◎◇◆")]
    [InlineData("Emoji 混排：🌾 水稻 🌱 幼苗 🌿 分蘖 🌾 抽穗 🍚 成熟")]
    [InlineData("数学符号：∑∏∫∂√∞≠≤≥αβγδπΣΩ")]
    [InlineData("箭头与符号：→←↑↓↔⇒⇐⇑⇓♦♣♥♠")]
    public void Dialogue_WithEmoji_PassesValidation_AndPreserved(string text)
    {
        var pkg = BuildPackageWithDialogue(text);

        // 校验通过
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid, string.Join("; ", result.Errors.Select(e => e.Code)));

        // 序列化往返一致
        AssertDialogueTextPreserved(pkg, text);
    }

    // ========================================================================
    // 2. 引号与转义字符
    // ========================================================================

    [Theory]
    [InlineData("她说\"你好\"，然后走了")]
    [InlineData("路径: C:\\Users\\test\\file.txt")]
    [InlineData("包含'单引号'和\"双引号\"的文本")]
    [InlineData("转义序列: \\n \\t \\r \\\\ \\\"")]
    [InlineData("JSON 片段: {\"key\": \"value\", \"nested\": {\"a\": 1}}")]
    [InlineData("混合引号: \"He said 'hello' to her\"")]
    public void Dialogue_WithQuotes_PassesValidation_AndPreserved(string text)
    {
        var pkg = BuildPackageWithDialogue(text);
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);

        AssertDialogueTextPreserved(pkg, text);
    }

    // ========================================================================
    // 3. 换行符与制表符
    // ========================================================================

    [Theory]
    [InlineData("第一行\n第二行\n第三行")]
    [InlineData("制表符\t分隔\t的文本")]
    [InlineData("Windows\r\n换行")]
    [InlineData("混合\r\n\t换行和制表符\n")]
    [InlineData("多段落\n\n\n空行分隔")]
    public void Dialogue_WithNewlines_PassesValidation_AndPreserved(string text)
    {
        var pkg = BuildPackageWithDialogue(text);
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);

        AssertDialogueTextPreserved(pkg, text);
    }

    // ========================================================================
    // 4. HTML / XSS 载荷（验证不被执行，仅作为纯文本处理）
    // ========================================================================

    [Theory]
    [InlineData("<script>alert('XSS')</script>")]
    [InlineData("<img src=x onerror=alert(1)>")]
    [InlineData("<div onclick='steal()'>点击</div>")]
    [InlineData("\"><script>alert(1)</script>")]
    [InlineData("<iframe src='evil.com'></iframe>")]
    [InlineData("&lt;script&gt;alert(1)&lt;/script&gt;")]
    public void Dialogue_WithHtmlPayload_TreatedAsPlainText(string text)
    {
        var pkg = BuildPackageWithDialogue(text);

        // 校验通过（文本非空即可）
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);

        // 序列化后 HTML 标签作为文本保留（JSON 转义）
        AssertDialogueTextPreserved(pkg, text);
    }

    // ========================================================================
    // 5. SQL 注入载荷
    // ========================================================================

    [Theory]
    [InlineData("'; DROP TABLE scenes; --")]
    [InlineData("' OR '1'='1")]
    [InlineData("1; DELETE FROM game_packages WHERE 1=1; --")]
    [InlineData("UNION SELECT * FROM users --")]
    [InlineData("'; EXEC xp_cmdshell('dir'); --")]
    public void Dialogue_WithSqlInjection_TreatedAsPlainText(string text)
    {
        var pkg = BuildPackageWithDialogue(text);
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);

        AssertDialogueTextPreserved(pkg, text);
    }

    // ========================================================================
    // 6. 多语言 Unicode
    // ========================================================================

    [Theory]
    [InlineData("日本語テキスト：水稲の分げつ期管理")]
    [InlineData("한국어 텍스트: 벼 분얼기 관리")]
    [InlineData("العربية: إدارة مرحلة التفرع في الأرز")]
    [InlineData("Русский: управление фазой кущения риса")]
    [InlineData("Español: gestión de la fase de ahijamiento del arroz")]
    [InlineData("Français: gestion de la phase de tallage du riz")]
    [InlineData("多语言混排：水稻(Oryza sativa)の分げつ(분얼)관리")]
    public void Dialogue_WithUnicode_PassesValidation_AndPreserved(string text)
    {
        var pkg = BuildPackageWithDialogue(text);
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);

        AssertDialogueTextPreserved(pkg, text);
    }

    // ========================================================================
    // 7. 超长文本
    // ========================================================================

    [Fact]
    public void Dialogue_With10KCharacters_PassesValidation()
    {
        var text = string.Concat(Enumerable.Repeat("水稻分蘖期管理。", 1000)); // ~8000 字符
        var pkg = BuildPackageWithDialogue(text);
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);
        AssertDialogueTextPreserved(pkg, text);
    }

    [Fact]
    public void Dialogue_With100KCharacters_PassesValidation()
    {
        var text = new string('A', 100_000); // 100K ASCII
        var pkg = BuildPackageWithDialogue(text);
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);
        AssertDialogueTextPreserved(pkg, text);
    }

    [Fact]
    public void Dialogue_With50KUnicodeCharacters_PassesValidation()
    {
        var text = string.Concat(Enumerable.Repeat("水稻", 25_000)); // ~50K Unicode 字符
        var pkg = BuildPackageWithDialogue(text);
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);
        AssertDialogueTextPreserved(pkg, text);
    }

    [Fact]
    public void Dialogue_WithLongText_SimulatorDoesNotCrash()
    {
        var text = new string('测', 10_000);
        var pkg = BuildPackageWithDialogue(text);
        var playResult = GamePlaythroughSimulator.Run(pkg, ChoiceStrategy.AlwaysCorrect);

        Assert.True(playResult.Completed);
        Assert.Single(playResult.DialogueLog);
        Assert.Equal(text, playResult.DialogueLog[0].Text);
    }

    // ========================================================================
    // 8. 空白字符边缘情况
    // ========================================================================

    [Theory]
    [InlineData("   ")]          // 纯空格
    [InlineData("\t\t\t")]       // 纯制表符
    [InlineData("\n\n\n")]       // 纯换行
    [InlineData(" \t\n ")]       // 混合空白
    public void Dialogue_WithOnlyWhitespace_FailsValidation(string text)
    {
        var pkg = BuildPackageWithDialogue(text);
        var result = _validator.Validate(pkg);
        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Code == "EMPTY_DIALOGUE_FIELD");
    }

    [Theory]
    [InlineData(" a ")]          // 前后空格 + 内容
    [InlineData("\t内容\t")]      // 前后制表符 + 内容
    [InlineData("\n有内容\n")]    // 前后换行 + 内容
    public void Dialogue_WithWhitespaceAroundContent_PassesValidation(string text)
    {
        var pkg = BuildPackageWithDialogue(text);
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);
    }

    // ========================================================================
    // 9. Null / 特殊 emotion 值
    // ========================================================================

    [Fact]
    public void Dialogue_WithNullEmotion_PassesValidation()
    {
        var pkg = BuildPackageWithDialogue("正常文本", emotion: null);
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);
    }

    [Fact]
    public void Dialogue_WithEmptyEmotion_PassesValidation()
    {
        var pkg = BuildPackageWithDialogue("正常文本", emotion: "");
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);
    }

    [Fact]
    public void Dialogue_WithLongEmotion_PassesValidation()
    {
        var pkg = BuildPackageWithDialogue("正常文本", emotion: new string('情', 500));
        var result = _validator.Validate(pkg);
        Assert.True(result.Valid);
    }

    // ========================================================================
    // 10. 特殊字符在选项文本中
    // ========================================================================

    [Fact]
    public void Choice_WithSpecialCharacters_PassesValidation()
    {
        var pkg = new GamePackage(
            SchemaVersion: "1.0",
            PackageId: PkgId,
            GeneratorVersion: "gala-0.1.0",
            ReviewPlanId: PlanId,
            SnapshotVersion: "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
            EntrySceneId: "scene-001",
            Scenes: new Scene[]
            {
                new(
                    SceneId: "scene-001",
                    Title: "<script>alert('title')</script>",
                    Dialogue: new DialogueLine[]
                    {
                        new("heroine", "题干包含 emoji 🎯 和引号\"test\"", "curious"),
                    },
                    Choices: new Choice[]
                    {
                        new("c1", QId, "选项含 <b>HTML</b> 和 '; DROP TABLE--", null, 1, PointId,
                            AnswerKind.CHOICE, Correct: true),
                        new("c2", QId, "🌾 正确选项", null, 0, PointId,
                            AnswerKind.CHOICE, Correct: false),
                        new("c3", QId, "Unicode: 日本語한국어", null, 0, PointId,
                            AnswerKind.CHOICE, Correct: false),
                    },
                    KnowledgeBindings: new KnowledgeBinding[]
                    {
                        new(PointId, QId, KnowledgePurpose.QUESTION),
                    }),
            },
            Assets: Array.Empty<AssetRef>());

        var result = _validator.Validate(pkg);
        Assert.True(result.Valid, string.Join("; ", result.Errors.Select(e => e.Code)));

        // 模拟器不崩溃
        var playResult = GamePlaythroughSimulator.Run(pkg, ChoiceStrategy.AlwaysCorrect);
        Assert.True(playResult.Completed);
        Assert.Equal(1, playResult.FinalScore);
    }

    // ========================================================================
    // 11. Checksum 稳定性：特殊字符不影响 checksum 一致性
    // ========================================================================

    [Fact]
    public void Checksum_StableWithSpecialCharacters()
    {
        var pkg = BuildPackageWithDialogue("特殊字符 🎯 \"引号\" \n 换行 <script>");

        var hash1 = GamePackageValidator.ComputeChecksum(pkg);
        var hash2 = GamePackageValidator.ComputeChecksum(pkg);

        Assert.Equal(hash1, hash2);
        Assert.Equal(64, hash1.Length); // SHA-256 hex
    }

    [Fact]
    public void Checksum_DifferentForDifferentSpecialText()
    {
        var pkg1 = BuildPackageWithDialogue("文本 A 🎯");
        var pkg2 = BuildPackageWithDialogue("文本 B 🌾");

        var hash1 = GamePackageValidator.ComputeChecksum(pkg1);
        var hash2 = GamePackageValidator.ComputeChecksum(pkg2);

        Assert.NotEqual(hash1, hash2);
    }

    // ========================================================================
    // 12. JSON 序列化往返：特殊字符完整保留
    // ========================================================================

    [Fact]
    public void Serialization_RoundTrip_PreservesSpecialCharacters()
    {
        var specialTexts = new[]
        {
            "emoji 🎯🌾✨",
            "引号 \"hello\" 'world'",
            "换行\n制表\t符",
            "<script>alert(1)</script>",
            "'; DROP TABLE--",
            "日本語한국어العربية",
        };

        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        };
        options.Converters.Add(new JsonStringEnumConverter());

        foreach (var text in specialTexts)
        {
            var pkg = BuildPackageWithDialogue(text);
            var json = JsonSerializer.Serialize(pkg, options);
            var deserialized = JsonSerializer.Deserialize<GamePackage>(json, options);

            Assert.NotNull(deserialized);
            Assert.Equal(text, deserialized!.Scenes[0].Dialogue[0].Text);
        }
    }

    // ========================================================================
    // 辅助方法
    // ========================================================================

    /// <summary>验证对话文本在序列化往返后完整保留</summary>
    private static void AssertDialogueTextPreserved(GamePackage pkg, string expectedText)
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        };
        options.Converters.Add(new JsonStringEnumConverter());

        var json = JsonSerializer.Serialize(pkg, options);
        var deserialized = JsonSerializer.Deserialize<GamePackage>(json, options);

        Assert.NotNull(deserialized);
        Assert.Equal(expectedText, deserialized!.Scenes[0].Dialogue[0].Text);
    }
}
