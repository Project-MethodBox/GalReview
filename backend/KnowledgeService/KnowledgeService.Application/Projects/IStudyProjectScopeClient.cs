namespace KnowledgeService.Application.Projects;

public interface IStudyProjectScopeClient
{
    Task ValidateMaterialScopeAsync(
        Guid studyProjectId,
        Guid materialId,
        Guid ownerUserId,
        string correlationId,
        CancellationToken cancellationToken);
}
