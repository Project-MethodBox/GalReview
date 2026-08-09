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
    private static readonly Regex ReferenceAnswerMarker = new(@"【参考答案】", RegexOptions.Compiled);
    private static readonly Regex NumberedItemMarker = new(
        @"(?<![\p{L}\p{N}])(?<number>\d{1,3})[\.、．]\s*",
        RegexOptions.Compiled);
    private static readonly Regex SectionHeading = new(
        @"(?<title>名词解释|填空题|选择题|单项选择题|简答题|论述题|综合题|大题|重要知识点|还有重要的知识点|结课思考题)",
        RegexOptions.Compiled);
    private static readonly Regex StructuralBoundary = new(
        @"(?:第[一二三四五六七八九十百\d]+章\s*[^\r\n]{0,80}|[一二三四五六七八九十]+、\s*(?:名词解释|填空题|选择题|单项选择题|简答题|论述题|综合题|大题|重要知识点|还有重要的知识点))",
        RegexOptions.Compiled);
    private static readonly Regex OptionMarker = new(
        @"(?<![A-Za-z0-9])(?<id>[A-DＡ-Ｄ])[\.、．]\s*",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex PageNoise = new(
        @"(?:山东农业大学农学院农业生态学教学组版权所有不得复制！\s*\d{1,3}|2019级植科一班张旋波|农业生态学试题库\s*2021版)",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private readonly JsonSerializerOptions _json = new(JsonSerializerDefaults.Web);

    private string? ApiKey => configuration["QuestionGeneration:ApiKey"];
    private string Endpoint => configuration["QuestionGeneration:Endpoint"] ?? "https://api.deepseek.com/chat/completions";
    private string Model => configuration["QuestionGeneration:Model"] ?? "deepseek-v4-flash";
    private int Parallelism => Math.Clamp(configuration.GetValue("QuestionGeneration:Parallelism", 4), 1, 8);

    public QuestionGenerationEstimate Estimate(QuestionGenerationInput input)
    {
        Validate(input);
        var extraction = ExtractGroundedQuestions(input);
        var chunks = BuildChunks(input.Materials, input.Points).Count(chunk => chunk.Points.Count > 0 && !IsCoveredChunk(chunk, extraction.CoveredRanges));
        var target = ResolveTargetCount(input, extraction.Drafts.Count, chunks, extraction.IsExplicitQuestionBank);
        if (extraction.IsExplicitQuestionBank || extraction.Drafts.Count >= target)
            return new(target, 1, extraction.IsExplicitQuestionBank ? "SOURCE_EXTRACTION" : "HYBRID_EXTRACTION");

        var sourceCharacters = input.Materials.Sum(material => (long)material.Text.Length);
        var maximumTokens = checked(Math.Max(1L, sourceCharacters + target * 1400L));
        return new(target, maximumTokens, extraction.Drafts.Count == 0 ? "GROUNDED_GENERATION" : "HYBRID_GENERATION");
    }

    public async Task<QuestionGenerationOutput> GenerateAsync(QuestionGenerationInput input, CancellationToken cancellationToken)
    {
        Validate(input);
        var extraction = ExtractGroundedQuestions(input);
        var allChunks = BuildChunks(input.Materials, input.Points)
            .Where(chunk => chunk.Points.Count > 0 && !IsCoveredChunk(chunk, extraction.CoveredRanges))
            .ToArray();
        var target = ResolveTargetCount(input, extraction.Drafts.Count, allChunks.Length, extraction.IsExplicitQuestionBank);
        var drafts = extraction.Drafts.Take(target).ToList();
        var diagnostics = extraction.Diagnostics.ToList();

        if (extraction.IsExplicitQuestionBank || drafts.Count >= target)
            return new(drafts, diagnostics, 1, extraction.IsExplicitQuestionBank ? "SOURCE_EXTRACTION" : "HYBRID_EXTRACTION");

        if (string.IsNullOrWhiteSpace(ApiKey))
        {
            diagnostics.Add(new(null, "QUESTION_MODEL_NOT_CONFIGURED",
                "资料中没有足够的可直接核对题目；QuestionGeneration:ApiKey 未配置，未使用模板猜测题目。", false));
            return new(drafts, diagnostics, 1, drafts.Count == 0 ? "MODEL_REQUIRED" : "HYBRID_EXTRACTION");
        }

        var remaining = target - drafts.Count;
        var chunks = allChunks
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
            catch (Exception error) when (error is not OperationCanceledException and not PracticeDomainException)
            {
                logger.LogWarning(error, "Question generation chunk failed for material {MaterialId} at {Offset}.", chunks[index].Material.MaterialId, chunks[index].StartOffset);
                outputs[index] = new([], [new(chunks[index].Material.MaterialId, "QUESTION_GENERATION_CHUNK_FAILED", error.Message, true)], 0);
            }
        });

        long actualTokens = 0;
        var seenQuestions = drafts.Select(QuestionDedupKey).ToHashSet(StringComparer.Ordinal);
        foreach (var output in outputs.Where(output => output is not null).Cast<GeneratedChunk>())
        {
            actualTokens += output.TokenUnits;
            diagnostics.AddRange(output.Diagnostics);
            foreach (var draft in output.Drafts)
            {
                if (drafts.Count >= target) break;
                if (seenQuestions.Add(QuestionDedupKey(draft))) drafts.Add(draft);
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

    private static int ResolveTargetCount(QuestionGenerationInput input, int extractedCount, int groundedChunkCount, bool explicitQuestionBank)
    {
        if (input.RequestedTargetCount is int requested) return requested;
        if (explicitQuestionBank) return Math.Clamp(extractedCount, 1, MaximumQuestions);
        return Math.Clamp(extractedCount + groundedChunkCount * 8, 1, MaximumQuestions);
    }

    private static ExtractionBatch ExtractGroundedQuestions(QuestionGenerationInput input)
    {
        var kinds = (input.Kinds.Count == 0 ? ClassicKinds : input.Kinds).ToHashSet();
        var drafts = new List<QuestionDraft>();
        var diagnostics = new List<PracticeJobDiagnostic>();
        var coveredRanges = new List<GroundedRange>();
        var explicitItems = 0;
        foreach (var material in input.Materials)
        {
            var occupied = new List<(int Start, int End)>();
            var explicitSources = ExtractExplicitSourceItems(material.Text, diagnostics, material.MaterialId);
            explicitItems += explicitSources.Count;
            foreach (var sourceItem in explicitSources)
            {
                var parsed = ParseSourceItem(material, sourceItem, true, input.Points, diagnostics);
                occupied.Add((sourceItem.StartOffset, sourceItem.EndOffset));
                coveredRanges.Add(new(material.MaterialId, sourceItem.StartOffset, sourceItem.EndOffset));
                if (parsed is not null && kinds.Contains(parsed.Kind)) drafts.Add(parsed);
            }
            foreach (var sourceItem in ExtractSemiStructuredSourceItems(material.Text, occupied))
            {
                var parsed = ParseSourceItem(material, sourceItem, false, input.Points, diagnostics);
                coveredRanges.Add(new(material.MaterialId, sourceItem.StartOffset, sourceItem.EndOffset));
                if (parsed is not null && kinds.Contains(parsed.Kind)) drafts.Add(parsed);
            }
        }
        var unique = drafts
            .GroupBy(QuestionDedupKey, StringComparer.Ordinal)
            .Select(group => group.First())
            .OrderBy(draft => draft.SourceReferences[0].MaterialId)
            .ThenBy(draft => draft.SourceReferences[0].StartOffset)
            .ToArray();
        return new(unique, diagnostics, explicitItems >= 3, coveredRanges);
    }

    private static bool IsCoveredChunk(SourceChunk chunk, IReadOnlyList<GroundedRange> ranges)
    {
        if (chunk.Text.Length == 0) return true;
        var chunkEnd = chunk.StartOffset + chunk.Text.Length;
        var covered = ranges.Where(range => range.MaterialId == chunk.Material.MaterialId)
            .Sum(range => Math.Max(0, Math.Min(chunkEnd, range.EndOffset) - Math.Max(chunk.StartOffset, range.StartOffset)));
        return covered >= chunk.Text.Length * 0.75;
    }

    private static IReadOnlyList<SourceItem> ExtractExplicitSourceItems(
        string text,
        List<PracticeJobDiagnostic> diagnostics,
        Guid materialId)
    {
        var answerMarkers = ReferenceAnswerMarker.Matches(text).Cast<Match>().ToArray();
        if (answerMarkers.Length == 0) return [];
        var promptMarkers = new SourceMarker?[answerMarkers.Length];
        var previousAnswerMarkerEnd = 0;
        for (var index = 0; index < answerMarkers.Length; index++)
        {
            var answerMarker = answerMarkers[index];
            var candidates = NumberedItemMarker.Matches(text[previousAnswerMarkerEnd..answerMarker.Index]);
            if (candidates.Count > 0)
            {
                var candidate = candidates[^1];
                promptMarkers[index] = new(previousAnswerMarkerEnd + candidate.Index, candidate.Length);
            }
            else diagnostics.Add(new(materialId, "SOURCE_QUESTION_BOUNDARY_NOT_FOUND",
                $"资料中的第 {index + 1} 个参考答案标记之前没有可核对题号，已拒绝自动成题。", false));
            previousAnswerMarkerEnd = answerMarker.Index + answerMarker.Length;
        }

        var items = new List<SourceItem>();
        for (var index = 0; index < answerMarkers.Length; index++)
        {
            var promptMarker = promptMarkers[index];
            if (promptMarker is null) continue;
            var marker = answerMarkers[index];
            var structuralEnd = FindNextStructuralBoundary(text, marker.Index + marker.Length);
            var nextPromptEnd = index + 1 < promptMarkers.Length && promptMarkers[index + 1] is SourceMarker nextPrompt
                ? nextPrompt.Index
                : text.Length;
            var end = Math.Min(structuralEnd, nextPromptEnd);
            end = Math.Clamp(end, marker.Index + marker.Length, text.Length);
            var section = FindSection(text, promptMarker.Index);
            items.Add(new(promptMarker.Index, end,
                text[(promptMarker.Index + promptMarker.Length)..marker.Index],
                text[(marker.Index + marker.Length)..end], section?.Title, section?.Meta ?? string.Empty));
        }
        return items;
    }

    private static IReadOnlyList<SourceItem> ExtractSemiStructuredSourceItems(
        string text,
        IReadOnlyList<(int Start, int End)> occupied)
    {
        var sections = SectionHeading.Matches(text).Cast<Match>().ToArray();
        var items = new List<SourceItem>();
        foreach (var section in sections)
        {
            var title = section.Groups["title"].Value;
            var sectionStart = section.Index + section.Length;
            var nextSection = sections.FirstOrDefault(candidate => candidate.Index >= sectionStart);
            var boundary = StructuralBoundary.Match(text, sectionStart);
            var sectionEnd = new[]
                {
                    nextSection?.Index ?? text.Length,
                    boundary.Success ? boundary.Index : text.Length,
                    text.Length
                }
                .Min();
            if (sectionEnd <= sectionStart) continue;

            if (title == "结课思考题")
            {
                var raw = text[sectionStart..sectionEnd].TrimStart('：', ':', ' ', '\t');
                var answerStart = Regex.Match(raw, @"。(?=\s*\d{1,2}(?![\d\.]))");
                if (answerStart.Success)
                {
                    var absoluteStart = sectionStart + text[sectionStart..sectionEnd].IndexOf(raw, StringComparison.Ordinal);
                    var source = new SourceItem(absoluteStart, sectionEnd, raw[..(answerStart.Index + 1)],
                        raw[(answerStart.Index + 1)..], title, string.Empty);
                    if (!Overlaps(source.StartOffset, source.EndOffset, occupied)) items.Add(source);
                }
                continue;
            }

            var sectionText = text[sectionStart..sectionEnd];
            var markers = NumberedItemMarker.Matches(sectionText).Cast<Match>().ToArray();
            for (var index = 0; index < markers.Length; index++)
            {
                var marker = markers[index];
                var itemStart = sectionStart + marker.Index;
                var itemEnd = index + 1 < markers.Length ? sectionStart + markers[index + 1].Index : sectionEnd;
                if (Overlaps(itemStart, itemEnd, occupied)) continue;
                var body = text[(itemStart + marker.Length)..itemEnd];
                var split = FindAnswerSeparator(body, title);
                if (split < 1 || split >= body.Length - 1) continue;
                items.Add(new(itemStart, itemEnd, body[..split], body[(split + 1)..], title, string.Empty));
            }
        }
        return items;
    }

    private static int FindAnswerSeparator(string body, string section)
    {
        var colon = body.IndexOfAny(['：', ':']);
        return colon < 1 ? -1 : colon;
    }

    private static bool Overlaps(int start, int end, IReadOnlyList<(int Start, int End)> occupied) =>
        occupied.Any(range => start < range.End && end > range.Start);

    private static int FindNextStructuralBoundary(string text, int start)
    {
        var section = SectionHeading.Match(text, start);
        var structural = StructuralBoundary.Match(text, start);
        return new[]
        {
            section.Success ? section.Index : text.Length,
            structural.Success ? structural.Index : text.Length,
            text.Length
        }.Min();
    }

    private static QuestionDraft? ParseSourceItem(MaterialText material, SourceItem item, bool explicitAnswer,
        IReadOnlyList<PlanGraphPoint> points, List<PracticeJobDiagnostic> diagnostics)
    {
        var body = CleanText(item.Prompt);
        var answer = CleanAnswer(item.Answer);
        var options = ParseOptions(body, out var prompt);
        prompt = Regex.Replace(prompt, @"^\s*\(?\d+\s*分\)?\s*", string.Empty).Trim();
        if (prompt.Length < 2 || answer.Length < 1) return null;

        var kind = InferKind(item.SectionTitle, prompt, options.Length);
        IReadOnlyList<string> correctAnswers;
        if (kind == PracticeQuestionKind.SingleChoice)
        {
            var optionId = Regex.Match(answer, @"(?i)(?<![A-Z])[A-H](?![A-Z])").Value.ToUpperInvariant();
            if (options.Length < 2 || optionId.Length == 0 || !options.Any(option => option.Id == optionId))
            {
                diagnostics.Add(new(material.MaterialId, "SOURCE_CHOICE_ANSWER_AMBIGUOUS", $"原题“{TrimForDiagnostic(prompt)}”的选项或答案无法唯一核对，保留为草稿。", false));
                return null;
            }
            else correctAnswers = [optionId];
        }
        else correctAnswers = [answer];

        var excerpt = material.Text[item.StartOffset..item.EndOffset];
        var source = new SourceReference(material.MaterialId, item.StartOffset, item.EndOffset,
            material.SourceMapVersion, PracticeRules.Sha256(excerpt));
        var binding = KnowledgePointBindingRules.Bind(kind, prompt, correctAnswers, excerpt, points, [source]);
        var answerSupported = EvidenceSupportsAnswer(excerpt, answer);
        var reliableChoice = kind != PracticeQuestionKind.SingleChoice || options.Length == 4;
        var ready = binding.PointId.HasValue && answerSupported && reliableChoice;
        if (!binding.PointId.HasValue)
            diagnostics.Add(new(material.MaterialId, binding.Ambiguous ? "KNOWLEDGE_POINT_BINDING_AMBIGUOUS" : "KNOWLEDGE_POINT_SOURCE_NOT_FOUND",
                $"原题“{TrimForDiagnostic(prompt)}”未能唯一绑定本册知识点，已保留为待核对草稿。", false));
        if (!answerSupported)
            diagnostics.Add(new(material.MaterialId, "SOURCE_ANSWER_NOT_SUPPORTED",
                $"原题“{TrimForDiagnostic(prompt)}”的答案不能由同一原文区间完整支持，已保留为待核对草稿。", false));
        if (!reliableChoice)
            diagnostics.Add(new(material.MaterialId, "SOURCE_CHOICE_OPTIONS_UNRELIABLE",
                $"原题“{TrimForDiagnostic(prompt)}”不是恰好四个选项，未自动收入 READY 题库。", false));
        return new(kind, EnsureQuestionPrompt(prompt, kind), options, correctAnswers,
            explicitAnswer ? "题目与答案按资料原文提取。" : "题目与答案按资料中的可核对问答结构提取。",
            ParseScore(item.SectionMeta, excerpt, kind), InferDifficulty(kind), binding.PointId, [source], ready ? QuestionStatus.Ready : QuestionStatus.Draft);
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
        var diagnostics = new List<PracticeJobDiagnostic>();
        IReadOnlyList<ModelCandidate> candidates;
        try
        {
            candidates = ParseModelCandidates(generated.Content, chunk, input);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException)
        {
            diagnostics.Add(new(chunk.Material.MaterialId, "QUESTION_MODEL_OUTPUT_INVALID",
                "题目模型返回的 JSON 不符合候选题契约，未保存任何猜测题目。", false));
            return new([], diagnostics, generated.TokenUnits);
        }
        if (candidates.Count == 0)
        {
            diagnostics.Add(new(chunk.Material.MaterialId, "NO_VERIFIED_QUESTIONS_IN_CHUNK",
                $"资料区间 {chunk.StartOffset}-{chunk.StartOffset + chunk.Text.Length} 没有题目通过确定性校验。", false));
            return new([], diagnostics, generated.TokenUnits);
        }

        var verifierUser = JsonSerializer.Serialize(new
        {
            task = "在与生成调用分离的第二次推理中复核候选题。只能依据 evidence 重新作答，再将 recoveredAnswers 与候选标准答案比较；仅接受答案一致、题干清晰且 pointId 语义一致的题。",
            evidence = chunk.Text,
            suppliedPoints = points,
            candidates = candidates.Select((candidate, index) => new { index, candidate.Draft.Kind, candidate.Draft.Prompt, candidate.Draft.Options, candidate.Draft.CorrectAnswers, candidate.PointId, candidate.SourceQuote }),
            output = new { results = new[] { new { index = 0, accepted = true, recoveredAnswers = new[] { "" }, reason = "" } } }
        }, _json);
        var verified = await CompleteJsonAsync("你是第二遍来源约束题目核验器。不得利用 evidence 之外的常识放宽答案。输出严格 JSON。", verifierUser, cancellationToken);
        IReadOnlySet<int> accepted;
        try
        {
            accepted = ParseRoundTripResults(verified.Content, candidates);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException)
        {
            diagnostics.Add(new(chunk.Material.MaterialId, "QUESTION_ROUND_TRIP_OUTPUT_INVALID",
                "第二遍回验返回的 JSON 不符合回验契约，候选题均未进入 READY。", false));
            return new([], diagnostics, checked(generated.TokenUnits + verified.TokenUnits));
        }
        var result = candidates.Where((_, index) => accepted.Contains(index)).Select(candidate => candidate.Draft).ToArray();
        if (result.Length < candidates.Count)
            diagnostics.Add(new(chunk.Material.MaterialId, "QUESTION_ROUND_TRIP_REJECTED",
                $"第二遍回验拒绝了 {candidates.Count - result.Length} 道不能从同一证据稳定还原答案的候选题。", false));
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
        JsonDocument document;
        try { document = JsonDocument.Parse(body); }
        catch (JsonException)
        {
            throw new PracticeDomainException(502, "QUESTION_MODEL_RESPONSE_INVALID", "题目模型返回了非 JSON 响应，未保存候选题。");
        }
        using (document)
        {
            if (!document.RootElement.TryGetProperty("usage", out var usage)
                || !usage.TryGetProperty("total_tokens", out var total)
                || !total.TryGetInt64(out var tokens)
                || tokens <= 0)
                throw new PracticeDomainException(502, "QUESTION_MODEL_USAGE_MISSING", "题目模型未返回有效 usage.total_tokens，无法按实际消耗结算 credits。");
            if (!document.RootElement.TryGetProperty("choices", out var choices)
                || choices.ValueKind != JsonValueKind.Array
                || choices.GetArrayLength() == 0
                || !choices[0].TryGetProperty("message", out var message)
                || !message.TryGetProperty("content", out var rawContent)
                || rawContent.ValueKind != JsonValueKind.String
                || string.IsNullOrWhiteSpace(rawContent.GetString()))
                throw new PracticeDomainException(502, "QUESTION_MODEL_RESPONSE_INVALID", "题目模型响应缺少 choices[0].message.content。");
            return new(rawContent.GetString()!, tokens);
        }
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
                if (answers.Length == 0 || ContainsPageNoise(quote)) continue;
                var options = item.TryGetProperty("options", out var rawOptions) && rawOptions.ValueKind == JsonValueKind.Array
                    ? rawOptions.EnumerateArray().Select(option => new QuestionOption(option.GetProperty("id").GetString() ?? string.Empty, option.GetProperty("text").GetString() ?? string.Empty)).ToArray()
                    : [];
                if (kind != PracticeQuestionKind.SingleChoice
                    && answers.Any(answer => !Normalize(quote).Contains(Normalize(answer), StringComparison.Ordinal))) continue;
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
        if (kind != PracticeQuestionKind.SingleChoice
            && answers.Any(answer => Normalize(prompt).Contains(Normalize(answer), StringComparison.Ordinal))) return false;
        if (kind == PracticeQuestionKind.FillBlank) return Regex.Matches(prompt, "____").Count == answers.Count
            && answers.All(answer => answer.Length <= 40) && options.Count == 0
            && prompt.Replace("____", "待填内容", StringComparison.Ordinal).Length >= 6;
        if (kind == PracticeQuestionKind.TermDefinition) return options.Count == 0 && !Normalize(prompt).Contains(Normalize(quote), StringComparison.Ordinal);
        if (kind == PracticeQuestionKind.Essay) return options.Count == 0 && !Normalize(prompt).Contains(Normalize(quote), StringComparison.Ordinal);
        if (kind != PracticeQuestionKind.SingleChoice || options.Count != 4 || answers.Count != 1) return false;
        var answerOption = options.SingleOrDefault(option => string.Equals(option.Id, answers[0], StringComparison.OrdinalIgnoreCase));
        if (answerOption is null
            || Normalize(prompt).Contains(Normalize(answerOption.Text), StringComparison.Ordinal)
            || !Normalize(quote).Contains(Normalize(answerOption.Text), StringComparison.Ordinal)) return false;
        return options.Where(option => !string.Equals(option.Id, answerOption.Id, StringComparison.OrdinalIgnoreCase))
            .All(option => !Normalize(quote).Contains(Normalize(option.Text), StringComparison.Ordinal));
    }

    private static IReadOnlySet<int> ParseRoundTripResults(string json, IReadOnlyList<ModelCandidate> candidates)
    {
        using var document = JsonDocument.Parse(ExtractJsonObject(json));
        if (!document.RootElement.TryGetProperty("results", out var results) || results.ValueKind != JsonValueKind.Array) return new HashSet<int>();
        var accepted = new HashSet<int>();
        foreach (var result in results.EnumerateArray())
        {
            if (!result.TryGetProperty("index", out var rawIndex) || !rawIndex.TryGetInt32(out var index)
                || index < 0 || index >= candidates.Count
                || !result.TryGetProperty("accepted", out var rawAccepted) || rawAccepted.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
                || !rawAccepted.GetBoolean()
                || !result.TryGetProperty("recoveredAnswers", out var recovered) || recovered.ValueKind != JsonValueKind.Array) continue;
            var recoveredAnswers = recovered.EnumerateArray()
                .Where(value => value.ValueKind == JsonValueKind.String)
                .Select(value => value.GetString()?.Trim() ?? string.Empty)
                .Where(value => value.Length > 0)
                .Select(Normalize)
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToArray();
            var expectedAnswers = candidates[index].Draft.CorrectAnswers
                .Select(Normalize)
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToArray();
            if (recoveredAnswers.SequenceEqual(expectedAnswers, StringComparer.Ordinal)) accepted.Add(index);
        }
        return accepted;
    }

    private static IEnumerable<SourceChunk> BuildChunks(IReadOnlyList<MaterialText> materials, IReadOnlyList<PlanGraphPoint> points)
    {
        foreach (var material in materials)
        {
            var position = 0;
            while (position < material.Text.Length)
            {
                while (position < material.Text.Length && char.IsWhiteSpace(material.Text[position])) position++;
                if (position >= material.Text.Length) break;
                var start = position;
                var preferredEnd = Math.Min(start + ChunkCharacters, material.Text.Length);
                var end = FindChunkBoundary(material.Text, start, preferredEnd);
                while (end > start && char.IsWhiteSpace(material.Text[end - 1])) end--;
                if (end <= start)
                {
                    end = preferredEnd;
                }
                var text = material.Text[start..end].Trim();
                var actualStart = material.Text.IndexOf(text, start, StringComparison.Ordinal);
                if (text.Length >= 40)
                    yield return new(material, actualStart, text, BindCandidatePoints(text, points));
                position = end;
            }
        }
    }

    private static int FindChunkBoundary(string text, int start, int preferredEnd)
    {
        if (preferredEnd >= text.Length) return text.Length;
        var minimum = start + Math.Max(1, (preferredEnd - start) * 3 / 5);
        for (var index = preferredEnd; index > minimum; index--)
        {
            if (text[index - 1] is '\n' or '。' or '！' or '？' or '.' or '!' or '?' or '；' or ';')
                return index;
        }
        return preferredEnd;
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

    private static (string Title, string Meta)? FindSection(string text, int offset)
    {
        var sections = SectionHeading.Matches(text[..Math.Clamp(offset, 0, text.Length)]);
        if (sections.Count == 0) return null;
        var match = sections[^1];
        return (match.Groups["title"].Value.Trim(), string.Empty);
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
        prompt = Regex.Replace(prompt, @"[（(]?1[）)]?\s*定义$", string.Empty).Trim();
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
        var answer = CleanText(value);
        answer = Regex.Replace(answer, @"(?ms)\s*评分标准.*$", string.Empty);
        answer = Regex.Replace(answer, @"[ \t]+", " ");
        answer = Regex.Replace(answer, @"\s*\r?\n\s*", "\n");
        return answer.Trim();
    }

    private static string CleanText(string value)
    {
        var cleaned = PageNoise.Replace(value, " ");
        cleaned = Regex.Replace(cleaned, @"[ \t]+", " ");
        return cleaned.Trim();
    }

    private static QuestionOption[] ParseOptions(string body, out string prompt)
    {
        var matches = OptionMarker.Matches(body).Cast<Match>().ToArray();
        if (matches.Length < 2)
        {
            prompt = body.Trim();
            return [];
        }
        prompt = body[..matches[0].Index].Trim();
        return matches.Select((match, index) =>
        {
            var end = index + 1 < matches.Length ? matches[index + 1].Index : body.Length;
            return new QuestionOption(NormalizeOptionId(match.Groups["id"].Value), body[(match.Index + match.Length)..end].Trim());
        }).Where(option => option.Text.Length > 0).ToArray();
    }

    private static bool EvidenceSupportsAnswer(string evidence, string answer) =>
        Normalize(CleanText(evidence)).Contains(Normalize(CleanText(answer)), StringComparison.Ordinal);

    private static bool ContainsPageNoise(string value) => PageNoise.IsMatch(value);

    private static string QuestionDedupKey(QuestionDraft draft)
    {
        var point = draft.KnowledgePointId?.ToString("D")
            ?? $"unbound:{draft.SourceReferences.FirstOrDefault()?.MaterialId:D}:{draft.SourceReferences.FirstOrDefault()?.StartOffset}";
        var atom = string.Join('|', draft.CorrectAnswers.Select(Normalize).OrderBy(value => value, StringComparer.Ordinal));
        return $"{point}:{draft.Kind}:{atom}";
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
        if (string.IsNullOrWhiteSpace(value))
            return string.Empty;
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

    private sealed record ExtractionBatch(IReadOnlyList<QuestionDraft> Drafts, IReadOnlyList<PracticeJobDiagnostic> Diagnostics,
        bool IsExplicitQuestionBank, IReadOnlyList<GroundedRange> CoveredRanges);
    private sealed record GroundedRange(Guid MaterialId, int StartOffset, int EndOffset);
    private sealed record SourceMarker(int Index, int Length);
    private sealed record SourceItem(int StartOffset, int EndOffset, string Prompt, string Answer, string? SectionTitle, string SectionMeta);
    private sealed record SourceChunk(MaterialText Material, int StartOffset, string Text, IReadOnlyList<PlanGraphPoint> Points);
    private sealed record ModelCompletion(string Content, long TokenUnits);
    private sealed record ModelCandidate(QuestionDraft Draft, Guid PointId, string SourceQuote);
    private sealed record GeneratedChunk(IReadOnlyList<QuestionDraft> Drafts, IReadOnlyList<PracticeJobDiagnostic> Diagnostics, long TokenUnits);
}
