using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using PracticeService.Application;
using PracticeService.Domain;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PracticeService.Persistence;

public sealed class ReciteQuestionGenerator(
    IHttpClientFactory clients,
    IConfiguration configuration,
    ILogger<ReciteQuestionGenerator> logger) : IPracticeQuestionGenerator
{
    private const int MaximumQuestions = 1000;
    private const int ChunkCharacters = 1400;
    private static readonly PracticeQuestionKind[] ClassicKinds =
    [
        PracticeQuestionKind.SingleChoice,
        PracticeQuestionKind.FillBlank,
        PracticeQuestionKind.TermDefinition,
        PracticeQuestionKind.Essay
    ];
    private static readonly Regex ExplicitAnswer = new(
        @"(?ms)^\s*(?<number>\d{1,3})[\.、]\s*(?<body>.*?)[ \t]*【参考答案】[ \t]*(?<answer>.*?)(?=^\s*\d{1,3}[\.、]\s|^\s*[一二三四五六七八九十]+、|\z)",
        RegexOptions.Compiled);
    private static readonly Regex NumberedAnswer = new(
        @"(?ms)^\s*(?<number>\d{1,3})[\.、]\s*(?<lead>[^\r\n：:]{2,120})[：:]\s*(?<answer>.*?)(?=^\s*\d{1,3}[\.、]\s|^\s*[一二三四五六七八九十]+、|\z)",
        RegexOptions.Compiled);
    private static readonly Regex SectionHeading = new(
        @"(?m)^\s*(?:[一二三四五六七八九十]+、\s*)?(?<title>名词解释|填空题|选择题|单项选择题|简答题|论述题|综合题|大题|重要知识点|还有重要的知识点)\s*(?<meta>[^\r\n]*)$",
        RegexOptions.Compiled);
    private static readonly Regex OptionLine = new(
        @"(?m)^\s*(?<id>[A-HＡ-Ｈ])[\.、．]\s*(?<text>.+?)\s*$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex PageNoise = new(
        @"(?m)^.*(?:版权所有不得复制|2019.*复习资料|复习资料).*$",
        RegexOptions.Compiled);
    private readonly JsonSerializerOptions _json = new(JsonSerializerDefaults.Web);

    private string? ApiKey => configuration["QuestionGeneration:ApiKey"];
    private string Endpoint => configuration["QuestionGeneration:Endpoint"] ?? "https://api.deepseek.com/chat/completions";
    private string Model => configuration["QuestionGeneration:Model"] ?? "deepseek-v4-flash";
    private int Parallelism => Math.Clamp(configuration.GetValue("QuestionGeneration:Parallelism", 4), 1, 8);

    public QuestionGenerationEstimate Estimate(QuestionGenerationInput input)
    {
        Validate(input);
        var extraction = ExtractGroundedQuestions(input);
        var target = ResolveTargetCount(input, extraction.Drafts.Count);
        if (extraction.IsStructured || extraction.Drafts.Count >= target)
            return new(target, 1, extraction.IsStructured ? "SOURCE_EXTRACTION" : "HYBRID_EXTRACTION");

        var sourceCharacters = input.Materials.Sum(material => (long)material.Text.Length);
        var maximumTokens = checked(Math.Max(1L, sourceCharacters + target * 1400L));
        return new(target, maximumTokens, extraction.Drafts.Count == 0 ? "GROUNDED_GENERATION" : "HYBRID_GENERATION");
    }

    public async Task<QuestionGenerationOutput> GenerateAsync(QuestionGenerationInput input, CancellationToken cancellationToken)
    {
        Validate(input);
        var extraction = ExtractGroundedQuestions(input);
        var target = ResolveTargetCount(input, extraction.Drafts.Count);
        var drafts = extraction.Drafts.Take(target).ToList();
        var diagnostics = extraction.Diagnostics.ToList();

        if (extraction.IsStructured || drafts.Count >= target)
            return new(drafts, diagnostics, 1, extraction.IsStructured ? "SOURCE_EXTRACTION" : "HYBRID_EXTRACTION");

        if (string.IsNullOrWhiteSpace(ApiKey))
        {
            diagnostics.Add(new(null, "QUESTION_MODEL_NOT_CONFIGURED",
                "资料中没有足够的可直接核对题目；QuestionGeneration:ApiKey 未配置，未使用模板猜测题目。", false));
            return new(drafts, diagnostics, 1, drafts.Count == 0 ? "MODEL_REQUIRED" : "HYBRID_EXTRACTION");
        }

        var remaining = target - drafts.Count;
        var chunks = BuildChunks(input.Materials, input.Points)
            .Where(chunk => chunk.Points.Count > 0)
            .Take((int)Math.Ceiling(remaining / 8d) + 2)
            .ToArray();
        if (chunks.Length == 0)
        {
            diagnostics.Add(new(null, "KNOWLEDGE_POINT_SOURCE_NOT_FOUND",
                "没有找到同时含资料证据与本册知识点的正文分片，未猜测贴签。", false));
            return new(drafts, diagnostics, 1, drafts.Count == 0 ? "MODEL_REQUIRED" : "HYBRID_EXTRACTION");
        }

        var outputs = new GeneratedChunk?[chunks.Length];
        await Parallel.ForEachAsync(Enumerable.Range(0, chunks.Length), new ParallelOptions
        {
            MaxDegreeOfParallelism = Parallelism,
            CancellationToken = cancellationToken
        }, async (index, ct) =>
        {
            try { outputs[index] = await GenerateChunkAsync(chunks[index], input, ct); }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                logger.LogWarning(error, "Question generation chunk failed for material {MaterialId} at {Offset}.", chunks[index].Material.MaterialId, chunks[index].StartOffset);
                outputs[index] = new([], [new(chunks[index].Material.MaterialId, "QUESTION_GENERATION_CHUNK_FAILED", error.Message, true)], 0);
            }
        });

        long actualTokens = 0;
        var seenPrompts = drafts.Select(draft => Normalize(draft.Prompt)).ToHashSet(StringComparer.Ordinal);
        foreach (var output in outputs.Where(output => output is not null).Cast<GeneratedChunk>())
        {
            actualTokens += output.TokenUnits;
            diagnostics.AddRange(output.Diagnostics);
            foreach (var draft in output.Drafts)
            {
                if (drafts.Count >= target) break;
                if (seenPrompts.Add(Normalize(draft.Prompt))) drafts.Add(draft);
            }
        }
        if (drafts.Count == 0)
            diagnostics.Add(new(null, "NO_VERIFIED_QUESTIONS", "没有题目通过来源、答案、题型和知识点的全部校验门禁。", false));
        return new(drafts, diagnostics, Math.Max(1, actualTokens), extraction.Drafts.Count == 0 ? "GROUNDED_GENERATION" : "HYBRID_GENERATION");
    }

    private static void Validate(QuestionGenerationInput input)
    {
        if (!string.Equals(input.GeneratorVersion, "recite-question-v2", StringComparison.Ordinal))
            throw new PracticeDomainException(400, "GENERATOR_VERSION_UNSUPPORTED", "generatorVersion 当前只支持 recite-question-v2。");
        if (input.Materials.Count == 0) throw new PracticeDomainException(422, "PROJECT_MATERIALS_REQUIRED", "研习册至少需要一份资料。");
        if (input.Points.Count == 0) throw new PracticeDomainException(422, "PLAN_TARGETS_EMPTY", "整册知识点快照为空，无法为题目标记知识点。");
        if (input.RequestedTargetCount is < 1 or > MaximumQuestions)
            throw new PracticeDomainException(400, "VALIDATION_ERROR", $"targetCount 必须在 1-{MaximumQuestions} 范围内，或省略以自动建库。");
        var unsupported = input.Kinds.Except(ClassicKinds).ToArray();
        if (unsupported.Length > 0)
            throw new PracticeDomainException(400, "QUESTION_KIND_UNSUPPORTED", "自动建库仅支持单选、填空、名词解释和简答/论述；判断题仍可手工录入或导入。", new { kinds = unsupported });
    }

    private static int ResolveTargetCount(QuestionGenerationInput input, int extractedCount)
    {
        if (input.RequestedTargetCount is int requested) return requested;
        if (extractedCount > 0) return Math.Min(MaximumQuestions, extractedCount);
        var estimatedAtoms = input.Materials.Sum(material => Math.Max(1, (int)Math.Ceiling(material.Text.Length / (double)ChunkCharacters)) * 8);
        return Math.Clamp(estimatedAtoms, 1, MaximumQuestions);
    }

    private static ExtractionBatch ExtractGroundedQuestions(QuestionGenerationInput input)
    {
        var kinds = (input.Kinds.Count == 0 ? ClassicKinds : input.Kinds).ToHashSet();
        var drafts = new List<QuestionDraft>();
        var diagnostics = new List<PracticeJobDiagnostic>();
        var explicitMatches = 0;
        foreach (var material in input.Materials)
        {
            var occupied = new List<(int Start, int End)>();
            foreach (Match match in ExplicitAnswer.Matches(material.Text))
            {
                var parsed = ParseSourceItem(material, match, true, input.Points, diagnostics);
                occupied.Add((match.Index, match.Index + match.Length));
                explicitMatches++;
                if (parsed is not null && kinds.Contains(parsed.Kind)) drafts.Add(parsed);
            }
            foreach (Match match in NumberedAnswer.Matches(material.Text))
            {
                if (occupied.Any(range => match.Index < range.End && match.Index + match.Length > range.Start)) continue;
                var section = FindSection(material.Text, match.Index);
                if (section is null || section.Value.Title is not ("名词解释" or "大题" or "简答题" or "论述题" or "综合题")) continue;
                var parsed = ParseSourceItem(material, match, false, input.Points, diagnostics);
                if (parsed is not null && kinds.Contains(parsed.Kind)) drafts.Add(parsed);
            }
        }
        var unique = drafts
            .GroupBy(draft => $"{draft.SourceReferences[0].MaterialId:D}:{Normalize(draft.Prompt)}", StringComparer.Ordinal)
            .Select(group => group.First())
            .OrderBy(draft => draft.SourceReferences[0].MaterialId)
            .ThenBy(draft => draft.SourceReferences[0].StartOffset)
            .ToArray();
        return new(unique, diagnostics, explicitMatches >= 3);
    }

    private static QuestionDraft? ParseSourceItem(MaterialText material, Match match, bool explicitAnswer,
        IReadOnlyList<PlanGraphPoint> points, List<PracticeJobDiagnostic> diagnostics)
    {
        var body = explicitAnswer ? match.Groups["body"].Value : match.Groups["lead"].Value;
        var answer = CleanAnswer(match.Groups["answer"].Value);
        var options = OptionLine.Matches(body).Select(option => new QuestionOption(
            NormalizeOptionId(option.Groups["id"].Value), option.Groups["text"].Value.Trim())).ToArray();
        var prompt = OptionLine.Replace(body, string.Empty).Trim();
        prompt = Regex.Replace(prompt, @"^\s*\(?\d+\s*分\)?\s*", string.Empty).Trim();
        if (prompt.Length < 2 || answer.Length < 1) return null;

        var section = FindSection(material.Text, match.Index);
        var kind = InferKind(section?.Title, prompt, options.Length);
        IReadOnlyList<string> correctAnswers;
        if (kind == PracticeQuestionKind.SingleChoice)
        {
            var optionId = Regex.Match(answer, @"(?i)(?<![A-Z])[A-H](?![A-Z])").Value.ToUpperInvariant();
            if (options.Length < 2 || optionId.Length == 0 || !options.Any(option => option.Id == optionId))
            {
                diagnostics.Add(new(material.MaterialId, "SOURCE_CHOICE_ANSWER_AMBIGUOUS", $"原题“{TrimForDiagnostic(prompt)}”的选项或答案无法唯一核对，保留为草稿。", false));
                kind = PracticeQuestionKind.Essay;
                options = [];
                correctAnswers = [answer];
            }
            else correctAnswers = [optionId];
        }
        else correctAnswers = [answer];

        var excerpt = material.Text.Substring(match.Index, match.Length);
        var binding = BindPoint(prompt, answer, excerpt, points);
        var ready = binding.PointId.HasValue && !(kind == PracticeQuestionKind.SingleChoice && options.Length < 2);
        if (!binding.PointId.HasValue)
            diagnostics.Add(new(material.MaterialId, binding.Ambiguous ? "KNOWLEDGE_POINT_BINDING_AMBIGUOUS" : "KNOWLEDGE_POINT_SOURCE_NOT_FOUND",
                $"原题“{TrimForDiagnostic(prompt)}”未能唯一绑定本册知识点，已保留为待核对草稿。", false));
        var source = new SourceReference(material.MaterialId, match.Index, match.Index + match.Length,
            material.SourceMapVersion, PracticeRules.Sha256(excerpt));
        return new(kind, EnsureQuestionPrompt(prompt, kind), options, correctAnswers,
            explicitAnswer ? "题目与答案按资料原文提取。" : "题目与答案按资料中的可核对问答结构提取。",
            ParseScore(section?.Meta, match.Value, kind), InferDifficulty(kind), binding.PointId, [source], ready ? QuestionStatus.Ready : QuestionStatus.Draft);
    }

    private async Task<GeneratedChunk> GenerateChunkAsync(SourceChunk chunk, QuestionGenerationInput input, CancellationToken cancellationToken)
    {
        var allowedKinds = (input.Kinds.Count == 0 ? ClassicKinds : input.Kinds).Select(kind => kind.ToString()).ToArray();
        var points = chunk.Points.Select(point => new { pointId = point.KnowledgePointId, point.Title, point.Summary, point.Tags }).ToArray();
        var system = "你是农学、社会科学与人文类复习资料的题库编辑。只处理事实、概念、关系、比较、步骤和论述，不生成计算题、公式推导或复杂理工题。先从原文识别可独立作答的答案原子，再据此写题。不得补充原文没有的信息。输出严格 JSON。";
        var user = JsonSerializer.Serialize(new
        {
            task = "从 evidence 中生成至多 8 道互不重复的复习题",
            rules = new[]
            {
                "每题必须绑定 suppliedPoints 中唯一 pointId",
                "sourceQuote 必须逐字复制 evidence 中能完整支持标准答案的最短连续原文",
                "correctAnswers 必须逐字出现在 sourceQuote 中；简答题可把多个原文要点作为多个数组元素",
                "填空题必须有 ____ 且答案为不超过 40 字的明确短语",
                "名词解释只用于原文存在术语与定义关系时",
                "单选题必须恰有 A-D 四项，只有正确项文本可由 sourceQuote 支持；无法构造可靠干扰项就不要出单选",
                "题干不得包含答案，不得使用请概括下述内容之类把答案原句塞进题干的模板",
                "不要为凑题数重复同一知识原子"
            },
            allowedKinds,
            suppliedPoints = points,
            evidence = chunk.Text,
            output = new
            {
                questions = new[] { new { kind = "FillBlank|TermDefinition|Essay|SingleChoice", prompt = "", options = new[] { new { id = "A", text = "" } }, correctAnswers = new[] { "" }, explanation = "", score = 2, difficulty = 2, knowledgePointId = Guid.Empty, sourceQuote = "" } }
            }
        }, _json);
        var generated = await CompleteJsonAsync(system, user, cancellationToken);
        var candidates = ParseModelCandidates(generated.Content, chunk, input);
        var diagnostics = new List<PracticeJobDiagnostic>();
        if (candidates.Count == 0)
        {
            diagnostics.Add(new(chunk.Material.MaterialId, "NO_VERIFIED_QUESTIONS_IN_CHUNK",
                $"资料区间 {chunk.StartOffset}-{chunk.StartOffset + chunk.Text.Length} 没有题目通过确定性校验。", false));
            return new([], diagnostics, generated.TokenUnits);
        }

        var verifierUser = JsonSerializer.Serialize(new
        {
            task = "独立复核候选题。只能依据 evidence 作答；仅接受标准答案可由 evidence 完整推出、题干清晰且 pointId 语义一致的题。",
            evidence = chunk.Text,
            suppliedPoints = points,
            candidates = candidates.Select((candidate, index) => new { index, candidate.Draft.Kind, candidate.Draft.Prompt, candidate.Draft.Options, candidate.Draft.CorrectAnswers, candidate.PointId, candidate.SourceQuote }),
            output = new { acceptedIndices = new[] { 0 }, rejected = new[] { new { index = 1, reason = "" } } }
        }, _json);
        var verified = await CompleteJsonAsync("你是独立题目核验器。不得利用 evidence 之外的常识放宽答案。输出严格 JSON。", verifierUser, cancellationToken);
        var accepted = ParseAcceptedIndices(verified.Content, candidates.Count);
        var result = candidates.Where((_, index) => accepted.Contains(index)).Select(candidate => candidate.Draft).ToArray();
        if (result.Length < candidates.Count)
            diagnostics.Add(new(chunk.Material.MaterialId, "QUESTION_ROUND_TRIP_REJECTED",
                $"独立核验拒绝了 {candidates.Count - result.Length} 道不能从同一证据稳定还原答案的候选题。", false));
        return new(result, diagnostics, checked(generated.TokenUnits + verified.TokenUnits));
    }

    private async Task<ModelCompletion> CompleteJsonAsync(string system, string user, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ApiKey);
        request.Content = JsonContent.Create(new
        {
            model = Model,
            messages = new[] { new { role = "system", content = system }, new { role = "user", content = user } },
            response_format = new { type = "json_object" },
            temperature = 0.1,
            max_tokens = 6000
        }, options: _json);
        using var response = await clients.CreateClient("question-generation").SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw new PracticeDomainException((int)response.StatusCode, "QUESTION_MODEL_FAILED", $"题目模型调用失败：HTTP {(int)response.StatusCode}。");
        using var document = JsonDocument.Parse(body);
        var content = document.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString() ?? "{}";
        var tokens = document.RootElement.TryGetProperty("usage", out var usage) && usage.TryGetProperty("total_tokens", out var total)
            ? total.GetInt64()
            : throw new PracticeDomainException(502, "QUESTION_MODEL_USAGE_MISSING", "题目模型未返回 usage.total_tokens，无法按实际消耗结算 credits。");
        return new(content, tokens);
    }

    private static IReadOnlyList<ModelCandidate> ParseModelCandidates(string json, SourceChunk chunk, QuestionGenerationInput input)
    {
        var candidates = new List<ModelCandidate>();
        using var document = JsonDocument.Parse(ExtractJsonObject(json));
        if (!document.RootElement.TryGetProperty("questions", out var questions) || questions.ValueKind != JsonValueKind.Array) return candidates;
        var allowedKinds = (input.Kinds.Count == 0 ? ClassicKinds : input.Kinds).ToHashSet();
        var pointIds = chunk.Points.Select(point => point.KnowledgePointId).ToHashSet();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in questions.EnumerateArray())
        {
            try
            {
                if (!Enum.TryParse<PracticeQuestionKind>(item.GetProperty("kind").GetString(), true, out var kind) || !allowedKinds.Contains(kind)) continue;
                var prompt = item.GetProperty("prompt").GetString()?.Trim() ?? string.Empty;
                var quote = item.GetProperty("sourceQuote").GetString()?.Trim() ?? string.Empty;
                if (prompt.Length < 2 || quote.Length < 2 || Normalize(prompt) == Normalize(quote) || !seen.Add(Normalize(prompt))) continue;
                var relativeOffset = chunk.Text.IndexOf(quote, StringComparison.Ordinal);
                if (relativeOffset < 0) continue;
                var pointId = item.GetProperty("knowledgePointId").GetGuid();
                if (!pointIds.Contains(pointId)) continue;
                var answers = item.GetProperty("correctAnswers").EnumerateArray().Select(answer => answer.GetString()?.Trim() ?? string.Empty).Where(answer => answer.Length > 0).ToArray();
                if (answers.Length == 0 || answers.Any(answer => !Normalize(quote).Contains(Normalize(answer), StringComparison.Ordinal))) continue;
                var options = item.TryGetProperty("options", out var rawOptions) && rawOptions.ValueKind == JsonValueKind.Array
                    ? rawOptions.EnumerateArray().Select(option => new QuestionOption(option.GetProperty("id").GetString() ?? string.Empty, option.GetProperty("text").GetString() ?? string.Empty)).ToArray()
                    : [];
                if (!ValidateGeneratedShape(kind, prompt, quote, options, answers)) continue;
                var source = new SourceReference(chunk.Material.MaterialId, chunk.StartOffset + relativeOffset,
                    chunk.StartOffset + relativeOffset + quote.Length, chunk.Material.SourceMapVersion, PracticeRules.Sha256(quote));
                var score = item.TryGetProperty("score", out var rawScore) && rawScore.TryGetDecimal(out var parsedScore) ? Math.Clamp(parsedScore, 1, 20) : DefaultScore(kind);
                var difficulty = item.TryGetProperty("difficulty", out var rawDifficulty) && rawDifficulty.TryGetInt32(out var parsedDifficulty) ? Math.Clamp(parsedDifficulty, 1, 5) : InferDifficulty(kind);
                var explanation = item.TryGetProperty("explanation", out var rawExplanation) ? rawExplanation.GetString() : null;
                var draft = new QuestionDraft(kind, prompt, options, answers, explanation, score, difficulty, pointId, [source], QuestionStatus.Ready);
                PracticeRules.ValidateAnswerShape(kind, options, answers);
                candidates.Add(new(draft, pointId, quote));
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                _ = error;
            }
        }
        return candidates;
    }

    private static bool ValidateGeneratedShape(PracticeQuestionKind kind, string prompt, string quote,
        IReadOnlyList<QuestionOption> options, IReadOnlyList<string> answers)
    {
        if (Normalize(prompt).Contains(Normalize(answers[0]), StringComparison.Ordinal)) return false;
        if (kind == PracticeQuestionKind.FillBlank) return prompt.Contains("____", StringComparison.Ordinal) && answers.All(answer => answer.Length <= 40) && options.Count == 0;
        if (kind == PracticeQuestionKind.TermDefinition) return options.Count == 0 && !Normalize(prompt).Contains(Normalize(quote), StringComparison.Ordinal);
        if (kind == PracticeQuestionKind.Essay) return options.Count == 0 && !Normalize(prompt).Contains(Normalize(quote), StringComparison.Ordinal);
        if (kind != PracticeQuestionKind.SingleChoice || options.Count != 4 || answers.Count != 1) return false;
        var answerOption = options.SingleOrDefault(option => string.Equals(option.Id, answers[0], StringComparison.OrdinalIgnoreCase));
        if (answerOption is null || !Normalize(quote).Contains(Normalize(answerOption.Text), StringComparison.Ordinal)) return false;
        return options.Where(option => !string.Equals(option.Id, answerOption.Id, StringComparison.OrdinalIgnoreCase))
            .All(option => !Normalize(quote).Contains(Normalize(option.Text), StringComparison.Ordinal));
    }

    private static IReadOnlySet<int> ParseAcceptedIndices(string json, int count)
    {
        using var document = JsonDocument.Parse(ExtractJsonObject(json));
        if (!document.RootElement.TryGetProperty("acceptedIndices", out var accepted) || accepted.ValueKind != JsonValueKind.Array) return new HashSet<int>();
        return accepted.EnumerateArray().Where(value => value.TryGetInt32(out _)).Select(value => value.GetInt32()).Where(index => index >= 0 && index < count).ToHashSet();
    }

    private static IEnumerable<SourceChunk> BuildChunks(IReadOnlyList<MaterialText> materials, IReadOnlyList<PlanGraphPoint> points)
    {
        foreach (var material in materials)
        {
            var paragraphs = Regex.Matches(material.Text, @"(?ms)(?:^|\n)\s*\S.*?(?=\n\s*\n|\z)")
                .Cast<Match>().Where(match => match.Value.Trim().Length >= 40).ToArray();
            var position = 0;
            while (position < paragraphs.Length)
            {
                var start = paragraphs[position].Index;
                var end = paragraphs[position].Index + paragraphs[position].Length;
                while (position + 1 < paragraphs.Length && paragraphs[position + 1].Index + paragraphs[position + 1].Length - start <= ChunkCharacters)
                {
                    position++;
                    end = paragraphs[position].Index + paragraphs[position].Length;
                }
                var text = material.Text[start..end].Trim();
                var actualStart = material.Text.IndexOf(text, start, StringComparison.Ordinal);
                var candidates = BindCandidatePoints(text, points);
                yield return new(material, actualStart, text, candidates);
                position++;
            }
        }
    }

    private static IReadOnlyList<PlanGraphPoint> BindCandidatePoints(string text, IReadOnlyList<PlanGraphPoint> points)
    {
        var normalized = Normalize(text);
        var matched = points.Where(point =>
                Normalize(point.Title).Length >= 2 && normalized.Contains(Normalize(point.Title), StringComparison.Ordinal)
                || point.Tags.Any(tag => Normalize(tag).Length >= 3 && normalized.Contains(Normalize(tag), StringComparison.Ordinal)))
            .Take(24).ToArray();
        return matched;
    }

    private static BindingResult BindPoint(string prompt, string answer, string excerpt, IReadOnlyList<PlanGraphPoint> points)
    {
        var normalizedPrompt = Normalize(prompt);
        var normalizedEvidence = Normalize(prompt + answer + excerpt);
        var titleMatches = points.Where(point =>
                Normalize(point.Title).Length >= 2
                && (normalizedPrompt.Contains(Normalize(point.Title), StringComparison.Ordinal)
                    || normalizedEvidence.Contains(Normalize(point.Title), StringComparison.Ordinal)))
            .Select(point => new { Point = point, Length = Normalize(point.Title).Length })
            .OrderByDescending(item => item.Length).ToArray();
        if (titleMatches.Length > 0)
        {
            var longest = titleMatches[0].Length;
            var winners = titleMatches.Where(item => item.Length == longest).Select(item => item.Point).ToArray();
            return winners.Length == 1 ? new(winners[0].KnowledgePointId, false) : new(null, true);
        }
        var tagMatches = points.Where(point => point.Tags.Any(tag => Normalize(tag).Length >= 3 && normalizedEvidence.Contains(Normalize(tag), StringComparison.Ordinal))).ToArray();
        return tagMatches.Length == 1 ? new(tagMatches[0].KnowledgePointId, false) : new(null, tagMatches.Length > 1);
    }

    private static (string Title, string Meta)? FindSection(string text, int offset)
    {
        var sections = SectionHeading.Matches(text[..Math.Clamp(offset, 0, text.Length)]);
        if (sections.Count == 0) return null;
        var match = sections[^1];
        return (match.Groups["title"].Value.Trim(), match.Groups["meta"].Value.Trim());
    }

    private static PracticeQuestionKind InferKind(string? section, string prompt, int optionCount)
    {
        if (optionCount >= 2 || section is "选择题" or "单项选择题") return PracticeQuestionKind.SingleChoice;
        if (section == "填空题" || prompt.Contains("____", StringComparison.Ordinal) || prompt.Contains("（ ）", StringComparison.Ordinal)) return PracticeQuestionKind.FillBlank;
        if (section == "名词解释") return PracticeQuestionKind.TermDefinition;
        return PracticeQuestionKind.Essay;
    }

    private static string EnsureQuestionPrompt(string prompt, PracticeQuestionKind kind)
    {
        prompt = Regex.Replace(prompt.Trim(), @"^[\d\s\.、]+", string.Empty).Trim();
        if (kind == PracticeQuestionKind.TermDefinition)
        {
            var term = prompt.TrimEnd('。', '？', '?', '：', ':');
            return term.StartsWith("解释", StringComparison.Ordinal) || term.StartsWith("什么是", StringComparison.Ordinal)
                ? term + "。"
                : $"请解释“{term}”。";
        }
        if (prompt.EndsWith('？') || prompt.EndsWith('?') || prompt.EndsWith('。')) return prompt;
        return prompt + "。";
    }

    private static string CleanAnswer(string value)
    {
        var answer = PageNoise.Replace(value, string.Empty);
        answer = Regex.Replace(answer, @"(?ms)\s*评分标准.*$", string.Empty);
        answer = Regex.Replace(answer, @"[ \t]+", " ");
        answer = Regex.Replace(answer, @"\s*\r?\n\s*", "\n");
        return answer.Trim();
    }

    private static decimal ParseScore(string? sectionMeta, string raw, PracticeQuestionKind kind)
    {
        var value = $"{sectionMeta} {raw[..Math.Min(raw.Length, 80)]}";
        var match = Regex.Match(value, @"(?<score>\d{1,2})\s*分");
        return match.Success && decimal.TryParse(match.Groups["score"].Value, out var score) && score is > 0 and <= 20
            ? score : DefaultScore(kind);
    }

    private static decimal DefaultScore(PracticeQuestionKind kind) => kind switch
    {
        PracticeQuestionKind.SingleChoice => 3,
        PracticeQuestionKind.FillBlank => 2,
        PracticeQuestionKind.TermDefinition => 4,
        _ => 5
    };

    private static int InferDifficulty(PracticeQuestionKind kind) => kind switch
    {
        PracticeQuestionKind.FillBlank => 2,
        PracticeQuestionKind.SingleChoice => 2,
        _ => 3
    };

    private static string Normalize(string value) => new(value.Normalize(NormalizationForm.FormC)
        .Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
    private static string NormalizeOptionId(string value)
    {
        var character = value.Trim().ToUpperInvariant()[0];
        if (character is >= 'Ａ' and <= 'Ｈ') character = (char)('A' + character - 'Ａ');
        return character.ToString();
    }
    private static string TrimForDiagnostic(string value) => value.Length <= 32 ? value : value[..32] + "…";
    private static string ExtractJsonObject(string value)
    {
        var start = value.IndexOf('{');
        var end = value.LastIndexOf('}');
        return start >= 0 && end > start ? value[start..(end + 1)] : "{}";
    }

    private sealed record ExtractionBatch(IReadOnlyList<QuestionDraft> Drafts, IReadOnlyList<PracticeJobDiagnostic> Diagnostics, bool IsStructured);
    private sealed record SourceChunk(MaterialText Material, int StartOffset, string Text, IReadOnlyList<PlanGraphPoint> Points);
    private sealed record BindingResult(Guid? PointId, bool Ambiguous);
    private sealed record ModelCompletion(string Content, long TokenUnits);
    private sealed record ModelCandidate(QuestionDraft Draft, Guid PointId, string SourceQuote);
    private sealed record GeneratedChunk(IReadOnlyList<QuestionDraft> Drafts, IReadOnlyList<PracticeJobDiagnostic> Diagnostics, long TokenUnits);
}
