namespace KnowledgeService.Application.Exceptions;

public sealed class KnowledgeServiceException : Exception
{
    public KnowledgeServiceException(
        int statusCode,
        string code,
        string message,
        IReadOnlyDictionary<string, object?>? details = null,
        Exception? innerException = null)
        : base(message, innerException)
    {
        StatusCode = statusCode;
        Code = code;
        Details = details ?? new Dictionary<string, object?>();
    }

    public int StatusCode { get; }

    public string Code { get; }

    public IReadOnlyDictionary<string, object?> Details { get; }
}
