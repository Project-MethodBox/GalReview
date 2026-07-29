using KnowledgeService.Domain.Graphs;

namespace KnowledgeService.Application.Planning;

internal sealed class DependencyPathAnalyzer
{
    private readonly IReadOnlyDictionary<Guid, IReadOnlyList<KnowledgeRelation>> _incoming;
    private readonly IReadOnlyDictionary<Guid, int> _prerequisiteCounts;

    public DependencyPathAnalyzer(KnowledgeGraph graph)
    {
        var prerequisiteRelations = graph.Relations
            .Where(relation => relation.Type == KnowledgeRelationType.Prerequisite)
            .ToArray();
        _incoming = prerequisiteRelations
            .GroupBy(relation => relation.ToPointId)
            .ToDictionary(
                group => group.Key,
                group => (IReadOnlyList<KnowledgeRelation>)group
                    .OrderByDescending(relation => relation.Confidence)
                    .ThenBy(relation => relation.FromPointId)
                    .ToArray());
        _prerequisiteCounts = prerequisiteRelations
            .GroupBy(relation => relation.ToPointId)
            .ToDictionary(
                group => group.Key,
                group => group
                    .Select(relation => relation.FromPointId)
                    .Distinct()
                    .Count());
    }

    /// <summary>
    /// Returns one maximum-product path for every reachable prerequisite.
    /// State is bounded by depth, so diamond graphs never enumerate all paths.
    /// </summary>
    public IReadOnlyDictionary<Guid, PathEvidence> BestPrerequisiteEvidence(
        Guid targetPointId,
        int maximumDepth,
        double depthDecay)
    {
        var bestByPoint = new Dictionary<Guid, PathEvidence>();
        IReadOnlyDictionary<Guid, PathEvidence> current =
            new Dictionary<Guid, PathEvidence>
            {
                [targetPointId] = new(
                    1,
                    0,
                    new[] { targetPointId })
            };

        for (var depth = 1; depth <= maximumDepth; depth++)
        {
            var next = new Dictionary<Guid, PathEvidence>();
            foreach (var state in current
                         .OrderBy(pair => pair.Key)
                         .Select(pair => (
                             PointId: pair.Key,
                             Evidence: pair.Value)))
            {
                if (!_incoming.TryGetValue(
                        state.PointId,
                        out var incoming))
                {
                    continue;
                }

                var degreeDivisor = Math.Max(
                    1,
                    _prerequisiteCounts.GetValueOrDefault(state.PointId));
                foreach (var relation in incoming)
                {
                    if (state.Evidence.PathPointIds.Contains(
                            relation.FromPointId))
                    {
                        continue;
                    }

                    var strength = state.Evidence.Strength *
                                   Math.Clamp(
                                       relation.Confidence,
                                       0,
                                       1) *
                                   depthDecay /
                                   degreeDivisor;
                    var path = new[] { relation.FromPointId }
                        .Concat(state.Evidence.PathPointIds)
                        .ToArray();
                    var evidence = new PathEvidence(
                        strength,
                        depth,
                        path);
                    if (!next.TryGetValue(
                            relation.FromPointId,
                            out var knownAtDepth) ||
                        IsBetter(evidence, knownAtDepth))
                    {
                        next[relation.FromPointId] = evidence;
                    }

                    if (!bestByPoint.TryGetValue(
                            relation.FromPointId,
                            out var knownForPoint) ||
                        IsBetter(evidence, knownForPoint))
                    {
                        bestByPoint[relation.FromPointId] = evidence;
                    }
                }
            }

            current = next;
            if (current.Count == 0)
            {
                break;
            }
        }

        return bestByPoint;
    }

    private static bool IsBetter(
        PathEvidence candidate,
        PathEvidence current)
    {
        if (candidate.Strength > current.Strength + 1e-12)
        {
            return true;
        }

        if (Math.Abs(candidate.Strength - current.Strength) > 1e-12)
        {
            return false;
        }

        if (candidate.Depth != current.Depth)
        {
            return candidate.Depth < current.Depth;
        }

        for (var index = 0;
             index < candidate.PathPointIds.Count;
             index++)
        {
            var comparison = candidate.PathPointIds[index]
                .CompareTo(current.PathPointIds[index]);
            if (comparison != 0)
            {
                return comparison < 0;
            }
        }

        return false;
    }
}
