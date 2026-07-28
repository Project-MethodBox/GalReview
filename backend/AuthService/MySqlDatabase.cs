using MySqlConnector;

public sealed class AuthDatabase(string connectionString)
{
    private readonly string _connectionString = connectionString;
    public MySqlConnection OpenConnection() { var connection = new MySqlConnection(_connectionString); connection.Open(); return connection; }
    public void EnsureCreated()
    {
        var builder = new MySqlConnectionStringBuilder(_connectionString);
        if (string.IsNullOrWhiteSpace(builder.Database) || !builder.Database.All(c => char.IsLetterOrDigit(c) || c == '_')) throw new InvalidOperationException("Invalid MySQL database name.");
        var database = builder.Database; builder.Database = string.Empty;
        using (var server = new MySqlConnection(builder.ConnectionString)) { server.Open(); using var create = server.CreateCommand(); create.CommandText = $"CREATE DATABASE IF NOT EXISTS `{database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; create.ExecuteNonQuery(); }
        using var connection = OpenConnection(); using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE IF NOT EXISTS auth_credentials (
              user_id CHAR(36) PRIMARY KEY, email VARCHAR(320) NOT NULL UNIQUE, password_hash TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS auth_sessions (
              session_id CHAR(36) PRIMARY KEY, user_id CHAR(36) NOT NULL,
              access_hash CHAR(64) NOT NULL UNIQUE, refresh_hash CHAR(64) NOT NULL UNIQUE,
              created_at DATETIME(6) NOT NULL, access_expires_at DATETIME(6) NOT NULL,
              refresh_expires_at DATETIME(6) NOT NULL, revoked_at DATETIME(6) NULL,
              INDEX idx_auth_sessions_user (user_id)
            );
            CREATE TABLE IF NOT EXISTS auth_password_resets (
              token_hash CHAR(64) PRIMARY KEY, user_id CHAR(36) NOT NULL,
              expires_at DATETIME(6) NOT NULL, used_at DATETIME(6) NULL
            );
            CREATE TABLE IF NOT EXISTS admin_user_overrides (
              user_id CHAR(36) PRIMARY KEY, display_name VARCHAR(64) NOT NULL, is_active BOOLEAN NOT NULL
            );
            CREATE TABLE IF NOT EXISTS admin_invitations (
              code VARCHAR(32) PRIMARY KEY, type VARCHAR(20) NOT NULL, max_uses INT NOT NULL,
              used_count INT NOT NULL DEFAULT 0, valid_from DATETIME(6) NULL,
              valid_to DATETIME(6) NULL, created_at DATETIME(6) NOT NULL
            );
            CREATE TABLE IF NOT EXISTS admin_audit_logs (
              audit_id CHAR(36) PRIMARY KEY, actor_user_id CHAR(36) NOT NULL,
              action VARCHAR(64) NOT NULL, target_user_id CHAR(36) NULL,
              target_invitation_code VARCHAR(32) NULL, outcome VARCHAR(32) NOT NULL,
              trace_id VARCHAR(128) NOT NULL, created_at DATETIME(6) NOT NULL,
              INDEX idx_admin_audit_created (created_at),
              INDEX idx_admin_audit_target_user (target_user_id)
            );
            """;
        command.ExecuteNonQuery();
        // Compatibility migration: read legacy credential rows once into Auth-owned storage.
        command.CommandText = """
            INSERT IGNORE INTO auth_credentials (user_id, email, password_hash)
            SELECT id, email, password_hash FROM users;
            """;
        command.ExecuteNonQuery();
    }
}
