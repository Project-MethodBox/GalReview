using System.Text.Json;
using KnowledgeService.API.Contracts;
using KnowledgeService.API.Infrastructure;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Reviews;
using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.Tests.Features;

public sealed class EnumSerializationTests
{
    private static readonly JsonSerializerOptions Options = CreateOptions();

    [Theory]
    [InlineData(ReviewPlanPurpose.Assessment, "\"ASSESSMENT\"")]
    [InlineData(ReviewPlanPurpose.Learning, "\"LEARNING\"")]
    public void Serializes_plan_purpose_as_upper_snake_case(
        ReviewPlanPurpose value,
        string expected) =>
        Assert.Equal(expected, JsonSerializer.Serialize(value, Options));

    [Theory]
    [InlineData(KnowledgeRelationType.Prerequisite, "\"PREREQUISITE\"")]
    [InlineData(KnowledgeRelationType.Contrasts, "\"CONTRASTS\"")]
    public void Serializes_relation_type_as_upper_snake_case(
        KnowledgeRelationType value,
        string expected) =>
        Assert.Equal(expected, JsonSerializer.Serialize(value, Options));

    [Fact]
    public void Serializes_plan_status_as_upper_snake_case() =>
        Assert.Equal(
            "\"OPEN\"",
            JsonSerializer.Serialize(ReviewPlanStatus.Open, Options));

    [Theory]
    [InlineData("0")]
    [InlineData("999")]
    public void Rejects_integer_segmentation_mode(string numericValue)
    {
        var json =
            $$"""
              {
                "materialId": "10000000-0000-0000-0000-000000000001",
                "segmentationMode": {{numericValue}}
              }
              """;

        Assert.Throws<JsonException>(
            () => JsonSerializer.Deserialize<GraphBuildRequest>(
                json,
                Options));
    }

    [Fact]
    public void Rejects_unknown_string_segmentation_mode()
    {
        const string json =
            """
            {
              "materialId": "10000000-0000-0000-0000-000000000001",
              "segmentationMode": "OUT_OF_RANGE"
            }
            """;

        Assert.Throws<JsonException>(
            () => JsonSerializer.Deserialize<GraphBuildRequest>(
                json,
                Options));
    }

    [Fact]
    public void Accepts_contract_segmentation_mode()
    {
        const string json =
            """
            {
              "materialId": "10000000-0000-0000-0000-000000000001",
              "segmentationMode": "HEADING_RULES"
            }
            """;

        var request = JsonSerializer.Deserialize<GraphBuildRequest>(
            json,
            Options);

        Assert.NotNull(request);
        Assert.Equal(
            SegmentationMode.HeadingRules,
            request.SegmentationMode);
    }

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions(
            JsonSerializerDefaults.Web);
        KnowledgeJsonOptions.Configure(options);
        return options;
    }
}
