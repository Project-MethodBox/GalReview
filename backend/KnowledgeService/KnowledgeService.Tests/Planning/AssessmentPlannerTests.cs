using KnowledgeService.Application.Planning;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Tests.Fixtures;

namespace KnowledgeService.Tests.Planning;

public sealed class AssessmentPlannerTests
{
    [Fact]
    public void Fully_mastered_scope_still_returns_one_deterministic_probe()
    {
        var graph = GraphFixture.CreateHubGraph();
        var mastery = graph.Points.ToDictionary(
            point => point.PointId,
            point => new MasteryState(
                graph.OwnerUserId,
                point.PointId,
                100,
                2.5,
                30,
                3,
                0,
                graph.CreatedAt.AddDays(30),
                graph.CreatedAt,
                "TEST_MASTERED",
                1));

        var plan = new AssessmentPlanner().Create(
            graph,
            mastery,
            new AssessmentPlanOptions(
                Array.Empty<Guid>(),
                MaximumQuestions: 5),
            graph.CreatedAt);

        Assert.Single(plan.Nodes, node => node.IsQuestionTarget);
        Assert.Equal(1, plan.Nodes.Sum(node => node.Weight), 6);
    }

    [Fact]
    public void Uses_fewer_questions_and_never_duplicates_shared_hub()
    {
        var graph = GraphFixture.CreateHubGraph();
        var requestedChapter = graph.Chapters.Single(chapter => chapter.Title == "目标章节");

        var plan = new AssessmentPlanner().Create(
            graph,
            new Dictionary<Guid, MasteryState>(),
            new AssessmentPlanOptions(
                new[] { requestedChapter.ChapterId },
                MaximumQuestions: 3,
                TargetCoverage: 0.75),
            graph.CreatedAt);

        Assert.InRange(plan.Nodes.Count(node => node.IsQuestionTarget), 1, 3);
        Assert.True(plan.Nodes.Count(node => node.IsQuestionTarget) < 5);
        var foundation = graph.Points.Single(point => point.Title == "生态学");
        Assert.Single(
            plan.Nodes,
            node => node.PointId == foundation.PointId);
        Assert.Equal(
            1,
            plan.Nodes.Where(node => node.IsQuestionTarget).Sum(node => node.Weight),
            6);
    }

    [Fact]
    public void Thousand_target_hub_is_materialized_once_not_per_path()
    {
        var graph = GraphFixture.CreateLargeHubGraph();
        var targetChapter = graph.Chapters.Single(
            chapter => chapter.Title == "目标章节");

        var plan = new AssessmentPlanner().Create(
            graph,
            new Dictionary<Guid, MasteryState>(),
            new AssessmentPlanOptions(
                new[] { targetChapter.ChapterId },
                MaximumQuestions: 12,
                TargetCoverage: 0.85,
                MaximumInferenceDepth: 1),
            graph.CreatedAt);

        var hub = graph.Points.Single(
            point => point.Title == "大型共享基础");
        Assert.Single(plan.Nodes, node => node.PointId == hub.PointId);
        Assert.Equal(12, plan.Nodes.Count(node => node.IsQuestionTarget));
        Assert.True(plan.Nodes.Count <= 13);
    }

    [Fact]
    public void Diamond_uses_stronger_two_hop_path_instead_of_low_confidence_shortcut()
    {
        var graph = GraphFixture.CreateDiamondGraph();
        var requestedChapter = graph.Chapters.Single(
            chapter => chapter.Title == "目标章节");

        var plan = new AssessmentPlanner().Create(
            graph,
            new Dictionary<Guid, MasteryState>(),
            new AssessmentPlanOptions(
                new[] { requestedChapter.ChapterId },
                MaximumQuestions: 1,
                TargetCoverage: 1,
                MaximumInferenceDepth: 3),
            graph.CreatedAt);

        var foundation = graph.Points.Single(point => point.Title == "共享基础");
        var foundationNode = Assert.Single(
            plan.Nodes,
            node => node.PointId == foundation.PointId);
        Assert.Equal(2, foundationNode.DependencyDepth);
        Assert.Contains(
            foundation.PointId,
            plan.Nodes.Single(node => node.IsQuestionTarget).CoversPointIds);
    }

    [Fact]
    public void Produces_stable_node_and_edge_order_when_graph_input_is_shuffled()
    {
        var graph = GraphFixture.CreateHubGraph();
        var shuffled = graph with
        {
            Points = graph.Points.Reverse().ToArray(),
            Relations = graph.Relations.Reverse().ToArray()
        };
        var requestedChapter = graph.Chapters.Single(
            chapter => chapter.Title == "目标章节");
        var options = new AssessmentPlanOptions(
            new[] { requestedChapter.ChapterId },
            MaximumQuestions: 3,
            TargetCoverage: 0.75);
        var planner = new AssessmentPlanner();

        var first = planner.Create(
            graph,
            new Dictionary<Guid, MasteryState>(),
            options,
            graph.CreatedAt);
        var second = planner.Create(
            shuffled,
            new Dictionary<Guid, MasteryState>(),
            options,
            graph.CreatedAt);

        Assert.Equal(
            first.Nodes.Select(node => node.PointId),
            second.Nodes.Select(node => node.PointId));
        Assert.Equal(
            first.Nodes.Select(node => node.Weight),
            second.Nodes.Select(node => node.Weight));
        Assert.Equal(
            first.Nodes.Select(node => string.Join(",", node.CoversPointIds)),
            second.Nodes.Select(node => string.Join(",", node.CoversPointIds)));
        Assert.Equal(first.Edges, second.Edges);
        Assert.Equal(first.EstimatedCoverage, second.EstimatedCoverage);
    }
}
