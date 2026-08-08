namespace CreditService.Domain;

public static class CreditPolicy
{
    public const long UnitsPerCredit = 100_000;
    public const long InitialUnits = UnitsPerCredit;
    public static decimal ToCredits(long units) => decimal.Round(units / (decimal)UnitsPerCredit, 5, MidpointRounding.AwayFromZero);
    public static long ToUnits(decimal credits)
    {
        if (credits <= 0 || credits > 10_000 || decimal.Round(credits, 5) != credits)
            throw new CreditDomainException(400, "VALIDATION_ERROR", "credits 必须大于 0，最多保留 5 位小数。");
        return checked((long)(credits * UnitsPerCredit));
    }
}

public sealed record CreditAccount(Guid UserId, long BalanceUnits, long HeldUnits, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt)
{
    public long AvailableUnits => BalanceUnits - HeldUnits;
}

public enum RedemptionCodeStatus { Active, Redeemed, Revoked, Expired }
public sealed record RedemptionCode(Guid CodeId, string Code, long CreditUnits, RedemptionCodeStatus Status, Guid? RedeemedBy,
    DateTimeOffset? RedeemedAt, DateTimeOffset? ExpiresAt, DateTimeOffset CreatedAt, Guid CreatedBy);

public enum ReservationStatus { Held, Settled, Released }
public sealed record CreditReservation(Guid OperationId, Guid UserId, string OperationType, long EstimatedUnits,
    long ActualUnits, ReservationStatus Status, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt);

public sealed class CreditDomainException(int statusCode, string code, string message, object? details = null) : Exception(message)
{
    public int StatusCode { get; } = statusCode;
    public string Code { get; } = code;
    public object Details { get; } = details ?? new { };
}
