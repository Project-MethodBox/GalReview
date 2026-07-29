using KnowledgeService.Application.Planning;
using KnowledgeService.Domain.Common;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Domain.Reviews;
using KnowledgeService.Tests.Fixtures;

namespace KnowledgeService.Tests.Planning;

public sealed class PlanGraphSnapshotTests
{
    [Fact]
    public void Snapshot_is_order_independent_but_content_sensitive()
    {
        var graph = GraphFixture.CreateHubGraph();
        var plan = new LearningPlanner().Create(
            graph,
            new Dictionary<Guid, MasteryState>(),
            new LearningPlanOptions(
                new[] { graph.Chapters.Last().ChapterId },
                MaximumPoints: 6),
            graph.CreatedAt);

        var reordered = PlanGraphFactory.SnapshotVersion(
            plan.ReviewPlanId,
            graph,
            ReviewPlanPurpose.Learning,
            KnowledgeAlgorithmVersions.LearningPlanner,
            plan.RequestedChapterIds.Reverse().ToArray(),
            plan.Nodes.Reverse().ToArray(),
            plan.Edges.Reverse().ToArray(),
            plan.EstimatedCoverage,
            plan.CreatedAt,
            plan.ExpiresAt);
        var changedNodes = plan.Nodes
            .Select((node, index) => index == 0
                ? node with { Title = $"{node.Title}-changed" }
                : node)
            .ToArray();
        var changed = PlanGraphFactory.SnapshotVersion(
            plan.ReviewPlanId,
            graph,
            ReviewPlanPurpose.Learning,
            KnowledgeAlgorithmVersions.LearningPlanner,
            plan.RequestedChapterIds,
            changedNodes,
            plan.Edges,
            plan.EstimatedCoverage,
            plan.CreatedAt,
            plan.ExpiresAt);

        Assert.Equal(plan.SnapshotVersion, reordered);
        Assert.NotEqual(plan.SnapshotVersion, changed);
    }

    [Fact]
    public void Snapshot_excludes_status_but_changes_with_owner_coverage_or_lifetime()
    {
        var graph = GraphFixture.CreateHubGraph();
        var plan = new LearningPlanner().Create(
            graph,
            new Dictionary<Guid, MasteryState>(),
            new LearningPlanOptions(
                new[] { graph.Chapters.Last().ChapterId },
                MaximumPoints: 6),
            graph.CreatedAt);
        var changedOwnerGraph = graph with
        {
            OwnerUserId = Guid.Parse(
                "40000000-0000-0000-0000-000000000001")
        };
        var completed = plan with { Status = ReviewPlanStatus.Completed };
        var variants = new[]
        {
            PlanGraphFactory.SnapshotVersion(
                plan.ReviewPlanId,
                changedOwnerGraph,
                plan.Purpose,
                plan.AlgorithmVersion,
                plan.RequestedChapterIds,
                plan.Nodes,
                plan.Edges,
                plan.EstimatedCoverage,
                plan.CreatedAt,
                plan.ExpiresAt),
            PlanGraphFactory.SnapshotVersion(
                plan.ReviewPlanId,
                graph,
                plan.Purpose,
                plan.AlgorithmVersion,
                plan.RequestedChapterIds,
                plan.Nodes,
                plan.Edges,
                plan.EstimatedCoverage >= 0.5
                    ? plan.EstimatedCoverage - 0.01
                    : plan.EstimatedCoverage + 0.01,
                plan.CreatedAt,
                plan.ExpiresAt),
            PlanGraphFactory.SnapshotVersion(
                plan.ReviewPlanId,
                graph,
                plan.Purpose,
                plan.AlgorithmVersion,
                plan.RequestedChapterIds,
                plan.Nodes,
                plan.Edges,
                plan.EstimatedCoverage,
                plan.CreatedAt.AddSeconds(1),
                plan.ExpiresAt),
            PlanGraphFactory.SnapshotVersion(
                plan.ReviewPlanId,
                graph,
                plan.Purpose,
                plan.AlgorithmVersion,
                plan.RequestedChapterIds,
                plan.Nodes,
                plan.Edges,
                plan.EstimatedCoverage,
                plan.CreatedAt,
                plan.ExpiresAt.AddSeconds(1))
        };

        Assert.All(
            variants,
            variant => Assert.NotEqual(plan.SnapshotVersion, variant));
        Assert.Equal(plan.SnapshotVersion, completed.SnapshotVersion);
    }
}
