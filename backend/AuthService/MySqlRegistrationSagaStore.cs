using MySqlConnector;

public sealed class MySqlRegistrationSagaStore(AuthDatabase database) : IRegistrationSagaStore
{
    public void Create(RegistrationSagaRecord record)
    {
        using var connection = database.OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO registration_sagas
              (saga_id, user_id, email, display_name, invitation_code, device_name,
               status, credential_created, profile_created, session_created,
               created_at, updated_at, compensated_at, last_error)
            VALUES
              (@sagaId, @userId, @email, @displayName, @invitationCode, @deviceName,
               @status, @credentialCreated, @profileCreated, @sessionCreated,
               @createdAt, @updatedAt, NULL, @lastError);
            """;
        command.Parameters.AddWithValue("@sagaId", record.SagaId);
        command.Parameters.AddWithValue("@userId", record.UserId);
        command.Parameters.AddWithValue("@email", record.Email);
        command.Parameters.AddWithValue("@displayName", record.DisplayName);
        command.Parameters.AddWithValue("@invitationCode", record.InvitationCode);
        command.Parameters.AddWithValue("@deviceName", (object?)record.DeviceName ?? DBNull.Value);
        command.Parameters.AddWithValue("@status", StatusToString(record.Status));
        command.Parameters.AddWithValue("@credentialCreated", record.CredentialCreated);
        command.Parameters.AddWithValue("@profileCreated", record.ProfileCreated);
        command.Parameters.AddWithValue("@sessionCreated", record.SessionCreated);
        command.Parameters.AddWithValue("@createdAt", record.CreatedAt.UtcDateTime);
        command.Parameters.AddWithValue("@updatedAt", record.UpdatedAt.UtcDateTime);
        command.Parameters.AddWithValue("@lastError", (object?)record.LastError ?? DBNull.Value);
        command.ExecuteNonQuery();
    }

    public bool TryUpdate(string sagaId, RegistrationSagaStatus status, bool credentialCreated, bool profileCreated, bool sessionCreated, string? lastError)
    {
        using var connection = database.OpenConnection();
        using var command = connection.CreateCommand();
        // 乐观并发：只有当记录仍为 PENDING（或从 PENDING→COMPLETED）时才更新。
        // COMPENSATING/FAILED 是终态（或由对账 worker 独占处理），不会被请求线程覆盖。
        command.CommandText = """
            UPDATE registration_sagas
            SET status=@status,
                credential_created=@credentialCreated,
                profile_created=@profileCreated,
                session_created=@sessionCreated,
                updated_at=UTC_TIMESTAMP(6),
                last_error=@lastError
            WHERE saga_id=@sagaId AND status='PENDING';
            """;
        command.Parameters.AddWithValue("@sagaId", sagaId);
        command.Parameters.AddWithValue("@status", StatusToString(status));
        command.Parameters.AddWithValue("@credentialCreated", credentialCreated);
        command.Parameters.AddWithValue("@profileCreated", profileCreated);
        command.Parameters.AddWithValue("@sessionCreated", sessionCreated);
        command.Parameters.AddWithValue("@lastError", (object?)lastError ?? DBNull.Value);
        return command.ExecuteNonQuery() == 1;
    }

    public bool TryMarkCompensated(string sagaId)
    {
        using var connection = database.OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            UPDATE registration_sagas
            SET status='FAILED',
                compensated_at=UTC_TIMESTAMP(6),
                updated_at=UTC_TIMESTAMP(6)
            WHERE saga_id=@sagaId AND status='COMPENSATING';
            """;
        command.Parameters.AddWithValue("@sagaId", sagaId);
        return command.ExecuteNonQuery() == 1;
    }

    public IReadOnlyList<RegistrationSagaRecord> FindStale(TimeSpan age, int limit)
    {
        using var connection = database.OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT saga_id, user_id, email, display_name, invitation_code, device_name,
                   status, credential_created, profile_created, session_created,
                   created_at, updated_at, compensated_at, last_error
            FROM registration_sagas
            WHERE status='PENDING' AND created_at < (UTC_TIMESTAMP(6) - INTERVAL @ageSecond SECOND)
            ORDER BY created_at ASC
            LIMIT @limit;
            """;
        command.Parameters.AddWithValue("@ageSecond", (int)age.TotalSeconds);
        command.Parameters.AddWithValue("@limit", limit);
        using var reader = command.ExecuteReader();
        var results = new List<RegistrationSagaRecord>();
        while (reader.Read()) results.Add(ReadRecord(reader));
        return results;
    }

    public RegistrationSagaRecord? Find(string sagaId)
    {
        using var connection = database.OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT saga_id, user_id, email, display_name, invitation_code, device_name,
                   status, credential_created, profile_created, session_created,
                   created_at, updated_at, compensated_at, last_error
            FROM registration_sagas
            WHERE saga_id=@sagaId;
            """;
        command.Parameters.AddWithValue("@sagaId", sagaId);
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadRecord(reader) : null;
    }

    public RegistrationSagaRecord? FindByUserId(string userId)
    {
        using var connection = database.OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT saga_id, user_id, email, display_name, invitation_code, device_name,
                   status, credential_created, profile_created, session_created,
                   created_at, updated_at, compensated_at, last_error
            FROM registration_sagas
            WHERE user_id=@userId
            ORDER BY created_at DESC
            LIMIT 1;
            """;
        command.Parameters.AddWithValue("@userId", userId);
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadRecord(reader) : null;
    }

    public RegistrationSagaRecord? FindLatestByEmail(string email)
    {
        using var connection = database.OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT saga_id, user_id, email, display_name, invitation_code, device_name,
                   status, credential_created, profile_created, session_created,
                   created_at, updated_at, compensated_at, last_error
            FROM registration_sagas
            WHERE email=@email
            ORDER BY created_at DESC
            LIMIT 1;
            """;
        command.Parameters.AddWithValue("@email", email);
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadRecord(reader) : null;
    }

    private static RegistrationSagaRecord ReadRecord(MySqlDataReader reader)
    {
        return new RegistrationSagaRecord(
            SagaId: reader.GetString(0),
            UserId: reader.GetString(1),
            Email: reader.GetString(2),
            DisplayName: reader.GetString(3),
            InvitationCode: reader.GetString(4),
            DeviceName: reader.IsDBNull(5) ? null : reader.GetString(5),
            Status: ParseStatus(reader.GetString(6)),
            CredentialCreated: reader.GetBoolean(7),
            ProfileCreated: reader.GetBoolean(8),
            SessionCreated: reader.GetBoolean(9),
            CreatedAt: AsUtc(reader.GetDateTime(10)),
            UpdatedAt: AsUtc(reader.GetDateTime(11)),
            CompensatedAt: reader.IsDBNull(12) ? null : AsUtc(reader.GetDateTime(12)),
            LastError: reader.IsDBNull(13) ? null : reader.GetString(13));
    }

    private static string StatusToString(RegistrationSagaStatus status) => status switch
    {
        RegistrationSagaStatus.Pending => "PENDING",
        RegistrationSagaStatus.Completed => "COMPLETED",
        RegistrationSagaStatus.Compensating => "COMPENSATING",
        RegistrationSagaStatus.Failed => "FAILED",
        _ => throw new ArgumentOutOfRangeException(nameof(status), status, "Unknown saga status"),
    };

    private static RegistrationSagaStatus ParseStatus(string value) => value switch
    {
        "PENDING" => RegistrationSagaStatus.Pending,
        "COMPLETED" => RegistrationSagaStatus.Completed,
        "COMPENSATING" => RegistrationSagaStatus.Compensating,
        "FAILED" => RegistrationSagaStatus.Failed,
        _ => RegistrationSagaStatus.Pending,
    };

    private static DateTimeOffset AsUtc(DateTime value) => new(DateTime.SpecifyKind(value, DateTimeKind.Utc));
}
