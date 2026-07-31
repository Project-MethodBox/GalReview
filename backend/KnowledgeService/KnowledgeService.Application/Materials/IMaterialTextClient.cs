using KnowledgeService.Domain.Materials;

namespace KnowledgeService.Application.Materials;

public interface IMaterialTextClient
{
    Task<MaterialTextDocument> GetExtractedTextAsync(
        Guid materialId,
        Guid expectedOwnerUserId,
        string correlationId,
        CancellationToken cancellationToken);
}
