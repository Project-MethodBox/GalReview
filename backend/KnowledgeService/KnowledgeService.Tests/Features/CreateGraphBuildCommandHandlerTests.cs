using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Features.Builds;
using KnowledgeService.Application.Time;
using KnowledgeService.Domain.Builds;
using KnowledgeService.Domain.Segmentation;
using KnowledgeService.Tests.Fixtures;

namespace KnowledgeService.Tests.Features;

public sealed class CreateGraphBuildCommandHandlerTests
{
    private static readonly Guid MaterialId =
        Guid.Parse("10000000-0000-0000-0000-000000000001");
    private static readonly Guid OwnerUserId =
        Guid.Parse("10000000-0000-0000-0000-000000000002");

    [Fact]
    public async Task Normalizes_uuid_d_idempotency_key_before_storage()
    {
        const string expectedKey =
            "abcdef01-2345-6789-abcd-ef0123456789";
        GraphBuildJob? captured = null;
        var repository = new KnowledgeRepositoryStub
        {
            CreateBuildJob = job =>
            {
                captured = job;
                return (job, true);
            }
        };
        var handler = new CreateGraphBuildCommandHandler(
            repository,
            new SystemClock());

        var result = await handler.Handle(
            Command($"  {expectedKey.ToUpperInvariant()}  "),
            CancellationToken.None);

        Assert.True(result.Created);
        Assert.NotNull(captured);
        Assert.Equal(expectedKey, captured.IdempotencyKey);
        Assert.Equal("AGRONOMY", captured.SubjectHint);
    }

    [Theory]
    [InlineData("not-a-uuid")]
    [InlineData("abcdef0123456789abcdef0123456789")]
    [InlineData("00000000-0000-0000-0000-000000000000")]
    public async Task Rejects_non_uuid_d_idempotency_key(string value)
    {
        var repository = new KnowledgeRepositoryStub
        {
            CreateBuildJob = job => (job, true)
        };
        var handler = new CreateGraphBuildCommandHandler(
            repository,
            new SystemClock());

        var exception = await Assert.ThrowsAsync<KnowledgeServiceException>(
            () => handler.Handle(
                Command(value),
                CancellationToken.None));

        Assert.Equal(400, exception.StatusCode);
        Assert.Equal("GRAPH_BUILD_REQUEST_INVALID", exception.Code);
    }

    [Fact]
    public async Task Same_key_and_request_returns_existing_job()
    {
        var existingBuildId =
            Guid.Parse("10000000-0000-0000-0000-000000000003");
        var repository = new KnowledgeRepositoryStub
        {
            CreateBuildJob = job => (
                job with
                {
                    BuildId = existingBuildId,
                    Status = GraphBuildStatus.Running,
                    Progress = 35
                },
                false)
        };
        var handler = new CreateGraphBuildCommandHandler(
            repository,
            new SystemClock());

        var result = await handler.Handle(
            Command("abcdef01-2345-6789-abcd-ef0123456789"),
            CancellationToken.None);

        Assert.False(result.Created);
        Assert.Equal(existingBuildId, result.Job.BuildId);
        Assert.Equal(GraphBuildStatus.Running, result.Job.Status);
    }

    [Fact]
    public async Task Different_request_for_same_key_uses_stable_conflict_code()
    {
        var repository = new KnowledgeRepositoryStub
        {
            CreateBuildJob = job => (
                job with { MaterialId = Guid.NewGuid() },
                false)
        };
        var handler = new CreateGraphBuildCommandHandler(
            repository,
            new SystemClock());

        var exception = await Assert.ThrowsAsync<KnowledgeServiceException>(
            () => handler.Handle(
                Command("abcdef01-2345-6789-abcd-ef0123456789"),
                CancellationToken.None));

        Assert.Equal(409, exception.StatusCode);
        Assert.Equal("IDEMPOTENCY_KEY_REUSED", exception.Code);
    }

    [Fact]
    public async Task Rejects_subject_code_with_hyphen()
    {
        var handler = HandlerReturningCandidate();

        var exception = await Assert.ThrowsAsync<KnowledgeServiceException>(
            () => handler.Handle(
                Command(
                    "abcdef01-2345-6789-abcd-ef0123456789",
                    subjectHint: "crop-science"),
                CancellationToken.None));

        Assert.Equal(400, exception.StatusCode);
        Assert.Equal("SUBJECT_CODE_INVALID", exception.Code);
    }

    [Fact]
    public async Task Accepts_and_normalizes_32_character_subject_code()
    {
        GraphBuildJob? captured = null;
        var repository = new KnowledgeRepositoryStub
        {
            CreateBuildJob = job =>
            {
                captured = job;
                return (job, true);
            }
        };
        var handler = new CreateGraphBuildCommandHandler(
            repository,
            new SystemClock());
        var subject = $"a{new string('b', 31)}";

        await handler.Handle(
            Command(
                "abcdef01-2345-6789-abcd-ef0123456789",
                subject),
            CancellationToken.None);

        Assert.NotNull(captured);
        Assert.Equal(subject.ToUpperInvariant(), captured.SubjectHint);
    }

    [Fact]
    public async Task Rejects_33_character_subject_code()
    {
        var handler = HandlerReturningCandidate();
        var subject = $"A{new string('B', 32)}";

        var exception = await Assert.ThrowsAsync<KnowledgeServiceException>(
            () => handler.Handle(
                Command(
                    "abcdef01-2345-6789-abcd-ef0123456789",
                    subject),
                CancellationToken.None));

        Assert.Equal(400, exception.StatusCode);
        Assert.Equal("SUBJECT_CODE_INVALID", exception.Code);
    }

    [Fact]
    public async Task Rejects_undefined_segmentation_mode()
    {
        var handler = HandlerReturningCandidate();

        var exception = await Assert.ThrowsAsync<KnowledgeServiceException>(
            () => handler.Handle(
                Command(
                    "abcdef01-2345-6789-abcd-ef0123456789",
                    segmentation: new SegmentationOptions(
                        (SegmentationMode)999)),
                CancellationToken.None));

        Assert.Equal(400, exception.StatusCode);
        Assert.Equal("SEGMENTATION_MODE_INVALID", exception.Code);
    }

    private static CreateGraphBuildCommandHandler
        HandlerReturningCandidate()
    {
        var repository = new KnowledgeRepositoryStub
        {
            CreateBuildJob = job => (job, true)
        };
        return new CreateGraphBuildCommandHandler(
            repository,
            new SystemClock());
    }

    private static CreateGraphBuildCommand Command(
        string idempotencyKey,
        string? subjectHint = "agronomy",
        SegmentationOptions? segmentation = null) =>
        new(
            MaterialId,
            OwnerUserId,
            subjectHint,
            segmentation ?? new SegmentationOptions(),
            null,
            idempotencyKey);
}
