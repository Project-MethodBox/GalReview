using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using PracticeService.Application;
using PracticeService.Domain;
using PracticeService.Persistence;
using System.Net;
using System.Text;
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

    private static ReciteQuestionGenerator CreateGenerator()
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["QuestionGeneration:ApiKey"] = string.Empty
        }).Build();
        return new(new StubHttpClientFactory(), configuration, NullLogger<ReciteQuestionGenerator>.Instance);
    }

    private static string Normalize(string value) => new(value.Where(char.IsLetterOrDigit).ToArray());

    private sealed class StubHttpClientFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(new StubHandler());
    }

    private sealed class StubHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError));
    }
}
