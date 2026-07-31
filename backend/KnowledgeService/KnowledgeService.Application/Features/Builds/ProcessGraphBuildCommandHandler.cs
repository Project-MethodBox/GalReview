using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Extraction;
using KnowledgeService.Application.Materials;
using KnowledgeService.Application.Persistence;
using KnowledgeService.Application.Segmentation;
using KnowledgeService.Application.Time;
using KnowledgeService.Domain.Builds;
using MediatR;

namespace KnowledgeService.Application.Features.Builds;

public sealed class ProcessGraphBuildCommandHandler
    : IRequestHandler<ProcessGraphBuildCommand, GraphBuildJob>
{
    private const int MaximumMaterialCharacters = 10_000_000;
    private readonly IKnowledgeRepository _repository;
    private readonly IMaterialTextClient _materialTextClient;
    private readonly IChapterSegmenter _segmenter;
    private readonly IKnowledgeExtractor _extractor;
    private readonly ISystemClock _clock;

    public ProcessGraphBuildCommandHandler(
        IKnowledgeRepository repository,
        IMaterialTextClient materialTextClient,
        IChapterSegmenter segmenter,
        IKnowledgeExtractor extractor,
        ISystemClock clock)
    {
        _repository = repository;
        _materialTextClient = materialTextClient;
        _segmenter = segmenter;
        _extractor = extractor;
        _clock = clock;
    }

    public async Task<GraphBuildJob> Handle(
        ProcessGraphBuildCommand request,
        CancellationToken cancellationToken)
    {
        var job = await _repository.GetBuildJobAsync(
            request.BuildId,
            null,
            cancellationToken) ?? throw new KnowledgeServiceException(
                404,
                "GRAPH_BUILD_NOT_FOUND",
                "图谱构建任务不存在。");
        if (job.Status == GraphBuildStatus.Succeeded)
        {
            return job;
        }

        try
        {
            job = job with
            {
                Status = GraphBuildStatus.Running,
                Progress = 10,
                ErrorCode = null,
                ErrorMessage = null,
                UpdatedAt = _clock.UtcNow
            };
            await _repository.UpdateBuildJobAsync(job, cancellationToken);

            var material = await _materialTextClient.GetExtractedTextAsync(
                job.MaterialId,
                job.OwnerUserId,
                request.CorrelationId,
                cancellationToken);
            if (material.MaterialId != job.MaterialId ||
                material.Text.Length > MaximumMaterialCharacters ||
                string.IsNullOrWhiteSpace(material.TextChecksum))
            {
                throw new KnowledgeServiceException(
                    422,
                    "MATERIAL_TEXT_INVALID",
                    "文件服务返回的文本标识、checksum 或长度不符合契约。");
            }

            job = job with { Progress = 35, UpdatedAt = _clock.UtcNow };
            job = job with { SourceTextChecksum = material.TextChecksum };
            await _repository.UpdateBuildJobAsync(job, cancellationToken);

            var segments = _segmenter.Segment(
                material.Text,
                job.Segmentation);
            var graphId = Guid.NewGuid();
            var graph = _extractor.Extract(
                graphId,
                job.MaterialId,
                job.OwnerUserId,
                material.TextChecksum,
                job.SubjectHint ?? "GENERAL",
                segments,
                _clock.UtcNow);
            graph = SourceReferenceLocator.Apply(
                graph,
                material.SourceMap,
                material.Blocks);
            if (graph.Points.Count == 0)
            {
                throw new KnowledgeServiceException(
                    422,
                    "KNOWLEDGE_POINTS_NOT_FOUND",
                    "在规范化文本中未提取到可用知识点。");
            }

            job = job with { Progress = 75, UpdatedAt = _clock.UtcNow };
            await _repository.UpdateBuildJobAsync(job, cancellationToken);
            var saved = await _repository.SaveGraphAsync(
                graph,
                job.BuildId,
                cancellationToken);
            job = job with
            {
                Status = GraphBuildStatus.Succeeded,
                Progress = 100,
                GraphId = saved.GraphId,
                UpdatedAt = _clock.UtcNow
            };
            await _repository.UpdateBuildJobAsync(job, cancellationToken);
            return job;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception exception)
        {
            var serviceException = exception as KnowledgeServiceException;
            job = job with
            {
                Status = GraphBuildStatus.Failed,
                ErrorCode = serviceException?.Code ?? "GRAPH_BUILD_FAILED",
                ErrorMessage = exception.Message,
                UpdatedAt = _clock.UtcNow
            };
            await _repository.UpdateBuildJobAsync(job, CancellationToken.None);
            return job;
        }
    }
}
