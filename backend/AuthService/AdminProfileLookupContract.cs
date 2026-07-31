using System.Net.Http.Json;
using System.Text.Json;

public static class AdminProfileLookupContract
{
    public static async Task<Dictionary<string, string>> ReadAsync(
        HttpContent content,
        IReadOnlyCollection<string> requestedUserIds,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(content);
        ArgumentNullException.ThrowIfNull(requestedUserIds);

        ApiEnvelope<AdminProfileSummary?[]>? envelope;
        try
        {
            envelope = await content.ReadFromJsonAsync<
                ApiEnvelope<AdminProfileSummary?[]>>(
                cancellationToken: cancellationToken);
        }
        catch (Exception exception) when (
            exception is JsonException or NotSupportedException)
        {
            throw new UpstreamContractException(
                "UserService profile lookup response is not valid JSON.",
                exception);
        }

        if (envelope?.Data is null ||
            envelope.Meta.ValueKind != JsonValueKind.Object ||
            envelope.Meta.EnumerateObject().Any() ||
            string.IsNullOrWhiteSpace(envelope.TraceId))
        {
            throw new UpstreamContractException(
                "UserService profile lookup response envelope is invalid.");
        }

        var requestedIds = requestedUserIds.ToHashSet(
            StringComparer.Ordinal);
        var displayNames = new Dictionary<string, string>(
            StringComparer.Ordinal);
        foreach (var profile in envelope.Data)
        {
            if (profile is null ||
                !Guid.TryParse(profile.UserId, out _) ||
                !requestedIds.Contains(profile.UserId) ||
                string.IsNullOrWhiteSpace(profile.DisplayName) ||
                !displayNames.TryAdd(
                    profile.UserId,
                    profile.DisplayName))
            {
                throw new UpstreamContractException(
                    "UserService profile lookup data is invalid.");
            }
        }

        return displayNames;
    }
}
