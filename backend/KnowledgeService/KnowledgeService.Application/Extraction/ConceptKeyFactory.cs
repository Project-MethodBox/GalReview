using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace KnowledgeService.Application.Extraction;

internal static partial class ConceptKeyFactory
{
    public static string Create(string subjectCode, string title)
    {
        var canonicalTitle = NonSemanticCharactersRegex()
            .Replace(title.Normalize(NormalizationForm.FormKC).ToLowerInvariant(), string.Empty);
        var bytes = SHA256.HashData(
            Encoding.UTF8.GetBytes($"{subjectCode.ToUpperInvariant()}:{canonicalTitle}"));
        return Convert.ToHexString(bytes).ToLowerInvariant()[..24];
    }

    [GeneratedRegex(@"[\s\p{P}\p{S}]+", RegexOptions.CultureInvariant)]
    private static partial Regex NonSemanticCharactersRegex();
}
