using System.Text.RegularExpressions;

namespace KnowledgeService.Domain.Common;

public static partial class SubjectCodePolicy
{
    public static string? NormalizeOptional(string? value) =>
        string.IsNullOrWhiteSpace(value)
            ? null
            : value.Trim().ToUpperInvariant();

    public static bool IsValid(string? value) =>
        value is not null && SubjectCodeRegex().IsMatch(value);

    [GeneratedRegex(
        @"^[A-Z][A-Z0-9_]{0,31}$",
        RegexOptions.CultureInvariant)]
    private static partial Regex SubjectCodeRegex();
}
