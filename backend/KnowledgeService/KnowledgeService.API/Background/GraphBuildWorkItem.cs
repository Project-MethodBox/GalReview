namespace KnowledgeService.API.Background;

internal sealed record GraphBuildWorkItem(
    Guid BuildId,
    string CorrelationId);
