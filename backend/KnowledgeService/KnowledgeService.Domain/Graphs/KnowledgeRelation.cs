namespace KnowledgeService.Domain.Graphs;

/// <summary>
/// For prerequisite relations, FromPointId is the prerequisite and ToPointId is
/// the dependent knowledge point. This direction is stable in storage and APIs.
/// </summary>
public sealed record KnowledgeRelation(
    Guid RelationId,
    Guid GraphId,
    Guid FromPointId,
    Guid ToPointId,
    KnowledgeRelationType Type,
    double Confidence,
    string Rationale);
