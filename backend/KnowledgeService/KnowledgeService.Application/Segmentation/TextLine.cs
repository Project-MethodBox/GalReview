namespace KnowledgeService.Application.Segmentation;

internal sealed record TextLine(
    int StartOffset,
    int EndOffset,
    string Text);
