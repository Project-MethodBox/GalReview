using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Segmentation;
using KnowledgeService.Persistence.Mapping;

namespace KnowledgeService.Persistence.Repositories;

internal static class GraphFingerprint
{
    public static string Create(
        KnowledgeGraph graph,
        SegmentationOptions requestedSegmentation)
    {
        ArgumentNullException.ThrowIfNull(graph);
        ArgumentNullException.ThrowIfNull(requestedSegmentation);

        string?[] fields =
        [
            Neo4jParameterMapper.Id(graph.OwnerUserId),
            Neo4jParameterMapper.Id(graph.MaterialId),
            graph.TextChecksum.ToUpperInvariant(),
            graph.SegmenterVersion,
            graph.ExtractorVersion,
            graph.SubjectCode,
            graph.SegmentationMode.ToString(),
            requestedSegmentation.Mode.ToString(),
            requestedSegmentation.Delimiter,
            requestedSegmentation.MinChapterCharacters.ToString(
                CultureInfo.InvariantCulture),
            requestedSegmentation.MaxChapterCharacters.ToString(
                CultureInfo.InvariantCulture),
            requestedSegmentation.FixedWindowCharacters.ToString(
                CultureInfo.InvariantCulture)
        ];
        var canonical = new StringBuilder();
        foreach (var field in fields)
        {
            AppendLengthPrefixed(canonical, field);
        }

        return Convert.ToHexString(
                SHA256.HashData(
                    Encoding.UTF8.GetBytes(canonical.ToString())))
            .ToLowerInvariant();
    }

    private static void AppendLengthPrefixed(
        StringBuilder output,
        string? value)
    {
        if (value is null)
        {
            output.Append("-1:");
            return;
        }

        output
            .Append(value.Length.ToString(CultureInfo.InvariantCulture))
            .Append(':')
            .Append(value);
    }
}
