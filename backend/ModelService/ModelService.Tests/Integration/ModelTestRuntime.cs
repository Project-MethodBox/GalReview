using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using ModelService.Application;
using ModelService.Domain;
using ModelService.Persistence;
using PracticeApplication = PracticeService.Application;
using PracticeDomain = PracticeService.Domain;
using Xunit;

namespace ModelService.Tests.Integration;

internal static class ModelTestRuntime
{
    public static MultilingualNliInferenceEngine Create()
    {
        var modelRoot = Path.GetFullPath(Path.Combine(
            AppContext.BaseDirectory, "..", "..", "..", ".."));
        var catalog = new ModelAssetCatalog(Path.Combine(modelRoot, "Resources"));
        Assert.True(catalog.NliReady,
            "Run scripts/download-model-resources.ps1 before the model tests.");
        return new(
            catalog,
            new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Nli:MinimumTopProbability"] = "0.75",
                ["Nli:MinimumMargin"] = "0.20"
            }).Build(),
            NullLogger<MultilingualNliInferenceEngine>.Instance);
    }
}

internal sealed class PracticeFacetAdjudicatorAdapter(IFacetInferenceEngine engine) :
    PracticeApplication.IFacetAdjudicator
{
    public async Task<PracticeApplication.FacetAdjudicationBatch> AdjudicateAsync(
        string answer,
        IReadOnlyList<PracticeApplication.ReferenceFacet> facets,
        CancellationToken cancellationToken)
    {
        var batch = await engine.InferAsync(
            answer,
            facets.Select(facet => facet.Claim).ToArray(),
            cancellationToken);
        return new(
            batch.Available,
            batch.ModelVersion,
            batch.Facets.Select(facet => new PracticeApplication.FacetAdjudication(
                facet.Claim,
                facet.Verdict switch
                {
                    FacetVerdict.Entailed => PracticeDomain.FacetVerdict.Entailed,
                    FacetVerdict.Omitted => PracticeDomain.FacetVerdict.Omitted,
                    FacetVerdict.Contradicted => PracticeDomain.FacetVerdict.Contradicted,
                    _ => PracticeDomain.FacetVerdict.Indeterminate
                },
                facet.EntailmentProbability,
                facet.NeutralProbability,
                facet.ContradictionProbability)).ToArray(),
            batch.FailureReason);
    }
}
