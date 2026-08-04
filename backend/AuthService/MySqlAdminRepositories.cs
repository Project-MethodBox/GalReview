using System.Security.Cryptography;
using MySqlConnector;

public sealed class MySqlAdminRepository(AuthDatabase database) : IAdminRepository
{
    public List<AdminAccount> ListUsers()
    {
        using var c = database.OpenConnection(); using var q = c.CreateCommand();
        q.CommandText = "SELECT CAST(user_id AS CHAR), email FROM auth_credentials ORDER BY email;";
        using var r = q.ExecuteReader(); var result = new List<AdminAccount>();
        while (r.Read()) result.Add(new AdminAccount(DbText(r.GetValue(0)), DbText(r.GetValue(1))));
        return result;
    }
    public bool UserExists(string userId)
    {
        using var c = database.OpenConnection(); using var q = c.CreateCommand();
        q.CommandText = "SELECT COUNT(*) FROM auth_credentials WHERE user_id=@id;";
        q.Parameters.AddWithValue("@id", userId);
        return Convert.ToInt32(q.ExecuteScalar()) == 1;
    }
    public bool DeleteAuthUser(string userId)
    {
        using var c=database.OpenConnection();using var tx=c.BeginTransaction();using var q=c.CreateCommand();q.Transaction=tx;
        q.CommandText="SELECT COUNT(*) FROM auth_credentials WHERE user_id=@id;";q.Parameters.AddWithValue("@id",userId);if(Convert.ToInt32(q.ExecuteScalar())==0){tx.Rollback();return false;}
        q.Parameters.Clear();q.CommandText="DELETE FROM auth_sessions WHERE user_id=@id; DELETE FROM auth_password_resets WHERE user_id=@id; DELETE FROM admin_user_overrides WHERE user_id=@id; DELETE FROM auth_credentials WHERE user_id=@id;";q.Parameters.AddWithValue("@id",userId);q.ExecuteNonQuery();tx.Commit();return true;
    }
    public List<AdminInvitation> ListInvitations()
    {
        using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="SELECT code,type,max_uses,used_count,valid_from,valid_to,created_at FROM admin_invitations ORDER BY created_at DESC;";using var r=q.ExecuteReader();var result=new List<AdminInvitation>();
        while(r.Read())result.Add(new AdminInvitation(r.GetString(0),r.GetString(1),r.GetInt32(2),r.GetInt32(3),r.IsDBNull(4)?null:Utc(r.GetDateTime(4)),r.IsDBNull(5)?null:Utc(r.GetDateTime(5)),Utc(r.GetDateTime(6))));return result;
    }
    public AdminInvitation? CreateInvitation(CreateInvitationRequest request)
    {
        var type=request.Type?.Trim().ToLowerInvariant();if(type is not ("single-use" or "multi-use" or "time-window")||(type=="multi-use"&&!request.MaxUses.HasValue))return null;var max=type=="single-use"?1:request.MaxUses.GetValueOrDefault(10);if(max is <1 or >10000||(type=="time-window"&&(!request.ValidFrom.HasValue||!request.ValidTo.HasValue||request.ValidTo<=request.ValidFrom)))return null;
        for(var i=0;i<3;i++){var value=new AdminInvitation("MS-"+Convert.ToHexString(RandomNumberGenerator.GetBytes(5)),type,max,0,request.ValidFrom,request.ValidTo,DateTimeOffset.UtcNow);try{using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="INSERT INTO admin_invitations (code,type,max_uses,used_count,valid_from,valid_to,created_at) VALUES (@code,@type,@max,0,@from,@to,@created);";q.Parameters.AddWithValue("@code",value.Code);q.Parameters.AddWithValue("@type",value.Type);q.Parameters.AddWithValue("@max",value.MaxUses);q.Parameters.AddWithValue("@from",value.ValidFrom?.UtcDateTime??(object)DBNull.Value);q.Parameters.AddWithValue("@to",value.ValidTo?.UtcDateTime??(object)DBNull.Value);q.Parameters.AddWithValue("@created",value.CreatedAt.UtcDateTime);q.ExecuteNonQuery();return value;}catch(MySqlException ex)when(ex.Number==1062){}}return null;
    }
    public bool DeleteInvitation(string code){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="DELETE FROM admin_invitations WHERE code=@code;";q.Parameters.AddWithValue("@code",code);return q.ExecuteNonQuery()==1;}
    private static string DbText(object value)=>value is Guid guid?guid.ToString():Convert.ToString(value)!;
    private static DateTimeOffset Utc(DateTime value)=>new(DateTime.SpecifyKind(value,DateTimeKind.Utc));
}

public sealed class MySqlAdminAuditRepository(AuthDatabase database) : IAdminAuditRepository
{
    public void Write(AdminAuditRecord record)
    {
        using var connection = database.OpenConnection(); using var command = connection.CreateCommand();
        command.CommandText = "INSERT INTO admin_audit_logs (audit_id,actor_user_id,action,target_user_id,target_invitation_code,outcome,trace_id,created_at) VALUES (@auditId,@actorUserId,@action,@targetUserId,@targetInvitationCode,@outcome,@traceId,@createdAt);";
        command.Parameters.AddWithValue("@auditId", record.AuditId);
        command.Parameters.AddWithValue("@actorUserId", record.ActorUserId);
        command.Parameters.AddWithValue("@action", record.Action);
        command.Parameters.AddWithValue("@targetUserId", record.TargetUserId ?? (object)DBNull.Value);
        command.Parameters.AddWithValue("@targetInvitationCode", record.TargetInvitationCode ?? (object)DBNull.Value);
        command.Parameters.AddWithValue("@outcome", record.Outcome);
        command.Parameters.AddWithValue("@traceId", record.TraceId);
        command.Parameters.AddWithValue("@createdAt", record.CreatedAt.UtcDateTime);
        command.ExecuteNonQuery();
    }
}
