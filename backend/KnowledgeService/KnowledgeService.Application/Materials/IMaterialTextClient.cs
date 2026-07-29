using KnowledgeService.Domain.Materials;

namespace KnowledgeService.Application.Materials;

public interface IMaterialTextClient
{
    Task<MaterialTextDocument> GetExtractedTextAsync(
        Guid materialId,
        string correlationId,
        CancellationToken cancellationToken);
}
