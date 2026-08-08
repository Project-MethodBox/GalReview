using KnowledgeService.Application.Exceptions;
using KnowledgeService.Domain.Common;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.Application.Planning;

public sealed class LearningPlanner
{
    private const double OutsideChapterFraction = 0.30;

    public ReviewPlanGraph Create(
        KnowledgeGraph graph,
        IReadOnlyDictionary<Guid, MasteryState> mastery,
        LearningPlanOptions options,
        DateTimeOffset now)
    {
        Validate(options);
        var requestedChapters = ResolveChapters(graph, options.ChapterIds);
        var requestedChapterSet = requestedChapters.ToHashSet();
        var pointById = graph.Points.ToDictionary(point => point.PointId);
        var targets = graph.Points
            .Where(point => requestedChapterSet.Contains(point.ChapterId))
            .OrderBy(point => point.Ordinal)
            .ThenBy(point => point.PointId)
            .ToArray();
        if (targets.Length == 0)
        {
            throw new KnowledgeServiceException(
                422,
                "LEARNING_SCOPE_EMPTY",
                "所选章节中没有可复习知识点。");
        }

        var riskByTarget = targets.ToDictionary(
            point => point.PointId,
                point => ReviewNeedModel.DueNeed(
                mastery.GetValueOrDefault(point.PointId),
                now));
        var analyzer = new DependencyPathAnalyzer(graph);
        var evidenceByTarget = targets.ToDictionary(
            point => point.PointId,
            point => analyzer.BestPrerequisiteEvidence(
                point.PointId,
                options.MaximumDependencyDepth,
                depthDecay: 1));
        var globalPriorities = BuildGlobalPriorities(
            targets,
            evidenceByTarget,
            riskByTarget);

        var candidates = BuildPathBundles(
            targets,
            evidenceByTarget,
            riskByTarget);
        var selection = SelectPathClosedNodes(
            candidates,
            pointById,
            requestedChapterSet,
            options.MaximumPoints);
        var selectedPointIds = selection.PointIds;
        if (selectedPointIds.Count == 0)
        {
            // Validation guarantees at least one target and one available slot.
            selectedPointIds.Add(targets[0].PointId);
        }

        var selectedTargetIds = targets
            .Where(target => selectedPointIds.Contains(target.PointId))
            .Select(target => target.PointId)
            .ToHashSet();
        var outsidePointIds = selectedPointIds
            .Where(pointId =>
                !requestedChapterSet.Contains(pointById[pointId].ChapterId))
            .ToHashSet();
        var normalizedWeights = PlanWeightNormalizer.Normalize(
            selectedPointIds.ToDictionary(
                pointId => pointId,
                pointId => globalPriorities.GetValueOrDefault(pointId)),
            outsidePointIds);

        var nodes = selectedPointIds
            .Select(pointId => BuildPlanNode(
                pointById[pointId],
                selectedPointIds,
                selectedTargetIds,
                requestedChapterSet,
                selection.Bundles,
                mastery,
                normalizedWeights))
            .OrderByDescending(node => node.IsQuestionTarget)
            .ThenByDescending(node => node.Weight)
            .ThenBy(node => pointById[node.PointId].Ordinal)
            .ThenBy(node => node.PointId)
            .ToArray();

        var totalRisk = Math.Max(riskByTarget.Values.Sum(), 1e-12);
        var selectedRisk = selectedTargetIds.Sum(
            pointId => riskByTarget[pointId]);
        var planId = Guid.NewGuid();
        var edges = PlanGraphFactory.EdgesFor(
            graph,
            selectedPointIds);
        var status = ReviewPlanStatus.Open;
        var estimatedCoverage = Math.Round(selectedRisk / totalRisk, 4);
        var createdAt = now;
        var expiresAt = now.AddDays(7);
        var snapshotVersion = PlanGraphFactory.SnapshotVersion(
            planId,
            graph,
            ReviewPlanPurpose.Learning,
            KnowledgeAlgorithmVersions.LearningPlanner,
            requestedChapters,
            nodes,
            edges,
            estimatedCoverage,
            createdAt,
            expiresAt);
        return new ReviewPlanGraph(
            planId,
            graph.GraphId,
            graph.OwnerUserId,
            graph.Version,
            snapshotVersion,
            ReviewPlanPurpose.Learning,
            status,
            requestedChapters,
            nodes,
            edges,
            estimatedCoverage,
            KnowledgeAlgorithmVersions.LearningPlanner,
            createdAt,
            expiresAt);
    }

    private static IReadOnlyDictionary<Guid, double> BuildGlobalPriorities(
        IReadOnlyList<KnowledgePoint> targets,
        IReadOnlyDictionary<
            Guid,
            IReadOnlyDictionary<Guid, PathEvidence>> evidenceByTarget,
        IReadOnlyDictionary<Guid, double> riskByTarget)
    {
        var priorities = new Dictionary<Guid, double>();
        foreach (var target in targets)
        {
            priorities[target.PointId] = Math.Max(
                priorities.GetValueOrDefault(target.PointId),
                riskByTarget[target.PointId]);
            foreach (var evidence in evidenceByTarget[target.PointId])
            {
                priorities[evidence.Key] = Math.Max(
                    priorities.GetValueOrDefault(evidence.Key),
                    riskByTarget[target.PointId] *
                    evidence.Value.Strength);
            }
        }

        return priorities;
    }

    private static IReadOnlyList<PathBundle> BuildPathBundles(
        IReadOnlyList<KnowledgePoint> targets,
        IReadOnlyDictionary<
            Guid,
            IReadOnlyDictionary<Guid, PathEvidence>> evidenceByTarget,
        IReadOnlyDictionary<Guid, double> riskByTarget)
    {
        var bundles = new List<PathBundle>();
        foreach (var target in targets)
        {
            bundles.Add(new PathBundle(
                target.PointId,
                target.PointId,
                new[] { target.PointId },
                new Dictionary<Guid, double>
                {
                    [target.PointId] = riskByTarget[target.PointId]
                }));
            bundles.AddRange(evidenceByTarget[target.PointId]
                .Where(pair => pair.Value.Strength > 0)
                .Select(pair => new PathBundle(
                    pair.Key,
                    target.PointId,
                    pair.Value.PathPointIds,
                    pair.Value.PathPointIds.ToDictionary(
                        pointId => pointId,
                        pointId => pointId == target.PointId
                            ? riskByTarget[target.PointId]
                            : riskByTarget[target.PointId] *
                              evidenceByTarget[target.PointId][pointId]
                                  .Strength))));
        }

        return bundles
            .OrderByDescending(bundle =>
                bundle.Contributions.Values.Average())
            .ThenBy(bundle => bundle.PathPointIds.Count)
            .ThenBy(bundle => bundle.TargetPointId)
            .ThenBy(bundle => bundle.AnchorPointId)
            .ToArray();
    }

    private static SelectionResult SelectPathClosedNodes(
        IReadOnlyList<PathBundle> candidates,
        IReadOnlyDictionary<Guid, KnowledgePoint> pointById,
        IReadOnlySet<Guid> requestedChapterIds,
        int maximumPoints)
    {
        var selected = new HashSet<Guid>();
        var coveredContributions = new Dictionary<Guid, double>();
        var selectedBundles = new List<PathBundle>();
        var maximumOutsidePoints = (int)Math.Floor(
            maximumPoints * OutsideChapterFraction);

        while (selected.Count < maximumPoints)
        {
            var feasible = candidates
                .Select(bundle =>
                {
                    var newPointIds = bundle.PathPointIds
                        .Where(pointId => !selected.Contains(pointId))
                        .Distinct()
                        .ToArray();
                    var proposed = bundle.Contributions.ToDictionary(
                        pair => pair.Key,
                        pair => pair.Value);
                    var marginal = proposed.Sum(pair =>
                        Math.Max(
                            0,
                            pair.Value -
                            coveredContributions.GetValueOrDefault(pair.Key)));
                    return new BundleAddition(
                        bundle,
                        newPointIds,
                        proposed,
                        marginal);
                })
                .Where(addition =>
                    addition.NewPointIds.Count > 0 ||
                    addition.MarginalCoverage > 1e-12)
                .Where(addition =>
                    selected.Count + addition.NewPointIds.Count <=
                    maximumPoints)
                .Where(addition =>
                {
                    var existingOutside = selected.Count(pointId =>
                        !requestedChapterIds.Contains(
                            pointById[pointId].ChapterId));
                    var newOutside = addition.NewPointIds.Count(pointId =>
                        !requestedChapterIds.Contains(
                            pointById[pointId].ChapterId));
                    return existingOutside + newOutside <=
                           maximumOutsidePoints;
                })
                .OrderByDescending(addition => addition.Density)
                .ThenByDescending(addition => addition.MarginalCoverage)
                .ThenBy(addition => addition.NewPointIds.Count)
                .ThenBy(addition => addition.Bundle.TargetPointId)
                .ThenBy(addition => addition.Bundle.AnchorPointId)
                .FirstOrDefault();
            if (feasible is null)
            {
                break;
            }

            if (feasible.MarginalCoverage <= 1e-12 &&
                selected.Count > 0)
            {
                break;
            }

            foreach (var pointId in feasible.NewPointIds)
            {
                selected.Add(pointId);
            }

            foreach (var contribution in feasible.ProposedContributions)
            {
                coveredContributions[contribution.Key] = Math.Max(
                    coveredContributions.GetValueOrDefault(contribution.Key),
                    contribution.Value);
            }

            selectedBundles.Add(feasible.Bundle);
        }

        return new SelectionResult(
            selected,
            selectedBundles);
    }

    private static PlanNode BuildPlanNode(
        KnowledgePoint point,
        IReadOnlySet<Guid> selectedPointIds,
        IReadOnlySet<Guid> selectedTargetIds,
        IReadOnlySet<Guid> requestedChapterIds,
        IReadOnlyList<PathBundle> selectedBundles,
        IReadOnlyDictionary<Guid, MasteryState> mastery,
        IReadOnlyDictionary<Guid, double> normalizedWeights)
    {
        var bundleSupports = selectedBundles
            .Where(bundle =>
                selectedTargetIds.Contains(bundle.TargetPointId))
            .Select(bundle =>
            {
                var index = bundle.PathPointIds
                    .ToList()
                    .IndexOf(point.PointId);
                return index < 0
                    ? null
                    : new TargetSupport(
                        bundle.TargetPointId,
                        bundle.Contributions[point.PointId],
                        bundle.PathPointIds.Skip(index).ToArray());
            })
            .Where(support => support is not null)
            .Select(support => support!)
            .Append(selectedTargetIds.Contains(point.PointId)
                ? new TargetSupport(
                    point.PointId,
                    1,
                    new[] { point.PointId })
                : null)
            .Where(support => support is not null)
            .Select(support => support!)
            .Where(support => support.PathPointIds.All(
                selectedPointIds.Contains))
            .GroupBy(support => support.TargetPointId)
            .Select(group => group
                .OrderByDescending(support => support.Contribution)
                .ThenBy(support => support.PathPointIds.Count)
                .First())
            .OrderByDescending(support => support.Contribution)
            .ThenBy(support => support.TargetPointId)
            .ToArray();
        var covers = bundleSupports
            .SelectMany(support => support.PathPointIds)
            .Distinct()
            .OrderBy(pointId => pointId)
            .ToArray();
        var isTarget = selectedTargetIds.Contains(point.PointId);
        return new PlanNode(
            point.PointId,
            point.ChapterId,
            point.Title,
            point.Summary,
            point.Tags,
            mastery.GetValueOrDefault(point.PointId)?.Score ?? 0,
            normalizedWeights[point.PointId],
            isTarget,
            !requestedChapterIds.Contains(point.ChapterId),
            bundleSupports
                .Select(support => support.PathPointIds.Count - 1)
                .DefaultIfEmpty(0)
                .Min(),
            covers.Length == 0 ? new[] { point.PointId } : covers,
            bundleSupports
                .Select(support => support.TargetPointId)
                .Distinct()
                .OrderBy(pointId => pointId)
                .ToArray(),
            isTarget
                ? "REQUESTED_CHAPTER_FORGETTING_RISK"
                : "MAX_PRODUCT_PREREQUISITE_PATH");
    }

    private static IReadOnlyList<Guid> ResolveChapters(
        KnowledgeGraph graph,
        IReadOnlyList<Guid> requested)
    {
        var available = graph.Chapters
            .Select(chapter => chapter.ChapterId)
            .ToHashSet();
        var result = requested.Distinct().ToArray();
        if (result.Length == 0)
        {
            throw new KnowledgeServiceException(
                400,
                "LEARNING_CHAPTERS_REQUIRED",
                "学习计划必须由上游明确提供至少一个章节。");
        }

        if (result.Any(chapterId => !available.Contains(chapterId)))
        {
            throw new KnowledgeServiceException(
                422,
                "CHAPTER_NOT_IN_GRAPH",
                "请求包含不属于当前图谱的章节。");
        }

        return result;
    }

    private static void Validate(LearningPlanOptions options)
    {
        if (options.ChapterIds.Count is < 1 or > 100 ||
            options.MaximumPoints is < 1 or > 1000 ||
            options.MaximumDependencyDepth is < 0 or > 8)
        {
            throw new KnowledgeServiceException(
                400,
                "LEARNING_OPTIONS_INVALID",
                "学习计划参数超出允许范围。");
        }
    }

    private sealed record PathBundle(
        Guid AnchorPointId,
        Guid TargetPointId,
        IReadOnlyList<Guid> PathPointIds,
        IReadOnlyDictionary<Guid, double> Contributions);

    private sealed record BundleAddition(
        PathBundle Bundle,
        IReadOnlyList<Guid> NewPointIds,
        IReadOnlyDictionary<Guid, double> ProposedContributions,
        double MarginalCoverage)
    {
        public double Density => NewPointIds.Count == 0
            ? double.PositiveInfinity
            : MarginalCoverage / NewPointIds.Count;
    }

    private sealed record TargetSupport(
        Guid TargetPointId,
        double Contribution,
        IReadOnlyList<Guid> PathPointIds);

    private sealed record SelectionResult(
        HashSet<Guid> PointIds,
        IReadOnlyList<PathBundle> Bundles);
}
