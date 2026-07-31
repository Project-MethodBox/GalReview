public sealed class UpstreamContractException : Exception
{
    public UpstreamContractException(string message)
        : base(message)
    {
    }

    public UpstreamContractException(
        string message,
        Exception innerException)
        : base(message, innerException)
    {
    }
}
