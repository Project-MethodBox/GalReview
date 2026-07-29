using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Planning;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.Application.Mastery;

public sealed class MasteryEvidenceUpdater
{
    private const int MaximumPositiveInferenceDepth = 3;
    private const double MaximumInferredScoreIncrease = 5;
    private static readonly TimeSpan AllowedClockSkew = TimeSpan.FromMinutes(5);

    public MasteryUpdateBatch Calculate(
        ReviewPlanGraph plan,
        KnowledgeGraph graph,
        IReadOnlyDictionary<Guid, MasteryState> existing,
        ReviewResultSubmission submission,
        DateTimeOffset now)
    {
        Validate(plan, graph, submission, existing, now);
        var allowed = plan.Purpose == ReviewPlanPurpose.Assessment
            ? plan.Nodes
                .Where(node => node.IsQuestionTarget)
                .Select(node => node.PointId)
                .ToHashSet()
            : plan.Nodes.Select(node => node.PointId).ToHashSet();
        if (submission.Answers.Any(answer => !allowed.Contains(answer.KnowledgePointId)))
        {
            throw new KnowledgeServiceException(
                422,
                "ANSWER_POINT_NOT_IN_PLAN",
                "结果包含不属于该计划可作答范围的知识点。");
        }

        var directPointIds = submission.Answers
            .Select(answer => answer.KnowledgePointId)
            .ToHashSet();
        var states = new Dictionary<Guid, MasteryState>();
        var changes = new List<AppliedMasteryChange>();

        foreach (var answer in submission.Answers)
        {
            var current = existing.GetValueOrDefault(answer.KnowledgePointId) ??
                          MasteryState.Initial(
                              plan.OwnerUserId,
                              answer.KnowledgePointId,
                              graph.CreatedAt);
            var updated = Sm2Scheduler.Apply(
                current,
                answer.Quality,
                answer.Correct,
                answer.UsedHint,
                submission.CompletedAt,
                plan.Purpose.ToString().ToUpperInvariant());
            states[answer.KnowledgePointId] = updated;
            changes.Add(new AppliedMasteryChange(
                answer.KnowledgePointId,
                current.Score,
                updated.Score,
                true,
                updated.Reason));
        }

        if (plan.Purpose == ReviewPlanPurpose.Assessment)
        {
            // Ancestor inference is deliberately assessment-only and is
            // bounded by MaximumPositiveInferenceDepth.
            AddPositivePrerequisiteEvidence(
                graph,
                plan,
                submission,
                existing,
                directPointIds,
                states,
                changes,
                submission.CompletedAt);
        }

        return new MasteryUpdateBatch(states.Values.ToArray(), changes);
    }

    private static void AddPositivePrerequisiteEvidence(
        KnowledgeGraph graph,
        ReviewPlanGraph plan,
        ReviewResultSubmission submission,
        IReadOnlyDictionary<Guid, MasteryState> existing,
        IReadOnlySet<Guid> directPointIds,
        IDictionary<Guid, MasteryState> states,
        ICollection<AppliedMasteryChange> changes,
        DateTimeOffset completedAt)
    {
        var analyzer = new DependencyPathAnalyzer(graph);
        var bestEvidence = new Dictionary<Guid, InferredEvidence>();

        foreach (var answer in submission.Answers.Where(answer =>
                     answer.Correct &&
                     answer.Quality >= 4 &&
                     !answer.UsedHint))
        {
            foreach (var ancestor in analyzer.BestPrerequisiteEvidence(
                         answer.KnowledgePointId,
                         MaximumPositiveInferenceDepth,
                         depthDecay: 1))
            {
                if (directPointIds.Contains(ancestor.Key) ||
                    plan.Nodes.All(node => node.PointId != ancestor.Key))
                {
                    continue;
                }

                var baseline = existing.GetValueOrDefault(ancestor.Key) ??
                               MasteryState.Initial(
                                   plan.OwnerUserId,
                                   ancestor.Key,
                                   graph.CreatedAt);
                if (baseline.LastReviewedAt > completedAt)
                {
                    // Old indirect evidence must never change an ancestor that
                    // has since received newer direct evidence.
                    continue;
                }

                var observedScore = answer.Quality / 5d * 100;
                var actualIncrease = Math.Min(
                    MaximumInferredScoreIncrease,
                    Math.Max(
                        0,
                        (observedScore - baseline.Score) *
                        ancestor.Value.Strength));
                var evidence = new InferredEvidence(
                    actualIncrease,
                    ancestor.Value.Strength,
                    ancestor.Value.Depth);
                if (!bestEvidence.TryGetValue(ancestor.Key, out var current) ||
                    evidence.ActualIncrease > current.ActualIncrease ||
                    (Math.Abs(
                         evidence.ActualIncrease -
                         current.ActualIncrease) < 1e-12 &&
                     evidence.PathStrength > current.PathStrength))
                {
                    // A shared prerequisite receives the strongest path once.
                    // Multiple upstream paths are deliberately not summed.
                    bestEvidence[ancestor.Key] = evidence;
                }
            }
        }

        foreach (var pair in bestEvidence)
        {
            var current = existing.GetValueOrDefault(pair.Key) ??
                          MasteryState.Initial(
                              plan.OwnerUserId,
                              pair.Key,
                              graph.CreatedAt);
            var increase = pair.Value.ActualIncrease;
            if (increase <= 0)
            {
                continue;
            }

            var updated = current with
            {
                Score = Math.Round(
                    Math.Clamp(current.Score + increase, 0, 100),
                    2),
                Reason =
                    $"INFERRED_POSITIVE:depth={pair.Value.Depth};" +
                    $"strength={pair.Value.PathStrength:F6}",
                Version = current.Version + 1
            };
            states[pair.Key] = updated;
            changes.Add(new AppliedMasteryChange(
                pair.Key,
                current.Score,
                updated.Score,
                false,
                updated.Reason));
        }
    }

    private static void Validate(
        ReviewPlanGraph plan,
        KnowledgeGraph graph,
        ReviewResultSubmission submission,
        IReadOnlyDictionary<Guid, MasteryState> existing,
        DateTimeOffset now)
    {
        if (submission.SubmissionId == Guid.Empty ||
            submission.IdempotencyKey == Guid.Empty ||
            submission.UserId != plan.OwnerUserId ||
            submission.ReviewPlanId != Guid.Empty &&
            submission.ReviewPlanId != plan.ReviewPlanId)
        {
            throw new KnowledgeServiceException(
                422,
                "REVIEW_EVIDENCE_IDENTITY_INVALID",
                "resultId、idempotencyKey 或 userId 无效。");
        }

        if (!string.Equals(
                submission.SnapshotVersion,
                plan.SnapshotVersion,
                StringComparison.Ordinal))
        {
            throw new KnowledgeServiceException(
                409,
                "SNAPSHOT_VERSION_CONFLICT",
                "提交结果使用的图谱快照与计划不一致。");
        }

        if (plan.Status != ReviewPlanStatus.Open)
        {
            throw new KnowledgeServiceException(
                409,
                "REVIEW_PLAN_NOT_OPEN",
                "复习计划已结束或过期。");
        }

        if (submission.CompletedAt < plan.CreatedAt - AllowedClockSkew ||
            submission.CompletedAt > plan.ExpiresAt ||
            submission.CompletedAt > now + AllowedClockSkew)
        {
            throw new KnowledgeServiceException(
                422,
                "REVIEW_COMPLETION_TIME_INVALID",
                "completedAt 不在计划有效期内或超出允许的时钟偏差。");
        }

        if (plan.GraphId != graph.GraphId || plan.GraphVersion != graph.Version)
        {
            throw new KnowledgeServiceException(
                409,
                "GRAPH_VERSION_CONFLICT",
                "复习计划绑定的图谱版本不一致。");
        }

        if (submission.Answers.Count is < 1 or > 100 ||
            submission.Answers.Select(answer => answer.AttemptId).Distinct().Count() !=
            submission.Answers.Count ||
            submission.Answers.Select(answer => answer.KnowledgePointId).Distinct().Count() !=
            submission.Answers.Count)
        {
            throw new KnowledgeServiceException(
                400,
                "ANSWER_RESULTS_INVALID",
                "答题结果为空、重复或超过数量限制。");
        }

        if (submission.Answers.Any(answer =>
                answer.UsedHint && answer.Quality > 3))
        {
            throw new KnowledgeServiceException(
                422,
                "REVIEW_EVIDENCE_INVALID",
                "使用提示的答案 quality 不得高于 3。");
        }

        if (submission.Answers.Any(answer =>
                answer.Quality is < 0 or > 5 ||
                answer.DurationSeconds is < 0 or > 86_400 ||
                string.IsNullOrWhiteSpace(answer.AttemptId) ||
                (answer.Correct && answer.Quality < 3) ||
                (!answer.Correct && answer.Quality >= 3)))
        {
            throw new KnowledgeServiceException(
                422,
                "ANSWER_EVIDENCE_INCONSISTENT",
                "quality、correct、耗时或 attemptId 不一致。");
        }

        var stalePoint = submission.Answers
            .Select(answer => existing.GetValueOrDefault(
                answer.KnowledgePointId))
            .FirstOrDefault(state =>
                state?.LastReviewedAt > submission.CompletedAt);
        if (stalePoint is not null)
        {
            throw new KnowledgeServiceException(
                409,
                "STALE_REVIEW_EVIDENCE",
                "该结果早于知识点现有的直接复习记录，不能倒序覆盖掌握度。");
        }
    }

    private sealed record InferredEvidence(
        double ActualIncrease,
        double PathStrength,
        int Depth);
}
