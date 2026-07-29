using System.Text;
using KnowledgeService.Application.Exceptions;

namespace KnowledgeService.API.Infrastructure;

internal static class CursorPagination
{
    public static (IReadOnlyList<T> Items, string? NextCursor) Page<T>(
        IReadOnlyList<T> source,
        string? cursor,
        int limit)
    {
        if (limit is < 1 or > 100)
        {
            throw new KnowledgeServiceException(
                400,
                "PAGINATION_INVALID",
                "limit 必须在 1 到 100 之间。");
        }

        var offset = Decode(cursor);
        if (offset < 0 || offset > source.Count)
        {
            throw new KnowledgeServiceException(
                400,
                "CURSOR_INVALID",
                "分页游标无效。");
        }

        var items = source.Skip(offset).Take(limit).ToArray();
        var nextOffset = offset + items.Length;
        return (
            items,
            nextOffset < source.Count ? Encode(nextOffset) : null);
    }

    private static string Encode(int offset) =>
        Convert.ToBase64String(Encoding.UTF8.GetBytes($"v1:{offset}"));

    private static int Decode(string? cursor)
    {
        if (string.IsNullOrWhiteSpace(cursor))
        {
            return 0;
        }

        try
        {
            var value = Encoding.UTF8.GetString(Convert.FromBase64String(cursor));
            return value.StartsWith("v1:", StringComparison.Ordinal) &&
                   int.TryParse(value.AsSpan(3), out var offset)
                ? offset
                : -1;
        }
        catch (FormatException)
        {
            return -1;
        }
    }
}
