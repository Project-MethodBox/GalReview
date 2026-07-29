using KnowledgeService.Domain.Graphs;

namespace KnowledgeService.Domain.Reviews;

public sealed record PlanEdge(
    Guid FromPointId,
    Guid ToPointId,
    KnowledgeRelationType Type,
    double Confidence,
    double InfluenceWeight);
