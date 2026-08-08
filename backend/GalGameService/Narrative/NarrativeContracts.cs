using System.Text.Json.Serialization;

public sealed record NarrativePrompt(string System, string User);
public sealed record NarrativeModelResult(string Json, long TotalTokens);
public sealed record NarrativeGenerationResult(GamePackage Package, long TotalTokens);

public interface INarrativeModelClient
{
    bool IsEnabled { get; }
    string ModelName { get; }
    Task<NarrativeModelResult> GenerateJsonAsync(NarrativePrompt prompt, CancellationToken cancellationToken);
}

public sealed record NarrativeDraft(
    [property: JsonRequired] string PromptVersion,
    [property: JsonRequired] NarrativeSceneDraft[] Scenes);

public sealed record NarrativeSceneDraft(
    [property: JsonRequired] string SceneId,
    [property: JsonRequired] string Title,
    [property: JsonRequired] NarrativeDialogueDraft[] Dialogue,
    [property: JsonRequired] string[] GroundingQuotes,
    string? KnowledgeUse,
    [property: JsonRequired] NarrativeChoiceDraft[] Choices);

public sealed record NarrativeDialogueDraft(
    [property: JsonRequired] string SpeakerId,
    [property: JsonRequired] string Text,
    string? Emotion);

public sealed record NarrativeChoiceDraft(
    [property: JsonRequired] string ChoiceId,
    [property: JsonRequired] string Text,
    string? GroundingQuote);
