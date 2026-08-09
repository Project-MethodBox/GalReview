using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using PracticeService.Application;
using PracticeService.Domain;
using PracticeService.Persistence;
using System.Net;
using System.Text;
using System.Text.Json;
using Xunit;

namespace PracticeService.Tests.Application;

public sealed class ReciteQuestionGeneratorTests
{
    [Fact]
    public async Task Explicit_answer_bank_preserves_real_questions_answers_and_sources()
    {
        const string text = """
            三、简答题（每小题5分）
            4. 生态平衡的基本特征有哪些？
            【参考答案】生态系统的结构和功能相互协调；能量流动和物质循环保持动态平衡。
            5. 循环农业坚持的“4R原则”是什么？
            【参考答案】减量化、再利用、再循环和可控化。
            四、论述题（每小题10分）
            3. 解读中国生态农业原理之绿色发展原理。
            【参考答案】绿色发展要求资源节约、环境友好，并协调生产、生活与生态。
            """;
        var material = Material(text);
        var points = new[]
        {
            Point("生态平衡的基本特征有哪些"),
            Point("循环农业坚持的4R原则是什么"),
            Point("解读中国生态农业原理之绿色发展原理")
        };
        var generator = CreateGenerator();

        var output = await generator.GenerateAsync(Input(material, points), CancellationToken.None);

        Assert.Equal(3, output.Drafts.Count);
        Assert.DoesNotContain(output.Drafts, draft => draft.Prompt.Contains("请概括下述内容", StringComparison.Ordinal));
        Assert.DoesNotContain(output.Drafts, draft => draft.Prompt.Contains("____", StringComparison.Ordinal));
        var balance = Assert.Single(output.Drafts, draft => draft.Prompt.Contains("生态平衡", StringComparison.Ordinal));
        Assert.Contains("动态平衡", Assert.Single(balance.CorrectAnswers));
        var green = Assert.Single(output.Drafts, draft => draft.Prompt.Contains("绿色发展", StringComparison.Ordinal));
        Assert.NotEqual(Normalize(green.Prompt), Normalize(Assert.Single(green.CorrectAnswers)));
        Assert.All(output.Drafts, draft =>
        {
            Assert.Equal(QuestionStatus.Ready, draft.Status);
            Assert.NotNull(draft.KnowledgePointId);
            var source = Assert.Single(draft.SourceReferences);
            var excerpt = text[(int)source.StartOffset..(int)source.EndOffset];
            Assert.Equal(PracticeRules.Sha256(excerpt), source.ExcerptChecksum);
        });
    }

    [Fact]
    public async Task Semi_structured_humanities_notes_extract_answer_first_questions_without_model()
    {
        const string text = """
            绪论 微生物与人类
            名词解释
            1. 微生物：一切肉眼看不见或看不清、个体结构简单的微小生物的总称。
            2. 微生物学：研究微生物生命活动基本规律并应用于生产实践的科学。
            大题
            1. 微生物作为模式生物具有如下优点：
            ① 结构相对简单；
            ② 培养成本低、群体数量大；
            ③ 生长速度快、倍增时间短。
            """;
        var material = Material(text);
        var generator = CreateGenerator();

        var output = await generator.GenerateAsync(Input(material,
            [Point("微生物"), Point("微生物学"), Point("微生物作为模式生物的优点")]), CancellationToken.None);

        Assert.Equal(3, output.Drafts.Count);
        Assert.Equal(2, output.Drafts.Count(draft => draft.Kind == PracticeQuestionKind.TermDefinition));
        var essay = Assert.Single(output.Drafts, draft => draft.Kind == PracticeQuestionKind.Essay);
        Assert.Contains("模式生物", essay.Prompt);
        Assert.Contains("培养成本低", Assert.Single(essay.CorrectAnswers));
        Assert.Equal(1, output.ActualTokenUnits);
    }

    [Fact]
    public async Task Exact_prompt_point_wins_over_same_length_concept_mentioned_in_answer()
    {
        const string text = "名词解释\n1. 土壤结构：土壤结构会影响土壤肥力。";
        var target = Point("土壤结构");
        var related = Point("土壤肥力");

        var output = await CreateGenerator().GenerateAsync(
            Input(Material(text), [target, related]), CancellationToken.None);

        var question = Assert.Single(output.Drafts);
        Assert.Equal(QuestionStatus.Ready, question.Status);
        Assert.Equal(target.KnowledgePointId, question.KnowledgePointId);
    }

    [Fact]
    public async Task Flattened_pdf_pages_preserve_inline_questions_and_remove_known_page_noise()
    {
        const string text = "第一章 绪论 一、简答题（每小题5分） 4. 生态平衡的基本特征有哪些？ 【参考答案】（1）相对平衡；（2）物流和能流比例合理。 5. 循环农业坚持的4R原则是什么？ 【参考答案】适量化、再循环、再利用、可控化。 四、论述题 3. 解读中国生态农业原理之绿色发展原理。 山东农业大学农学院农业生态学教学组版权所有不得复制！ 17 【参考答案】绿色发展要求最大绿色覆盖并提高光合作用效率。";
        var output = await CreateGenerator().GenerateAsync(Input(Material(text),
            [Point("生态平衡的基本特征有哪些"), Point("循环农业坚持的4R原则是什么"), Point("绿色发展原理")]), CancellationToken.None);

        Assert.Equal(3, output.Drafts.Count);
        Assert.All(output.Drafts, question => Assert.Equal(QuestionStatus.Ready, question.Status));
        Assert.DoesNotContain(output.Drafts, question => question.Prompt.Contains("版权所有", StringComparison.Ordinal));
        Assert.Contains(output.Drafts, question => question.Prompt.Contains("4R原则", StringComparison.Ordinal)
            && Assert.Single(question.CorrectAnswers).Contains("可控化", StringComparison.Ordinal));
        Assert.Contains(output.Drafts, question => question.Prompt.Contains("绿色发展原理", StringComparison.Ordinal)
            && !question.CorrectAnswers.Any(answer => Normalize(answer) == Normalize(question.Prompt)));
    }

    [Fact]
    public async Task Multiline_numbered_answer_is_not_cut_at_internal_list_items()
    {
        const string text = """
            三、简答题
            1. 农业生态系统的特点有哪些？
            【参考答案】1. 受人类活动调控；
            2. 具有较高开放性；
            3. 生物组成受生产目标影响。
            2. 农业生态系统如何保持稳定？
            【参考答案】通过增加多样性并控制外部压力。
            3. 农业生态系统的核心目标是什么？
            【参考答案】兼顾生产、生态与社会效益。
            """;
        var output = await CreateGenerator().GenerateAsync(Input(Material(text),
            [Point("农业生态系统的特点"), Point("农业生态系统如何保持稳定"), Point("农业生态系统的核心目标")]), CancellationToken.None);

        var first = Assert.Single(output.Drafts, question => question.Prompt.Contains("特点", StringComparison.Ordinal));
        var answer = Assert.Single(first.CorrectAnswers);
        Assert.Contains("受人类活动调控", answer);
        Assert.Contains("具有较高开放性", answer);
        Assert.Contains("生物组成受生产目标影响", answer);
    }

    [Fact]
    public async Task Explicit_answer_stops_at_the_next_section_before_a_later_answer_marker()
    {
        const string text = """
            三、简答题
            1. 农业面源污染如何控制？
            【参考答案】（1）科学施肥；（2）合理用药。
            四、综合题
            1. 请结合案例分析农业生产活动对碳循环的影响。
            第五章 能量流动
            三、简答题
            1. 农业生态系统能量流动如何调控？
            【参考答案】扩源、强库、截流、减耗。
            2. 食物链有哪些主要类型？
            【参考答案】捕食食物链、腐食食物链、寄生食物链和混合食物链。
            """;
        var output = await CreateGenerator().GenerateAsync(Input(Material(text),
            [Point("农业面源污染控制"), Point("农业生态系统能量流动调控"), Point("食物链主要类型")]), CancellationToken.None);

        var first = Assert.Single(output.Drafts, question => question.Prompt.Contains("面源污染", StringComparison.Ordinal));
        var answer = Assert.Single(first.CorrectAnswers);
        Assert.Contains("科学施肥", answer);
        Assert.DoesNotContain("综合题", answer);
        Assert.DoesNotContain("第五章", answer);
    }

    [Fact]
    public async Task Flattened_microbiology_notes_extract_terms_and_point_answer_without_rewriting()
    {
        const string text = "第一章绪论名词解释1.微生物：一切肉眼看不见或看不清的形体微小生物的总称。2.微生物学：研究微生物生命活动基本规律并应用于生产实践的科学。大题1.微生物作为模式生物具有如下优点：1结构相对简单；2培养成本低、群体数量大；3生长速度快。还有重要的知识点1.微生物的定义及特点(1)定义：微生物形态微小、结构简单。";
        var output = await CreateGenerator().GenerateAsync(Input(Material(text),
            [Point("微生物"), Point("微生物学"), Point("微生物作为模式生物的优点"), Point("微生物的定义及特点")]), CancellationToken.None);

        Assert.True(output.Drafts.Count >= 3);
        Assert.Equal(2, output.Drafts.Count(question => question.Kind == PracticeQuestionKind.TermDefinition));
        Assert.Contains(output.Drafts, question => question.Prompt.Contains("模式生物", StringComparison.Ordinal)
            && Assert.Single(question.CorrectAnswers).Contains("培养成本低", StringComparison.Ordinal));
        Assert.DoesNotContain(output.Drafts.SelectMany(question => question.CorrectAnswers), answer => answer.Contains("2019级植科", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Automatic_bank_size_follows_verified_atoms_and_can_reach_hundreds()
    {
        var source = new StringBuilder("名词解释\n");
        var points = new List<PlanGraphPoint>();
        for (var index = 1; index <= 240; index++)
        {
            source.Append(index).Append(". 农学概念").Append(index).Append("：这是农学概念").Append(index).Append("的可核对定义。\n");
            points.Add(Point($"农学概念{index}"));
        }
        var material = Material(source.ToString());
        var generator = CreateGenerator();

        var estimate = generator.Estimate(Input(material, points));
        var output = await generator.GenerateAsync(Input(material, points), CancellationToken.None);

        Assert.Equal(240, estimate.ResolvedTargetCount);
        Assert.Equal(240, output.Drafts.Count);
        Assert.All(output.Drafts, draft => Assert.Equal(QuestionStatus.Ready, draft.Status));
        Assert.Equal(240, output.Drafts.Select(draft => draft.KnowledgePointId).Distinct().Count());
    }

    [Fact]
    public void Flattened_long_document_is_split_into_multiple_grounded_model_chunks()
    {
        var text = new StringBuilder();
        var points = new List<PlanGraphPoint>();
        for (var index = 1; index <= 80; index++)
        {
            var title = $"农业制度概念{index}";
            text.Append(title).Append("是用于说明农业生产组织、资源利用和生态约束关系的课程概念，并具有可由原文核对的定义与应用条件。");
            points.Add(Point(title));
        }
        var generator = CreateGenerator();

        var estimate = generator.Estimate(Input(Material(text.ToString()), points));

        Assert.Equal("GROUNDED_GENERATION", estimate.Mode);
        Assert.True(estimate.ResolvedTargetCount >= 32);
    }

    [Fact]
    public async Task DeepSeek_json_and_round_trip_answers_use_reported_token_units()
    {
        var point = Point("土壤通气性");
        const string text = "土壤团粒结构能够改善土壤通气性，并协调水分和空气之间的关系，从而有利于作物根系正常生长。";
        var candidate = JsonSerializer.Serialize(new
        {
            questions = new[]
            {
                new { kind = "FillBlank", prompt = "土壤团粒结构能够改善土壤的____。", options = Array.Empty<object>(),
                    correctAnswers = new[] { "通气性" }, explanation = "依据原文。", score = 2, difficulty = 2,
                    knowledgePointId = point.KnowledgePointId, sourceQuote = "土壤团粒结构能够改善土壤通气性" }
            }
        });
        var verifier = JsonSerializer.Serialize(new { results = new[] { new { index = 0, accepted = true, recoveredAnswers = new[] { "通气性" }, reason = "" } } });
        var generator = CreateGenerator(Completion(candidate, 37), Completion(verifier, 11));

        var output = await generator.GenerateAsync(Input(Material(text), [point]), CancellationToken.None);

        var question = Assert.Single(output.Drafts);
        Assert.Equal(QuestionStatus.Ready, question.Status);
        Assert.Equal(48, output.ActualTokenUnits);
    }

    [Fact]
    public async Task Model_response_without_usage_is_rejected_instead_of_guessing_settlement()
    {
        var response = JsonSerializer.Serialize(new { choices = new[] { new { message = new { content = "{\"questions\":[]}" } } } });
        var error = await Assert.ThrowsAsync<PracticeDomainException>(() => CreateGenerator(response)
            .GenerateAsync(Input(OrdinaryMaterial(), [Point("土壤通气性")]), CancellationToken.None));

        Assert.Equal("QUESTION_MODEL_USAGE_MISSING", error.Code);
    }

    [Fact]
    public async Task Non_json_provider_response_is_rejected()
    {
        var error = await Assert.ThrowsAsync<PracticeDomainException>(() => CreateGenerator("not-json")
            .GenerateAsync(Input(OrdinaryMaterial(), [Point("土壤通气性")]), CancellationToken.None));

        Assert.Equal("QUESTION_MODEL_RESPONSE_INVALID", error.Code);
    }

    [Fact]
    public async Task Invalid_point_quote_answer_and_choice_shape_are_all_rejected_before_round_trip()
    {
        var point = Point("土壤通气性");
        var content = JsonSerializer.Serialize(new
        {
            questions = new object[]
            {
                Candidate(Guid.NewGuid(), "土壤团粒结构能够改善土壤通气性", "通气性"),
                Candidate(point.KnowledgePointId, "原文中不存在的引文", "通气性"),
                Candidate(point.KnowledgePointId, "土壤团粒结构能够改善土壤通气性", "保水性"),
                new { kind = "SingleChoice", prompt = "哪项是原文结论？", options = new[] { new { id = "A", text = "通气性" }, new { id = "B", text = "保水性" }, new { id = "C", text = "盐碱化" }, new { id = "D", text = "板结" } },
                    correctAnswers = new[] { "A", "B" }, explanation = "", score = 2, difficulty = 2,
                    knowledgePointId = point.KnowledgePointId, sourceQuote = "土壤团粒结构能够改善土壤通气性" }
            }
        });
        var output = await CreateGenerator(Completion(content, 19)).GenerateAsync(Input(OrdinaryMaterial(), [point]), CancellationToken.None);

        Assert.Empty(output.Drafts);
        Assert.Contains(output.Diagnostics, diagnostic => diagnostic.Code == "NO_VERIFIED_QUESTIONS_IN_CHUNK");
        Assert.Equal(19, output.ActualTokenUnits);
    }

    [Fact]
    public async Task Round_trip_must_recover_the_same_answer()
    {
        var point = Point("土壤通气性");
        var candidate = JsonSerializer.Serialize(new { questions = new[] { Candidate(point.KnowledgePointId, "土壤团粒结构能够改善土壤通气性", "通气性") } });
        var verifier = JsonSerializer.Serialize(new { results = new[] { new { index = 0, accepted = true, recoveredAnswers = new[] { "保水性" }, reason = "答案不一致" } } });
        var output = await CreateGenerator(Completion(candidate, 23), Completion(verifier, 7))
            .GenerateAsync(Input(OrdinaryMaterial(), [point]), CancellationToken.None);

        Assert.Empty(output.Drafts);
        Assert.Contains(output.Diagnostics, diagnostic => diagnostic.Code == "QUESTION_ROUND_TRIP_REJECTED");
        Assert.Equal(30, output.ActualTokenUnits);
    }

    private static QuestionGenerationInput Input(MaterialText material, IReadOnlyList<PlanGraphPoint> points) =>
        new([material], [PracticeQuestionKind.SingleChoice, PracticeQuestionKind.FillBlank, PracticeQuestionKind.TermDefinition, PracticeQuestionKind.Essay],
            null, points, "recite-question-v2");

    private static MaterialText Material(string text) =>
        new(Guid.NewGuid(), Guid.NewGuid(), text, PracticeRules.Sha256(text), "source-map-1");

    private static PlanGraphPoint Point(string title)
    {
        var id = Guid.NewGuid();
        return new(id, Guid.NewGuid(), title, title, [title], 1, [id]);
    }

    private static MaterialText OrdinaryMaterial() => Material("土壤团粒结构能够改善土壤通气性，并协调水分和空气之间的关系，从而有利于作物根系正常生长。");

    private static object Candidate(Guid pointId, string quote, string answer) => new
    {
        kind = "FillBlank", prompt = "土壤团粒结构能够改善土壤的____。", options = Array.Empty<object>(),
        correctAnswers = new[] { answer }, explanation = "", score = 2, difficulty = 2,
        knowledgePointId = pointId, sourceQuote = quote
    };

    private static string Completion(string content, long totalTokens) => JsonSerializer.Serialize(new
    {
        choices = new[] { new { message = new { content } } },
        usage = new { total_tokens = totalTokens }
    });

    private static ReciteQuestionGenerator CreateGenerator(params string[] responses)
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["QuestionGeneration:ApiKey"] = responses.Length == 0 ? string.Empty : "test-key"
        }).Build();
        return new(new StubHttpClientFactory(responses), configuration, NullLogger<ReciteQuestionGenerator>.Instance);
    }

    private static string Normalize(string value) => new(value.Where(char.IsLetterOrDigit).ToArray());

    private sealed class StubHttpClientFactory(params string[] responses) : IHttpClientFactory
    {
        private readonly Queue<string> _responses = new(responses);
        public HttpClient CreateClient(string name) => new(new StubHandler(_responses));
    }

    private sealed class StubHandler(Queue<string> responses) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (responses.Count == 0) return Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError));
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(responses.Dequeue(), Encoding.UTF8, "application/json")
            });
        }
    }
}
