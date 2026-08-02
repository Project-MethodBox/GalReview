using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Serialization;
using MongoDB.Bson;
using MongoDB.Bson.Serialization;
using MongoDB.Bson.Serialization.Attributes;
using MongoDB.Bson.Serialization.Serializers;
using MongoDB.Driver;

// ============================================================================
// MongoDB 持久化存储
//
// 实现 IGameStore 接口，将 GameGenerationJob、GamePackage、GamePackageManifest
// 和 ownerUserId 持久化到 MongoDB。
//
// 线程安全策略：
// - MongoDB 的 UpdateOne / ReplaceOne with IsUpsert 保证单文档原子性
// - TryTransitionJob 使用 MongoDB 的 FindOneAndUpdate + 条件过滤器实现 CAS 语义
//   （等价于 InMemoryGameStore 的 per-job 锁，但无需应用层锁）
// - MaxJobs 容量限制通过 TTL 索引 + 启动时清理实现
//
// 集合设计：
// - game_jobs:         GameGenerationJob 文档（_id = GenerationId）
// - game_packages:     GamePackage 文档（_id = PackageId）
// - game_manifests:    GamePackageManifest 文档（_id = PackageId）
// - game_owners:       { _id: PackageId, ownerUserId: string } 映射文档
// ============================================================================

// ---------------------------------------------------------------------------
// BSON 映射（仅在首次使用时注册）
// ---------------------------------------------------------------------------

internal static class MongoGameStoreMappings
{
    private static int _registered;

    public static void EnsureRegistered()
    {
        if (Interlocked.Exchange(ref _registered, 1) == 1) return;

        // --- GameGenerationJob ---
        BsonClassMap.RegisterClassMap<GameGenerationJob>(cm =>
        {
            cm.AutoMap();
            cm.SetIdMember(cm.GetMemberMap(j => j.GenerationId));
            cm.GetMemberMap(j => j.GenerationId).SetElementName("_id");
            cm.GetMemberMap(j => j.OwnerUserId).SetElementName("ownerUserId");
            cm.GetMemberMap(j => j.Status).SetSerializer(
                new EnumSerializer<JobStatus>(BsonType.String));
            cm.GetMemberMap(j => j.Progress).SetElementName("progress");
            cm.GetMemberMap(j => j.PackageId).SetElementName("packageId");
            cm.GetMemberMap(j => j.GeneratorVersion).SetElementName("generatorVersion");
            cm.GetMemberMap(j => j.Error).SetElementName("error");
            cm.GetMemberMap(j => j.CreatedAt).SetElementName("createdAt");
            cm.GetMemberMap(j => j.UpdatedAt).SetElementName("updatedAt");
        });

        // --- GamePackageManifest ---
        BsonClassMap.RegisterClassMap<GamePackageManifest>(cm =>
        {
            cm.AutoMap();
            cm.SetIdMember(cm.GetMemberMap(m => m.PackageId));
            cm.GetMemberMap(m => m.PackageId).SetElementName("_id");
            cm.GetMemberMap(m => m.SchemaVersion).SetElementName("schemaVersion");
            cm.GetMemberMap(m => m.GeneratorVersion).SetElementName("generatorVersion");
            cm.GetMemberMap(m => m.ReviewPlanId).SetElementName("reviewPlanId");
            cm.GetMemberMap(m => m.SnapshotVersion).SetElementName("snapshotVersion");
            cm.GetMemberMap(m => m.EntrySceneId).SetElementName("entrySceneId");
            cm.GetMemberMap(m => m.SceneCount).SetElementName("sceneCount");
            cm.GetMemberMap(m => m.Checksum).SetElementName("checksum");
            cm.GetMemberMap(m => m.ContentUrl).SetElementName("contentUrl");
            cm.GetMemberMap(m => m.OwnerUserId).SetElementName("ownerUserId");
            cm.GetMemberMap(m => m.CreatedAt).SetElementName("createdAt");
        });

        // --- ApiError (嵌套在 Job.Error 中) ---
        BsonClassMap.RegisterClassMap<ApiError>(cm =>
        {
            cm.AutoMap();
            cm.MapMember(e => e.Code).SetElementName("code");
            cm.MapMember(e => e.Message).SetElementName("message");
            cm.MapMember(e => e.Details).SetElementName("details");
        });
    }
}

// ---------------------------------------------------------------------------
// Owner 映射文档
// ---------------------------------------------------------------------------

internal sealed class PackageOwnerDocument
{
    [BsonId]
    public Guid PackageId { get; set; }
    public string OwnerUserId { get; set; } = "";
}

// ---------------------------------------------------------------------------
// 持久化存储实现
// ---------------------------------------------------------------------------

public sealed class MongoGameStore : IGameStore
{
    private const int MaxJobs = 10_000;

    private readonly IMongoCollection<GameGenerationJob> _jobs;
    private readonly IMongoCollection<BsonDocument> _packages;
    private readonly IMongoCollection<GamePackageManifest> _manifests;
    private readonly IMongoCollection<PackageOwnerDocument> _owners;
    private readonly IMongoDatabase _database;
    private readonly ILogger<MongoGameStore>? _logger;

    // JSON 序列化选项（与 Program.cs 的 HttpJsonOptions 一致）
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(allowIntegerValues: false) }
    };

    public MongoGameStore(
        IConfiguration configuration,
        ILogger<MongoGameStore>? logger = null,
        bool seedGoldenPackage = false)
    {
        _logger = logger;
        MongoGameStoreMappings.EnsureRegistered();

        var connectionString = configuration.GetConnectionString("GameDatabase")
            ?? "mongodb://127.0.0.1:5253";
        var databaseName = configuration["MongoDb:Database"]
            ?? "moonstone_galgame";

        _database = new MongoClient(connectionString).GetDatabase(databaseName);
        _jobs = _database.GetCollection<GameGenerationJob>("game_jobs");
        _packages = _database.GetCollection<BsonDocument>("game_packages");
        _manifests = _database.GetCollection<GamePackageManifest>("game_manifests");
        _owners = _database.GetCollection<PackageOwnerDocument>("game_owners");

        // 索引创建和黄金包预置在 MongoDB 不可用时优雅降级
        // IsReady() 会返回 false，/readyz 端点将返回 503
        try
        {
            EnsureIndexes();

            if (seedGoldenPackage)
                SeedGoldenPackage();
        }
        catch (MongoException ex)
        {
            _logger?.LogWarning(ex, "MongoDB not available during initialization; store will report unhealthy until connection is restored");
        }
    }

    /// <summary>
    /// 恢复因服务重启而卡在 RUNNING 的生成任务。
    /// 将所有 status=RUNNING 或 status=QUEUED 的 job 标记为 FAILED，
    /// 因为当前实例无法继续执行前一个实例的生成流程。
    /// 应在应用启动阶段调用。
    /// </summary>
    public int RecoverStaleJobs()
    {
        try
        {
            var staleFilter = Builders<GameGenerationJob>.Filter.Or(
                Builders<GameGenerationJob>.Filter.Eq(j => j.Status, JobStatus.RUNNING),
                Builders<GameGenerationJob>.Filter.Eq(j => j.Status, JobStatus.QUEUED));

            var recoveryError = new ApiError(
                Code: "JOB_RECOVERED_AFTER_RESTART",
                Message: "Service restarted while job was running; job has been marked as failed",
                Details: new { });

            var update = Builders<GameGenerationJob>.Update
                .Set(j => j.Status, JobStatus.FAILED)
                .Set(j => j.Error, recoveryError)
                .Set(j => j.Progress, 100)
                .Set(j => j.UpdatedAt, DateTimeOffset.UtcNow);

            var result = _jobs.UpdateMany(staleFilter, update);
            var recovered = (int)result.ModifiedCount;

            if (recovered > 0)
            {
                _logger?.LogWarning(
                    "Recovered {Count} stale job(s) (RUNNING/QUEUED -> FAILED) after service restart",
                    recovered);
            }

            return recovered;
        }
        catch (MongoException ex)
        {
            _logger?.LogWarning(ex, "Failed to recover stale jobs; they will remain in RUNNING/QUEUED state");
            return 0;
        }
    }

    // --- 索引创建 ---

    private void EnsureIndexes()
    {
        // job 状态索引：用于清理查询
        _jobs.Indexes.CreateOne(
            new CreateIndexModel<GameGenerationJob>(
                Builders<GameGenerationJob>.IndexKeys
                    .Ascending(j => j.Status)
                    .Ascending(j => j.UpdatedAt)));

        // job owner 索引：用于按用户查询
        _jobs.Indexes.CreateOne(
            new CreateIndexModel<GameGenerationJob>(
                Builders<GameGenerationJob>.IndexKeys
                    .Ascending(j => j.OwnerUserId)
                    .Descending(j => j.CreatedAt)));

        // manifest owner 索引
        _manifests.Indexes.CreateOne(
            new CreateIndexModel<GamePackageManifest>(
                Builders<GamePackageManifest>.IndexKeys
                    .Ascending(m => m.OwnerUserId)
                    .Descending(m => m.CreatedAt)));

        // TTL 索引：已完成 job 30 天后自动过期
        _jobs.Indexes.CreateOne(
            new CreateIndexModel<GameGenerationJob>(
                Builders<GameGenerationJob>.IndexKeys
                    .Ascending(j => j.UpdatedAt),
                new CreateIndexOptions<GameGenerationJob>
                {
                    Name = "ttl_completed_jobs",
                    ExpireAfter = TimeSpan.FromDays(30),
                    PartialFilterExpression = Builders<GameGenerationJob>.Filter.Or(
                        Builders<GameGenerationJob>.Filter.Eq(j => j.Status, JobStatus.SUCCEEDED),
                        Builders<GameGenerationJob>.Filter.Eq(j => j.Status, JobStatus.FAILED))
                }));
    }

    // --- 黄金包预置 ---

    private void SeedGoldenPackage()
    {
        var goldenPackageId = Guid.Parse("f2561bb2-b88c-47ef-b0ae-8f283ff64f1b");
        var reviewPlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");
        var questionId = Guid.Parse("6428a20a-66dd-44c9-944f-d7b36fa9c95a");
        var knowledgePointId = Guid.Parse("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb");
        var ownerUserId = "7bc4918a-9079-4ea2-9e8e-369ad79a9f20";

        // 检查是否已存在
        if (_owners.Find(o => o.PackageId == goldenPackageId).Any())
            return;

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

        SavePackage(goldenPackage, manifest, ownerUserId);
    }

    // --- IGameStore 实现 ---

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

        // 容量保护：超限时清理最旧已完成 job
        var count = (int)_jobs.CountDocuments(FilterDefinition<GameGenerationJob>.Empty);
        if (count >= MaxJobs)
            EvictOldestCompletedJobs();

        _jobs.InsertOne(job);
        return job;
    }

    public GameGenerationJob? GetJob(Guid generationId)
    {
        return _jobs.Find(j => j.GenerationId == generationId).FirstOrDefault();
    }

    /// <summary>无条件更新 job（覆盖当前值）</summary>
    public void UpdateJob(GameGenerationJob job)
    {
        var updated = job with { UpdatedAt = DateTimeOffset.UtcNow };
        _jobs.ReplaceOne(
            j => j.GenerationId == job.GenerationId,
            updated,
            new ReplaceOptions { IsUpsert = true });
    }

    /// <summary>
    /// 原子状态转换：CAS 语义。
    /// 使用 MongoDB FindOneAndUpdate 实现条件更新，无需应用层锁。
    /// 仅当当前 job.Status == expectedStatus 时执行 update 并返回更新后的文档。
    /// </summary>
    public GameGenerationJob? TryTransitionJob(
        Guid generationId, JobStatus expectedStatus,
        Func<GameGenerationJob, GameGenerationJob> update)
    {
        var filter = Builders<GameGenerationJob>.Filter.And(
            Builders<GameGenerationJob>.Filter.Eq(j => j.GenerationId, generationId),
            Builders<GameGenerationJob>.Filter.Eq(j => j.Status, expectedStatus));

        // 先读取当前 job（在应用层执行 update 函数）
        var current = _jobs.Find(filter).FirstOrDefault();
        if (current is null)
            return null;

        var updated = update(current) with { UpdatedAt = DateTimeOffset.UtcNow };

        // 条件替换：仅当状态仍为 expectedStatus 时才写入
        var result = _jobs.FindOneAndReplace(
            filter,
            updated,
            new FindOneAndReplaceOptions<GameGenerationJob, GameGenerationJob>
            {
                ReturnDocument = ReturnDocument.After
            });

        return result;
    }

    public void SavePackage(GamePackage package, GamePackageManifest manifest, string ownerUserId)
    {
        // GamePackage 的嵌套 record 数组需要通过 JSON 序列化存储为 BsonDocument
        var packageJson = JsonSerializer.Serialize(package, JsonOpts);
        var packageBson = BsonDocument.Parse(packageJson);

        // 原子写入三个集合（MongoDB 单文档操作各自原子）
        _packages.ReplaceOne(
            new BsonDocument("_id", new BsonBinaryData(package.PackageId, GuidRepresentation.Standard)),
            packageBson,
            new ReplaceOptions { IsUpsert = true });

        _manifests.ReplaceOne(
            m => m.PackageId == package.PackageId,
            manifest,
            new ReplaceOptions { IsUpsert = true });

        _owners.ReplaceOne(
            o => o.PackageId == package.PackageId,
            new PackageOwnerDocument { PackageId = package.PackageId, OwnerUserId = ownerUserId },
            new ReplaceOptions { IsUpsert = true });
    }

    public GamePackage? GetPackage(Guid packageId)
    {
        var bson = _packages.Find(new BsonDocument("_id", new BsonBinaryData(packageId, GuidRepresentation.Standard))).FirstOrDefault();
        if (bson is null) return null;

        var json = bson.ToJson();
        return JsonSerializer.Deserialize<GamePackage>(json, JsonOpts);
    }

    public GamePackageManifest? GetManifest(Guid packageId)
    {
        return _manifests.Find(m => m.PackageId == packageId).FirstOrDefault();
    }

    public string? GetPackageOwner(Guid packageId)
    {
        return _owners.Find(o => o.PackageId == packageId)
            .FirstOrDefault()?.OwnerUserId;
    }

    // --- 健康检查 ---

    public bool IsReady()
    {
        try
        {
            _database.RunCommand<BsonDocument>(new BsonDocument("ping", 1));
            return true;
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(ex, "MongoDB health check failed");
            return false;
        }
    }

    // --- 清理 ---

    /// <summary>清除最旧的已完成（SUCCEEDED/FAILED）job，释放空间</summary>
    private void EvictOldestCompletedJobs()
    {
        var filter = Builders<GameGenerationJob>.Filter.Or(
            Builders<GameGenerationJob>.Filter.Eq(j => j.Status, JobStatus.SUCCEEDED),
            Builders<GameGenerationJob>.Filter.Eq(j => j.Status, JobStatus.FAILED));

        var completed = _jobs.Find(filter)
            .Sort(Builders<GameGenerationJob>.Sort.Ascending(j => j.UpdatedAt))
            .Limit(MaxJobs / 10) // 每次清除 10%
            .Project(j => j.GenerationId)
            .ToList();

        if (completed.Count > 0)
        {
            _jobs.DeleteMany(
                Builders<GameGenerationJob>.Filter.In(j => j.GenerationId, completed));
        }
    }
}
