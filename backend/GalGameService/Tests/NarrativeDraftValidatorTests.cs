using System.Text.Json.Nodes;
using Xunit;

public sealed class NarrativeDraftValidatorTests
{
    private readonly GamePackageValidator _packageValidator = new();

    [Fact]
    public void TryApply_ValidDraftChangesOnlyDisplayContent()
    {
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();
        var skeleton = NarrativeTestData.CreateSkeleton(plan, request);
        var validator = new NarrativeDraftValidator(_packageValidator);

        var accepted = validator.TryApply(
            NarrativeTestData.CreateValidDraftJson(skeleton),
            skeleton,
            plan,
            request,
            NarrativeTestData.PromptVersion,
            out var enhanced,
            out var errors);

        Assert.True(accepted, string.Join(',', errors));
        Assert.Equal(skeleton.PackageId, enhanced.PackageId);
        Assert.Equal(skeleton.EntrySceneId, enhanced.EntrySceneId);
        Assert.Equal(skeleton.Assets, enhanced.Assets);
        Assert.Equal("雨停前的温室记录", enhanced.Scenes[0].Title);

        for (var sceneIndex = 0; sceneIndex < skeleton.Scenes.Length; sceneIndex++)
        {
            var before = skeleton.Scenes[sceneIndex];
            var after = enhanced.Scenes[sceneIndex];
            Assert.Equal(before.SceneId, after.SceneId);
            Assert.Equal(before.KnowledgeBindings, after.KnowledgeBindings);
            Assert.Equal(before.Choices.Length, after.Choices.Length);
            for (var choiceIndex = 0; choiceIndex < before.Choices.Length; choiceIndex++)
            {
                Assert.Equal(before.Choices[choiceIndex] with { Text = after.Choices[choiceIndex].Text }, after.Choices[choiceIndex]);
            }
        }

        Assert.True(_packageValidator.Validate(enhanced).Valid);
    }

    [Fact]
    public void TryApply_ChangedChoiceIdRejectsWholeDraft()
    {
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();
        var skeleton = NarrativeTestData.CreateSkeleton(plan, request);
        var document = JsonNode.Parse(NarrativeTestData.CreateValidDraftJson(skeleton))!.AsObject();
        document["scenes"]![0]!["choices"]![0]!["choiceId"] = "model-invented-id";

        var accepted = new NarrativeDraftValidator(_packageValidator).TryApply(
            document.ToJsonString(), skeleton, plan, request, NarrativeTestData.PromptVersion,
            out var enhanced, out var errors);

        Assert.False(accepted);
        Assert.Same(skeleton, enhanced);
        Assert.Contains(errors, error => error.Contains("CHOICE", StringComparison.Ordinal));
    }

    [Fact]
    public void TryApply_UngroundedQuestionTextRejectsWholeDraft()
    {
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();
        var skeleton = NarrativeTestData.CreateSkeleton(plan, request);
        var document = JsonNode.Parse(NarrativeTestData.CreateValidDraftJson(skeleton))!.AsObject();
        var questionScene = document["scenes"]!.AsArray()
            .First(scene => scene!["sceneId"]!.GetValue<string>() == "scene-003")!;
        questionScene["choices"]![0]!["groundingQuote"] = "资料中从未出现的结论";

        var accepted = new NarrativeDraftValidator(_packageValidator).TryApply(
            document.ToJsonString(), skeleton, plan, request, NarrativeTestData.PromptVersion,
            out _, out var errors);

        Assert.False(accepted);
        Assert.Contains(errors, error => error.Contains("INVALID_GROUNDING_QUOTE", StringComparison.Ordinal));
    }

    [Fact]
    public void TryApply_DryQuizTemplateRejectsWholeDraft()
    {
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();
        var skeleton = NarrativeTestData.CreateSkeleton(plan, request);
        var document = JsonNode.Parse(NarrativeTestData.CreateValidDraftJson(skeleton))!.AsObject();
        var questionScene = document["scenes"]!.AsArray()
            .First(scene => scene!["sceneId"]!.GetValue<string>() == "scene-003")!;
        questionScene["dialogue"]![0]!["text"] = "根据所学内容，来看看这道题。";

        var accepted = new NarrativeDraftValidator(_packageValidator).TryApply(
            document.ToJsonString(), skeleton, plan, request, NarrativeTestData.PromptVersion,
            out _, out var errors);

        Assert.False(accepted);
        Assert.Contains(errors, error => error.Contains("FORBIDDEN_META_TEXT", StringComparison.Ordinal));
    }

    [Fact]
    public void TryApply_KnowledgeSceneWithoutNarrativeGroundingRejectsWholeDraft()
    {
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();
        var skeleton = NarrativeTestData.CreateSkeleton(plan, request);
        var document = JsonNode.Parse(NarrativeTestData.CreateValidDraftJson(skeleton))!.AsObject();
        var explainScene = document["scenes"]!.AsArray()
            .First(scene => scene!["sceneId"]!.GetValue<string>() == "scene-002")!;
        explainScene["groundingQuotes"] = new JsonArray();

        var accepted = new NarrativeDraftValidator(_packageValidator).TryApply(
            document.ToJsonString(), skeleton, plan, request, NarrativeTestData.PromptVersion,
            out _, out var errors);

        Assert.False(accepted);
        Assert.Contains(errors, error => error.Contains("MISSING_SCENE_GROUNDING", StringComparison.Ordinal));
    }

    [Fact]
    public void TryApply_ConceptGroundingInDialogue_DoesNotCountAsAnswerLeak()
    {
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();
        var skeleton = NarrativeTestData.CreateSkeleton(plan, request);
        var document = JsonNode.Parse(NarrativeTestData.CreateValidDraftJson(skeleton))!.AsObject();
        var questionScene = document["scenes"]!.AsArray()
            .First(scene => scene!["sceneId"]!.GetValue<string>() == "scene-003")!;
        questionScene["groundingQuotes"] = new JsonArray("分蘖期");
        foreach (var choice in questionScene["choices"]!.AsArray())
            choice!["groundingQuote"] = "分蘖期";

        var accepted = new NarrativeDraftValidator(_packageValidator).TryApply(
            document.ToJsonString(), skeleton, plan, request, NarrativeTestData.PromptVersion,
            out _, out var errors);

        Assert.True(accepted, string.Join(',', errors));
    }
}
