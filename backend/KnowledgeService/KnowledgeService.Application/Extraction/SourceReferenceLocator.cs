using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Materials;

namespace KnowledgeService.Application.Extraction;

internal static class SourceReferenceLocator
{
    public static KnowledgeGraph Apply(
        KnowledgeGraph graph,
        IReadOnlyList<MaterialSourceSpan> sourceMap,
        IReadOnlyList<MaterialTextBlock> blocks)
    {
        ArgumentNullException.ThrowIfNull(graph);
        ArgumentNullException.ThrowIfNull(sourceMap);
        ArgumentNullException.ThrowIfNull(blocks);

        var points = graph.Points
            .Select(point => point with
            {
                SourceReferences = point.SourceReferences
                    .Select(reference => reference with
                    {
                        Location = ResolveLocation(
                            reference,
                            sourceMap,
                            blocks)
                    })
                    .ToArray()
            })
            .ToArray();
        return graph with { Points = points };
    }

    private static string ResolveLocation(
        SourceReference reference,
        IReadOnlyList<MaterialSourceSpan> sourceMap,
        IReadOnlyList<MaterialTextBlock> blocks)
    {
        var labels = sourceMap
            .Where(span => Overlaps(reference, span))
            .Select(DisplaySpan)
            .Where(label => label is not null)
            .Cast<string>()
            .Distinct(StringComparer.Ordinal)
            .Take(3)
            .ToArray();
        if (labels.Length > 0)
        {
            return string.Join(" / ", labels);
        }

        labels = blocks
            .Where(block => Overlaps(reference, block.Source))
            .Select(DisplayBlock)
            .Distinct(StringComparer.Ordinal)
            .Take(3)
            .ToArray();
        return labels.Length == 0
            ? reference.Location
            : string.Join(" / ", labels);
    }

    private static bool Overlaps(
        SourceReference reference,
        MaterialSourceSpan span) =>
        span.StartOffset < reference.EndOffset &&
        span.EndOffset > reference.StartOffset;

    private static string? DisplaySpan(MaterialSourceSpan span)
    {
        if (!string.IsNullOrWhiteSpace(span.SourceLabel))
        {
            return span.SourceLabel;
        }

        if (span.PageNumber is not null)
        {
            return $"第 {span.PageNumber.Value} 页";
        }

        return span.ParagraphIndex is null
            ? null
            : $"段落 {span.ParagraphIndex.Value + 1}";
    }

    private static string DisplayBlock(MaterialTextBlock block)
    {
        var sourceLabel = DisplaySpan(block.Source);
        if (sourceLabel is not null)
        {
            return sourceLabel;
        }

        return block.Kind.ToUpperInvariant() switch
        {
            "HEADING" when block.Level is not null =>
                $"{block.Level.Value} 级标题",
            "HEADING" => "标题",
            "LIST_ITEM" => "列表项",
            "TABLE" => "表格",
            "CODE" => "代码块",
            "QUOTE" => "引用",
            _ => "段落"
        };
    }
}
