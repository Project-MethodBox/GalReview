using ModelService.Domain;

namespace ModelService.Application;

public interface IFacetInferenceEngine
{
    Task<FacetInferenceBatch> InferAsync(
        string answer,
        IReadOnlyList<string> claims,
        CancellationToken cancellationToken);
}

public interface IModelAssetStatusReader
{
    IReadOnlyList<ModelAssetState> Inspect();
}
