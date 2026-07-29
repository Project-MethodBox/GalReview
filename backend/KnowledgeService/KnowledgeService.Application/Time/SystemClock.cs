namespace KnowledgeService.Application.Time;

public sealed class SystemClock : ISystemClock
{
    public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;
}
