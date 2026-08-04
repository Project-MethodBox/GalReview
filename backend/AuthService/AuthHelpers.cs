using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Identity;

internal static class AuthHelpers
{
    public static async Task<bool> CreateProfileAsync(HttpClient client, string key, string correlationId, string userId, string displayName, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/internal/v1/users") { Content = JsonContent.Create(new { userId, displayName, locale = "zh-CN" }) };
        request.Headers.Add("X-Service-Name", "AuthService"); request.Headers.Add("X-Service-Key", key); request.Headers.Add("X-Correlation-Id", correlationId);
        try { using var response = await client.SendAsync(request, cancellation); return response.IsSuccessStatusCode || response.StatusCode == System.Net.HttpStatusCode.Conflict; } catch (HttpRequestException) { return false; }
    }

    public static async Task<Dictionary<string, string>?> LookupProfileDisplayNamesAsync(HttpClient client, string key, string correlationId, string[] userIds, CancellationToken cancellation)
    {
        if (userIds.Length == 0) return new Dictionary<string, string>(StringComparer.Ordinal);
        using var request = new HttpRequestMessage(HttpMethod.Post, "/internal/v1/users/profile-lookups") { Content = JsonContent.Create(new { userIds }) };
        request.Headers.Add("X-Service-Name", "AuthService"); request.Headers.Add("X-Service-Key", key); request.Headers.Add("X-Correlation-Id", correlationId);
        try
        {
            using var response = await client.SendAsync(request, cancellation);
            if (!response.IsSuccessStatusCode) return null;
            return await AdminProfileLookupContract.ReadAsync(
                response.Content,
                userIds,
                cancellation);
        }
        catch (HttpRequestException) { return null; }
    }

    public static async Task<bool> DeleteUserProfileAsync(HttpClient client, string key, string correlationId, string userId, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/internal/v1/users/{Uri.EscapeDataString(userId)}");
        request.Headers.Add("X-Service-Name", "AuthService"); request.Headers.Add("X-Service-Key", key); request.Headers.Add("X-Correlation-Id", correlationId);
        try
        {
            using var response = await client.SendAsync(request, cancellation);
            return response.IsSuccessStatusCode || response.StatusCode == System.Net.HttpStatusCode.NotFound;
        }
        catch (HttpRequestException) { return false; }
    }

    public static bool IsGateway(HttpContext c, string key)
    {
        var values = c.Request.Headers["X-Gateway-Key"];
        return values.Count == 1 && FixedTimeEquals(values[0]!, key);
    }

    public static string? GetGatewayUser(HttpContext c, string key) => IsGateway(c, key) && !string.IsNullOrWhiteSpace(c.Request.Headers["X-User-Id"]) ? c.Request.Headers["X-User-Id"].ToString() : null;

    public static bool ValidEmail(string? value) => !string.IsNullOrWhiteSpace(value) && value.Length <= 320 && value.Contains('@');
    public static bool ValidName(string? value) => !string.IsNullOrWhiteSpace(value) && value.Trim().Length is >= 1 and <= 64;
    public static bool ValidPassword(string? value) => !string.IsNullOrWhiteSpace(value) && value.Length >= 8;
    public static string? NormalizeInvitationCode(string? value) => string.IsNullOrWhiteSpace(value) || value.Trim().Length > 32 ? null : value.Trim().ToUpperInvariant();

    public static bool PasswordMatches(IPasswordHasher<Credential> hasher, Credential credential, string password)
    {
        try { return hasher.VerifyHashedPassword(credential, credential.PasswordHash, password) is not PasswordVerificationResult.Failed; }
        catch (FormatException) { return false; }
        catch (ArgumentException) { return false; }
    }

    public static IResult Failure(HttpContext c, int status, string code, string message) => Results.Json(ApiFailure.Create(code, message, c.TraceIdentifier), statusCode: status);

    public static bool FixedTimeEquals(string left, string right)
    {
        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);
        var length = Math.Max(leftBytes.Length, rightBytes.Length);
        var paddedLeft = new byte[length];
        var paddedRight = new byte[length];
        leftBytes.CopyTo(paddedLeft, 0);
        rightBytes.CopyTo(paddedRight, 0);
        return CryptographicOperations.FixedTimeEquals(paddedLeft, paddedRight) && leftBytes.Length == rightBytes.Length;
    }

    public static bool IsAdmin(HttpContext c, string key) => GetGatewayUser(c, key) == AdminIdentity.UserId;
}
