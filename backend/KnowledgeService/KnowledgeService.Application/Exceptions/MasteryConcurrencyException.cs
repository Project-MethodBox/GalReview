namespace KnowledgeService.Application.Exceptions;

public sealed class MasteryConcurrencyException : Exception
{
    public MasteryConcurrencyException(string message)
        : base(message)
    {
    }
}
