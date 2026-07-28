using MailKit.Net.Smtp;
using MailKit.Security;
using MimeKit;

public sealed class PasswordResetEmailSender(
    IConfiguration configuration,
    ILogger<PasswordResetEmailSender> logger)
{
    public async Task<bool> SendAsync(string recipient, string resetToken, string correlationId, CancellationToken cancellationToken)
    {
        var host = configuration["Email:SmtpHost"];
        var username = configuration["Email:Username"];
        var password = configuration["Email:Password"];
        var fromAddress = configuration["Email:FromAddress"];

        if (string.IsNullOrWhiteSpace(host) || string.IsNullOrWhiteSpace(username) ||
            string.IsNullOrWhiteSpace(password) || string.IsNullOrWhiteSpace(fromAddress))
        {
            logger.LogWarning("Password-reset email is not configured. CorrelationId: {CorrelationId}", correlationId);
            return false;
        }

        var port = configuration.GetValue("Email:SmtpPort", 465);
        var useSsl = configuration.GetValue("Email:UseSsl", true);
        var fromName = configuration["Email:FromName"] ?? "\u5343\u77e5\u4e07\u7406";

        var message = new MimeMessage();
        message.From.Add(new MailboxAddress(fromName, fromAddress));
        message.To.Add(MailboxAddress.Parse(recipient));
        message.Subject = "\u60a8\u7684\u91cd\u7f6e\u9a8c\u8bc1\u7801";
        message.Body = new TextPart("html")
        {
            Text = $"<div style=\"line-height: 1.7;\">\u60a8\u597d\uff0c<br>\u6211\u4eec\u6536\u5230\u4e86\u60a8\u7684\u5bc6\u7801\u91cd\u7f6e\u8bf7\u6c42\u3002<br>\u4f60\u7684\u91cd\u7f6e\u4ee4\u724c\u4e3a\uff1a<br><span style=\"font-size: 20px; font-weight: 700; letter-spacing: 1px;\">{resetToken}</span><br>\u8bf7\u5c06\u8be5\u4ee4\u724c\u586b\u5165\u5bc6\u7801\u6062\u590d\u9875\u9762\uff0c\u5e76\u8bbe\u7f6e\u65b0\u5bc6\u7801\u3002\u4ee4\u724c\u5c06\u5728 10 \u5206\u949f\u540e\u5931\u6548\u3002\u5982\u679c\u4e0d\u662f\u4f60\u672c\u4eba\u64cd\u4f5c\uff0c\u8bf7\u5ffd\u7565\u6b64\u90ae\u4ef6\u3002</div>"
        };

        try
        {
            using var client = new SmtpClient { Timeout = 10_000 };
            var security = useSsl ? SecureSocketOptions.SslOnConnect : SecureSocketOptions.StartTlsWhenAvailable;
            await client.ConnectAsync(host, port, security, cancellationToken);
            await client.AuthenticateAsync(username, password, cancellationToken);
            await client.SendAsync(message, cancellationToken);
            await client.DisconnectAsync(true, cancellationToken);
            return true;
        }
        catch (Exception exception)
        {
            logger.LogError(exception, "Password-reset email delivery failed. CorrelationId: {CorrelationId}", correlationId);
            return false;
        }
    }
}
