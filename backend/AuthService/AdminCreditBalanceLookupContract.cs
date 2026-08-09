using System.Net.Http.Json;
using System.Text.Json;

public static class AdminCreditBalanceLookupContract
{
    public static async Task<Dictionary<string, decimal>> ReadAsync(
        HttpContent content,
        IReadOnlyCollection<string> requestedUserIds,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(content);
        ArgumentNullException.ThrowIfNull(requestedUserIds);

        ApiEnvelope<AdminCreditBalanceSummary?[]>? envelope;
        try
        {
            envelope = await content.ReadFromJsonAsync<ApiEnvelope<AdminCreditBalanceSummary?[]>>(
                cancellationToken: cancellationToken);
        }
        catch (Exception exception) when (exception is JsonException or NotSupportedException)
        {
            throw new UpstreamContractException(
                "CreditService balance lookup response is not valid JSON.",
                exception);
        }

        if (envelope?.Data is null ||
            envelope.Meta.ValueKind != JsonValueKind.Object ||
            envelope.Meta.EnumerateObject().Any() ||
            string.IsNullOrWhiteSpace(envelope.TraceId))
        {
            throw new UpstreamContractException(
                "CreditService balance lookup response envelope is invalid.");
        }

        var requestedById = new Dictionary<Guid, string>();
        foreach (var requestedUserId in requestedUserIds)
        {
            if (!Guid.TryParse(requestedUserId, out var parsedId) ||
                !requestedById.TryAdd(parsedId, requestedUserId))
            {
                throw new ArgumentException(
                    "Requested user IDs must be unique UUIDs.",
                    nameof(requestedUserIds));
            }
        }

        var balances = new Dictionary<string, decimal>(StringComparer.Ordinal);
        foreach (var balance in envelope.Data)
        {
            if (balance is null ||
                !Guid.TryParse(balance.UserId, out var userId) ||
                !requestedById.TryGetValue(userId, out var requestedUserId) ||
                balance.Balance < 0 ||
                balance.Available < 0 ||
                balance.Held < 0 ||
                balance.Available + balance.Held != balance.Balance ||
                !balances.TryAdd(requestedUserId, balance.Available))
            {
                throw new UpstreamContractException(
                    "CreditService balance lookup data is invalid.");
            }
        }

        if (balances.Count != requestedById.Count)
        {
            throw new UpstreamContractException(
                "CreditService balance lookup data is incomplete.");
        }

        return balances;
    }
}

public sealed record AdminCreditBalanceSummary(
    string UserId,
    decimal Balance,
    decimal Available,
    decimal Held,
    DateTimeOffset UpdatedAt);
