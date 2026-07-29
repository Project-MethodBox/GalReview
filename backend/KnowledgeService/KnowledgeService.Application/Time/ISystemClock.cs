namespace KnowledgeService.Application.Time;

public interface ISystemClock
{
    DateTimeOffset UtcNow { get; }
}
