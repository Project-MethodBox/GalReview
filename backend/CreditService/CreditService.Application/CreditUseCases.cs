using CreditService.Domain;
using MediatR;

namespace CreditService.Application;

public interface ICreditRepository
{
    CreditAccount Provision(Guid userId);
    CreditAccount? GetAccount(Guid userId);
    void DeleteAccount(Guid userId);
    (CreditAccount Account, RedemptionCode Code) Redeem(Guid userId, string code);
    IReadOnlyList<RedemptionCode> ListCodes();
    IReadOnlyList<RedemptionCode> CreateCodes(Guid adminUserId, int count, long creditUnits, DateTimeOffset? expiresAt);
    bool RevokeCode(Guid codeId);
    CreditReservation Reserve(Guid userId, Guid operationId, string operationType, long estimatedUnits);
    CreditReservation Settle(Guid operationId, long actualUnits);
    CreditReservation Release(Guid operationId);
}

public sealed record CreditBalance(Guid UserId, decimal Balance, decimal Available, decimal Held, DateTimeOffset UpdatedAt)
{
    public static CreditBalance From(CreditAccount account) => new(account.UserId, CreditPolicy.ToCredits(account.BalanceUnits),
        CreditPolicy.ToCredits(account.AvailableUnits), CreditPolicy.ToCredits(account.HeldUnits), account.UpdatedAt);
}
public sealed record RedemptionCodeView(Guid CodeId, string Code, decimal Credits, string Status, Guid? RedeemedBy, DateTimeOffset? RedeemedAt, DateTimeOffset? ExpiresAt, DateTimeOffset CreatedAt);
public sealed record ReservationView(Guid OperationId, string OperationType, decimal EstimatedCredits, decimal ActualCredits, string Status);

public sealed record ProvisionAccountCommand(Guid UserId) : IRequest<CreditBalance>;
public sealed record DeleteAccountCommand(Guid UserId) : IRequest;
public sealed record GetBalanceQuery(Guid UserId) : IRequest<CreditBalance>;
public sealed record RedeemCodeCommand(Guid UserId, string Code) : IRequest<CreditBalance>;
public sealed record ListCodesQuery : IRequest<IReadOnlyList<RedemptionCodeView>>;
public sealed record CreateCodeBatchCommand(Guid AdminUserId, int Count, decimal CreditsPerCode, DateTimeOffset? ExpiresAt) : IRequest<IReadOnlyList<RedemptionCodeView>>;
public sealed record RevokeCodeCommand(Guid CodeId) : IRequest;
public sealed record ReserveCreditsCommand(Guid UserId, Guid OperationId, string OperationType, long EstimatedTokenUnits) : IRequest<ReservationView>;
public sealed record SettleCreditsCommand(Guid OperationId, long ActualTokenUnits) : IRequest<ReservationView>;
public sealed record ReleaseCreditsCommand(Guid OperationId) : IRequest<ReservationView>;

public sealed class CreditHandlers(ICreditRepository repository) :
    IRequestHandler<ProvisionAccountCommand, CreditBalance>, IRequestHandler<DeleteAccountCommand>,
    IRequestHandler<GetBalanceQuery, CreditBalance>, IRequestHandler<RedeemCodeCommand, CreditBalance>,
    IRequestHandler<ListCodesQuery, IReadOnlyList<RedemptionCodeView>>,
    IRequestHandler<CreateCodeBatchCommand, IReadOnlyList<RedemptionCodeView>>, IRequestHandler<RevokeCodeCommand>,
    IRequestHandler<ReserveCreditsCommand, ReservationView>, IRequestHandler<SettleCreditsCommand, ReservationView>,
    IRequestHandler<ReleaseCreditsCommand, ReservationView>
{
    public Task<CreditBalance> Handle(ProvisionAccountCommand request, CancellationToken ct) => Task.FromResult(CreditBalance.From(repository.Provision(request.UserId)));
    public Task Handle(DeleteAccountCommand request, CancellationToken ct) { repository.DeleteAccount(request.UserId); return Task.CompletedTask; }
    // Provision is idempotent. Lazily provisioning here migrates users created
    // before CreditService was deployed without requiring a cross-database scan.
    public Task<CreditBalance> Handle(GetBalanceQuery request, CancellationToken ct) => Task.FromResult(CreditBalance.From(repository.Provision(request.UserId)));
    public Task<CreditBalance> Handle(RedeemCodeCommand request, CancellationToken ct)
    {
        repository.Provision(request.UserId);
        var code = NormalizeCode(request.Code); var result = repository.Redeem(request.UserId, code); return Task.FromResult(CreditBalance.From(result.Account));
    }
    public Task<IReadOnlyList<RedemptionCodeView>> Handle(ListCodesQuery request, CancellationToken ct) => Task.FromResult<IReadOnlyList<RedemptionCodeView>>(repository.ListCodes().Select(View).ToArray());
    public Task<IReadOnlyList<RedemptionCodeView>> Handle(CreateCodeBatchCommand request, CancellationToken ct)
    {
        if (request.Count is < 1 or > 1000) throw new CreditDomainException(400, "VALIDATION_ERROR", "批量数量必须在 1 到 1000 之间。");
        if (request.ExpiresAt is not null && request.ExpiresAt <= DateTimeOffset.UtcNow) throw new CreditDomainException(400, "VALIDATION_ERROR", "过期时间必须晚于当前时间。");
        var units = CreditPolicy.ToUnits(request.CreditsPerCode);
        return Task.FromResult<IReadOnlyList<RedemptionCodeView>>(repository.CreateCodes(request.AdminUserId, request.Count, units, request.ExpiresAt).Select(View).ToArray());
    }
    public Task Handle(RevokeCodeCommand request, CancellationToken ct)
    {
        if (!repository.RevokeCode(request.CodeId)) throw NotFound(); return Task.CompletedTask;
    }
    public Task<ReservationView> Handle(ReserveCreditsCommand request, CancellationToken ct)
    {
        if (request.EstimatedTokenUnits <= 0 || request.EstimatedTokenUnits > 10_000_000_000) throw new CreditDomainException(400, "VALIDATION_ERROR", "estimatedTokenUnits 超出允许范围。");
        if (string.IsNullOrWhiteSpace(request.OperationType) || request.OperationType.Length > 64) throw new CreditDomainException(400, "VALIDATION_ERROR", "operationType 格式不正确。");
        repository.Provision(request.UserId);
        return Task.FromResult(View(repository.Reserve(request.UserId, request.OperationId, request.OperationType.Trim().ToUpperInvariant(), request.EstimatedTokenUnits)));
    }
    public Task<ReservationView> Handle(SettleCreditsCommand request, CancellationToken ct)
    {
        if (request.ActualTokenUnits < 0 || request.ActualTokenUnits > 10_000_000_000) throw new CreditDomainException(400, "VALIDATION_ERROR", "actualTokenUnits 超出允许范围。");
        return Task.FromResult(View(repository.Settle(request.OperationId, request.ActualTokenUnits)));
    }
    public Task<ReservationView> Handle(ReleaseCreditsCommand request, CancellationToken ct) => Task.FromResult(View(repository.Release(request.OperationId)));
    private static string NormalizeCode(string value) => string.IsNullOrWhiteSpace(value) || value.Trim().Length > 48 ? throw new CreditDomainException(400, "VALIDATION_ERROR", "兑换码格式不正确。") : value.Trim().ToUpperInvariant();
    private static CreditDomainException NotFound() => new(404, "RESOURCE_NOT_FOUND", "资源不存在。");
    private static RedemptionCodeView View(RedemptionCode x) => new(x.CodeId, x.Code, CreditPolicy.ToCredits(x.CreditUnits), x.Status.ToString().ToUpperInvariant(), x.RedeemedBy, x.RedeemedAt, x.ExpiresAt, x.CreatedAt);
    private static ReservationView View(CreditReservation x) => new(x.OperationId, x.OperationType, CreditPolicy.ToCredits(x.EstimatedUnits), CreditPolicy.ToCredits(x.ActualUnits), x.Status.ToString().ToUpperInvariant());
}
