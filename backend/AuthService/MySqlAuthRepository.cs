using System.Security.Cryptography;
using System.Text;
using MySqlConnector;

public sealed class MySqlAuthRepository(AuthDatabase database) : IAuthRepository
{
    public RegistrationOutcome TryCreateCredentialWithInvitation(Credential value, string invitationCode)
    {
        using var connection = database.OpenConnection(); using var transaction = connection.BeginTransaction(); using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT type,max_uses,used_count,valid_from,valid_to FROM admin_invitations WHERE code=@code LIMIT 1 FOR UPDATE;";
        command.Parameters.AddWithValue("@code", invitationCode);
        var foundInvitation = false;
        string? type = null;
        var maxUses = 0;
        var usedCount = 0;
        DateTime? validFrom = null;
        DateTime? validTo = null;
        using (var reader = command.ExecuteReader())
        {
            if (reader.Read())
            {
                foundInvitation = true;
                type = reader.GetString(0);
                maxUses = reader.GetInt32(1);
                usedCount = reader.GetInt32(2);
                validFrom = reader.IsDBNull(3) ? null : reader.GetDateTime(3);
                validTo = reader.IsDBNull(4) ? null : reader.GetDateTime(4);
            }
        }

        if (!foundInvitation) { transaction.Rollback(); return RegistrationOutcome.InvitationUnavailable; }
        var now = DateTime.UtcNow;
        var timeWindowIsValid = type != "time-window" || (validFrom is not null && validTo is not null && validFrom <= now && validTo >= now);
        if (usedCount >= maxUses || !timeWindowIsValid) { transaction.Rollback(); return RegistrationOutcome.InvitationUnavailable; }
        try
        {
            command.Parameters.Clear();
            command.CommandText = "INSERT INTO auth_credentials (user_id,email,password_hash) VALUES (@id,@email,@hash);";
            command.Parameters.AddWithValue("@id", value.UserId); command.Parameters.AddWithValue("@email", value.Email); command.Parameters.AddWithValue("@hash", value.PasswordHash);
            command.ExecuteNonQuery();
        }
        catch (MySqlException exception) when (exception.Number == 1062)
        {
            transaction.Rollback();
            return RegistrationOutcome.EmailAlreadyRegistered;
        }
        command.Parameters.Clear();
        command.CommandText = "UPDATE admin_invitations SET used_count=used_count+1 WHERE code=@code AND used_count<max_uses;";
        command.Parameters.AddWithValue("@code", invitationCode);
        if (command.ExecuteNonQuery() != 1) { transaction.Rollback(); return RegistrationOutcome.InvitationUnavailable; }
        transaction.Commit();
        return RegistrationOutcome.Created;
    }
    public void RollbackRegistration(string userId, string invitationCode)
    {
        using var connection = database.OpenConnection(); using var transaction = connection.BeginTransaction(); using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "DELETE FROM auth_credentials WHERE user_id=@id;";
        command.Parameters.AddWithValue("@id", userId);
        var deleted = command.ExecuteNonQuery();
        if (deleted == 1)
        {
            command.Parameters.Clear();
            command.CommandText = "UPDATE admin_invitations SET used_count=used_count-1 WHERE code=@code AND used_count>0;";
            command.Parameters.AddWithValue("@code", invitationCode);
            command.ExecuteNonQuery();
        }
        transaction.Commit();
    }
    public void DeleteCredential(string id) { using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="DELETE FROM auth_credentials WHERE user_id=@id;";q.Parameters.AddWithValue("@id",id);q.ExecuteNonQuery(); }
    public bool DeleteAccount(string userId)
    {
        using var connection = database.OpenConnection(); using var transaction = connection.BeginTransaction(); using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT CAST(user_id AS CHAR) FROM auth_credentials WHERE user_id=@id LIMIT 1 FOR UPDATE;";
        command.Parameters.AddWithValue("@id", userId);
        if (command.ExecuteScalar() is null) { transaction.Rollback(); return false; }
        command.Parameters.Clear();
        command.CommandText = "DELETE FROM auth_sessions WHERE user_id=@id; DELETE FROM auth_password_resets WHERE user_id=@id; DELETE FROM admin_user_overrides WHERE user_id=@id; DELETE FROM auth_credentials WHERE user_id=@id;";
        command.Parameters.AddWithValue("@id", userId);
        command.ExecuteNonQuery();
        transaction.Commit();
        return true;
    }
    public Credential? FindCredential(string email) { using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="SELECT CAST(user_id AS CHAR),email,password_hash FROM auth_credentials WHERE email=@email;";q.Parameters.AddWithValue("@email",email);using var r=q.ExecuteReader();return r.Read()?new Credential(DbText(r.GetValue(0)),r.GetString(1),r.GetString(2)):null; }
    public Credential? FindCredentialById(string userId) { using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="SELECT CAST(user_id AS CHAR),email,password_hash FROM auth_credentials WHERE user_id=@id;";q.Parameters.AddWithValue("@id",userId);using var r=q.ExecuteReader();return r.Read()?new Credential(DbText(r.GetValue(0)),r.GetString(1),r.GetString(2)):null; }
    public StoredSession CreateSession(string userId,string? deviceName) { var now=DateTimeOffset.UtcNow;var s=new StoredSession(Guid.NewGuid().ToString(),userId,Token(),Token(),now,now.AddMinutes(15),now.AddDays(7),null); InsertSession(s);return s; }
    public StoredSession? FindSession(string id) => FindSession("session_id",id,false);
    public StoredSession? FindByAccessToken(string token)=>FindSession("access_hash",Hash(token),true);
    public StoredSession? TouchAccessToken(string token) { var session=FindByAccessToken(token); var now=DateTimeOffset.UtcNow; return session is null||session.Status!="ACTIVE"||session.AccessExpiresAt<=now?null:session; }
    public bool RevokeSession(string sessionId,string userId) { using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="UPDATE auth_sessions SET revoked_at=UTC_TIMESTAMP(6) WHERE session_id=@id AND user_id=@user AND revoked_at IS NULL;";q.Parameters.AddWithValue("@id",sessionId);q.Parameters.AddWithValue("@user",userId);return q.ExecuteNonQuery()==1; }
    public StoredSession? Rotate(string refresh) { var old=FindSession("refresh_hash",Hash(refresh),true); if(old is null||old.Status!="ACTIVE")return null;using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="UPDATE auth_sessions SET revoked_at=UTC_TIMESTAMP(6) WHERE session_id=@id AND revoked_at IS NULL;";q.Parameters.AddWithValue("@id",old.SessionId);q.ExecuteNonQuery();return CreateSession(old.UserId,null); }
    public void RevokeAllSessions(string userId){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="UPDATE auth_sessions SET revoked_at=UTC_TIMESTAMP(6) WHERE user_id=@id AND revoked_at IS NULL;";q.Parameters.AddWithValue("@id",userId);q.ExecuteNonQuery();}
    public void UpdatePassword(Credential credential){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="UPDATE auth_credentials SET password_hash=@hash WHERE user_id=@id;";q.Parameters.AddWithValue("@id",credential.UserId);q.Parameters.AddWithValue("@hash",credential.PasswordHash);q.ExecuteNonQuery();}
    public string CreatePasswordReset(string userId)
    {
        var token = PasswordResetToken();
        using var c = database.OpenConnection();
        using var tx = c.BeginTransaction();
        using var q = c.CreateCommand();
        q.Transaction = tx;
        q.CommandText = "DELETE FROM auth_password_resets WHERE user_id=@user AND used_at IS NULL;";
        q.Parameters.AddWithValue("@user", userId);
        q.ExecuteNonQuery();
        q.Parameters.Clear();
        q.CommandText = "INSERT INTO auth_password_resets (token_hash,user_id,expires_at,used_at) VALUES (@hash,@user,@expires,NULL);";
        q.Parameters.AddWithValue("@hash", Hash(token));
        q.Parameters.AddWithValue("@user", userId);
        q.Parameters.AddWithValue("@expires", DateTime.UtcNow.AddMinutes(10));
        q.ExecuteNonQuery();
        tx.Commit();
        return token;
    }
    public void DeletePasswordReset(string token){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="DELETE FROM auth_password_resets WHERE token_hash=@hash AND used_at IS NULL;";q.Parameters.AddWithValue("@hash",Hash(token));q.ExecuteNonQuery();}
    public Credential? ConsumePasswordReset(string token){if(token.Length!=6||token.Any(character=>!char.IsAsciiDigit(character)))return null;using var c=database.OpenConnection();using var tx=c.BeginTransaction();using var q=c.CreateCommand();q.Transaction=tx;q.CommandText="SELECT CAST(user_id AS CHAR) FROM auth_password_resets WHERE token_hash=@hash AND used_at IS NULL AND expires_at>UTC_TIMESTAMP(6) LIMIT 1 FOR UPDATE;";q.Parameters.AddWithValue("@hash",Hash(token));var rawUser=q.ExecuteScalar();var user=rawUser is null?null:DbText(rawUser);if(user is null){tx.Rollback();return null;}q.Parameters.Clear();q.CommandText="UPDATE auth_password_resets SET used_at=UTC_TIMESTAMP(6) WHERE token_hash=@hash;";q.Parameters.AddWithValue("@hash",Hash(token));q.ExecuteNonQuery();tx.Commit();using var q2=c.CreateCommand();q2.CommandText="SELECT CAST(user_id AS CHAR),email,password_hash FROM auth_credentials WHERE user_id=@id;";q2.Parameters.AddWithValue("@id",user);using var r=q2.ExecuteReader();return r.Read()?new Credential(DbText(r.GetValue(0)),r.GetString(1),r.GetString(2)):null;}
    private void InsertSession(StoredSession s){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="INSERT INTO auth_sessions (session_id,user_id,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at,revoked_at) VALUES (@id,@user,@access,@refresh,@created,@accessExpires,@refreshExpires,NULL);";q.Parameters.AddWithValue("@id",s.SessionId);q.Parameters.AddWithValue("@user",s.UserId);q.Parameters.AddWithValue("@access",Hash(s.AccessToken));q.Parameters.AddWithValue("@refresh",Hash(s.RefreshToken));q.Parameters.AddWithValue("@created",s.CreatedAt.UtcDateTime);q.Parameters.AddWithValue("@accessExpires",s.AccessExpiresAt.UtcDateTime);q.Parameters.AddWithValue("@refreshExpires",s.RefreshExpiresAt.UtcDateTime);q.ExecuteNonQuery();}
    private StoredSession? FindSession(string column,string value,bool hashed){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText=$"SELECT CAST(session_id AS CHAR),CAST(user_id AS CHAR),created_at,access_expires_at,refresh_expires_at,revoked_at FROM auth_sessions WHERE {ResolveSessionColumn(column)}=@value LIMIT 1;";q.Parameters.AddWithValue("@value",value);using var r=q.ExecuteReader();return r.Read()?new StoredSession(DbText(r.GetValue(0)),DbText(r.GetValue(1)),string.Empty,string.Empty,AsUtc(r.GetDateTime(2)),AsUtc(r.GetDateTime(3)),AsUtc(r.GetDateTime(4)),r.IsDBNull(5)?null:AsUtc(r.GetDateTime(5))):null;}
    /// <summary>
    /// 将逻辑列名映射到物理列名，消除 SQL 注入风险。
    /// 只有预定义的列名允许使用，任何其它值将抛出异常。
    /// </summary>
    private static string ResolveSessionColumn(string column) => column switch
    {
        "session_id" => "session_id",
        "access_hash" => "access_hash",
        "refresh_hash" => "refresh_hash",
        _ => throw new ArgumentException($"Unknown session column: {column}", nameof(column)),
    };
    private static string Token()=>Convert.ToBase64String(RandomNumberGenerator.GetBytes(48)).Replace('+','-').Replace('/','_').TrimEnd('=');
    private static string PasswordResetToken()=>RandomNumberGenerator.GetInt32(1_000_000).ToString("D6");
    private static string Hash(string value)=>Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    private static string DbText(object value)=>value is Guid guid?guid.ToString():Convert.ToString(value)!;
    private static DateTimeOffset AsUtc(DateTime value)=>new(DateTime.SpecifyKind(value,DateTimeKind.Utc));
}
