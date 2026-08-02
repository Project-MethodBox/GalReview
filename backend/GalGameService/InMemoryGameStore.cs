using System.Collections.Concurrent;

// ============================================================================
// Mock 内存存储
//
// 存储 GameGenerationJob、GamePackage 和 GamePackageManifest。
// 启动时预置黄金游戏包（contract.md §7.4 Mock），供直接读取测试。
//
// 线程安全策略：
// - ConcurrentDictionary 保证单个 Get/Set 原子性
// - UpdateJob / TryTransitionJob 使用 per-job 锁防止 lost-update
//   （后台 Task.Run 与 HTTP 请求可能并发访问同一 job）
// ============================================================================

public interface IGameStore
{
    GameGenerationJob CreateJob(string ownerUserId, GameGenerationRequest request);
    GameGenerationJob? GetJob(Guid generationId);

    /// <summary>无条件更新 job（覆盖当前值）</summary>
    void UpdateJob(GameGenerationJob job);

    /// <summary>
    /// 原子状态转换：仅当当前 status == expectedStatus 时才更新。
    /// 返回更新后的 job（成功）或 null（状态不匹配，已被其他线程修改）。
    /// </summary>
    GameGenerationJob? TryTransitionJob(Guid generationId, JobStatus expectedStatus, Func<GameGenerationJob, GameGenerationJob> update);

    void SavePackage(GamePackage package, GamePackageManifest manifest, string ownerUserId);
    GamePackage? GetPackage(Guid packageId);
    GamePackageManifest? GetManifest(Guid packageId);
    string? GetPackageOwner(Guid packageId);

    /// <summary>
    /// 启动恢复：将卡在 RUNNING/QUEUED 的任务标记为 FAILED。
    /// InMemoryGameStore 无持久化，直接返回 0。
    /// </summary>
    int RecoverStaleJobs() => 0;
}

public sealed class InMemoryGameStore : IGameStore
{
    private readonly ConcurrentDictionary<Guid, GameGenerationJob> _jobs = new();
    private readonly ConcurrentDictionary<Guid, GamePackage> _packages = new();
    private readonly ConcurrentDictionary<Guid, GamePackageManifest> _manifests = new();
    private readonly ConcurrentDictionary<Guid, string> _packageOwners = new();

    // per-job 锁：防止同一 job 的并发 read-modify-write 导致 lost-update
    private readonly ConcurrentDictionary<Guid, object> _jobLocks = new();
    private readonly object _saveLock = new();

    // 内存上限：防止 Mock 模式下无限增长
    private const int MaxJobs = 10_000;
    private int _jobCount;

    public InMemoryGameStore(bool seedGoldenPackage = false)
    {
        if (seedGoldenPackage)
            SeedGoldenPackage();
    }

    /// <summary>预置黄金游戏包（contract.md §7.4 Mock 数据）</summary>
    private void SeedGoldenPackage()
    {
        var goldenPackageId = Guid.Parse("f2561bb2-b88c-47ef-b0ae-8f283ff64f1b");
        var reviewPlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");
        var questionId = Guid.Parse("6428a20a-66dd-44c9-944f-d7b36fa9c95a");
        var knowledgePointId = Guid.Parse("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb");
        var ownerUserId = "7bc4918a-9079-4ea2-9e8e-369ad79a9f20";

        var goldenPackage = new GamePackage(
            SchemaVersion: "1.0",
            PackageId: goldenPackageId,
            GeneratorVersion: "gala-0.1.0",
            ReviewPlanId: reviewPlanId,
            SnapshotVersion: PlanGraphClient.MockSnapshotVersion,
            EntrySceneId: "scene-001",
            Scenes: new Scene[]
            {
                new(
                    SceneId: "scene-001",
                    Title: null,
                    Dialogue: new DialogueLine[]
                    {
                        new("heroine", "水稻分蘖期最关键的管理目标是什么？", "curious"),
                    },
                    Choices: new Choice[]
                    {
                        new(
                            ChoiceId: "c1",
                            QuestionId: questionId,
                            Text: "协调群体数量与个体生长",
                            NextSceneId: null,
                            ScoreDelta: 1,
                            KnowledgePointId: knowledgePointId,
                            AnswerKind: AnswerKind.CHOICE,
                            Correct: true),
                    },
                    KnowledgeBindings: new KnowledgeBinding[]
                    {
                        new(knowledgePointId, questionId, KnowledgePurpose.QUESTION),
                    }),
            },
            Assets: Array.Empty<AssetRef>());

        var checksum = GamePackageValidator.ComputeChecksum(goldenPackage);
        var manifest = new GamePackageManifest(
            PackageId: goldenPackageId,
            SchemaVersion: "1.0",
            GeneratorVersion: "gala-0.1.0",
            ReviewPlanId: reviewPlanId,
            SnapshotVersion: PlanGraphClient.MockSnapshotVersion,
            EntrySceneId: "scene-001",
            SceneCount: 1,
            Checksum: checksum,
            ContentUrl: $"/api/v1/game-packages/{goldenPackageId}/content",
            OwnerUserId: ownerUserId,
            CreatedAt: DateTimeOffset.Parse("2026-07-27T08:55:00Z"));

        _packages[goldenPackageId] = goldenPackage;
        _manifests[goldenPackageId] = manifest;
        _packageOwners[goldenPackageId] = ownerUserId;
    }

    public GameGenerationJob CreateJob(string ownerUserId, GameGenerationRequest request)
    {
        var now = DateTimeOffset.UtcNow;
        var job = new GameGenerationJob(
            GenerationId: Guid.NewGuid(),
            OwnerUserId: ownerUserId,
            Status: JobStatus.QUEUED,
            Progress: 0,
            PackageId: null,
            GeneratorVersion: "gala-0.1.0",
            Error: null,
            CreatedAt: now,
            UpdatedAt: now);

        // 简单的内存保护：超过上限时清除最旧的已完成 job
        if (Interlocked.Increment(ref _jobCount) > MaxJobs)
        {
            EvictOldestCompletedJobs();
        }

        _jobs[job.GenerationId] = job;
        return job;
    }

    public GameGenerationJob? GetJob(Guid generationId)
        => _jobs.TryGetValue(generationId, out var job) ? job : null;

    /// <summary>无条件更新 job。使用 per-job 锁保证与 TryTransitionJob 互斥。</summary>
    public void UpdateJob(GameGenerationJob job)
    {
        var lockObj = _jobLocks.GetOrAdd(job.GenerationId, _ => new object());
        lock (lockObj)
        {
            _jobs[job.GenerationId] = job with { UpdatedAt = DateTimeOffset.UtcNow };
        }
    }

    /// <summary>
    /// 原子状态转换：CAS 语义。
    /// 仅当当前 job.Status == expectedStatus 时执行 update 并写入。
    /// 防止后台任务与用户请求的竞态（如 job 已被标记 FAILED 后不再接受 RUNNING 更新）。
    /// </summary>
    public GameGenerationJob? TryTransitionJob(
        Guid generationId, JobStatus expectedStatus,
        Func<GameGenerationJob, GameGenerationJob> update)
    {
        var lockObj = _jobLocks.GetOrAdd(generationId, _ => new object());
        lock (lockObj)
        {
            if (!_jobs.TryGetValue(generationId, out var current))
                return null;
            if (current.Status != expectedStatus)
                return null;
            var updated = update(current) with { UpdatedAt = DateTimeOffset.UtcNow };
            _jobs[generationId] = updated;
            return updated;
        }
    }

    public void SavePackage(GamePackage package, GamePackageManifest manifest, string ownerUserId)
    {
        lock (_saveLock)
        {
            _packages[package.PackageId] = package;
            _manifests[package.PackageId] = manifest;
            _packageOwners[package.PackageId] = ownerUserId;
        }
    }

    public GamePackage? GetPackage(Guid packageId)
        => _packages.TryGetValue(packageId, out var pkg) ? pkg : null;

    public GamePackageManifest? GetManifest(Guid packageId)
        => _manifests.TryGetValue(packageId, out var manifest) ? manifest : null;

    public string? GetPackageOwner(Guid packageId)
        => _packageOwners.TryGetValue(packageId, out var owner) ? owner : null;

    /// <summary>清除最旧的已完成（SUCCEEDED/FAILED）job，释放内存</summary>
    private void EvictOldestCompletedJobs()
    {
        var completed = _jobs
            .Where(kvp => kvp.Value.Status is JobStatus.SUCCEEDED or JobStatus.FAILED)
            .OrderBy(kvp => kvp.Value.UpdatedAt)
            .Take(MaxJobs / 10) // 每次清除 10%
            .Select(kvp => kvp.Key)
            .ToList();

        foreach (var id in completed)
        {
            if (_jobs.TryRemove(id, out _))
                Interlocked.Decrement(ref _jobCount);
        }
    }
}
