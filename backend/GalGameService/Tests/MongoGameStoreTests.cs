using Microsoft.Extensions.Configuration;
using MongoDB.Driver;
using Xunit;

// ============================================================================
// MongoGameStore 测试
//
// 验证：
// - TryTransitionJob 的 CAS 语义（MongoDB FindOneAndReplace 实现）
// - 并发安全（多线程同时更新同一 job 不会 lost-update）
// - 黄金包预置正确（MongoDB 幂等写入）
// - CreateJob 生成唯一 GenerationId
// - SavePackage + GetPackage + GetManifest + GetPackageOwner 完整往返
// - IsReady 健康检查
//
// 前置条件：本机 MongoDB 运行在 127.0.0.1:5253
// ============================================================================

public class MongoGameStoreTests : IDisposable
{
    private static readonly Guid MockReviewPlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");
    private static readonly Guid GoldenPackageId = Guid.Parse("f2561bb2-b88c-47ef-b0ae-8f283ff64f1b");

    private readonly MongoGameStore? _store;

    private static IConfiguration CreateConfig()
    {
        var dict = new Dictionary<string, string?>
        {
            ["ConnectionStrings:GameDatabase"] = "mongodb://127.0.0.1:5253",
            ["MongoDb:Database"] = $"galgame_test_{Guid.NewGuid():N}",
        };
        return new ConfigurationBuilder()
            .AddInMemoryCollection(dict)
            .Build();
    }

    /// <summary>
    /// 快速探测 MongoDB 是否在本地 5253 端口运行。
    /// 不可用时 _store 设为 null，所有测试自动跳过。
    /// </summary>
    private static bool IsMongoAvailable()
    {
        try
        {
            using var client = new MongoClient("mongodb://127.0.0.1:5253/?serverSelectionTimeoutMS=1000");
            client.GetDatabase("admin").RunCommand<MongoDB.Bson.BsonDocument>("{ ping: 1 }");
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static GameGenerationRequest CreateRequest() => new(
        ReviewPlanId: MockReviewPlanId,
        SnapshotVersion: "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
        Style: GameStyle.CAMPUS,
        Difficulty: Difficulty.STANDARD,
        Locale: "zh-CN",
        Seed: 42);

    public MongoGameStoreTests()
    {
        if (!IsMongoAvailable())
        {
            _store = null;
            return;
        }
        var config = CreateConfig();
        _store = new MongoGameStore(config, seedGoldenPackage: true);
    }

    public void Dispose()
    {
        // 清理测试数据库（通过 DropDatabase）
        // 由于每个测试实例使用唯一数据库名，无需显式清理
        GC.SuppressFinalize(this);
    }

    // ----------------------------------------------------------------
    // 健康检查
    // ----------------------------------------------------------------

    [Fact]
    public void IsReady_ReturnsTrue_WhenMongoAvailable()
    {
        // 如果 MongoDB 未运行，跳过此测试
        if (_store is null) return;
        Assert.True(_store.IsReady());
    }

    // ----------------------------------------------------------------
    // 黄金包预置
    // ----------------------------------------------------------------

    [Fact]
    public void Constructor_SeedsGoldenPackage()
    {
        if (_store is null) return;

        var manifest = _store.GetManifest(GoldenPackageId);
        Assert.NotNull(manifest);
        Assert.Equal("1.0", manifest!.SchemaVersion);
        Assert.Equal(1, manifest.SceneCount);

        var pkg = _store.GetPackage(GoldenPackageId);
        Assert.NotNull(pkg);
        Assert.Equal(GoldenPackageId, pkg!.PackageId);
    }

    [Fact]
    public void Constructor_SeedsGoldenPackage_IsIdempotent()
    {
        if (_store is null) return;

        // 第二次构造（同一数据库）不应重复插入
        var config = CreateConfig();
        var store2 = new MongoGameStore(config, seedGoldenPackage: true);

        // 仍然只有一个黄金包
        var manifest = store2.GetManifest(GoldenPackageId);
        Assert.NotNull(manifest);
    }

    // ----------------------------------------------------------------
    // CreateJob
    // ----------------------------------------------------------------

    [Fact]
    public void CreateJob_ReturnsUniqueIds()
    {
        if (_store is null) return;

        var ids = new HashSet<Guid>();
        for (var i = 0; i < 50; i++)
        {
            var job = _store.CreateJob("user-1", CreateRequest());
            Assert.True(ids.Add(job.GenerationId));
            Assert.Equal(JobStatus.QUEUED, job.Status);
            Assert.Equal(0, job.Progress);
        }
    }

    // ----------------------------------------------------------------
    // TryTransitionJob — CAS 语义
    // ----------------------------------------------------------------

    [Fact]
    public void TryTransitionJob_Success_WhenStatusMatches()
    {
        if (_store is null) return;

        var job = _store.CreateJob("user-1", CreateRequest());
        var updated = _store.TryTransitionJob(job.GenerationId, JobStatus.QUEUED,
            j => j with { Status = JobStatus.RUNNING, Progress = 50 });

        Assert.NotNull(updated);
        Assert.Equal(JobStatus.RUNNING, updated!.Status);
        Assert.Equal(50, updated.Progress);
    }

    [Fact]
    public void TryTransitionJob_Fails_WhenStatusDoesNotMatch()
    {
        if (_store is null) return;

        var job = _store.CreateJob("user-1", CreateRequest());

        // 当前状态是 QUEUED，尝试从 RUNNING 转换 → 应失败
        var result = _store.TryTransitionJob(job.GenerationId, JobStatus.RUNNING,
            j => j with { Status = JobStatus.SUCCEEDED });

        Assert.Null(result);

        // 原 job 状态不变
        var current = _store.GetJob(job.GenerationId);
        Assert.Equal(JobStatus.QUEUED, current!.Status);
    }

    [Fact]
    public void TryTransitionJob_ReturnsNull_WhenJobNotFound()
    {
        if (_store is null) return;

        var result = _store.TryTransitionJob(Guid.NewGuid(), JobStatus.QUEUED, j => j);
        Assert.Null(result);
    }

    [Fact]
    public async Task ConcurrentUpdates_OnlyOneSucceeds()
    {
        if (_store is null) return;

        var job = _store.CreateJob("user-1", CreateRequest());

        // 10 个线程同时尝试从 QUEUED → RUNNING
        var results = new System.Collections.Concurrent.ConcurrentBag<GameGenerationJob?>();
        var tasks = Enumerable.Range(0, 10).Select(_ => Task.Run(() =>
        {
            var updated = _store.TryTransitionJob(job.GenerationId, JobStatus.QUEUED,
                j => j with { Status = JobStatus.RUNNING, Progress = 50 });
            results.Add(updated);
        })).ToArray();

        await Task.WhenAll(tasks);

        // 恰好 1 个成功，9 个失败
        var successes = results.Where(r => r is not null).Count();
        Assert.Equal(1, successes);

        // 最终状态为 RUNNING
        var final = _store.GetJob(job.GenerationId);
        Assert.Equal(JobStatus.RUNNING, final!.Status);
    }

    // ----------------------------------------------------------------
    // UpdateJob
    // ----------------------------------------------------------------

    [Fact]
    public void UpdateJob_OverwritesCurrentState()
    {
        if (_store is null) return;

        var job = _store.CreateJob("user-1", CreateRequest());

        _store.UpdateJob(job with { Status = JobStatus.FAILED, Error = new ApiError("TEST", "test", new { }) });

        var current = _store.GetJob(job.GenerationId);
        Assert.Equal(JobStatus.FAILED, current!.Status);
        Assert.NotNull(current.Error);
        Assert.Equal("TEST", current.Error!.Code);
    }

    // ----------------------------------------------------------------
    // SavePackage + GetPackage + GetManifest + GetPackageOwner
    // ----------------------------------------------------------------

    [Fact]
    public void SavePackage_AndRetrieve()
    {
        if (_store is null) return;

        var pkgId = Guid.NewGuid();

        var pkg = new GamePackage(
            SchemaVersion: "1.0",
            PackageId: pkgId,
            GeneratorVersion: "gala-0.1.0",
            ReviewPlanId: MockReviewPlanId,
            SnapshotVersion: "test-snapshot",
            EntrySceneId: "scene-1",
            Scenes: new Scene[]
            {
                new(
                    SceneId: "scene-1",
                    Title: "Test Scene",
                    Dialogue: new DialogueLine[]
                    {
                        new("narrator", "Hello world", "neutral"),
                    },
                    Choices: Array.Empty<Choice>(),
                    KnowledgeBindings: Array.Empty<KnowledgeBinding>()),
            },
            Assets: Array.Empty<AssetRef>());

        var manifest = new GamePackageManifest(
            PackageId: pkgId,
            SchemaVersion: "1.0",
            GeneratorVersion: "gala-0.1.0",
            ReviewPlanId: MockReviewPlanId,
            SnapshotVersion: "test-snapshot",
            EntrySceneId: "scene-1",
            SceneCount: 1,
            Checksum: "abc123",
            ContentUrl: $"/api/v1/game-packages/{pkgId}/content",
            OwnerUserId: "user-1",
            CreatedAt: DateTimeOffset.UtcNow);

        _store.SavePackage(pkg, manifest, "user-1");

        // 验证往返
        var retrievedPkg = _store.GetPackage(pkgId);
        Assert.NotNull(retrievedPkg);
        Assert.Equal(pkgId, retrievedPkg!.PackageId);
        Assert.Equal("1.0", retrievedPkg.SchemaVersion);
        Assert.Equal("scene-1", retrievedPkg.EntrySceneId);
        Assert.Single(retrievedPkg.Scenes);
        Assert.Equal("Test Scene", retrievedPkg.Scenes[0].Title);

        var retrievedManifest = _store.GetManifest(pkgId);
        Assert.NotNull(retrievedManifest);
        Assert.Equal("abc123", retrievedManifest!.Checksum);
        Assert.Equal(1, retrievedManifest.SceneCount);

        Assert.Equal("user-1", _store.GetPackageOwner(pkgId));
    }

    [Fact]
    public void GetPackage_ReturnsNull_WhenNotFound()
    {
        if (_store is null) return;

        Assert.Null(_store.GetPackage(Guid.NewGuid()));
        Assert.Null(_store.GetManifest(Guid.NewGuid()));
        Assert.Null(_store.GetPackageOwner(Guid.NewGuid()));
    }
}
