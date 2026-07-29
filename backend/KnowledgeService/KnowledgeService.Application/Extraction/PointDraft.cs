using KnowledgeService.Domain.Graphs;

namespace KnowledgeService.Application.Extraction;

internal sealed record PointDraft(
    Guid ChapterId,
    string ChapterTitle,
    int ChapterOrdinal,
    string ConceptKey,
    string Title,
    string Summary,
    IReadOnlyList<string> Tags,
    double Confidence,
    IReadOnlyList<SourceReference> SourceReferences,
    int SourceOrder);
