using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace PracticeService.Domain;

public static class FillBlankAnswerEquivalence
{
    public const string Version = "deterministic-fill-equivalence-v1";

    private static readonly Regex StructuralWhitespace = new(
        @"\s*([,()\[\]{}])\s*",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly IReadOnlyDictionary<string, string> TermAliases =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["g+"] = "term:gram-positive",
            ["g+菌"] = "term:gram-positive",
            ["革兰阳性"] = "term:gram-positive",
            ["革兰氏阳性"] = "term:gram-positive",
            ["革兰阳性菌"] = "term:gram-positive",
            ["革兰氏阳性菌"] = "term:gram-positive",
            ["革兰阳性细菌"] = "term:gram-positive",
            ["革兰氏阳性细菌"] = "term:gram-positive",
            ["grampositive"] = "term:gram-positive",
            ["gram-positive"] = "term:gram-positive",
            ["grampositivebacterium"] = "term:gram-positive",
            ["grampositivebacteria"] = "term:gram-positive",
            ["gram-positivebacterium"] = "term:gram-positive",
            ["gram-positivebacteria"] = "term:gram-positive",
            ["g-"] = "term:gram-negative",
            ["g-菌"] = "term:gram-negative",
            ["革兰阴性"] = "term:gram-negative",
            ["革兰氏阴性"] = "term:gram-negative",
            ["革兰阴性菌"] = "term:gram-negative",
            ["革兰氏阴性菌"] = "term:gram-negative",
            ["革兰阴性细菌"] = "term:gram-negative",
            ["革兰氏阴性细菌"] = "term:gram-negative",
            ["gramnegative"] = "term:gram-negative",
            ["gram-negative"] = "term:gram-negative",
            ["gramnegativebacterium"] = "term:gram-negative",
            ["gramnegativebacteria"] = "term:gram-negative",
            ["gram-negativebacterium"] = "term:gram-negative",
            ["gram-negativebacteria"] = "term:gram-negative"
        };

    public static bool AreEquivalent(string actual, string expected) =>
        string.Equals(Canonicalize(actual), Canonicalize(expected), StringComparison.Ordinal);

    internal static string Canonicalize(string value)
    {
        var surface = NormalizeSurface(value);
        if (surface.Length == 0) return "text:";

        var aliasKey = RemoveWhitespace(surface);
        if (TermAliases.TryGetValue(aliasKey, out var term)) return term;

        if (TryCanonicalizeTuple(surface, out var tuple)) return tuple;
        if (TryCanonicalizeNumber(surface, out var number)) return number;

        return $"text:{surface}";
    }

    private static string NormalizeSurface(string value)
    {
        var normalized = (value ?? string.Empty)
            .Normalize(NormalizationForm.FormKC)
            .Replace('−', '-')
            .Replace('–', '-')
            .Replace('—', '-')
            .Trim();
        while (normalized.Length > 0 && normalized[^1] is '。' or '.' or '；' or ';')
            normalized = normalized[..^1].TrimEnd();
        normalized = StructuralWhitespace.Replace(normalized, "$1");
        normalized = string.Join(' ', normalized.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return normalized.ToLowerInvariant();
    }

    private static string RemoveWhitespace(string value) =>
        string.Concat(value.Where(character => !char.IsWhiteSpace(character)));

    private static bool TryCanonicalizeTuple(string value, out string canonical)
    {
        canonical = string.Empty;
        if (value.Length < 5 || value[0] != '(' || value[^1] != ')') return false;
        var parts = value[1..^1].Split(',', StringSplitOptions.TrimEntries);
        if (parts.Length < 2 || parts.Any(part => part.Length == 0)) return false;
        var canonicalParts = new string[parts.Length];
        for (var index = 0; index < parts.Length; index++)
        {
            if (!TryCanonicalizeNumber(parts[index], out canonicalParts[index])) return false;
        }
        canonical = $"tuple:({string.Join(',', canonicalParts)})";
        return true;
    }

    private static bool TryCanonicalizeNumber(string value, out string canonical)
    {
        canonical = string.Empty;
        var candidate = RemoveWhitespace(value);
        if (candidate.EndsWith('个')) candidate = candidate[..^1];
        if (candidate.Length == 0) return false;

        if (decimal.TryParse(candidate, NumberStyles.Float, CultureInfo.InvariantCulture, out var decimalValue))
        {
            canonical = $"number:{decimalValue.ToString("G29", CultureInfo.InvariantCulture)}";
            return true;
        }

        if (!TryParseChineseInteger(candidate, out var integerValue)) return false;
        canonical = $"number:{integerValue.ToString(CultureInfo.InvariantCulture)}";
        return true;
    }

    private static bool TryParseChineseInteger(string value, out long result)
    {
        result = 0;
        if (value.Length == 0 || value.Length > 16) return false;
        var sign = 1L;
        if (value[0] is '负' or '-')
        {
            sign = -1;
            value = value[1..];
        }
        else if (value[0] is '正' or '+') value = value[1..];
        if (value.Length == 0) return false;

        var hasUnit = value.Any(character => ChineseUnit(character) > 0);
        try
        {
            checked
            {
                if (!hasUnit)
                {
                    long digits = 0;
                    foreach (var character in value)
                    {
                        var digit = ChineseDigit(character);
                        if (digit < 0) return false;
                        digits = digits * 10 + digit;
                    }
                    result = sign * digits;
                    return true;
                }

                long total = 0;
                long section = 0;
                long currentDigit = 0;
                foreach (var character in value)
                {
                    var digit = ChineseDigit(character);
                    if (digit >= 0)
                    {
                        currentDigit = digit;
                        continue;
                    }

                    var unit = ChineseUnit(character);
                    if (unit == 0) return false;
                    if (unit == 10_000)
                    {
                        section += currentDigit;
                        if (section == 0) section = 1;
                        total += section * unit;
                        section = 0;
                    }
                    else
                    {
                        if (currentDigit == 0) currentDigit = 1;
                        section += currentDigit * unit;
                    }
                    currentDigit = 0;
                }
                result = sign * (total + section + currentDigit);
                return true;
            }
        }
        catch (OverflowException)
        {
            return false;
        }
    }

    private static int ChineseDigit(char value) => value switch
    {
        '零' or '〇' => 0,
        '一' => 1,
        '二' or '两' => 2,
        '三' => 3,
        '四' => 4,
        '五' => 5,
        '六' => 6,
        '七' => 7,
        '八' => 8,
        '九' => 9,
        _ => -1
    };

    private static int ChineseUnit(char value) => value switch
    {
        '十' => 10,
        '百' => 100,
        '千' => 1_000,
        '万' => 10_000,
        _ => 0
    };
}
