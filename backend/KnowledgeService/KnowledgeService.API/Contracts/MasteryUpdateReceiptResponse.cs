using KnowledgeService.Domain.Common;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.API.Contracts;

public sealed record MasteryUpdateReceiptResponse(
    Guid ResultId,
    Guid ReviewPlanId,
    string Status,
    IReadOnlyList<Guid> UpdatedPointIds,
    IReadOnlyList<AppliedMasteryChange> Changes,
    int IgnoredEvidenceCount,
    string AlgorithmVersion,
    DateTimeOffset ProcessedAt)
{
    public static MasteryUpdateReceiptResponse From(
        ReviewResultReceipt receipt) =>
        new(
            receipt.SubmissionId,
            receipt.ReviewPlanId,
            receipt.Duplicate ? "DUPLICATE" : "ACCEPTED",
            receipt.Changes
                .Select(change => change.PointId)
                .Distinct()
                .ToArray(),
            receipt.Changes,
            0,
            KnowledgeAlgorithmVersions.Mastery,
            receipt.AppliedAt);
}
