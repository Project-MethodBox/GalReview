using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

public sealed partial class NarrativeDraftValidator
{
    private const int MaxDialogueLinesPerDraftScene = 8;
    private const int MaxLineLength = 320;
    private const int MaxChoiceLength = 280;
    private const int MaxTotalCharacters = 60_000;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private static readonly string[] ForbiddenOutputFragments =
    {
        "知识点权重", "关键标签", "questionTarget", "selectionReason", "masteryScore",
        "PlanGraph", "UUID", "系统已生成评估问题", "知识点讲解", "来看看这道题",
        "根据所学内容", "本轮复习结束", "让我们探索", "知识之光",
    };

    private readonly GamePackageValidator _packageValidator;

    public NarrativeDraftValidator(GamePackageValidator packageValidator)
    {
        _packageValidator = packageValidator;
    }

    public bool TryApply(
        string rawJson,
        GamePackage skeleton,
        PlanGraph plan,
        GameGenerationRequest request,
        string promptVersion,
        out GamePackage enhanced,
        out string[] errors)
    {
        enhanced = skeleton;
        var issues = new List<string>();
        NarrativeDraft? draft;

        try
        {
            draft = JsonSerializer.Deserialize<NarrativeDraft>(rawJson, JsonOptions);
        }
        catch (Exception ex) when (ex is JsonException or NotSupportedException)
        {
            errors = new[] { "INVALID_JSON" };
            return false;
        }

        if (draft is null)
        {
            errors = new[] { "EMPTY_DRAFT" };
            return false;
        }

        if (!string.Equals(draft.PromptVersion, promptVersion, StringComparison.Ordinal))
            issues.Add("PROMPT_VERSION_MISMATCH");

        if (draft.Scenes is null || draft.Scenes.Length != skeleton.Scenes.Length)
        {
            issues.Add("SCENE_SET_MISMATCH");
            errors = issues.ToArray();
            return false;
        }

        var draftScenes = new Dictionary<string, NarrativeSceneDraft>(StringComparer.Ordinal);
        foreach (var scene in draft.Scenes)
        {
            if (scene is null || string.IsNullOrWhiteSpace(scene.SceneId)
                || !draftScenes.TryAdd(scene.SceneId, scene))
                issues.Add("DUPLICATE_OR_EMPTY_SCENE_ID");
        }

        var skeletonIds = skeleton.Scenes.Select(scene => scene.SceneId).ToHashSet(StringComparer.Ordinal);
        if (!draftScenes.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(skeletonIds))
            issues.Add("SCENE_SET_MISMATCH");

        if (issues.Count > 0)
        {
            errors = issues.Distinct(StringComparer.Ordinal).ToArray();
            return false;
        }

        var nodeById = (plan.Nodes ?? Array.Empty<PlanNode>()).ToDictionary(node => node.PointId);
        var allowedSpeakers = NarrativePromptBuilder.AllowedSpeakers(request.Style);
        var rewrittenScenes = new List<Scene>(skeleton.Scenes.Length);
        var totalCharacters = 0;

        foreach (var sourceScene in skeleton.Scenes)
        {
            var scene = draftScenes[sourceScene.SceneId];
            var path = sourceScene.SceneId;
            var sceneTitle = scene.Title?.Trim() ?? string.Empty;

            if (sceneTitle.Length == 0 || sceneTitle.Length > 120)
                issues.Add($"{path}:INVALID_TITLE");
            if (ContainsForbiddenFragment(sceneTitle))
                issues.Add($"{path}:FORBIDDEN_META_TEXT");

            if (scene.Dialogue is null
                || scene.Dialogue.Length is < 1 or > MaxDialogueLinesPerDraftScene)
            {
                issues.Add($"{path}:INVALID_DIALOGUE_COUNT");
            }

            var dialogue = new List<DialogueLine>();
            foreach (var line in scene.Dialogue ?? Array.Empty<NarrativeDialogueDraft>())
            {
                if (line is null || !allowedSpeakers.Contains(line.SpeakerId))
                {
                    issues.Add($"{path}:INVALID_SPEAKER");
                    continue;
                }
                var lineText = line.Text?.Trim() ?? string.Empty;
                if (lineText.Length == 0 || lineText.Length > MaxLineLength)
                    issues.Add($"{path}:INVALID_DIALOGUE_TEXT");
                if (line.Emotion is not null && !EmotionToken().IsMatch(line.Emotion))
                    issues.Add($"{path}:INVALID_EMOTION");
                if (ContainsForbiddenFragment(line.Text))
                    issues.Add($"{path}:FORBIDDEN_META_TEXT");

                totalCharacters += lineText.Length;
                dialogue.Add(new DialogueLine(line.SpeakerId.Trim(), lineText, line.Emotion));
            }

            if (scene.Choices is null || scene.Choices.Length != sourceScene.Choices.Length)
            {
                issues.Add($"{path}:CHOICE_SET_MISMATCH");
                continue;
            }

            var choiceDrafts = new Dictionary<string, NarrativeChoiceDraft>(StringComparer.Ordinal);
            foreach (var choice in scene.Choices)
            {
                if (choice is null || string.IsNullOrWhiteSpace(choice.ChoiceId)
                    || !choiceDrafts.TryAdd(choice.ChoiceId, choice))
                    issues.Add($"{path}:DUPLICATE_OR_EMPTY_CHOICE_ID");
            }

            var sourceChoiceIds = sourceScene.Choices.Select(choice => choice.ChoiceId)
                .ToHashSet(StringComparer.Ordinal);
            if (!choiceDrafts.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(sourceChoiceIds))
            {
                issues.Add($"{path}:CHOICE_SET_MISMATCH");
                continue;
            }

            var questionBinding = sourceScene.KnowledgeBindings
                .FirstOrDefault(binding => binding.Purpose == KnowledgePurpose.QUESTION);
            var explainBindings = sourceScene.KnowledgeBindings
                .Where(binding => binding.Purpose == KnowledgePurpose.EXPLAIN)
                .ToArray();
            PlanNode? target = null;
            if (questionBinding is not null
                && !nodeById.TryGetValue(questionBinding.KnowledgePointId, out target))
                issues.Add($"{path}:UNKNOWN_QUESTION_TARGET");

            var dialogueText = string.Join('\n', dialogue.Select(line => line.Text));
            var sceneGroundingQuotes = scene.GroundingQuotes ?? Array.Empty<string>();
            if (questionBinding is null && explainBindings.Length == 0)
            {
                if (sceneGroundingQuotes.Length != 0)
                    issues.Add($"{path}:UNEXPECTED_SCENE_GROUNDING");
                if (!string.IsNullOrWhiteSpace(scene.KnowledgeUse))
                    issues.Add($"{path}:UNEXPECTED_KNOWLEDGE_USE");
            }
            else
            {
                var boundNodes = sourceScene.KnowledgeBindings
                    .Where(binding => binding.Purpose is KnowledgePurpose.EXPLAIN or KnowledgePurpose.QUESTION)
                    .Select(binding => nodeById.GetValueOrDefault(binding.KnowledgePointId))
                    .ToArray();
                if (sceneGroundingQuotes.Length == 0 || boundNodes.Any(node => node is null))
                {
                    issues.Add($"{path}:MISSING_SCENE_GROUNDING");
                }
                else
                {
                    foreach (var quote in sceneGroundingQuotes)
                    {
                        if (string.IsNullOrWhiteSpace(quote)
                            || !boundNodes.Any(node => node is not null && IsExactGroundingQuote(quote, node)))
                            issues.Add($"{path}:INVALID_SCENE_GROUNDING");
                    }
                    foreach (var node in boundNodes.Where(node => node is not null))
                    {
                        if (!sceneGroundingQuotes.Any(quote => IsExactGroundingQuote(quote, node!)))
                            issues.Add($"{path}:UNGROUNDED_BOUND_POINT");
                        if (!ContainsKnowledgeAnchor(dialogueText, node!))
                            issues.Add($"{path}:KNOWLEDGE_NOT_IN_DIALOGUE");
                    }
                }

                var knowledgeUse = scene.KnowledgeUse?.Trim() ?? string.Empty;
                if (knowledgeUse.Length is < 8 or > 280 || ContainsForbiddenFragment(knowledgeUse))
                    issues.Add($"{path}:INVALID_KNOWLEDGE_USE");
            }

            var choices = new List<Choice>(sourceScene.Choices.Length);
            var displayTexts = new HashSet<string>(StringComparer.Ordinal);
            foreach (var sourceChoice in sourceScene.Choices)
            {
                var choice = choiceDrafts[sourceChoice.ChoiceId];
                var choiceText = choice.Text?.Trim() ?? string.Empty;
                if (choiceText.Length == 0 || choiceText.Length > MaxChoiceLength)
                    issues.Add($"{path}:{sourceChoice.ChoiceId}:INVALID_CHOICE_TEXT");
                if (!displayTexts.Add(choiceText))
                    issues.Add($"{path}:DUPLICATE_CHOICE_TEXT");
                if (ContainsForbiddenFragment(choice.Text))
                    issues.Add($"{path}:{sourceChoice.ChoiceId}:FORBIDDEN_META_TEXT");

                if (questionBinding is null)
                {
                    if (!string.IsNullOrWhiteSpace(choice.GroundingQuote))
                        issues.Add($"{path}:{sourceChoice.ChoiceId}:UNEXPECTED_GROUNDING_QUOTE");
                }
                else if (target is null || string.IsNullOrWhiteSpace(choice.GroundingQuote)
                    || !IsExactGroundingQuote(choice.GroundingQuote, target))
                {
                    issues.Add($"{path}:{sourceChoice.ChoiceId}:INVALID_GROUNDING_QUOTE");
                }

                totalCharacters += choiceText.Length;
                choices.Add(sourceChoice with { Text = choiceText });
            }

            rewrittenScenes.Add(sourceScene with
            {
                Title = sceneTitle,
                Dialogue = dialogue.ToArray(),
                Choices = choices.ToArray(),
            });

            if (questionBinding is not null
                && string.Equals(plan.Type, "ASSESSMENT", StringComparison.OrdinalIgnoreCase))
            {
                var correctDraft = sourceScene.Choices
                    .Where(choice => choice.Correct is true)
                    .Select(choice => choiceDrafts[choice.ChoiceId])
                    .FirstOrDefault();
                var correctQuote = correctDraft?.GroundingQuote?.Trim();
                var textBeforeAnswer = string.Join('\n',
                    rewrittenScenes.SelectMany(item => item.Dialogue).Select(line => line.Text));
                if (!string.IsNullOrWhiteSpace(correctQuote)
                    && textBeforeAnswer.Contains(correctQuote, StringComparison.Ordinal))
                    issues.Add($"{path}:ASSESSMENT_ANSWER_LEAKED_IN_DIALOGUE");
            }
        }

        if (totalCharacters > MaxTotalCharacters)
            issues.Add("DRAFT_TOO_LARGE");

        if (issues.Count > 0)
        {
            errors = issues.Distinct(StringComparer.Ordinal).ToArray();
            return false;
        }

        var candidate = skeleton with { Scenes = rewrittenScenes.ToArray() };
        var packageValidation = _packageValidator.Validate(candidate);
        if (!packageValidation.Valid)
        {
            errors = packageValidation.Errors
                .Select(error => $"PACKAGE_{error.Code}")
                .Distinct(StringComparer.Ordinal)
                .ToArray();
            return false;
        }

        enhanced = candidate;
        errors = Array.Empty<string>();
        return true;
    }

    private static bool IsExactGroundingQuote(string? quote, PlanNode node)
    {
        var value = quote?.Trim() ?? string.Empty;
        return value.Length is >= 2 and <= 800
            && ((node.Title?.Contains(value, StringComparison.Ordinal) ?? false)
                || (node.Summary?.Contains(value, StringComparison.Ordinal) ?? false));
    }

    private static bool ContainsKnowledgeAnchor(string dialogue, PlanNode node)
    {
        var anchors = (node.Tags ?? Array.Empty<string>())
            .Append(node.Title ?? string.Empty)
            .Select(value => value.Trim())
            .Where(value => value.Length >= 2)
            .ToList();

        var title = node.Title?.Trim() ?? string.Empty;
        for (var index = 0; index + 2 <= title.Length; index += 2)
            anchors.Add(title.Substring(index, 2));

        return anchors.Any(anchor => dialogue.Contains(anchor, StringComparison.OrdinalIgnoreCase));
    }

    private static bool ContainsForbiddenFragment(string? text) =>
        text is not null
        && ForbiddenOutputFragments.Any(fragment =>
            text.Contains(fragment, StringComparison.OrdinalIgnoreCase));

    [GeneratedRegex("^[a-z][a-z0-9_-]{0,31}$", RegexOptions.CultureInvariant)]
    private static partial Regex EmotionToken();
}
