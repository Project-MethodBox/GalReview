using System.Text.Json;
using Microsoft.AspNetCore.Identity;
using Xunit;

public sealed class AdminPasswordHashTests
{
    [Fact]
    public void DevelopmentAdminHashIsAcceptedByConfiguredPasswordHasher()
    {
        var settingsPath = Path.Combine(AppContext.BaseDirectory, "appsettings.Development.json");
        using var settings = JsonDocument.Parse(File.ReadAllText(settingsPath));
        var passwordHash = settings.RootElement
            .GetProperty("Admin")
            .GetProperty("PasswordHash")
            .GetString();

        Assert.False(string.IsNullOrWhiteSpace(passwordHash));
        var credential = new Credential(Guid.NewGuid().ToString(), "admin", passwordHash!);
        var result = new PasswordHasher<Credential>()
            .VerifyHashedPassword(credential, passwordHash!, "admin");

        Assert.NotEqual(PasswordVerificationResult.Failed, result);
    }
}
