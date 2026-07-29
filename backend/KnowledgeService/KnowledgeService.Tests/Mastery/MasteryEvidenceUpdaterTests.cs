using KnowledgeService.Application.Mastery;
using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Planning;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Domain.Reviews;
using KnowledgeService.Tests.Fixtures;

namespace KnowledgeService.Tests.Mastery;

public sealed class MasteryEvidenceUpdaterTests
{
    [Fact]
    public void Shared_prerequisite_receives_one_bounded_positive_inference()
    {
        var graph = GraphFixture.CreateHubGraph();
        var requestedChapter = graph.Chapters.Single(chapter => chapter.Title == "目标章节");
        var plan = new AssessmentPlanner().Create(
            graph,
            new Dictionary<Guid, MasteryState>(),
            new AssessmentPlanOptions(
                new[] { requestedChapter.ChapterId },
                MaximumQuestions: 3,
                TargetCoverage: 1),
            graph.CreatedAt);
        var targets = plan.Nodes.Where(node => node.IsQuestionTarget).Take(2).ToArray();
        Assert.NotEmpty(targets);
        var submission = new ReviewResultSubmission(
            Guid.NewGuid(),
            Guid.NewGuid(),
            graph.OwnerUserId,
            plan.SnapshotVersion,
            targets.Select((target, index) => new ReviewAnswer(
                target.PointId,
                $"attempt-{index}",
                true,
                5,
                10,
                false)).ToArray(),
            graph.CreatedAt.AddMinutes(5));

        var result = new MasteryEvidenceUpdater().Calculate(
            plan,
            graph,
            new Dictionary<Guid, MasteryState>(),
            submission,
            submission.CompletedAt);
        var foundation = graph.Points.Single(point => point.Title == "生态学");
        var inferred = result.Changes.Where(change =>
            change.PointId == foundation.PointId &&
            !change.DirectEvidence).ToArray();

        Assert.Single(inferred);
        Assert.All(inferred, change => Assert.InRange(change.NewScore, 0.01, 5));
        var inferredState = Assert.Single(
            result.States,
            state => state.PointId == foundation.PointId);
        Assert.Equal(graph.CreatedAt, inferredState.NextReviewAt);
        Assert.Null(inferredState.LastReviewedAt);
    }

    [Fact]
    public void Negative_answer_does_not_propagate_to_prerequisites()
    {
        var graph = GraphFixture.CreateHubGraph();
        var requestedChapter = graph.Chapters.Single(chapter => chapter.Title == "目标章节");
        var plan = new AssessmentPlanner().Create(
            graph,
            new Dictionary<Guid, MasteryState>(),
            new AssessmentPlanOptions(
                new[] { requestedChapter.ChapterId },
                MaximumQuestions: 1),
            graph.CreatedAt);
        var target = plan.Nodes.Single(node => node.IsQuestionTarget);
        var submission = new ReviewResultSubmission(
            Guid.NewGuid(),
            Guid.NewGuid(),
            graph.OwnerUserId,
            plan.SnapshotVersion,
            new[]
            {
                new ReviewAnswer(
                    target.PointId,
                    "attempt-1",
                    false,
                    0,
                    12,
                    false)
            },
            graph.CreatedAt.AddMinutes(2));

        var result = new MasteryEvidenceUpdater().Calculate(
            plan,
            graph,
            new Dictionary<Guid, MasteryState>(),
            submission,
            submission.CompletedAt);

        Assert.Single(result.Changes);
        Assert.True(result.Changes[0].DirectEvidence);
    }

    [Fact]
    public void Diamond_inference_uses_stronger_path_not_low_confidence_shortcut()
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
        var target = Assert.Single(plan.Nodes, node => node.IsQuestionTarget);
        var foundation = graph.Points.Single(point => point.Title == "共享基础");
        var existingFoundation = new MasteryState(
            graph.OwnerUserId,
            foundation.PointId,
            95,
            2.5,
            30,
            3,
            0,
            graph.CreatedAt.AddDays(30),
            graph.CreatedAt,
            "TEST_EXISTING",
            1);
        var submission = Submission(
            graph.OwnerUserId,
            plan.SnapshotVersion,
            target.PointId,
            correct: true,
            quality: 5,
            completedAt: graph.CreatedAt.AddMinutes(5));

        var result = new MasteryEvidenceUpdater().Calculate(
            plan,
            graph,
            new Dictionary<Guid, MasteryState>
            {
                [foundation.PointId] = existingFoundation
            },
            submission,
            submission.CompletedAt);

        var inferred = Assert.Single(
            result.Changes,
            change =>
                change.PointId == foundation.PointId &&
                !change.DirectEvidence);
        Assert.Contains("depth=2", inferred.Reason);
    }

    [Theory]
    [InlineData(0, false, 32.5, 0, 1)]
    [InlineData(1, false, 39.5, 0, 1)]
    [InlineData(2, false, 46.5, 0, 1)]
    [InlineData(3, true, 53.5, 1, 0)]
    [InlineData(4, true, 60.5, 1, 0)]
    [InlineData(5, true, 67.5, 1, 0)]
    public void Direct_update_uses_fixed_quality_mapping(
        int quality,
        bool correct,
        double expectedScore,
        int expectedRepetitions,
        int expectedLapses)
    {
        var now = DateTimeOffset.Parse("2026-07-29T00:00:00Z");
        var (graph, plan, point) = SinglePointLearningPlan(now);
        var current = new MasteryState(
            graph.OwnerUserId,
            point.PointId,
            50,
            2.5,
            0,
            0,
            0,
            now,
            now,
            "TEST_EXISTING",
            1);

        var updated = ApplyDirect(
            graph,
            plan,
            point.PointId,
            current,
            quality,
            correct,
            completedAt: now,
            processedAt: now);

        Assert.Equal(expectedScore, updated.Score, 2);
        Assert.Equal(expectedRepetitions, updated.Repetitions);
        Assert.Equal(expectedLapses, updated.Lapses);
        Assert.Equal(1, updated.IntervalDays);
    }

    [Fact]
    public void Direct_update_clamps_large_interval_to_ten_years()
    {
        var now = DateTimeOffset.Parse("2026-07-29T00:00:00Z");
        var (graph, plan, point) = SinglePointLearningPlan(now);
        var current = new MasteryState(
            graph.OwnerUserId,
            point.PointId,
            80,
            2.5,
            2000,
            2,
            0,
            now.AddDays(2000),
            now,
            "TEST_EXISTING",
            1);

        var updated = ApplyDirect(
            graph,
            plan,
            point.PointId,
            current,
            quality: 5,
            correct: true,
            completedAt: now,
            processedAt: now);

        Assert.Equal(3650, updated.IntervalDays);
        Assert.Equal(now.AddDays(3650), updated.NextReviewAt);
    }

    [Fact]
    public void Delayed_processing_schedules_from_completed_at()
    {
        var completedAt = DateTimeOffset.Parse("2026-07-29T00:00:00Z");
        var processedAt = completedAt.AddDays(2);
        var (graph, plan, point) = SinglePointLearningPlan(completedAt);
        var current = MasteryState.Initial(
            graph.OwnerUserId,
            point.PointId,
            completedAt);

        var updated = ApplyDirect(
            graph,
            plan,
            point.PointId,
            current,
            quality: 5,
            correct: true,
            completedAt,
            processedAt);

        Assert.Equal(completedAt, updated.LastReviewedAt);
        Assert.Equal(completedAt.AddDays(1), updated.NextReviewAt);
    }

    [Fact]
    public void Rejects_completion_outside_plan_lifetime()
    {
        var now = DateTimeOffset.Parse("2026-07-29T00:00:00Z");
        var (graph, plan, point) = SinglePointLearningPlan(now);
        var submission = Submission(
            graph.OwnerUserId,
            plan.SnapshotVersion,
            point.PointId,
            correct: true,
            quality: 5,
            completedAt: plan.ExpiresAt.AddSeconds(1));

        var exception = Assert.Throws<KnowledgeServiceException>(() =>
            new MasteryEvidenceUpdater().Calculate(
                plan,
                graph,
                new Dictionary<Guid, MasteryState>(),
                submission,
                submission.CompletedAt));

        Assert.Equal("REVIEW_COMPLETION_TIME_INVALID", exception.Code);
    }

    [Fact]
    public void Rejects_direct_evidence_older_than_existing_review()
    {
        var completedAt =
            DateTimeOffset.Parse("2026-07-29T00:00:00Z");
        var (graph, plan, point) = SinglePointLearningPlan(completedAt);
        var newer = new MasteryState(
            graph.OwnerUserId,
            point.PointId,
            80,
            2.5,
            6,
            2,
            0,
            completedAt.AddDays(6),
            completedAt.AddMinutes(1),
            "NEWER_DIRECT",
            2);
        var submission = Submission(
            graph.OwnerUserId,
            plan.SnapshotVersion,
            point.PointId,
            correct: true,
            quality: 5,
            completedAt);

        var exception = Assert.Throws<KnowledgeServiceException>(() =>
            new MasteryEvidenceUpdater().Calculate(
                plan,
                graph,
                new Dictionary<Guid, MasteryState>
                {
                    [point.PointId] = newer
                },
                submission,
                completedAt.AddMinutes(2)));

        Assert.Equal("STALE_REVIEW_EVIDENCE", exception.Code);
    }

    [Fact]
    public void Skips_inference_when_ancestor_has_newer_direct_review()
    {
        var graph = GraphFixture.CreateHubGraph();
        var requestedChapter = graph.Chapters.Single(
            chapter => chapter.Title == "目标章节");
        var plan = new AssessmentPlanner().Create(
            graph,
            new Dictionary<Guid, MasteryState>(),
            new AssessmentPlanOptions(
                new[] { requestedChapter.ChapterId },
                MaximumQuestions: 1),
            graph.CreatedAt);
        var target = Assert.Single(
            plan.Nodes,
            node => node.IsQuestionTarget);
        var foundation = graph.Points.Single(
            point => point.Title == "生态学");
        var completedAt = graph.CreatedAt.AddMinutes(5);
        var newerAncestor = new MasteryState(
            graph.OwnerUserId,
            foundation.PointId,
            80,
            2.5,
            6,
            2,
            0,
            completedAt.AddDays(6),
            completedAt.AddMinutes(1),
            "NEWER_DIRECT",
            2);
        var submission = Submission(
            graph.OwnerUserId,
            plan.SnapshotVersion,
            target.PointId,
            correct: true,
            quality: 5,
            completedAt);

        var result = new MasteryEvidenceUpdater().Calculate(
            plan,
            graph,
            new Dictionary<Guid, MasteryState>
            {
                [foundation.PointId] = newerAncestor
            },
            submission,
            completedAt.AddMinutes(2));

        Assert.DoesNotContain(
            result.Changes,
            change =>
                change.PointId == foundation.PointId &&
                !change.DirectEvidence);
        Assert.DoesNotContain(
            result.States,
            state => state.PointId == foundation.PointId);
    }

    [Fact]
    public void Rejects_quality_above_three_when_hint_was_used()
    {
        var now = DateTimeOffset.Parse("2026-07-29T00:00:00Z");
        var (graph, plan, point) = SinglePointLearningPlan(now);
        var submission = Submission(
            graph.OwnerUserId,
            plan.SnapshotVersion,
            point.PointId,
            correct: true,
            quality: 5,
            completedAt: now,
            usedHint: true);

        var exception = Assert.Throws<KnowledgeServiceException>(() =>
            new MasteryEvidenceUpdater().Calculate(
                plan,
                graph,
                new Dictionary<Guid, MasteryState>(),
                submission,
                now));

        Assert.Equal("REVIEW_EVIDENCE_INVALID", exception.Code);
    }

    private static MasteryState ApplyDirect(
        KnowledgeGraph graph,
        ReviewPlanGraph plan,
        Guid pointId,
        MasteryState current,
        int quality,
        bool correct,
        DateTimeOffset completedAt,
        DateTimeOffset processedAt)
    {
        var submission = Submission(
            graph.OwnerUserId,
            plan.SnapshotVersion,
            pointId,
            correct,
            quality,
            completedAt);
        var result = new MasteryEvidenceUpdater().Calculate(
            plan,
            graph,
            new Dictionary<Guid, MasteryState>
            {
                [pointId] = current
            },
            submission,
            processedAt);
        return Assert.Single(result.States);
    }

    private static ReviewResultSubmission Submission(
        Guid ownerUserId,
        string snapshotVersion,
        Guid pointId,
        bool correct,
        int quality,
        DateTimeOffset completedAt,
        bool usedHint = false) =>
        new(
            Guid.NewGuid(),
            Guid.NewGuid(),
            ownerUserId,
            snapshotVersion,
            new[]
            {
                new ReviewAnswer(
                    pointId,
                    $"attempt-{Guid.NewGuid():N}",
                    correct,
                    quality,
                    10,
                    usedHint)
            },
            completedAt);

    private static (
        KnowledgeGraph Graph,
        ReviewPlanGraph Plan,
        KnowledgePoint Point) SinglePointLearningPlan(
        DateTimeOffset now)
    {
        var graph = GraphFixture.CreateHubGraph(now);
        var point = graph.Points.Single(item => item.Title == "生态学");
        var snapshotVersion = $"test:{graph.GraphId:N}:learning";
        var plan = new ReviewPlanGraph(
            Guid.NewGuid(),
            graph.GraphId,
            graph.OwnerUserId,
            graph.Version,
            snapshotVersion,
            ReviewPlanPurpose.Learning,
            ReviewPlanStatus.Open,
            new[] { point.ChapterId },
            new[]
            {
                new PlanNode(
                    point.PointId,
                    point.ChapterId,
                    point.Title,
                    point.Summary,
                    point.Tags,
                    0,
                    1,
                    false,
                    false,
                    0,
                    Array.Empty<Guid>(),
                    Array.Empty<Guid>(),
                    "TEST")
            },
            Array.Empty<PlanEdge>(),
            1,
            "test",
            now.AddDays(-1),
            now.AddDays(7));
        return (graph, plan, point);
    }
}
