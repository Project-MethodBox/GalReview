namespace KnowledgeService.Application.Planning;

internal static class PlanWeightNormalizer
{
    private const long QuantizationScale = 1_000_000;
    private const double PriorSupportFloor = 1e-12;

    public static IReadOnlyDictionary<Guid, double> Normalize(
        IReadOnlyDictionary<Guid, double> rawWeights,
        IReadOnlySet<Guid> outsideRequestedChapters,
        double outsideGroupCap = 0.30,
        double preferredNodeCap = 0.25)
    {
        if (rawWeights.Count == 0)
        {
            return new Dictionary<Guid, double>();
        }

        if (!double.IsFinite(outsideGroupCap) ||
            !double.IsFinite(preferredNodeCap) ||
            outsideGroupCap is < 0 or >= 1 ||
            preferredNodeCap is <= 0 or > 1 ||
            rawWeights.Values.Any(value =>
                !double.IsFinite(value) || value < 0))
        {
            throw new ArgumentOutOfRangeException(
                nameof(rawWeights),
                "Plan weights and caps must define a finite non-negative projection.");
        }

        var outside = rawWeights.Keys
            .Where(outsideRequestedChapters.Contains)
            .OrderBy(pointId => pointId)
            .ToArray();
        var inside = rawWeights.Keys
            .Where(pointId => !outsideRequestedChapters.Contains(pointId))
            .OrderBy(pointId => pointId)
            .ToArray();
        if (inside.Length == 0)
        {
            throw new InvalidOperationException(
                "A learning plan must contain at least one requested-chapter node.");
        }

        // These are the necessary and sufficient capacity bounds for a
        // simplex with a per-node cap and an outside-group upper bound.
        var nodeCap = Math.Max(
            preferredNodeCap,
            Math.Max(
                1d / rawWeights.Count,
                (1 - outsideGroupCap) / inside.Length));
        nodeCap = Math.Ceiling(nodeCap * QuantizationScale) /
                  QuantizationScale;

        var prior = BuildPositivePrior(rawWeights);

        // First solve the KL projection with the node cap only. If the group
        // inequality is inactive, this is already the joint optimum.
        IReadOnlyDictionary<Guid, double> projected = AllocateGroup(
            prior,
            rawWeights.Keys.OrderBy(pointId => pointId).ToArray(),
            1,
            nodeCap);
        var projectedOutsideMass = outside.Sum(pointId =>
            projected.GetValueOrDefault(pointId));

        // If the outside inequality is violated, its KKT multiplier is
        // positive, so the optimum lies at equality. The two groups then
        // have independent capped proportional projections.
        if (projectedOutsideMass > outsideGroupCap + 1e-12)
        {
            var grouped = new Dictionary<Guid, double>();
            foreach (var pair in AllocateGroup(
                         prior,
                         inside,
                         1 - outsideGroupCap,
                         nodeCap))
            {
                grouped[pair.Key] = pair.Value;
            }

            foreach (var pair in AllocateGroup(
                         prior,
                         outside,
                         outsideGroupCap,
                         nodeCap))
            {
                grouped[pair.Key] = pair.Value;
            }

            projected = grouped;
        }

        return Quantize(
            projected,
            outsideRequestedChapters,
            nodeCap,
            outsideGroupCap);
    }

    private static IReadOnlyDictionary<Guid, double> BuildPositivePrior(
        IReadOnlyDictionary<Guid, double> rawWeights)
    {
        var rawTotal = StableSum(
            rawWeights
                .OrderBy(pair => pair.Key)
                .Select(pair => pair.Value));
        if (!double.IsFinite(rawTotal))
        {
            throw new ArgumentOutOfRangeException(
                nameof(rawWeights),
                "The plan-weight prior is too large to normalize.");
        }

        if (rawTotal == 0)
        {
            return rawWeights.ToDictionary(
                pair => pair.Key,
                _ => 1d / rawWeights.Count);
        }

        var normalized = rawWeights.ToDictionary(
            pair => pair.Key,
            pair => pair.Value / rawTotal);
        var minimumPositive = normalized.Values
            .Where(value => value > 0)
            .Min();
        var zeroSupport = Math.Min(
            PriorSupportFloor,
            minimumPositive / (2 * rawWeights.Count));
        var supported = normalized.ToDictionary(
            pair => pair.Key,
            pair => pair.Value > 0 ? pair.Value : zeroSupport);
        var supportedTotal = StableSum(
            supported
                .OrderBy(pair => pair.Key)
                .Select(pair => pair.Value));
        return supported.ToDictionary(
            pair => pair.Key,
            pair => pair.Value / supportedTotal);
    }

    private static IReadOnlyDictionary<Guid, double> AllocateGroup(
        IReadOnlyDictionary<Guid, double> prior,
        IReadOnlyList<Guid> pointIds,
        double targetMass,
        double nodeCap)
    {
        if (pointIds.Count == 0)
        {
            if (targetMass > 1e-12)
            {
                throw new InvalidOperationException(
                    "Plan weight constraints are infeasible for an empty group.");
            }

            return new Dictionary<Guid, double>();
        }

        var result = pointIds.ToDictionary(pointId => pointId, _ => 0d);
        if (targetMass <= 0)
        {
            return result;
        }

        var active = pointIds.OrderBy(pointId => pointId).ToList();
        var remaining = targetMass;
        while (active.Count > 0)
        {
            var priorTotal = StableSum(active.Select(pointId =>
                prior.GetValueOrDefault(pointId)));
            var provisional = active.ToDictionary(
                pointId => pointId,
                pointId => priorTotal > 0
                    ? prior.GetValueOrDefault(pointId) /
                      priorTotal *
                      remaining
                    : remaining / active.Count);
            var capped = provisional
                .Where(pair => pair.Value > nodeCap + 1e-12)
                .Select(pair => pair.Key)
                .ToArray();
            if (capped.Length == 0)
            {
                foreach (var pair in provisional)
                {
                    result[pair.Key] = pair.Value;
                }

                break;
            }

            foreach (var pointId in capped)
            {
                result[pointId] = nodeCap;
                remaining -= nodeCap;
                active.Remove(pointId);
            }
        }

        return result;
    }

    private static IReadOnlyDictionary<Guid, double> Quantize(
        IReadOnlyDictionary<Guid, double> projected,
        IReadOnlySet<Guid> outsideRequestedChapters,
        double nodeCap,
        double outsideGroupCap)
    {
        var nodeCapUnits = (long)Math.Floor(
            nodeCap * QuantizationScale + 1e-9);
        var outsideCapUnits = (long)Math.Floor(
            outsideGroupCap * QuantizationScale + 1e-9);
        var units = projected.ToDictionary(
            pair => pair.Key,
            pair => (long)Math.Floor(
                pair.Value * QuantizationScale + 1e-9));
        var remaining = QuantizationScale - units.Values.Sum();
        var outsideUnits = units
            .Where(pair =>
                outsideRequestedChapters.Contains(pair.Key))
            .Sum(pair => pair.Value);
        var candidates = projected
            .Select(pair => new
            {
                pair.Key,
                Remainder =
                    pair.Value * QuantizationScale - units[pair.Key]
            })
            .OrderByDescending(candidate => candidate.Remainder)
            .ThenBy(candidate => candidate.Key)
            .ToArray();

        while (remaining > 0)
        {
            var changed = false;
            foreach (var candidate in candidates)
            {
                if (remaining == 0)
                {
                    break;
                }

                var isOutside =
                    outsideRequestedChapters.Contains(candidate.Key);
                if (units[candidate.Key] >= nodeCapUnits ||
                    isOutside && outsideUnits >= outsideCapUnits)
                {
                    continue;
                }

                units[candidate.Key]++;
                remaining--;
                changed = true;
                if (isOutside)
                {
                    outsideUnits++;
                }
            }

            if (!changed)
            {
                throw new InvalidOperationException(
                    "Plan weight constraints are numerically infeasible.");
            }
        }

        return units.ToDictionary(
            pair => pair.Key,
            pair => pair.Value / (double)QuantizationScale);
    }

    private static double StableSum(IEnumerable<double> values)
    {
        var sum = 0d;
        var compensation = 0d;
        foreach (var value in values)
        {
            var next = sum + value;
            compensation += Math.Abs(sum) >= Math.Abs(value)
                ? (sum - next) + value
                : (value - next) + sum;
            sum = next;
        }

        return sum + compensation;
    }
}
