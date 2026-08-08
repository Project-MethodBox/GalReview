using KnowledgeService.Domain.Segmentation;
using KnowledgeService.Persistence.Repositories;
using KnowledgeService.Tests.Fixtures;

namespace KnowledgeService.Tests.Persistence;

public sealed class GraphFingerprintTests
{
    [Fact]
    public void Changes_when_final_subject_code_changes()
    {
        var graph = GraphFixture.CreateHubGraph();
        var segmentation = new SegmentationOptions();

        var agronomy = GraphFingerprint.Create(graph, segmentation);
        var botany = GraphFingerprint.Create(
            graph with { SubjectCode = "BOTANY" },
            segmentation);

        Assert.NotEqual(agronomy, botany);
    }

    [Fact]
    public void Covers_every_exposed_segmentation_option()
    {
        var graph = GraphFixture.CreateHubGraph();
        var baseline = new SegmentationOptions();
        var baselineFingerprint = GraphFingerprint.Create(graph, baseline);
        SegmentationOptions[] alternatives =
        [
            baseline with { Mode = SegmentationMode.HeadingRules },
            baseline with { Delimiter = "---" },
            baseline with { MinChapterCharacters = 121 },
            baseline with { MaxChapterCharacters = 60_001 },
            baseline with { FixedWindowCharacters = 8_001 }
        ];

        Assert.All(
            alternatives,
            alternative => Assert.NotEqual(
                baselineFingerprint,
                GraphFingerprint.Create(graph, alternative)));
    }

    [Fact]
    public void Is_stable_for_equivalent_semantic_inputs()
    {
        var graph = GraphFixture.CreateHubGraph();
        var first = new SegmentationOptions(
            SegmentationMode.Delimiter,
            "---",
            120,
            60_000,
            8_000);
        var second = new SegmentationOptions(
            SegmentationMode.Delimiter,
            "---",
            120,
            60_000,
            8_000);

        Assert.Equal(
            GraphFingerprint.Create(graph, first),
            GraphFingerprint.Create(graph, second));
    }

    [Fact]
    public void Same_material_in_two_study_projects_has_distinct_fingerprints()
    {
        var graph = GraphFixture.CreateHubGraph() with { StudyProjectId = Guid.NewGuid() };
        var otherProjectGraph = graph with { StudyProjectId = Guid.NewGuid() };

        Assert.NotEqual(
            GraphFingerprint.Create(graph, new SegmentationOptions()),
            GraphFingerprint.Create(otherProjectGraph, new SegmentationOptions()));
    }
}
