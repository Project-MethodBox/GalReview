using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

public sealed class RegistrationSagaTests
{
    private const string InvitationCode = "MS-MOCK2026";

    [Fact]
    public async Task Successful_saga_creates_session_and_marks_completed()
    {
        var fixture = SagaFixture.Create();
        var session = await fixture.Coordinator.ExecuteAsync(
            "alice@example.com", "password123", "Alice", InvitationCode, null, "trace-1", CancellationToken.None);

        Assert.NotNull(session);
        var saga = fixture.Store.FindByUserId(session.UserId);
        Assert.NotNull(saga);
        Assert.Equal(RegistrationSagaStatus.Completed, saga!.Status);
        Assert.True(saga.CredentialCreated);
        Assert.True(saga.ProfileCreated);
        Assert.True(saga.SessionCreated);
    }

    [Fact]
    public async Task Profile_failure_triggers_compensation_and_marks_failed()
    {
        var fixture = SagaFixture.Create(profileSuccess: false);
        await Assert.ThrowsAsync<RegistrationDependencyException>(() =>
            fixture.Coordinator.ExecuteAsync("bob@example.com", "password123", "Bob", InvitationCode, null, "trace-2", CancellationToken.None));

        // 补偿后 saga 状态为 FAILED
        var saga = fixture.Store.FindLatestByEmail("bob@example.com");
        Assert.NotNull(saga);
        Assert.Equal(RegistrationSagaStatus.Failed, saga!.Status);
        Assert.True(saga.CredentialCreated);
        Assert.False(saga.ProfileCreated);
        // 凭据应已被回滚
        Assert.Null(fixture.Repository.FindCredentialById(saga.UserId));
    }

    [Fact]
    public async Task Duplicate_email_marks_failed_without_credential()
    {
        var fixture = SagaFixture.Create();
        // 第一次注册成功
        await fixture.Coordinator.ExecuteAsync("carol@example.com", "password123", "Carol", InvitationCode, null, "trace-3a", CancellationToken.None);
        // 第二次同邮箱应失败
        await Assert.ThrowsAsync<RegistrationConflictException>(() =>
            fixture.Coordinator.ExecuteAsync("carol@example.com", "password123", "Carol2", InvitationCode, null, "trace-3b", CancellationToken.None));

        // 第二次注册的 saga 应为 FAILED
        var saga = fixture.Store.FindLatestByEmail("carol@example.com");
        Assert.NotNull(saga);
        Assert.Equal(RegistrationSagaStatus.Failed, saga!.Status);
        Assert.False(saga.CredentialCreated);
    }

    [Fact]
    public async Task InMemorySagaStore_TryUpdate_returns_false_for_non_pending()
    {
        var store = new InMemoryRegistrationSagaStore();
        var record = RegistrationSagaRecord.Start("user-1", "e@x.com", "Name", "CODE", null);
        store.Create(record);
        Assert.True(store.TryUpdate(record.SagaId, RegistrationSagaStatus.Completed, true, true, true, null));
        // 已是 COMPLETED，再次更新应失败
        Assert.False(store.TryUpdate(record.SagaId, RegistrationSagaStatus.Failed, true, true, true, "test"));
    }

    [Fact]
    public void InMemorySagaStore_FindStale_only_returns_old_pending()
    {
        var store = new InMemoryRegistrationSagaStore();
        var oldSaga = RegistrationSagaRecord.Start("user-old", "old@x.com", "Old", "CODE", null);
        store.Create(oldSaga with { CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-10) });
        var newSaga = RegistrationSagaRecord.Start("user-new", "new@x.com", "New", "CODE", null);
        store.Create(newSaga);

        var stale = store.FindStale(TimeSpan.FromMinutes(5), 10);
        Assert.Single(stale);
        Assert.Equal("user-old", stale[0].UserId);
    }

    private sealed class SagaFixture
    {
        public MockAuthStore AuthStore { get; }
        public InMemoryAuthRepository Repository { get; }
        public InMemoryRegistrationSagaStore Store { get; }
        public RegistrationSagaCoordinator Coordinator { get; }

        private SagaFixture(MockAuthStore store, InMemoryAuthRepository repo, InMemoryRegistrationSagaStore sagaStore, RegistrationSagaCoordinator coordinator)
        {
            AuthStore = store; Repository = repo; Store = sagaStore; Coordinator = coordinator;
        }

        public static SagaFixture Create(bool profileSuccess = true)
        {
            var hasher = new PasswordHasher<Credential>();
            var authStore = new MockAuthStore(hasher);
            var repo = new InMemoryAuthRepository(authStore);
            var sagaStore = new InMemoryRegistrationSagaStore();
            var httpFactory = new StubHttpClientFactory(profileSuccess);
            var coordinator = new RegistrationSagaCoordinator(
                repo, sagaStore, hasher, httpFactory, "gateway-key",
                NullLogger<RegistrationSagaCoordinator>.Instance);

            return new SagaFixture(authStore, repo, sagaStore, coordinator);
        }
    }

    /// <summary>
    /// 简单的 IHttpClientFactory 桩：profileSuccess=false 时所有 HTTP 调用返回失败。
    /// </summary>
    private sealed class StubHttpClientFactory(bool profileSuccess) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name)
        {
            var handler = new StubHandler(profileSuccess);
            return new HttpClient(handler) { BaseAddress = new Uri("http://localhost:5000") };
        }
    }

    private sealed class StubHandler(bool profileSuccess) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            // CreateProfileAsync 对 /internal/v1/users POST 请求，成功返回 2xx 或 409
            // DeleteUserProfileAsync 对 /internal/v1/users/{id} DELETE 请求
            if (request.Method == HttpMethod.Post && request.RequestUri?.AbsolutePath == "/internal/v1/users")
            {
                var status = profileSuccess ? System.Net.HttpStatusCode.OK : System.Net.HttpStatusCode.ServiceUnavailable;
                return Task.FromResult(new HttpResponseMessage(status));
            }
            if (request.Method == HttpMethod.Delete)
            {
                return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK));
            }
            return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.NotFound));
        }
    }
}
