using Microsoft.AspNetCore.Identity;
using Xunit;

public sealed class InvitationRepositoryTests
{
    [Fact]
    public void Time_window_invitation_has_unlimited_uses_during_its_valid_period()
    {
        var (admin, auth) = CreateRepositories();
        var now = DateTimeOffset.UtcNow;
        var invitation = admin.CreateInvitation(new CreateInvitationRequest(
            "time-window",
            1,
            now.AddMinutes(-5),
            now.AddMinutes(5)));

        Assert.NotNull(invitation);
        Assert.Equal(int.MaxValue, invitation.MaxUses);
        Assert.Equal(RegistrationOutcome.Created, auth.TryCreateCredentialWithInvitation(
            Credential.New("window-one@example.com"),
            invitation.Code));
        Assert.Equal(RegistrationOutcome.Created, auth.TryCreateCredentialWithInvitation(
            Credential.New("window-two@example.com"),
            invitation.Code));
    }

    [Fact]
    public void Time_window_invitation_is_rejected_outside_its_valid_period()
    {
        var (admin, auth) = CreateRepositories();
        var now = DateTimeOffset.UtcNow;
        var invitation = admin.CreateInvitation(new CreateInvitationRequest(
            "time-window",
            null,
            now.AddMinutes(-10),
            now.AddMinutes(-5)));

        Assert.NotNull(invitation);
        Assert.Equal(RegistrationOutcome.InvitationUnavailable, auth.TryCreateCredentialWithInvitation(
            Credential.New("expired-window@example.com"),
            invitation.Code));
    }

    [Fact]
    public void Multi_use_invitation_still_obeys_its_maximum_use_count()
    {
        var (admin, auth) = CreateRepositories();
        var invitation = admin.CreateInvitation(new CreateInvitationRequest(
            "multi-use",
            1,
            null,
            null));

        Assert.NotNull(invitation);
        Assert.Equal(RegistrationOutcome.Created, auth.TryCreateCredentialWithInvitation(
            Credential.New("multi-one@example.com"),
            invitation.Code));
        Assert.Equal(RegistrationOutcome.InvitationUnavailable, auth.TryCreateCredentialWithInvitation(
            Credential.New("multi-two@example.com"),
            invitation.Code));
    }

    private static (InMemoryAdminRepository Admin, InMemoryAuthRepository Auth) CreateRepositories()
    {
        var store = new MockAuthStore(new PasswordHasher<Credential>());
        return (new InMemoryAdminRepository(store), new InMemoryAuthRepository(store));
    }
}
