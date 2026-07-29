using System.Collections;
using System.Globalization;

namespace KnowledgeService.Persistence.Mapping;

internal static class Neo4jPropertyReader
{
    public static string String(
        IReadOnlyDictionary<string, object> properties,
        string key,
        string defaultValue = "")
    {
        return properties.TryGetValue(key, out var value) && value is not null
            ? Convert.ToString(value, CultureInfo.InvariantCulture) ?? defaultValue
            : defaultValue;
    }

    public static string? NullableString(
        IReadOnlyDictionary<string, object> properties,
        string key)
    {
        var value = String(properties, key);
        return string.IsNullOrEmpty(value) ? null : value;
    }

    public static Guid Guid(
        IReadOnlyDictionary<string, object> properties,
        string key)
    {
        return System.Guid.Parse(String(properties, key));
    }

    public static Guid? NullableGuid(
        IReadOnlyDictionary<string, object> properties,
        string key)
    {
        var value = NullableString(properties, key);
        return value is null ? null : System.Guid.Parse(value);
    }

    public static int Int32(
        IReadOnlyDictionary<string, object> properties,
        string key,
        int defaultValue = 0)
    {
        return properties.TryGetValue(key, out var value) && value is not null
            ? Convert.ToInt32(value, CultureInfo.InvariantCulture)
            : defaultValue;
    }

    public static long Int64(
        IReadOnlyDictionary<string, object> properties,
        string key,
        long defaultValue = 0)
    {
        return properties.TryGetValue(key, out var value) && value is not null
            ? Convert.ToInt64(value, CultureInfo.InvariantCulture)
            : defaultValue;
    }

    public static double Double(
        IReadOnlyDictionary<string, object> properties,
        string key,
        double defaultValue = 0)
    {
        return properties.TryGetValue(key, out var value) && value is not null
            ? Convert.ToDouble(value, CultureInfo.InvariantCulture)
            : defaultValue;
    }

    public static bool Boolean(
        IReadOnlyDictionary<string, object> properties,
        string key,
        bool defaultValue = false)
    {
        return properties.TryGetValue(key, out var value) && value is not null
            ? Convert.ToBoolean(value, CultureInfo.InvariantCulture)
            : defaultValue;
    }

    public static DateTimeOffset DateTimeOffset(
        IReadOnlyDictionary<string, object> properties,
        string key)
    {
        return System.DateTimeOffset.Parse(
            String(properties, key),
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind);
    }

    public static DateTimeOffset? NullableDateTimeOffset(
        IReadOnlyDictionary<string, object> properties,
        string key)
    {
        var value = NullableString(properties, key);
        return value is null
            ? null
            : System.DateTimeOffset.Parse(
                value,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind);
    }

    public static TEnum Enum<TEnum>(
        IReadOnlyDictionary<string, object> properties,
        string key)
        where TEnum : struct, Enum
    {
        return System.Enum.Parse<TEnum>(String(properties, key), true);
    }

    public static IReadOnlyList<string> StringList(
        IReadOnlyDictionary<string, object> properties,
        string key)
    {
        if (!properties.TryGetValue(key, out var value) || value is null)
        {
            return [];
        }

        if (value is IEnumerable<string> strings)
        {
            return strings.ToArray();
        }

        if (value is IEnumerable values and not string)
        {
            return values
                .Cast<object?>()
                .Where(item => item is not null)
                .Select(item => Convert.ToString(
                    item,
                    CultureInfo.InvariantCulture) ?? string.Empty)
                .ToArray();
        }

        return [Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty];
    }

    public static IReadOnlyList<Guid> GuidList(
        IReadOnlyDictionary<string, object> properties,
        string key)
    {
        return StringList(properties, key)
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(System.Guid.Parse)
            .ToArray();
    }
}
