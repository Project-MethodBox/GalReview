using System.Text.Json;
using System.Text.Json.Serialization;

public sealed class CharacterVoiceConfiguration
{
    public Dictionary<string, CharacterStyleConfiguration> Styles { get; set; } = [];
    public string[] ExcludedSpeakers { get; set; } = [];
    public SpeakerVoiceConfiguration FallbackVoice { get; set; } = new();
    public Dictionary<string, SpeakerVoiceConfiguration> Characters { get; set; } = [];
    public Dictionary<string, string> EmotionDirections { get; set; } = [];
    public string UnknownEmotionDirection { get; set; } = string.Empty;
}

public sealed class CharacterStyleConfiguration
{
    public string GuideSpeaker { get; set; } = string.Empty;
    public string[] Speakers { get; set; } = [];
    public string PlayerDirection { get; set; } = string.Empty;
}

public sealed class SpeakerVoiceConfiguration
{
    public string Voice { get; set; } = string.Empty;
    public string Direction { get; set; } = string.Empty;
    public string NarrativeDirection { get; set; } = string.Empty;
}

public sealed record SpeakerVoiceProfile(string Voice, string Direction);

public sealed class CharacterVoiceCatalog
{
    public const string DefaultFileName = "character-voice-config.json";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private readonly IReadOnlyDictionary<GameStyle, CharacterStyleConfiguration> _styles;
    private readonly IReadOnlyDictionary<string, SpeakerVoiceProfile> _voices;
    private readonly IReadOnlyDictionary<string, string> _narrativeDirections;
    private readonly IReadOnlyDictionary<string, string> _emotionDirections;
    private readonly IReadOnlySet<string> _excludedSpeakers;
    private readonly SpeakerVoiceProfile _fallbackVoice;
    private readonly string _unknownEmotionDirection;

    private CharacterVoiceCatalog(CharacterVoiceConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);

        _excludedSpeakers = configuration.ExcludedSpeakers
            .Select(value => value?.Trim() ?? string.Empty)
            .Where(value => value.Length > 0)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        _voices = configuration.Characters.ToDictionary(
            pair => pair.Key.Trim(),
            pair => Profile(pair.Value, $"characters.{pair.Key}"),
            StringComparer.Ordinal);
        _narrativeDirections = configuration.Characters
            .Where(pair => !string.IsNullOrWhiteSpace(pair.Value.NarrativeDirection))
            .ToDictionary(
                pair => pair.Key.Trim(),
                pair => pair.Value.NarrativeDirection.Trim(),
                StringComparer.Ordinal);
        _emotionDirections = configuration.EmotionDirections.ToDictionary(
            pair => pair.Key.Trim(),
            pair => Required(pair.Value, $"emotionDirections.{pair.Key}"),
            StringComparer.OrdinalIgnoreCase);
        _fallbackVoice = Profile(configuration.FallbackVoice, "fallbackVoice");
        _unknownEmotionDirection = Required(
            configuration.UnknownEmotionDirection,
            "unknownEmotionDirection");

        var styles = new Dictionary<GameStyle, CharacterStyleConfiguration>();
        foreach (var style in Enum.GetValues<GameStyle>())
        {
            if (!configuration.Styles.TryGetValue(style.ToString(), out var configuredStyle)
                || configuredStyle is null)
                throw new InvalidDataException($"Character voice config is missing styles.{style}.");

            var speakers = configuredStyle.Speakers
                .Select(value => value?.Trim() ?? string.Empty)
                .Where(value => value.Length > 0)
                .ToArray();
            if (speakers.Length < 2 || speakers.Distinct(StringComparer.Ordinal).Count() != speakers.Length)
                throw new InvalidDataException($"styles.{style}.speakers must contain at least two unique names.");

            var guide = Required(configuredStyle.GuideSpeaker, $"styles.{style}.guideSpeaker");
            var playerDirection = Required(
                configuredStyle.PlayerDirection,
                $"styles.{style}.playerDirection");
            if (!speakers.Contains(guide, StringComparer.Ordinal))
                throw new InvalidDataException($"styles.{style}.guideSpeaker must be included in speakers.");

            foreach (var speaker in speakers.Where(IsVoiceRequired))
            {
                if (!_voices.ContainsKey(speaker))
                    throw new InvalidDataException($"Configured character '{speaker}' has no TTS voice profile.");
                if (!_narrativeDirections.ContainsKey(speaker))
                    throw new InvalidDataException($"Configured character '{speaker}' has no narrative direction.");
            }

            styles.Add(style, new CharacterStyleConfiguration
            {
                GuideSpeaker = guide,
                Speakers = speakers,
                PlayerDirection = playerDirection,
            });
        }
        _styles = styles;
    }

    public static CharacterVoiceCatalog Load(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new ArgumentException("Character voice config path cannot be blank.", nameof(path));
        var fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath))
            throw new FileNotFoundException("Character voice config file was not found.", fullPath);

        var json = File.ReadAllText(fullPath);
        var configuration = JsonSerializer.Deserialize<CharacterVoiceConfiguration>(json, JsonOptions)
            ?? throw new InvalidDataException("Character voice config cannot be empty.");
        return new CharacterVoiceCatalog(configuration);
    }

    public static CharacterVoiceCatalog LoadDefault() =>
        Load(Path.Combine(AppContext.BaseDirectory, DefaultFileName));

    public IReadOnlySet<string> AllowedSpeakers(GameStyle style) =>
        new HashSet<string>(Style(style).Speakers, StringComparer.Ordinal);

    public string GuideSpeaker(GameStyle style) => Style(style).GuideSpeaker;

    public string BuildNarrativeInstructions(GameStyle style)
    {
        var configuredStyle = Style(style);
        var lines = new List<string> { configuredStyle.PlayerDirection };
        lines.AddRange(configuredStyle.Speakers
            .Where(IsVoiceRequired)
            .Select(speaker => $"{speaker}：{_narrativeDirections[speaker]}"));
        return string.Join(Environment.NewLine + Environment.NewLine, lines);
    }

    public bool ShouldSynthesize(string speakerId) =>
        !string.IsNullOrWhiteSpace(speakerId)
        && !_excludedSpeakers.Contains(speakerId.Trim());

    public SpeakerVoiceProfile ResolveVoice(string speakerId)
    {
        if (_voices.TryGetValue(speakerId, out var profile))
            return profile;
        return _fallbackVoice with
        {
            Direction = _fallbackVoice.Direction.Replace(
                "{speakerId}", speakerId, StringComparison.Ordinal),
        };
    }

    public string BuildVoiceContext(SpeakerVoiceProfile profile, string? emotion)
    {
        if (string.IsNullOrWhiteSpace(emotion))
            return profile.Direction;
        var token = emotion.Trim();
        var direction = _emotionDirections.TryGetValue(token, out var configured)
            ? configured
            : _unknownEmotionDirection.Replace("{emotion}", token, StringComparison.Ordinal);
        return $"{profile.Direction}{direction}";
    }

    private CharacterStyleConfiguration Style(GameStyle style) =>
        _styles.TryGetValue(style, out var configured)
            ? configured
            : throw new ArgumentOutOfRangeException(nameof(style), style, "Unsupported narrative style.");

    private bool IsVoiceRequired(string speaker) => !_excludedSpeakers.Contains(speaker);

    private static SpeakerVoiceProfile Profile(SpeakerVoiceConfiguration configuration, string path)
    {
        if (configuration is null)
            throw new InvalidDataException($"{path} cannot be null.");
        return new SpeakerVoiceProfile(
            Required(configuration.Voice, $"{path}.voice"),
            Required(configuration.Direction, $"{path}.direction"));
    }

    private static string Required(string? value, string path)
    {
        var trimmed = value?.Trim() ?? string.Empty;
        return trimmed.Length > 0
            ? trimmed
            : throw new InvalidDataException($"{path} cannot be blank.");
    }
}
