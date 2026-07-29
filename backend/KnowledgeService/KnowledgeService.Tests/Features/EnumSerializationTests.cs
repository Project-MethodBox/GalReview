using System.Text.Json;
using System.Text.Json.Serialization;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.Tests.Features;

public sealed class EnumSerializationTests
{
    private static readonly JsonSerializerOptions Options = new()
    {
        Converters =
        {
            new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseUpper)
        }
    };

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
}
