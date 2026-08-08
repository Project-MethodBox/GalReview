using KnowledgeService.Application.Exceptions;
using KnowledgeService.Domain.Common;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.Application.Planning;

public sealed class AssessmentPlanner
{
    public ReviewPlanGraph Create(
        KnowledgeGraph graph,
        IReadOnlyDictionary<Guid, MasteryState> mastery,
        AssessmentPlanOptions options,
        DateTimeOffset now)
    {
        Validate(options);
        var requestedChapters = ResolveChapters(graph, options.ChapterIds);
        var requestedChapterSet = requestedChapters.ToHashSet();
        var targets = graph.Points
            .Where(point => requestedChapterSet.Contains(point.ChapterId))
            .OrderBy(point => point.Ordinal)
            .ThenBy(point => point.PointId)
            .ToArray();
        if (targets.Length == 0)
        {
            throw new KnowledgeServiceException(
                422,
                "ASSESSMENT_SCOPE_EMPTY",
                "所选章节中没有可测试知识点。");
        }

        var pathAnalyzer = new DependencyPathAnalyzer(graph);
        var evidenceByCandidate = targets.ToDictionary(
            point => point.PointId,
            point => BuildEvidence(
                pathAnalyzer,
                point.PointId,
                options.MaximumInferenceDepth));
        var universe = evidenceByCandidate.Values
            .SelectMany(evidence => evidence.Keys)
            .Append(targets[0].PointId)
            .ToHashSet();
        foreach (var target in targets)
        {
            universe.Add(target.PointId);
        }

        var need = graph.Points
            .Where(point => universe.Contains(point.PointId))
            .ToDictionary(
                point => point.PointId,
                point => ReviewNeedModel.DueNeed(
                    mastery.GetValueOrDefault(point.PointId),
                    now));
        var totalNeed = Math.Max(need.Values.Sum(), 1e-9);
        var coveredConfidence = universe.ToDictionary(pointId => pointId, _ => 0d);
        var selected = new List<SelectedQuestion>();

        while (selected.Count < Math.Min(options.MaximumQuestions, targets.Length))
        {
            var candidate = targets
                .Where(point => selected.All(item => item.Point.PointId != point.PointId))
                .Select(point =>
                {
                    var evidence = evidenceByCandidate[point.PointId];
                    var gain = evidence.Sum(pair =>
                        need.GetValueOrDefault(pair.Key, 1) *
                        Math.Max(
                            0,
                            pair.Value.Strength -
                            coveredConfidence.GetValueOrDefault(pair.Key)));
                    return new SelectedQuestion(point, gain, evidence);
                })
                .OrderByDescending(item => item.Gain)
                .ThenBy(item => item.Point.Ordinal)
                .ThenBy(item => item.Point.PointId)
                .FirstOrDefault();

            if (candidate is null ||
                candidate.Gain <= 1e-9 && selected.Count > 0)
            {
                break;
            }

            selected.Add(candidate);
            foreach (var evidence in candidate.Evidence)
            {
                coveredConfidence[evidence.Key] = Math.Max(
                    coveredConfidence.GetValueOrDefault(evidence.Key),
                    evidence.Value.Strength);
            }

            var coverage = coveredConfidence.Sum(pair =>
                need.GetValueOrDefault(pair.Key, 1) * pair.Value) / totalNeed;
            if (coverage >= options.TargetCoverage)
            {
                break;
            }
        }

        var selectedPointIds = selected
            .Select(item => item.Point.PointId)
            .ToHashSet();
        var includedPointIds = selected
            .SelectMany(item => item.Evidence.Keys)
            .Concat(selectedPointIds)
            .ToHashSet();
        var pointById = graph.Points.ToDictionary(point => point.PointId);
        var rawWeights = selected.ToDictionary(
            item => item.Point.PointId,
            item => Math.Max(item.Gain, 1e-6));
        var selectedWeightTotal = rawWeights.Values.Sum();
        var nodes = includedPointIds
            .Select(pointId =>
            {
                var point = pointById[pointId];
                var question = selected.FirstOrDefault(
                    item => item.Point.PointId == pointId);
                var supportedQuestions = selected
                    .Where(item => item.Evidence.ContainsKey(pointId))
                    .Select(item => item.Point.PointId)
                    .Distinct()
                    .ToArray();
                var depth = selected
                    .Where(item => item.Evidence.ContainsKey(pointId))
                    .Select(item => item.Evidence[pointId].Depth)
                    .DefaultIfEmpty(0)
                    .Min();
                return new PlanNode(
                    point.PointId,
                    point.ChapterId,
                    point.Title,
                    point.Summary,
                    point.Tags,
                    mastery.GetValueOrDefault(point.PointId)?.Score ?? 0,
                    question is null ? 0 : rawWeights[pointId] / selectedWeightTotal,
                    question is not null,
                    !requestedChapterSet.Contains(point.ChapterId),
                    depth,
                    question?.Evidence.Keys.OrderBy(id => id).ToArray() ??
                    Array.Empty<Guid>(),
                    supportedQuestions,
                    question is null
                        ? "PREREQUISITE_EVIDENCE_PATH"
                        : "MAX_UNCOVERED_DEPENDENCY_GAIN");
            })
            .OrderByDescending(node => node.IsQuestionTarget)
            .ThenByDescending(node => node.Weight)
            .ThenBy(node => pointById[node.PointId].Ordinal)
            .ThenBy(node => node.PointId)
            .ToArray();

        var coverageValue = coveredConfidence.Sum(pair =>
            need.GetValueOrDefault(pair.Key, 1) * pair.Value) / totalNeed;
        var planId = Guid.NewGuid();
        var edges = PlanGraphFactory.EdgesFor(
            graph,
            includedPointIds);
        var status = ReviewPlanStatus.Open;
        var estimatedCoverage = Math.Round(coverageValue, 4);
        var createdAt = now;
        var expiresAt = now.AddDays(7);
        var snapshotVersion = PlanGraphFactory.SnapshotVersion(
            planId,
            graph,
            ReviewPlanPurpose.Assessment,
            KnowledgeAlgorithmVersions.AssessmentPlanner,
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
            ReviewPlanPurpose.Assessment,
            status,
            requestedChapters,
            nodes,
            edges,
            estimatedCoverage,
            KnowledgeAlgorithmVersions.AssessmentPlanner,
            createdAt,
            expiresAt);
    }

    private static IReadOnlyDictionary<Guid, PathEvidence> BuildEvidence(
        DependencyPathAnalyzer analyzer,
        Guid pointId,
        int maximumDepth)
    {
        var evidence = analyzer
            .BestPrerequisiteEvidence(pointId, maximumDepth, 1)
            .ToDictionary(pair => pair.Key, pair => pair.Value);
        evidence[pointId] = new PathEvidence(1, 0, new[] { pointId });
        return evidence;
    }

    private static IReadOnlyList<Guid> ResolveChapters(
        KnowledgeGraph graph,
        IReadOnlyList<Guid> requested)
    {
        var available = graph.Chapters.Select(chapter => chapter.ChapterId).ToHashSet();
        var result = requested.Count == 0
            ? graph.Chapters.Select(chapter => chapter.ChapterId).ToArray()
            : requested.Distinct().ToArray();
        if (result.Any(chapterId => !available.Contains(chapterId)))
        {
            throw new KnowledgeServiceException(
                422,
                "CHAPTER_NOT_IN_GRAPH",
                "请求包含不属于当前图谱的章节。");
        }

        return result;
    }

    private static void Validate(AssessmentPlanOptions options)
    {
        if (options.ChapterIds.Count > 100 ||
            options.MaximumQuestions is < 1 or > 50 ||
            options.TargetCoverage is < 0.25 or > 1 ||
            options.MaximumInferenceDepth is < 0 or > 8)
        {
            throw new KnowledgeServiceException(
                400,
                "ASSESSMENT_OPTIONS_INVALID",
                "测试计划参数超出允许范围。");
        }
    }

    private sealed record SelectedQuestion(
        KnowledgePoint Point,
        double Gain,
        IReadOnlyDictionary<Guid, PathEvidence> Evidence);
}
