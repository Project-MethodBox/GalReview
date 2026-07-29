namespace KnowledgeService.Domain.Reviews;

public sealed record AppliedMasteryChange(
    Guid PointId,
    double PreviousScore,
    double NewScore,
    bool DirectEvidence,
    string Reason);
