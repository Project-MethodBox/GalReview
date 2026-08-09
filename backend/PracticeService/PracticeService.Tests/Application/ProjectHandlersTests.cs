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

    [Fact]
    public async Task Project_creation_rejects_a_preexisting_material_scoped_graph()
    {
        var owner = Guid.NewGuid(); var materialId = Guid.NewGuid();
        var handler = new ProjectHandlers(new InMemoryPracticeRepository(), new MaterialGateway(owner, materialId));

        var error = await Assert.ThrowsAsync<PracticeDomainException>(() => handler.Handle(
            new CreateProjectCommand(owner, "项目", "CS", [materialId], Guid.NewGuid()), CancellationToken.None));

        Assert.Equal("PROJECT_GRAPH_MUST_BE_CREATED_IN_PROJECT", error.Code);
    }

    [Fact]
    public async Task Project_update_only_attaches_a_graph_scoped_to_the_same_project()
    {
        var owner = Guid.NewGuid(); var materialId = Guid.NewGuid(); var repository = new InMemoryPracticeRepository();
        var gateway = new MaterialGateway(owner, materialId); var handler = new ProjectHandlers(repository, gateway);
        var project = await handler.Handle(new CreateProjectCommand(owner, "项目", "CS", [materialId], null), CancellationToken.None);
        gateway.StudyProjectId = Guid.NewGuid();

        var error = await Assert.ThrowsAsync<PracticeDomainException>(() => handler.Handle(
            new UpdateProjectCommand(owner, project.ProjectId, null, null, null, Guid.NewGuid(), project.Version), CancellationToken.None));

        Assert.Equal("GRAPH_OUTSIDE_PROJECT_SCOPE", error.Code);
    }

    private sealed class MaterialGateway(Guid owner, Guid materialId) : IPracticeGateway
    {
        public Guid? StudyProjectId { get; set; }
        public Task<MaterialText> GetMaterialTextAsync(Guid id, CancellationToken ct) => Task.FromResult(id == materialId
            ? new MaterialText(id, owner, "已就绪文本", PracticeRules.Sha256("已就绪文本"), "source-map-1") : throw PracticeOwnership.NotFound());
        public Task<PlanGraphSnapshot> GetPlanAsync(Guid planId, string snapshotVersion, CancellationToken ct) => throw new NotSupportedException();
        public Task<object> SubmitEvidenceAsync(PracticeSession session, IReadOnlyList<PracticeQuestion> questions, Guid resultId, Guid key, CancellationToken ct) => throw new NotSupportedException();
        public Task<KnowledgeGraphScope> GetGraphScopeAsync(Guid graphId, Guid ownerUserId, CancellationToken ct) =>
            Task.FromResult(new KnowledgeGraphScope(graphId, materialId, StudyProjectId, owner, []));
    }
}
