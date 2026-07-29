using KnowledgeService.Domain.Mastery;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.Application.Mastery;

public sealed record MasteryUpdateBatch(
    IReadOnlyList<MasteryState> States,
    IReadOnlyList<AppliedMasteryChange> Changes);
