using System.Security.Cryptography;
using System.Text;

// ============================================================================
// 游戏包生成器（§7.3.1 + §7.5）
//
// 从不可变 PlanGraph 生成符合 schema 1.0 的 GamePackage。
// - 仅为 PlanNode.questionTarget=true 的节点生成计分题目
// - questionId 确定性生成且输出满足公共 UUID v4 契约
// - 按 style（CAMPUS/FANTASY/SCIENCE）生成剧情模板
// - 按 difficulty（BASIC/STANDARD/ADVANCED）调整选项数量和讲解深度
// ============================================================================

public sealed class GameGenerator
{
    private const string GeneratorVersion = "gala-0.1.0";
    // UUID v5 namespace（固定值，用于确定性 questionId 生成）
    private static readonly Guid QuestionNamespace = Guid.Parse("a3f5c1e2-7b8d-4e6f-9a0b-1c2d3e4f5a6b");

    private readonly GamePackageValidator _validator;
    private readonly ILogger<GameGenerator> _logger;

    // ========================================================================
    // 静态剧情模板：3 种 style 只初始化一次，避免每次 Generate 重复分配
    // ========================================================================

    private readonly IReadOnlyDictionary<GameStyle, StyleTemplate> _styleTemplates;

    public GameGenerator(GamePackageValidator validator, ILogger<GameGenerator> logger)
        : this(validator, logger, CharacterVoiceCatalog.LoadDefault())
    {
    }

    public GameGenerator(
        GamePackageValidator validator,
        ILogger<GameGenerator> logger,
        CharacterVoiceCatalog characterVoiceCatalog)
    {
        _validator = validator;
        _logger = logger;
        _styleTemplates = new Dictionary<GameStyle, StyleTemplate>
        {
        [GameStyle.CAMPUS] = new StyleTemplate(
            GuideSpeaker: characterVoiceCatalog.GuideSpeaker(GameStyle.CAMPUS),
            EntrySceneTitle: "图书馆的自习时光",
            EntryDialogue: "你总算来了。闭馆前，我们得把这份资料里的关键线索理清。",
            EntryEmotion: "cheerful",
            QuestionIntro: "线索已经齐了。现在该做判断。",
            EndingSceneTitle: "复习结束",
            EndingDialogue: "最后一条线索对上了。把记录收好，我们该走了。"),
        [GameStyle.FANTASY] = new StyleTemplate(
            GuideSpeaker: characterVoiceCatalog.GuideSpeaker(GameStyle.FANTASY),
            EntrySceneTitle: "魔法学院的试炼",
            EntryDialogue: "风停在石门前。先别碰那道发亮的纹路，它在等一个能自洽的判断。",
            EntryEmotion: "mystical",
            QuestionIntro: "纹路重新亮起。现在必须决定下一步。",
            EndingSceneTitle: "试炼完成",
            EndingDialogue: "石门后的风终于流动起来，来路也在微光中重新显现。"),
        [GameStyle.SCIENCE] = new StyleTemplate(
            GuideSpeaker: characterVoiceCatalog.GuideSpeaker(GameStyle.SCIENCE),
            EntrySceneTitle: "空间站知识模块",
            EntryDialogue: "外环监测出现偏差。原始读数已封存，等待共同核对。",
            EntryEmotion: "calm",
            QuestionIntro: "可用证据已对齐。请选择处置方案：",
            EndingSceneTitle: "学习模块结束",
            EndingDialogue: "处置已完成，异常趋势停止扩散。相关证据已归档。"),
        };
    }

    /// <summary>
    /// 从 PlanGraph 生成游戏包。
    /// </summary>
    /// <exception cref="ArgumentNullException">plan 或 req 为 null</exception>
    /// <exception cref="ArgumentException">PlanGraph 为空或与请求快照不一致</exception>
    public GamePackage Generate(PlanGraph plan, GameGenerationRequest req, string ownerUserId)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(req);

        if (plan.ReviewPlanId != req.ReviewPlanId
            || !string.Equals(plan.SnapshotVersion, req.SnapshotVersion, StringComparison.Ordinal))
        {
            throw new ArgumentException("PlanGraph 与生成请求的 reviewPlanId/snapshotVersion 不一致", nameof(plan));
        }

        // 空值安全：plan.Nodes 可能为 null（反序列化空数组时）
        var nodes = plan.Nodes ?? Array.Empty<PlanNode>();
        if (nodes.Length == 0)
            throw new ArgumentException("PlanGraph.Nodes 为空，无法生成游戏包", nameof(plan));

        var seed = req.Seed ?? BitConverter.ToInt64(RandomNumberGenerator.GetBytes(8), 0);

        // 1. 筛选节点
        var targetNodes = nodes.Where(n => n.QuestionTarget).ToList();
        var explainNodes = nodes.Where(n => !n.QuestionTarget).ToList();

        // 2. 为每个 target 节点生成确定性 questionId
        var questions = targetNodes.Select(n => new QuestionSpec(
            Node: n,
            QuestionId: DeterministicGuid(n.PointId, seed))).ToList();

        // 3. 获取剧情模板（静态查表，O(1)）
        if (!_styleTemplates.TryGetValue(req.Style, out var template))
            throw new ArgumentOutOfRangeException(nameof(req.Style), req.Style, "不支持的剧情风格");

        // 4. 生成场景序列
        var scenes = new List<Scene>();
        var sceneIndex = 0;
        var primaryPointId = targetNodes.FirstOrDefault()?.PointId ?? nodes[0].PointId;

        // 4a. 开场场景
        scenes.Add(CreateEntryScene(template, plan, primaryPointId, ref sceneIndex));

        // 4b. 前置知识点讲解场景（EXPLAIN 绑定，不计分，按难度递增讲解深度）
        foreach (var node in explainNodes)
        {
            scenes.Add(CreateExplainScene(template, node, req.Difficulty, ref sceneIndex));
        }

        // 4c. 题目场景（QUESTION 绑定，计分）
        for (var i = 0; i < questions.Count; i++)
        {
            var q = questions[i];
            scenes.Add(CreateQuestionScene(template, q, req.Difficulty, nodes, plan.Type, ref sceneIndex));
        }

        // 4d. 结束场景（无 choice，根据计划类型调整措辞）
        scenes.Add(CreateEndingScene(template, questions, plan.Type, ref sceneIndex));

        // 5. 链接场景：每个场景的 choice.nextSceneId 指向下一个场景
        LinkScenes(scenes);

        // 6. 构造 GamePackage（生成风格化资源引用）
        var assets = GenerateAssets(req.Style);
        var pkg = new GamePackage(
            SchemaVersion: "1.0",
            PackageId: Guid.NewGuid(),
            GeneratorVersion: GeneratorVersion,
            ReviewPlanId: plan.ReviewPlanId,
            SnapshotVersion: plan.SnapshotVersion,
            EntrySceneId: scenes[0].SceneId,
            Scenes: scenes.ToArray(),
            Assets: assets);

        // 7. 自检：校验器验证生成的包
        var result = _validator.Validate(pkg);
        if (!result.Valid)
        {
            var errors = string.Join("; ", result.Errors.Select(e => $"{e.Path}: {e.Code}"));
            _logger.LogError("Generated package {PackageId} failed self-validation: {Errors}", pkg.PackageId, errors);
            throw new InvalidOperationException($"生成的游戏包未通过校验：{errors}");
        }

        _logger.LogInformation("Generated package {PackageId} with {SceneCount} scenes, seed={Seed}, style={Style}, difficulty={Difficulty}",
            pkg.PackageId, pkg.Scenes.Length, seed, req.Style, req.Difficulty);

        return pkg;
    }

    /// <summary>链接场景的 nextSceneId：每个场景的 choice 指向下一个场景</summary>
    private static void LinkScenes(List<Scene> scenes)
    {
        for (var i = 0; i < scenes.Count - 1; i++)
        {
            var scene = scenes[i];
            var nextId = scenes[i + 1].SceneId;
            if (scene.Choices.Length > 0)
            {
                var updatedChoices = scene.Choices.Select(c =>
                    c.NextSceneId is null ? c with { NextSceneId = nextId } : c).ToArray();
                scenes[i] = scene with { Choices = updatedChoices };
            }
        }
    }

    // ========================================================================
    // 场景生成
    // ========================================================================

    private static Scene CreateEntryScene(StyleTemplate template, PlanGraph plan, Guid primaryPointId, ref int index)
    {
        index++;
        var sceneId = $"scene-{index:D3}";
        var navQuestionId = NavigationGuid(sceneId);
        var isLearning = string.Equals(plan.Type, "LEARNING", StringComparison.OrdinalIgnoreCase);
        var topicLabel = isLearning ? "学习" : "复习";
        var dialogue = new DialogueLine[]
        {
            new(template.GuideSpeaker, template.EntryDialogue, template.EntryEmotion),
            new(template.GuideSpeaker, $"今天我们要{topicLabel}的主题是：{GetPlanTopic(plan)}", "encouraging"),
        };
        return new Scene(
            SceneId: sceneId,
            Title: template.EntrySceneTitle,
            Dialogue: dialogue,
            Choices: new[]
            {
                new Choice($"c-{sceneId}-1", navQuestionId, "准备好了，开始吧！", null, 0, primaryPointId),
            },
            KnowledgeBindings: new[]
            {
                new KnowledgeBinding(primaryPointId, navQuestionId, KnowledgePurpose.FEEDBACK),
            });
    }

    private static Scene CreateExplainScene(StyleTemplate template, PlanNode node, Difficulty difficulty, ref int index)
    {
        index++;
        var sceneId = $"scene-{index:D3}";
        var navQuestionId = NavigationGuid(sceneId);

        // 按难度递增讲解深度：BASIC 2 行 / STANDARD 3 行 / ADVANCED 4 行。
        var dialogue = new List<DialogueLine>
        {
            new(template.GuideSpeaker, $"在正式提问之前，先回顾一下「{node.Title}」。", "thoughtful"),
            new(template.GuideSpeaker, node.Summary, "explaining"),
        };

        if (difficulty is Difficulty.STANDARD or Difficulty.ADVANCED)
        {
            if (node.Tags is { Length: > 0 })
            {
                dialogue.Add(new DialogueLine(
                    template.GuideSpeaker,
                    $"关键标签：{string.Join("、", node.Tags)}。这些概念在实际应用中经常交叉出现，理解它们的关联很重要。",
                    "elaborating"));
            }
            else
            {
                dialogue.Add(new DialogueLine(
                    template.GuideSpeaker,
                    $"掌握「{node.Title}」的核心概念，有助于理解后续知识点。",
                    "elaborating"));
            }
        }

        if (difficulty is Difficulty.ADVANCED)
        {
            var depthHint = node.DependencyDepth > 0
                ? $"该知识点位于依赖链第 {node.DependencyDepth} 层，是理解目标知识点的重要前置。"
                : "该知识点是本复习计划的核心目标之一，需要重点掌握。";
            dialogue.Add(new DialogueLine(
                template.GuideSpeaker,
                $"{depthHint}（知识点权重：{node.Weight:F2}）",
                "analytical"));
        }

        return new Scene(
            SceneId: sceneId,
            Title: $"知识点讲解：{node.Title}",
            Dialogue: dialogue.ToArray(),
            Choices: new[]
            {
                new Choice($"c-{sceneId}-1", navQuestionId, "了解了，继续。", null, 0, node.PointId),
            },
            KnowledgeBindings: new[]
            {
                new KnowledgeBinding(node.PointId, navQuestionId, KnowledgePurpose.EXPLAIN),
            });
    }

    private static Scene CreateQuestionScene(
        StyleTemplate template, QuestionSpec q, Difficulty difficulty, PlanNode[] allNodes, string planType, ref int index)
    {
        index++;
        var sceneId = $"scene-{index:D3}";
        var node = q.Node;

        var introText = GetQuestionIntroForPlan(template, planType);
        var dialogue = new DialogueLine[]
        {
            new(template.GuideSpeaker, introText, "challenging"),
            new(template.GuideSpeaker, $"{node.Title}——{GetQuestionStem(node, difficulty)}", "questioning"),
        };

        // 生成选项（干扰项去重）
        var (correctChoice, distractors) = GenerateChoices(node, allNodes, difficulty, q.QuestionId, sceneId);
        var choices = new List<Choice> { correctChoice };
        choices.AddRange(distractors);
        // 确定性打乱选项顺序
        choices = DeterministicShuffle(choices, q.QuestionId).ToList();

        return new Scene(
            SceneId: sceneId,
            Title: $"复习题：{node.Title}",
            Dialogue: dialogue,
            Choices: choices.ToArray(),
            KnowledgeBindings: new[]
            {
                new KnowledgeBinding(node.PointId, q.QuestionId, KnowledgePurpose.QUESTION),
            });
    }

    private static Scene CreateEndingScene(StyleTemplate template, List<QuestionSpec> questions, string planType, ref int index)
    {
        index++;
        var sceneId = $"scene-{index:D3}";
        var isLearning = string.Equals(planType, "LEARNING", StringComparison.OrdinalIgnoreCase);
        var summaryText = questions.Count == 0
            ? (isLearning ? "本次学习已完成知识讲解，辛苦了！" : "本次复习已完成知识讲解，辛苦了！")
            : (isLearning
                ? $"本次学习共完成 {questions.Count} 道验收题目，辛苦了！"
                : $"本次复习共完成 {questions.Count} 道题目，辛苦了！");

        var dialogue = new DialogueLine[]
        {
            new(template.GuideSpeaker, template.EndingDialogue, "proud"),
            new(template.GuideSpeaker, summaryText, "warm"),
        };
        return new Scene(
            SceneId: sceneId,
            Title: template.EndingSceneTitle,
            Dialogue: dialogue,
            Choices: Array.Empty<Choice>(),
            KnowledgeBindings: Array.Empty<KnowledgeBinding>());
    }

    // ========================================================================
    // 选项生成
    // ========================================================================

    private static (Choice Correct, List<Choice> Distractors) GenerateChoices(
        PlanNode correctNode, PlanNode[] allNodes, Difficulty difficulty, Guid questionId, string sceneId)
    {
        // 正确选项
        var correctText = ExtractCorrectAnswer(correctNode);
        var correct = new Choice(
            ChoiceId: $"c-{sceneId}-correct",
            QuestionId: questionId,
            Text: correctText,
            NextSceneId: null,
            ScoreDelta: 1,
            KnowledgePointId: correctNode.PointId,
            AnswerKind: AnswerKind.CHOICE,
            Correct: true);

        // 干扰项数量
        var distractorCount = difficulty switch
        {
            Difficulty.BASIC => 3,
            Difficulty.STANDARD => 3,
            Difficulty.ADVANCED => 2,
            _ => 3,
        };

        // 从其他节点生成干扰项（去重：不与正确答案重复，干扰项之间也不重复）
        var distractors = new List<Choice>();
        var usedTexts = new HashSet<string>(StringComparer.Ordinal) { correctText };
        var otherNodes = allNodes
            .Where(n => n.PointId != correctNode.PointId)
            .OrderBy(n => n.PointId) // 确定性排序
            .ToList();

        var distractorIdx = 0;
        foreach (var node in otherNodes)
        {
            if (distractors.Count >= distractorCount) break;
            var text = ExtractDistractorFromNode(node);
            if (usedTexts.Add(text)) // 去重
            {
                distractors.Add(new Choice(
                    ChoiceId: $"c-{sceneId}-d{++distractorIdx}",
                    QuestionId: questionId,
                    Text: text,
                    NextSceneId: null,
                    ScoreDelta: 0,
                    KnowledgePointId: correctNode.PointId,
                    AnswerKind: AnswerKind.CHOICE,
                    Correct: false));
            }
        }

        // 不足时用通用干扰项补齐
        var genericPool = GetGenericDistractors(difficulty);
        var genericIdx = 0;
        while (distractors.Count < distractorCount && genericIdx < genericPool.Length)
        {
            var text = genericPool[genericIdx++];
            if (usedTexts.Add(text))
            {
                distractors.Add(new Choice(
                    ChoiceId: $"c-{sceneId}-d{++distractorIdx}",
                    QuestionId: questionId,
                    Text: text,
                    NextSceneId: null,
                    ScoreDelta: 0,
                    KnowledgePointId: correctNode.PointId,
                    AnswerKind: AnswerKind.CHOICE,
                    Correct: false));
            }
        }

        return (correct, distractors);
    }

    /// <summary>
    /// 提取正确答案：从 node.Summary 中取第一句完整句子。
    /// 支持中英文句号、分号作为分隔符。
    /// </summary>
    private static string ExtractCorrectAnswer(PlanNode node)
    {
        var summary = node.Summary?.Trim() ?? string.Empty;
        if (summary.Length == 0)
            return node.Title ?? "（无描述）";

        // 按句号/分号分割，取第一句
        var separators = new[] { '。', '；', '.', ';' };
        var firstSentenceEnd = summary.IndexOfAny(separators);
        if (firstSentenceEnd > 0)
            return summary[..firstSentenceEnd];

        // 无句号时截断到 60 字符
        return summary.Length > 60 ? summary[..60] + "…" : summary;
    }

    /// <summary>
    /// 从其他节点的摘要或标签构造语义化干扰项，避免复用标题或通用占位语。
    /// </summary>
    private static string ExtractDistractorFromNode(PlanNode node)
    {
        var summary = node.Summary?.Trim() ?? string.Empty;
        var separators = new[] { '。', '；', '.', ';' };
        var firstEnd = summary.IndexOfAny(separators);
        if (firstEnd >= 0 && firstEnd < summary.Length - 1)
        {
            var rest = summary[(firstEnd + 1)..].Trim();
            if (rest.Length > 0)
            {
                var secondEnd = rest.IndexOfAny(separators);
                return secondEnd > 0 ? rest[..secondEnd] : (rest.Length > 60 ? rest[..60] + "…" : rest);
            }
        }

        if (node.Tags is { Length: >= 1 })
        {
            var tag = node.Tags[0];
            return node.Role switch
            {
                "PREREQUISITE" => $"{tag}的基本概念已经过时，不再适用于现代实践",
                "TARGET" => $"{tag}与实际应用场景关联不大，了解即可",
                _ => $"{tag}的相关内容较为次要，可跳过深入",
            };
        }

        return string.IsNullOrWhiteSpace(node.Title)
            ? "（未命名知识点）"
            : $"关于「{node.Title}」的描述已不适用";
    }

    private static string[] GetGenericDistractors(Difficulty difficulty) => difficulty switch
    {
        Difficulty.BASIC => new[]
        {
            "该知识点仅适用于理论考试，实际生产中无参考价值",
            "这是一个已被现代技术完全替代的过时方法",
            "需要结合具体地区气候条件才能判断其适用性",
        },
        Difficulty.STANDARD => new[]
        {
            "该结论仅在特定实验条件下成立，不具备普适性",
            "与传统经验相反，现代研究表明该做法效果有限",
            "该措施的实际效果受多种因素制约，不能一概而论",
        },
        Difficulty.ADVANCED => new[]
        {
            "该观点在经典理论中被广泛接受，但最新研究已提出有力反证",
            "该结论依赖于理想化假设，在复杂实际场景中存在显著偏差",
        },
        _ => new[] { "干扰项" },
    };

    // ========================================================================
    // 资源引用生成
    // ========================================================================

    private static readonly Dictionary<GameStyle, AssetTemplate> AssetTemplates = new()
    {
        [GameStyle.CAMPUS] = new AssetTemplate(
            Backgrounds: new[] { "campus_library_day", "campus_library_evening", "campus_corridor", "campus_courtyard" },
            Characters: new[] { "char_senior_linn_neutral", "char_senior_linn_smile", "char_senior_linn_thinking" },
            Audio: new[] { "bgm_campus_calm", "sfx_page_flip", "sfx_chime_correct" }),
        [GameStyle.FANTASY] = new AssetTemplate(
            Backgrounds: new[] { "fantasy_tower_entrance", "fantasy_tower_library", "fantasy_forest_mystic", "fantasy_star_chamber" },
            Characters: new[] { "char_elf_aria_neutral", "char_elf_aria_casting", "char_elf_aria_smile" },
            Audio: new[] { "bgm_fantasy_mystic", "sfx_magic_chime", "sfx_spell_cast" }),
        [GameStyle.SCIENCE] = new AssetTemplate(
            Backgrounds: new[] { "sci_station_hub", "sci_station_lab", "sci_station_viewport", "sci_holographic_display" },
            Characters: new[] { "char_nexus_hologram_blue", "char_nexus_hologram_green", "char_nexus_hologram_amber" },
            Audio: new[] { "bgm_science_ambient", "sfx_ui_beep", "sfx_data_process" }),
    };

    private static AssetRef[] GenerateAssets(GameStyle style)
    {
        if (!AssetTemplates.TryGetValue(style, out var template))
            return Array.Empty<AssetRef>();

        var assets = new List<AssetRef>();
        var index = 0;
        var stylePath = style.ToString().ToLowerInvariant();

        foreach (var background in template.Backgrounds.Take(3))
        {
            assets.Add(new AssetRef(
                $"asset-{++index:D3}",
                AssetType.BACKGROUND,
                $"assets/{stylePath}/bg/{background}.webp"));
        }

        foreach (var character in template.Characters.Take(3))
        {
            assets.Add(new AssetRef(
                $"asset-{++index:D3}",
                AssetType.CHARACTER,
                $"assets/{stylePath}/char/{character}.webp"));
        }

        foreach (var audio in template.Audio)
        {
            assets.Add(new AssetRef(
                $"asset-{++index:D3}",
                AssetType.AUDIO,
                $"assets/{stylePath}/audio/{audio}.ogg"));
        }

        return assets.ToArray();
    }

    // ========================================================================
    // 辅助方法
    // ========================================================================

    private static string GetPlanTopic(PlanGraph plan)
    {
        var nodes = plan.Nodes ?? Array.Empty<PlanNode>();
        if (nodes.Length == 0) return "知识复习";
        var first = nodes[0];
        return first.Tags is { Length: > 0 } tags ? string.Join("·", tags) : first.Title;
    }

    private static string GetQuestionStem(PlanNode node, Difficulty difficulty) => difficulty switch
    {
        Difficulty.BASIC => $"关于「{node.Title}」，以下哪个说法是正确的？",
        Difficulty.STANDARD => $"根据所学内容，关于「{node.Title}」最准确的描述是？",
        Difficulty.ADVANCED => $"在深入理解「{node.Title}」的基础上，以下哪个选项最符合实际？",
        _ => $"关于「{node.Title}」，哪个说法正确？",
    };

    private static string GetQuestionIntroForPlan(StyleTemplate template, string planType)
    {
        if (string.Equals(planType, "LEARNING", StringComparison.OrdinalIgnoreCase))
            return "学习内容讲解完毕，让我们通过这道题验收一下学习效果：";
        return template.QuestionIntro;
    }

    /// <summary>确定性 UUID v4 形状：相同 pointId + seed → 相同 questionId。</summary>
    private static Guid DeterministicGuid(Guid pointId, long seed)
    {
        // 对稳定输入取摘要，再显式设置 RFC 4122 version/variant 位。
        Span<byte> buffer = stackalloc byte[16 + 16 + 8]; // Guid(16) + Guid(16) + long(8)
        QuestionNamespace.TryWriteBytes(buffer[..16]);
        pointId.TryWriteBytes(buffer.Slice(16, 16));
        BitConverter.TryWriteBytes(buffer.Slice(32, 8), seed);

        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(buffer, hash);
        return UuidV4FromDigest(hash);
    }

    /// <summary>为导航 choice 生成确定性 questionId（非计分场景的"继续"按钮）</summary>
    private static Guid NavigationGuid(string sceneId)
    {
        var nameBytes = Encoding.UTF8.GetBytes("nav:" + sceneId);
        var namespaceBytes = QuestionNamespace.ToByteArray();

        var combined = new byte[namespaceBytes.Length + nameBytes.Length];
        Buffer.BlockCopy(namespaceBytes, 0, combined, 0, namespaceBytes.Length);
        Buffer.BlockCopy(nameBytes, 0, combined, namespaceBytes.Length, nameBytes.Length);

        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(combined, hash);
        return UuidV4FromDigest(hash);
    }

    private static Guid UuidV4FromDigest(ReadOnlySpan<byte> digest)
    {
        Span<byte> bytes = stackalloc byte[16];
        digest[..16].CopyTo(bytes);
        bytes[6] = (byte)((bytes[6] & 0x0F) | 0x40);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);

        // ParseExact 使用规范字符串字节序，避免 Guid(byte[]) 的混合端序破坏版本位。
        return Guid.ParseExact(Convert.ToHexString(bytes), "N");
    }

    /// <summary>确定性打乱（基于 questionId 种子，Fisher-Yates）</summary>
    private static IEnumerable<Choice> DeterministicShuffle(List<Choice> choices, Guid seed)
    {
        var seedBytes = seed.ToByteArray();
        var seedInt = BitConverter.ToInt32(seedBytes, 0);
        var rng = new Random(seedInt);
        var arr = choices.ToArray();
        for (var i = arr.Length - 1; i > 0; i--)
        {
            var j = rng.Next(i + 1);
            (arr[i], arr[j]) = (arr[j], arr[i]);
        }
        return arr;
    }

    // ========================================================================
    // 内部类型
    // ========================================================================

    private sealed record StyleTemplate(
        string GuideSpeaker,
        string EntrySceneTitle,
        string EntryDialogue,
        string EntryEmotion,
        string QuestionIntro,
        string EndingSceneTitle,
        string EndingDialogue);

    private sealed record AssetTemplate(
        string[] Backgrounds,
        string[] Characters,
        string[] Audio);

    private sealed record QuestionSpec(PlanNode Node, Guid QuestionId);
}
