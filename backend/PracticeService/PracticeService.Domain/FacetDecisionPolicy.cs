namespace PracticeService.Domain;

public sealed record FacetDecision(
    GradingStatus Status,
    RecallOutcome Outcome,
    bool? Correct,
    int? Quality,
    string? AbstainReason);

public static class FacetDecisionPolicy
{
    public const string Version = "facet-sm2-observation-v1";

    public static FacetDecision Decide(
        IReadOnlyList<FacetAssessment> facets,
        bool answerIsBlank)
    {
        if (answerIsBlank)
            return Decided(RecallOutcome.NoRecall, false, 0);

        if (facets.Count == 0)
            return Abstain("RUBRIC_EMPTY");

        if (facets.Any(facet => facet.Verdict == FacetVerdict.Indeterminate))
            return Abstain("FACET_INDETERMINATE");

        if (facets.All(facet => facet.Verdict == FacetVerdict.Entailed))
            return Decided(RecallOutcome.Perfect, true, 5);

        if (facets.Any(facet => facet.Verdict == FacetVerdict.Contradicted))
            return Decided(RecallOutcome.WrongRelated, false, 1);

        if (facets.Any(facet => facet.Verdict == FacetVerdict.Entailed))
            return Decided(RecallOutcome.Partial, false, 2);

        return Decided(RecallOutcome.NoRecall, false, 0);
    }

    public static FacetDecision Exact(bool correct, bool partial = false) =>
        correct
            ? Decided(RecallOutcome.Perfect, true, 5)
            : partial
                ? Decided(RecallOutcome.Partial, false, 2)
                : Decided(RecallOutcome.NoRecall, false, 0);

    public static FacetDecision Abstain(string reason) =>
        new(GradingStatus.Abstained, RecallOutcome.Abstained, null, null, reason);

    private static FacetDecision Decided(RecallOutcome outcome, bool correct, int quality) =>
        new(GradingStatus.Decided, outcome, correct, quality, null);
}
