using KnowledgeService.API.Contracts;
using KnowledgeService.API.Infrastructure;
using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Features.Reviews;
using KnowledgeService.Application.Planning;
using KnowledgeService.Domain.Reviews;
using MediatR;

namespace KnowledgeService.API.Endpoints;

internal static class ReviewPlanEndpoints
{
    public static IEndpointRouteBuilder MapReviewPlanEndpoints(
        this IEndpointRouteBuilder endpoints)
    {
        endpoints.MapPost(
            "/api/v1/assessment-plans",
            async (
                CreateAssessmentPlanRequest request,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                var plan = await sender.Send(
                    new CreateAssessmentPlanCommand(
                        request.GraphId,
                        RequestIdentity.RequireUserId(context),
                        new AssessmentPlanOptions(
                            request.ChapterIds ?? Array.Empty<Guid>(),
                            request.MaxQuestions ?? 12,
                            request.CoverageTarget ?? 0.80,
                            request.MaximumInferenceDepth ?? 3)),
                    cancellationToken);
                return ApiResults.Success(
                    context,
                    PlanGraphResponse.From(plan),
                    StatusCodes.Status201Created);
            });

        endpoints.MapPost(
            "/api/v1/learning-plans",
            async (
                CreateLearningPlanRequest request,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                if (request.ChapterIds is null || request.ChapterIds.Count == 0)
                {
                    throw new KnowledgeServiceException(
                        400,
                        "CHAPTER_IDS_REQUIRED",
                        "学习计划必须指定至少一个章节。");
                }

                var plan = await sender.Send(
                    new CreateLearningPlanCommand(
                        request.GraphId,
                        RequestIdentity.RequireUserId(context),
                        new LearningPlanOptions(
                            request.ChapterIds,
                            request.MaxPoints ?? 20,
                            request.MaximumDependencyDepth ?? 5)),
                    cancellationToken);
                return ApiResults.Success(
                    context,
                    PlanGraphResponse.From(plan),
                    StatusCodes.Status201Created);
            });

        endpoints.MapGet(
            "/api/v1/review-plans/{reviewPlanId:guid}",
            async (
                Guid reviewPlanId,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                var plan = await sender.Send(
                    new GetReviewPlanQuery(
                        reviewPlanId,
                        RequestIdentity.RequireUserId(context)),
                    cancellationToken);
                return ApiResults.Success(
                    context,
                    PlanGraphResponse.From(plan));
            });

        endpoints.MapGet(
            "/internal/v1/review-plans/{reviewPlanId:guid}/graph",
            async (
                Guid reviewPlanId,
                string snapshotVersion,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                _ = RequestIdentity.RequireServiceName(context);
                var plan = await sender.Send(
                    new GetReviewPlanQuery(reviewPlanId, null),
                    cancellationToken);
                if (!string.Equals(
                        plan.SnapshotVersion,
                        snapshotVersion,
                        StringComparison.Ordinal))
                {
                    throw new KnowledgeServiceException(
                        409,
                        "SNAPSHOT_VERSION_CONFLICT",
                        "请求的计划快照版本不一致。");
                }

                return ApiResults.Success(
                    context,
                    PlanGraphResponse.From(plan));
            });

        endpoints.MapPut(
            "/internal/v1/review-evidence/{resultId:guid}",
            async (
                Guid resultId,
                ReviewEvidenceRequest request,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                _ = RequestIdentity.RequireServiceName(context);
                var submission = ReviewEvidenceMapper.Map(
                    resultId,
                    request);
                var receipt = await sender.Send(
                    new SubmitReviewResultCommand(
                        request.ReviewPlanId,
                        submission),
                    cancellationToken);
                return ApiResults.Success(
                    context,
                    MasteryUpdateReceiptResponse.From(receipt));
            });

        return endpoints;
    }
}
