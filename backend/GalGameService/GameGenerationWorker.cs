using System.Threading.Channels;

namespace GalGameService.Background;

/// <summary>
/// 游戏生成后台 worker：从 <see cref="GameGenerationQueue"/> 消费任务，
/// 调用 NarrativeGenerationService / MockStoryPackageFactory 完成生成。
/// 替换原 Program.cs 中 fire-and-forget Task.Run，提供：
/// 1) 进程停止时通过 stoppingToken 平滑取消；
/// 2) 单个 job 异常被记录但不让 worker 退出；
/// 3) 状态机转换保持原子（QUEUED → RUNNING → SUCCEEDED/FAILED）。
/// </summary>
public sealed class GameGenerationWorker : BackgroundService
{
    private readonly GameGenerationQueue _queue;
    private readonly IGameStore _store;
    private readonly NarrativeGenerationService _narrativeService;
    private readonly bool _isMockMode;
    private readonly ILogger<GameGenerationWorker> _logger;

    public GameGenerationWorker(
        GameGenerationQueue queue,
        IGameStore store,
        NarrativeGenerationService narrativeService,
        IConfiguration configuration,
        ILogger<GameGenerationWorker> logger)
    {
        _queue = queue;
        _store = store;
        _narrativeService = narrativeService;
        _isMockMode = string.Equals(
            configuration["MOONSTONE_MODE"] ?? Environment.GetEnvironmentVariable("MOONSTONE_MODE"),
            "Mock", StringComparison.OrdinalIgnoreCase);
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("GameGenerationWorker started.");
        try
        {
            await foreach (var item in _queue.Reader.ReadAllAsync(stoppingToken))
            {
                if (item is null) continue;
                try
                {
                    await ProcessItemAsync(item, stoppingToken);
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Job {GenerationId} failed during generation", item.GenerationId);
                    _store.TryTransitionJob(item.GenerationId, JobStatus.RUNNING,
                        j => j with { Status = JobStatus.FAILED, Error = new ApiError("INTERNAL_ERROR", ex.Message, new { }) });
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // 正常关闭。
        }
        finally
        {
            _logger.LogInformation("GameGenerationWorker stopped.");
        }
    }

    private async Task ProcessItemAsync(GameGenerationWorkItem item, CancellationToken cancellationToken)
    {
        // 原子状态转换：QUEUED → RUNNING
        if (_store.TryTransitionJob(item.GenerationId, JobStatus.QUEUED,
            j => j with { Status = JobStatus.RUNNING, Progress = 50 }) is null)
        {
            _logger.LogWarning("Job {GenerationId} was not in QUEUED state, skipping generation", item.GenerationId);
            return;
        }

        _logger.LogInformation("Job {GenerationId} started generating. Style={Style}, Difficulty={Difficulty}",
            item.GenerationId, item.Request.Style, item.Request.Difficulty);

        // Mock 固定返回同一套原创演示剧情；仍保留请求的计划与快照字段，
        // 使包的溯源、任务查询和权限边界继续符合 §7.1 / §7.3.1。
        // 非 Mock 才执行真实的骨架生成与可选叙事模型重写。
        var package = _isMockMode
            ? MockStoryPackageFactory.Create(item.Request)
            : await _narrativeService.GenerateAsync(item.Graph, item.Request, item.OwnerUserId, cancellationToken);
        var checksum = GamePackageValidator.ComputeChecksum(package);
        var manifest = new GamePackageManifest(
            package.PackageId, package.SchemaVersion, package.GeneratorVersion,
            package.ReviewPlanId, package.SnapshotVersion, package.EntrySceneId,
            package.Scenes.Length, checksum,
            $"/api/v1/game-packages/{package.PackageId}/content",
            item.OwnerUserId, DateTimeOffset.UtcNow);

        _store.SavePackage(package, manifest, item.OwnerUserId);

        // 原子状态转换：RUNNING → SUCCEEDED
        _store.TryTransitionJob(item.GenerationId, JobStatus.RUNNING,
            j => j with { Status = JobStatus.SUCCEEDED, Progress = 100, PackageId = package.PackageId });

        _logger.LogInformation("Job {GenerationId} succeeded. PackageId={PackageId}, Scenes={SceneCount}",
            item.GenerationId, package.PackageId, package.Scenes.Length);
    }
}
