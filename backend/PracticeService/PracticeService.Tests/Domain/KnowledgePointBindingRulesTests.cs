using PracticeService.Domain;
using Xunit;

namespace PracticeService.Tests.Domain;

public sealed class KnowledgePointBindingRulesTests
{
    [Fact]
    public void Unique_source_overlap_binds_when_wording_does_not_repeat_the_point_title()
    {
        var materialId = Guid.NewGuid(); var targetId = Guid.NewGuid();
        var target = Point(targetId, "出生时雌雄数量关系", materialId, 100, 150);
        var unrelated = Point(Guid.NewGuid(), "成年期雌雄数量关系", materialId, 300, 350);
        var questionSource = new SourceReference(materialId, 110, 145, "source-map-1", "checksum");

        var binding = KnowledgePointBindingRules.Bind(PracticeQuestionKind.Essay, "该比例如何定义？",
            ["由资料中的两个数量相除得到"], "由资料中的两个数量相除得到", [target, unrelated], [questionSource]);

        Assert.Equal(targetId, binding.PointId);
        Assert.Equal("SOURCE_RANGE_UNIQUE", binding.Rule);
    }

    [Fact]
    public void Multiple_source_overlaps_remain_ambiguous()
    {
        var materialId = Guid.NewGuid();
        var first = Point(Guid.NewGuid(), "概念甲", materialId, 100, 160);
        var second = Point(Guid.NewGuid(), "概念乙", materialId, 120, 180);
        var questionSource = new SourceReference(materialId, 130, 150, "source-map-1", "checksum");

        var binding = KnowledgePointBindingRules.Bind(PracticeQuestionKind.Essay, "该关系如何理解？",
            ["资料给出的关系"], "资料给出的关系", [first, second], [questionSource]);

        Assert.Null(binding.PointId);
        Assert.True(binding.Ambiguous);
        Assert.Equal("SOURCE_RANGE_UNIQUE", binding.Rule);
    }

    private static PlanGraphPoint Point(Guid pointId, string title, Guid materialId, long start, long end) =>
        new(pointId, Guid.NewGuid(), title, "", [], 0, [], [new KnowledgePointSource(materialId, start, end)]);
}
