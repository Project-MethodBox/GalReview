using PracticeService.Application;
using PracticeService.Domain;
using PracticeService.Persistence;
using Xunit;

namespace PracticeService.Tests.Application;

public sealed class ProjectHandlersTests
{
    [Fact]
    public async Task Project_creation_rejects_a_material_owned_by_another_user()
    {
        var owner = Guid.NewGuid(); var materialOwner = Guid.NewGuid(); var materialId = Guid.NewGuid();
        var handler = new ProjectHandlers(new InMemoryPracticeRepository(), new MaterialGateway(materialOwner, materialId));

        var error = await Assert.ThrowsAsync<PracticeDomainException>(() => handler.Handle(
            new CreateProjectCommand(owner, "项目", "CS", [materialId], null), CancellationToken.None));

        Assert.Equal("RESOURCE_NOT_FOUND", error.Code);
    }

    [Fact]
    public async Task Project_creation_accepts_only_a_ready_text_owned_by_the_user()
    {
        var owner = Guid.NewGuid(); var materialId = Guid.NewGuid(); var repository = new InMemoryPracticeRepository();
        var handler = new ProjectHandlers(repository, new MaterialGateway(owner, materialId));

        var project = await handler.Handle(new CreateProjectCommand(owner, "项目", "CS", [materialId], null), CancellationToken.None);

        Assert.Equal(owner, project.OwnerUserId);
        Assert.Equal(materialId, Assert.Single(project.MaterialIds));
    }

    private sealed class MaterialGateway(Guid owner, Guid materialId) : IPracticeGateway
    {
        public Task<MaterialText> GetMaterialTextAsync(Guid id, CancellationToken ct) => Task.FromResult(id == materialId
            ? new MaterialText(id, owner, "已就绪文本", PracticeRules.Sha256("已就绪文本"), "source-map-1") : throw PracticeOwnership.NotFound());
        public Task<PlanGraphSnapshot> GetPlanAsync(Guid planId, string snapshotVersion, CancellationToken ct) => throw new NotSupportedException();
        public Task<object> SubmitEvidenceAsync(PracticeSession session, IReadOnlyList<PracticeQuestion> questions, Guid resultId, Guid key, CancellationToken ct) => throw new NotSupportedException();
    }
}
