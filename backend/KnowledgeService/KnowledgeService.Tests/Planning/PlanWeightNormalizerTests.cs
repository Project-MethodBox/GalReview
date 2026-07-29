using System.Reflection;
using KnowledgeService.Application.Planning;

namespace KnowledgeService.Tests.Planning;

public sealed class PlanWeightNormalizerTests
{
    [Fact]
    public void Jointly_enforces_outside_group_and_node_caps_when_feasible()
    {
        var insideA = Guid.Parse("30000000-0000-0000-0000-000000000001");
        var insideB = Guid.Parse("30000000-0000-0000-0000-000000000002");
        var insideC = Guid.Parse("30000000-0000-0000-0000-000000000003");
        var outsideA = Guid.Parse("30000000-0000-0000-0000-000000000004");
        var outsideB = Guid.Parse("30000000-0000-0000-0000-000000000005");
        var rawWeights = new Dictionary<Guid, double>
        {
            [insideA] = 0.65,
            [insideB] = 0.08,
            [insideC] = 0.07,
            [outsideA] = 0.15,
            [outsideB] = 0.05
        };
        var outside = new HashSet<Guid> { outsideA, outsideB };

        var weights = Normalize(rawWeights, outside);

        Assert.Equal(1, weights.Values.Sum(), 6);
        Assert.True(
            outside.Sum(pointId => weights[pointId]) <= 0.300001,
            "The outside group must remain capped after node-cap redistribution.");
        Assert.All(
            weights,
            pair => Assert.InRange(pair.Value, 0, 0.250001));
        Assert.Equal(0.25, weights[insideA], 6);
        Assert.Equal(0.24, weights[insideB], 6);
        Assert.Equal(0.21, weights[insideC], 6);
        Assert.Equal(0.225, weights[outsideA], 6);
        Assert.Equal(0.075, weights[outsideB], 6);
    }

    [Theory]
    [InlineData(1, 1.0)]
    [InlineData(2, 0.5)]
    [InlineData(3, 0.333334)]
    [InlineData(4, 0.250001)]
    public void Relaxes_node_cap_only_to_the_minimum_feasible_value(
        int nodeCount,
        double expectedMaximum)
    {
        var raw = Enumerable.Range(1, nodeCount)
            .ToDictionary(
                index => Guid.Parse(
                    $"31000000-0000-0000-0000-{index:D12}"),
                index => (double)index);

        var weights = Normalize(raw, new HashSet<Guid>());

        Assert.Equal(1, weights.Values.Sum(), 6);
        Assert.All(
            weights,
            pair => Assert.InRange(
                pair.Value,
                0,
                expectedMaximum));
    }

    [Fact]
    public void Projects_globally_when_outside_constraint_is_inactive()
    {
        var insideA = Guid.Parse("32000000-0000-0000-0000-000000000001");
        var insideB = Guid.Parse("32000000-0000-0000-0000-000000000002");
        var insideC = Guid.Parse("32000000-0000-0000-0000-000000000003");
        var outside = Guid.Parse("32000000-0000-0000-0000-000000000004");

        var weights = Normalize(
            new Dictionary<Guid, double>
            {
                [insideA] = 0.70,
                [insideB] = 0.10,
                [insideC] = 0.10,
                [outside] = 0.10
            },
            new HashSet<Guid> { outside });

        Assert.Equal(0.25, weights[insideA], 6);
        Assert.Equal(0.25, weights[insideB], 6);
        Assert.Equal(0.25, weights[insideC], 6);
        Assert.Equal(0.25, weights[outside], 6);
    }

    [Fact]
    public void Rejects_a_plan_with_only_outside_nodes()
    {
        var outside = Guid.Parse(
            "33000000-0000-0000-0000-000000000001");

        var exception = Assert.Throws<TargetInvocationException>(() =>
            Normalize(
                new Dictionary<Guid, double> { [outside] = 1 },
                new HashSet<Guid> { outside }));

        Assert.IsType<InvalidOperationException>(exception.InnerException);
    }

    [Fact]
    public void Projects_an_all_zero_prior_uniformly_within_active_groups()
    {
        var pointIds = Enumerable.Range(1, 5)
            .Select(index => Guid.Parse(
                $"34000000-0000-0000-0000-{index:D12}"))
            .ToArray();
        var outside = new HashSet<Guid> { pointIds[3], pointIds[4] };
        var weights = Normalize(
            pointIds.ToDictionary(pointId => pointId, _ => 0d),
            outside);

        Assert.Equal(1, weights.Values.Sum(), 6);
        Assert.Equal(0.30, outside.Sum(pointId => weights[pointId]), 6);
        Assert.Equal(weights[pointIds[3]], weights[pointIds[4]]);
        Assert.All(
            pointIds.Take(3),
            pointId => Assert.InRange(
                weights[pointId],
                0.233333,
                0.233334));
    }

    [Fact]
    public void Numerical_support_does_not_reverse_positive_prior_order()
    {
        var pointIds = Enumerable.Range(1, 8)
            .Select(index => Guid.Parse(
                $"35000000-0000-0000-0000-{index:D12}"))
            .ToArray();
        var raw = pointIds.ToDictionary(pointId => pointId, _ => 1e-13);
        raw[pointIds[0]] = 1;
        raw[pointIds[7]] = 9e-13;

        var weights = Normalize(raw, new HashSet<Guid>());

        Assert.Equal(1, weights.Values.Sum(), 6);
        Assert.True(weights[pointIds[7]] > weights[pointIds[1]]);
        Assert.All(weights, pair => Assert.True(pair.Value <= 0.250001));
    }

    [Fact]
    public void Subnormal_positive_mass_is_stable_across_insertion_order()
    {
        var zero = Guid.Parse("36000000-0000-0000-0000-000000000001");
        var subnormal = Guid.Parse("36000000-0000-0000-0000-000000000099");
        var low = Guid.Parse("36000000-0000-0000-0000-000000000100");
        var middle = Guid.Parse("36000000-0000-0000-0000-000000000101");
        var high = Guid.Parse("36000000-0000-0000-0000-000000000102");
        var first = new Dictionary<Guid, double>
        {
            [high] = 0.13333333333333416,
            [low] = 0.1333333333333325,
            [middle] = 0.1333333333333333,
            [subnormal] = double.Epsilon,
            [zero] = 0
        };
        var second = new Dictionary<Guid, double>
        {
            [middle] = first[middle],
            [high] = first[high],
            [low] = first[low],
            [subnormal] = first[subnormal],
            [zero] = first[zero]
        };

        var left = Normalize(first, new HashSet<Guid>());
        var right = Normalize(second, new HashSet<Guid>());

        Assert.Equal(
            left.OrderBy(pair => pair.Key),
            right.OrderBy(pair => pair.Key));
        Assert.Equal(0.25, left[subnormal], 6);
        Assert.Equal(0, left[zero], 6);
    }

    private static IReadOnlyDictionary<Guid, double> Normalize(
        IReadOnlyDictionary<Guid, double> rawWeights,
        IReadOnlySet<Guid> outside)
    {
        var type = typeof(AssessmentPlanner).Assembly.GetType(
            "KnowledgeService.Application.Planning.PlanWeightNormalizer",
            throwOnError: true)!;
        var method = type.GetMethod(
            "Normalize",
            BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static)
            ?? throw new InvalidOperationException(
                "PlanWeightNormalizer.Normalize was not found.");
        return (IReadOnlyDictionary<Guid, double>)(method.Invoke(
            null,
            new object[] { rawWeights, outside, 0.30, 0.25 })
            ?? throw new InvalidOperationException(
                "PlanWeightNormalizer.Normalize returned null."));
    }
}
