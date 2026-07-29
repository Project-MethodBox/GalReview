using KnowledgeService.Domain.Builds;

namespace KnowledgeService.Application.Features.Builds;

public sealed record GraphBuildJobCreation(
    GraphBuildJob Job,
    bool Created);
