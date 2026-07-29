using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Mastery;

namespace KnowledgeService.API.Contracts;

public sealed record KnowledgePointResponse(
    Guid PointId,
    Guid GraphId,
    Guid ChapterId,
    string ConceptKey,
    string Title,
    string Summary,
    string SubjectCode,
    IReadOnlyList<string> Tags,
    double Confidence,
    IReadOnlyList<SourceReference> SourceReferences,
    MasteryState Mastery,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt)
{
    public static KnowledgePointResponse From(
        KnowledgePoint point,
        MasteryState mastery) =>
        new(
            point.PointId,
            point.GraphId,
            point.ChapterId,
            point.ConceptKey,
            point.Title,
            point.Summary,
            point.SubjectCode,
            point.Tags,
            point.Confidence,
            point.SourceReferences,
            mastery,
            point.CreatedAt,
            point.UpdatedAt);
}
