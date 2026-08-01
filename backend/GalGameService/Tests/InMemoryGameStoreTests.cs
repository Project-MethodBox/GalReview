using Xunit;

// ============================================================================
// InMemoryGameStore 测试
//
// 验证：
// - TryTransitionJob 的 CAS 语义（仅当状态匹配时才更新）
// - 并发安全（多线程同时更新同一 job 不会 lost-update）
// - 黄金包预置正确
// - CreateJob 生成唯一 GenerationId
// ============================================================================

public class InMemoryGameStoreTests
{
    private static readonly Guid MockReviewPlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");
    private static readonly Guid GoldenPackageId = Guid.Parse("f2561bb2-b88c-47ef-b0ae-8f283ff64f1b");

    private static GameGenerationRequest CreateRequest() => new(
        ReviewPlanId: MockReviewPlanId,
        SnapshotVersion: "plan-graph-1.0:3da5f48f",
        Style: GameStyle.CAMPUS,
        Difficulty: Difficulty.STANDARD,
        Locale: "zh-CN",
        Seed: 42);

    [Fact]
    public void Constructor_SeedsGoldenPackage()
    {
        var store = new InMemoryGameStore();
        var manifest = store.GetManifest(GoldenPackageId);
        Assert.NotNull(manifest);
        Assert.Equal("1.0", manifest!.SchemaVersion);
        Assert.Equal(1, manifest.SceneCount);

        var pkg = store.GetPackage(GoldenPackageId);
        Assert.NotNull(pkg);
        Assert.Equal(GoldenPackageId, pkg!.PackageId);
    }

    [Fact]
    public void CreateJob_ReturnsUniqueIds()
    {
        var store = new InMemoryGameStore();
        var ids = new HashSet<Guid>();

        for (var i = 0; i < 100; i++)
        {
            var job = store.CreateJob("user-1", CreateRequest());
            Assert.True(ids.Add(job.GenerationId)); // 每个 ID 唯一
            Assert.Equal(JobStatus.QUEUED, job.Status);
            Assert.Equal(0, job.Progress);
        }
    }

    [Fact]
    public void TryTransitionJob_Success_WhenStatusMatches()
    {
        var store = new InMemoryGameStore();
        var job = store.CreateJob("user-1", CreateRequest());

        var updated = store.TryTransitionJob(job.GenerationId, JobStatus.QUEUED,
            j => j with { Status = JobStatus.RUNNING, Progress = 50 });

        Assert.NotNull(updated);
        Assert.Equal(JobStatus.RUNNING, updated!.Status);
        Assert.Equal(50, updated.Progress);
    }

    [Fact]
    public void TryTransitionJob_Fails_WhenStatusDoesNotMatch()
    {
        var store = new InMemoryGameStore();
        var job = store.CreateJob("user-1", CreateRequest());

        // 当前状态是 QUEUED，尝试从 RUNNING 转换 → 应失败
        var result = store.TryTransitionJob(job.GenerationId, JobStatus.RUNNING,
            j => j with { Status = JobStatus.SUCCEEDED });

        Assert.Null(result);
        // 原 job 状态不变
        var current = store.GetJob(job.GenerationId);
        Assert.Equal(JobStatus.QUEUED, current!.Status);
    }

    [Fact]
    public void TryTransitionJob_ReturnsNull_WhenJobNotFound()
    {
        var store = new InMemoryGameStore();
        var result = store.TryTransitionJob(Guid.NewGuid(), JobStatus.QUEUED, j => j);
        Assert.Null(result);
    }

    [Fact]
    public async Task ConcurrentUpdates_OnlyOneSucceeds()
    {
        var store = new InMemoryGameStore();
        var job = store.CreateJob("user-1", CreateRequest());

        // 10 个线程同时尝试从 QUEUED → RUNNING
        var results = new System.Collections.Concurrent.ConcurrentBag<GameGenerationJob?>();
        var tasks = Enumerable.Range(0, 10).Select(_ => Task.Run(() =>
        {
            var updated = store.TryTransitionJob(job.GenerationId, JobStatus.QUEUED,
                j => j with { Status = JobStatus.RUNNING, Progress = 50 });
            results.Add(updated);
        })).ToArray();

        await Task.WhenAll(tasks);

        // 恰好 1 个成功，9 个失败
        var successes = results.Where(r => r is not null).Count();
        Assert.Equal(1, successes);

        // 最终状态为 RUNNING
        var final = store.GetJob(job.GenerationId);
        Assert.Equal(JobStatus.RUNNING, final!.Status);
    }

    [Fact]
    public void UpdateJob_OverwritesCurrentState()
    {
        var store = new InMemoryGameStore();
        var job = store.CreateJob("user-1", CreateRequest());

        // 无条件更新（不检查状态）
        store.UpdateJob(job with { Status = JobStatus.FAILED, Error = new ApiError("TEST", "test", new { }) });

        var current = store.GetJob(job.GenerationId);
        Assert.Equal(JobStatus.FAILED, current!.Status);
        Assert.NotNull(current.Error);
        Assert.Equal("TEST", current.Error!.Code);
    }

    [Fact]
    public void SavePackage_AndRetrieve()
    {
        var store = new InMemoryGameStore();
        var pkgId = Guid.NewGuid();

        var pkg = new GamePackage(
            SchemaVersion: "1.0",
            PackageId: pkgId,
            GeneratorVersion: "gala-0.1.0",
            ReviewPlanId: MockReviewPlanId,
            SnapshotVersion: "test-snapshot",
            EntrySceneId: "scene-1",
            Scenes: Array.Empty<Scene>(),
            Assets: Array.Empty<AssetRef>());

        var manifest = new GamePackageManifest(
            PackageId: pkgId,
            SchemaVersion: "1.0",
            GeneratorVersion: "gala-0.1.0",
            ReviewPlanId: MockReviewPlanId,
            SnapshotVersion: "test-snapshot",
            EntrySceneId: "scene-1",
            SceneCount: 0,
            Checksum: "abc123",
            ContentUrl: $"/api/v1/game-packages/{pkgId}/content",
            OwnerUserId: "user-1",
            CreatedAt: DateTimeOffset.UtcNow);

        store.SavePackage(pkg, manifest, "user-1");

        Assert.NotNull(store.GetPackage(pkgId));
        Assert.NotNull(store.GetManifest(pkgId));
        Assert.Equal("user-1", store.GetPackageOwner(pkgId));
    }
}
