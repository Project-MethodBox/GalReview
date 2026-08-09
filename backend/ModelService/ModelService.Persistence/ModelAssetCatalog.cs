using ModelService.Application;
using ModelService.Domain;
using System.Security.Cryptography;

namespace ModelService.Persistence;

public sealed class ModelAssetCatalog : IModelAssetStatusReader
{
    public const string SbertHash = "994a58868f7abacacbf2192aa0aae8f56da8c4505dbde2740c861b24426ede6b";
    public const string VocabHash = "45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c";
    public const string NliModelHash = "79f8cda2b1230585a95ea0514a6f1bd21c5c986ba0529bb3261213a3e195fa6e";
    public const string NliTokenizerHash = "cfc8146abe2a0488e9e2a0c56de7952f7c11ab059eca145a0a727afce0db2865";
    public const string SynonymHash = "de0d4c74e18633cc758f3d35d9479cb63d2e80abe77f2a7f49dba30fed2a482e";

    private readonly string _root;
    private readonly Lazy<IReadOnlyList<ModelAssetState>> _inspection;

    public ModelAssetCatalog(string root)
    {
        _root = root;
        _inspection = new(InspectCore, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public string SbertPath => Path.Combine(_root, "Models", "sbert.onnx");
    public string VocabPath => Path.Combine(_root, "vocab.txt");
    public string NliModelPath => Path.Combine(_root, "Models", "multilingual-minilm-nli", "model.onnx");
    public string NliTokenizerPath => Path.Combine(_root, "Models", "multilingual-minilm-nli", "sentencepiece.bpe.model");
    public string SynonymPath => Path.Combine(_root, "cn_synonym.txt");

    public IReadOnlyList<ModelAssetState> Inspect() => _inspection.Value;

    public bool NliReady => Inspect().Where(state => state.Required)
        .All(state => state.Status == "READY");

    private IReadOnlyList<ModelAssetState> InspectCore() =>
    [
        Check("nli-model.onnx", NliModelPath, NliModelHash, true),
        Check("nli-sentencepiece.model", NliTokenizerPath, NliTokenizerHash, true),
        Check("nli-synonym-lexicon", SynonymPath, SynonymHash, true),
        Check("sbert.onnx", SbertPath, SbertHash, false, "仅用于兼容诊断，不参与正误或 quality。"),
        Check("vocab.txt", VocabPath, VocabHash, false, "仅供兼容诊断 SBERT 使用。")
    ];

    private static ModelAssetState Check(
        string name,
        string path,
        string expected,
        bool required,
        string? readyDetail = null)
    {
        if (!File.Exists(path))
            return new(name, "MISSING", expected, null, "资产不存在。", required);
        try
        {
            using var input = File.OpenRead(path);
            var actual = Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant();
            return new(name, actual == expected ? "READY" : "HASH_MISMATCH", expected, actual,
                actual == expected ? readyDetail : "资产哈希不一致。", required);
        }
        catch (Exception error)
        {
            return new(name, "LOAD_FAILED", expected, null, error.Message, required);
        }
    }
}
