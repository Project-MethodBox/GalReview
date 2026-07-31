using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Primitives;

public static class InternalServiceAccessPolicy
{
    public static IReadOnlySet<string> CreateAllowlist(IConfigurationSection section, params string[] defaults)
    {
        var configured = section.GetChildren()
            .Select(child => child.Value)
            .Concat(SplitScalar(section.Value))
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value!.Trim())
            .ToArray();

        return new HashSet<string>(
            section.Exists() ? configured : defaults,
            StringComparer.OrdinalIgnoreCase);
    }

    public static bool IsTrusted(
        IHeaderDictionary headers,
        string gatewayKey,
        IReadOnlySet<string>? allowedServices = null)
    {
        if (!HasSingleExactValue(headers, "X-Gateway-Key", gatewayKey, StringComparison.Ordinal))
        {
            return false;
        }

        if (!headers.TryGetValue("X-Service-Name", out var serviceNames) || serviceNames.Count != 1)
        {
            return false;
        }

        var serviceName = serviceNames[0]?.Trim();
        if (string.IsNullOrWhiteSpace(serviceName))
        {
            return false;
        }

        return allowedServices is null || allowedServices.Contains(serviceName);
    }

    private static bool HasSingleExactValue(
        IHeaderDictionary headers,
        string headerName,
        string expected,
        StringComparison comparison)
    {
        return headers.TryGetValue(headerName, out StringValues values)
            && values.Count == 1
            && string.Equals(values[0], expected, comparison);
    }

    private static IEnumerable<string?> SplitScalar(string? value)
    {
        return value?.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            ?? Array.Empty<string>();
    }
}
