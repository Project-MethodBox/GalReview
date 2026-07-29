using KnowledgeService.Application.Planning;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Domain.Reviews;
using KnowledgeService.Tests.Fixtures;

namespace KnowledgeService.Tests.Planning;

public sealed class LearningPlannerTests
{
    [Fact]
    public void Caps_external_prerequisite_group_and_individual_hub_weight()
    {
        var graph = GraphFixture.CreateHubGraph();
        var requestedChapter = graph.Chapters.Single(chapter => chapter.Title == "目标章节");

        var plan = new LearningPlanner().Create(
            graph,
            new Dictionary<Guid, MasteryState>(),
            new LearningPlanOptions(
                new[] { requestedChapter.ChapterId },
                MaximumPoints: 6),
            graph.CreatedAt);

        Assert.Equal(1, plan.Nodes.Sum(node => node.Weight), 5);
        Assert.True(
            plan.Nodes
                .Where(node => node.IsOutsideRequestedChapters)
                .Sum(node => node.Weight) <= 0.300001);
        Assert.All(plan.Nodes, node => Assert.True(node.Weight <= 0.250001));
    }

    [Fact]
    public void Keeps_external_count_bounded_and_every_external_node_connected()
    {
        const int maximumPoints = 6;
        var graph = GraphFixture.CreateLearningPathGraph();
        var requestedChapter = graph.Chapters.Single(
            chapter => chapter.Title == "目标章节");
        var mastered = graph.Points
            .Where(point => point.Title == "外部根知识")
            .ToDictionary(
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

        var plan = new LearningPlanner().Create(
            graph,
            mastered,
            new LearningPlanOptions(
                new[] { requestedChapter.ChapterId },
                MaximumPoints: maximumPoints,
                MaximumDependencyDepth: 3),
            graph.CreatedAt);

        var externalNodes = plan.Nodes
            .Where(node => node.IsOutsideRequestedChapters)
            .ToArray();
        Assert.NotEmpty(externalNodes);
        Assert.True(
            externalNodes.Length <= (int)Math.Floor(maximumPoints * 0.30),
            "External prerequisite nodes must obey the count budget as well as the weight budget.");
        Assert.True(
            externalNodes.Sum(node => node.Weight) <= 0.300001,
            "External prerequisite nodes must obey the 30% weight cap.");
        Assert.All(
            externalNodes,
            node => Assert.True(
                HasPathToRequestedNode(
                    node.PointId,
                    requestedChapter.ChapterId,
                    plan.Nodes,
                    plan.Edges),
                $"External node {node.PointId} is disconnected from every selected requested-chapter node."));
    }

    [Fact]
    public void Produces_stable_order_when_points_and_relations_are_shuffled()
    {
        var graph = GraphFixture.CreateHubGraph();
        var shuffled = graph with
        {
            Points = graph.Points.Reverse().ToArray(),
            Relations = graph.Relations.Reverse().ToArray()
        };
        var requestedChapter = graph.Chapters.Single(
            chapter => chapter.Title == "目标章节");
        var options = new LearningPlanOptions(
            new[] { requestedChapter.ChapterId },
            MaximumPoints: 6,
            MaximumDependencyDepth: 3);
        var planner = new LearningPlanner();

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
        Assert.Equal(first.Edges, second.Edges);
        Assert.Equal(first.EstimatedCoverage, second.EstimatedCoverage);
    }

    private static bool HasPathToRequestedNode(
        Guid start,
        Guid requestedChapterId,
        IReadOnlyList<PlanNode> nodes,
        IReadOnlyList<PlanEdge> edges)
    {
        var nodeById = nodes.ToDictionary(node => node.PointId);
        var outgoing = edges
            .Where(edge => edge.Type == KnowledgeRelationType.Prerequisite)
            .GroupBy(edge => edge.FromPointId)
            .ToDictionary(
                group => group.Key,
                group => group.Select(edge => edge.ToPointId).ToArray());
        var visited = new HashSet<Guid> { start };
        var queue = new Queue<Guid>();
        queue.Enqueue(start);
        while (queue.TryDequeue(out var current))
        {
            if (current != start &&
                nodeById.TryGetValue(current, out var node) &&
                node.ChapterId == requestedChapterId)
            {
                return true;
            }

            foreach (var next in outgoing.GetValueOrDefault(
                         current,
                         Array.Empty<Guid>()))
            {
                if (visited.Add(next))
                {
                    queue.Enqueue(next);
                }
            }
        }

        return false;
    }
}
