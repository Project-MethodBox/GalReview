using PracticeService.Application;
using PracticeService.Domain;
using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PracticeService.Persistence;

public sealed class PracticePackageCodec : IPracticePackageCodec
{
    private const long MaxArchiveBytes = 50L * 1024 * 1024;
    private const long MaxExpandedBytes = 200L * 1024 * 1024;
    private const long MaxEntryBytes = 20L * 1024 * 1024;
    private const int MaxEntries = 2000;
    private static readonly JsonSerializerOptions Json = CreateJsonOptions();

    public DecodedPracticePackage Decode(string fileName, byte[] content)
    {
        if (content.LongLength == 0 || content.LongLength > MaxArchiveBytes)
            throw new PracticeDomainException(413, "PACKAGE_TOO_LARGE", "项目包必须大于 0 且不超过 50 MiB。");
        var extension = Path.GetExtension(fileName).ToLowerInvariant();
        return extension switch
        {
            ".rhproj" => DecodeLegacy(content),
            ".rhp" => DecodeArchive(content, false),
            ".qzwlp" or ".zip" => DecodeArchive(content, true),
            _ => throw new PracticeDomainException(415, "PACKAGE_FORMAT_UNSUPPORTED", "只支持 .rhproj、.rhp 与 .qzwlp 项目包。")
        };
    }

    public PracticePackageContent Encode(StudyProject project, IReadOnlyList<PracticeQuestion> questions)
    {
        var projectBytes = JsonSerializer.SerializeToUtf8Bytes(new PackageProject(project.Name, project.SubjectCode, project.MaterialIds, project.GraphId), Json);
        var questionBytes = JsonSerializer.SerializeToUtf8Bytes(questions.Select(x => new PackageQuestion(x.Kind, x.Prompt, x.Options,
            x.CorrectAnswers, x.Explanation, x.Score, x.Difficulty, x.KnowledgePointId, x.SourceReferences, x.Status)).ToArray(), Json);
        var manifest = new PackageManifest("qzwl-practice-package-1.0", "project.json", "questions.json",
            new Dictionary<string, string> { ["project.json"] = PracticeRules.Sha256(projectBytes), ["questions.json"] = PracticeRules.Sha256(questionBytes) }, DateTimeOffset.UtcNow);
        using var output = new MemoryStream();
        using (var archive = new ZipArchive(output, ZipArchiveMode.Create, true))
        {
            WriteEntry(archive, "manifest.json", JsonSerializer.SerializeToUtf8Bytes(manifest, Json));
            WriteEntry(archive, "project.json", projectBytes);
            WriteEntry(archive, "questions.json", questionBytes);
        }
        return new PracticePackageContent($"{SafeName(project.Name)}.qzwlp", "application/zip", output.ToArray());
    }

    private static DecodedPracticePackage DecodeArchive(byte[] content, bool allowNew)
    {
        using var input = new MemoryStream(content, false);
        using var archive = OpenSafeArchive(input);
        var entries = archive.Entries.Where(x => !string.IsNullOrEmpty(x.Name)).ToDictionary(x => NormalizeEntryName(x.FullName), StringComparer.OrdinalIgnoreCase);
        if (allowNew && entries.TryGetValue("manifest.json", out var manifestEntry))
        {
            var manifest = JsonSerializer.Deserialize<PackageManifest>(ReadEntry(manifestEntry), Json)
                ?? throw Invalid("manifest.json 无法读取。");
            if (!string.Equals(manifest.SchemaVersion, "qzwl-practice-package-1.0", StringComparison.Ordinal))
                throw new PracticeDomainException(422, "PACKAGE_SCHEMA_UNSUPPORTED", "不支持的项目包 schemaVersion。");
            var projectEntry = Require(entries, manifest.ProjectFile); var questionEntry = Require(entries, manifest.QuestionsFile);
            var projectBytes = ReadEntry(projectEntry); var questionBytes = ReadEntry(questionEntry);
            VerifyHash(manifest, manifest.ProjectFile, projectBytes); VerifyHash(manifest, manifest.QuestionsFile, questionBytes);
            var project = JsonSerializer.Deserialize<PackageProject>(projectBytes, Json) ?? throw Invalid("project.json 无法读取。");
            var questions = JsonSerializer.Deserialize<PackageQuestion[]>(questionBytes, Json) ?? [];
            return new(project.Name, project.SubjectCode, manifest.SchemaVersion, questions.Select(ToDraft).ToArray(), []);
        }
        var legacy = entries.Where(x => x.Key.EndsWith(".rhproj", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (legacy.Length != 1) throw Invalid(legacy.Length == 0 ? "项目包中没有 .rhproj。" : "项目包中包含多个 .rhproj，无法确定主项目。");
        return DecodeLegacy(ReadEntry(legacy[0].Value)) with { ImportedFromSchema = "recitehelper-rhp" };
    }

    private static DecodedPracticePackage DecodeLegacy(byte[] content)
    {
        try
        {
            using var document = JsonDocument.Parse(content, new JsonDocumentOptions { MaxDepth = 64 });
            var root = document.RootElement;
            var name = Text(root, "name") ?? "ReciteHelper 导入项目";
            var questions = new List<QuestionDraft>(); var diagnostics = new List<string>();
            if (TryProperty(root, "chapter", out var chapters) && chapters.ValueKind == JsonValueKind.Array)
            {
                foreach (var chapter in chapters.EnumerateArray())
                {
                    if (!TryProperty(chapter, "bank", out var bank) || bank.ValueKind != JsonValueKind.Array) continue;
                    foreach (var item in bank.EnumerateArray())
                    {
                        try { questions.Add(ReadLegacyQuestion(item)); }
                        catch (PracticeDomainException error) { diagnostics.Add($"QUESTION_SKIPPED:{error.Code}:{error.Message}"); }
                    }
                }
            }
            return new(name, null, "recitehelper-rhproj", questions, diagnostics);
        }
        catch (JsonException error) { throw new PracticeDomainException(422, "PACKAGE_JSON_INVALID", "ReciteHelper 项目 JSON 无法读取。", new { error.Message }); }
    }

    private static QuestionDraft ReadLegacyQuestion(JsonElement item)
    {
        var prompt = Text(item, "text") ?? ""; var kind = ReadLegacyKind(item);
        var options = new List<QuestionOption>();
        if (TryProperty(item, "options", out var optionArray) && optionArray.ValueKind == JsonValueKind.Array)
            foreach (var option in optionArray.EnumerateArray()) options.Add(new(Text(option, "id") ?? "", Text(option, "text") ?? ""));
        var answers = ReadStringArray(item, kind == PracticeQuestionKind.SingleChoice ? "correct_option_ids" : "correct_answers").ToList();
        var oldAnswer = Text(item, "correct_answer"); if (answers.Count == 0 && !string.IsNullOrWhiteSpace(oldAnswer)) answers.Add(oldAnswer);
        if (kind == PracticeQuestionKind.SingleChoice) answers = answers.Select(x => x.Trim()[..1].ToUpperInvariant()).ToList();
        if (kind == PracticeQuestionKind.TrueFalse) answers = answers.Select(PracticeRules.NormalizeTrueFalse).Where(x => x is not null).Cast<string>().ToList();
        var score = kind switch { PracticeQuestionKind.SingleChoice => 3, PracticeQuestionKind.FillBlank => Math.Max(1, answers.Count), PracticeQuestionKind.TrueFalse => 1, PracticeQuestionKind.TermDefinition => 4, _ => 5 };
        return new(kind, prompt, options, answers, null, score, 3, null, [], QuestionStatus.Ready);
    }

    private static PracticeQuestionKind ReadLegacyKind(JsonElement item)
    {
        if (!TryProperty(item, "type", out var value)) return PracticeQuestionKind.Essay;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number))
            return number switch { 1 => PracticeQuestionKind.SingleChoice, 2 => PracticeQuestionKind.FillBlank, 3 => PracticeQuestionKind.TrueFalse, 4 => PracticeQuestionKind.TermDefinition, _ => PracticeQuestionKind.Essay };
        var text = value.GetString()?.Replace("-", "_").Replace(" ", "_").ToLowerInvariant();
        return text switch { "singlechoice" or "single_choice" or "choice" or "选择题" or "单项选择题" => PracticeQuestionKind.SingleChoice,
            "fillblank" or "fill_blank" or "blank" or "填空题" => PracticeQuestionKind.FillBlank,
            "truefalse" or "true_false" or "judgment" or "判断题" => PracticeQuestionKind.TrueFalse,
            "termdefinition" or "term_definition" or "definition" or "名词解释" => PracticeQuestionKind.TermDefinition, _ => PracticeQuestionKind.Essay };
    }

    private static ZipArchive OpenSafeArchive(Stream stream)
    {
        ZipArchive archive;
        try { archive = new ZipArchive(stream, ZipArchiveMode.Read, true); }
        catch (InvalidDataException) { throw Invalid("项目包不是有效的 ZIP 文件。"); }
        if (archive.Entries.Count > MaxEntries) { archive.Dispose(); throw new PracticeDomainException(422, "PACKAGE_ENTRY_LIMIT", "项目包条目不能超过 2000。\n"); }
        long total = 0; var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in archive.Entries)
        {
            var name = NormalizeEntryName(entry.FullName);
            if (!names.Add(name)) { archive.Dispose(); throw Unsafe("项目包包含重复规范化路径。"); }
            if (entry.Length > MaxEntryBytes || (total += entry.Length) > MaxExpandedBytes) { archive.Dispose(); throw new PracticeDomainException(422, "PACKAGE_EXPANDED_LIMIT", "项目包解压大小超过安全限制。"); }
            var unixType = (entry.ExternalAttributes >> 16) & 0xF000;
            if (unixType == 0xA000) { archive.Dispose(); throw Unsafe("项目包不允许符号链接。"); }
        }
        return archive;
    }

    private static string NormalizeEntryName(string value)
    {
        var replaced = value.Replace('\\', '/');
        if (string.IsNullOrWhiteSpace(replaced) || replaced.StartsWith('/') || replaced.StartsWith("//") || replaced.Contains(':')) throw Unsafe("项目包包含绝对路径或盘符。");
        var segments = replaced.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Any(x => x is "." or "..")) throw Unsafe("项目包路径包含不安全的相对段。");
        return string.Join('/', segments);
    }
    private static byte[] ReadEntry(ZipArchiveEntry entry)
    {
        using var stream = entry.Open(); using var output = new MemoryStream(); stream.CopyTo(output); return output.ToArray();
    }
    private static ZipArchiveEntry Require(IReadOnlyDictionary<string, ZipArchiveEntry> entries, string path) =>
        entries.TryGetValue(NormalizeEntryName(path), out var entry) ? entry : throw Invalid($"缺少 {path}。");
    private static void VerifyHash(PackageManifest manifest, string path, byte[] content)
    {
        if (!manifest.Sha256.TryGetValue(path, out var expected) || !string.Equals(expected, PracticeRules.Sha256(content), StringComparison.OrdinalIgnoreCase))
            throw new PracticeDomainException(422, "PACKAGE_CHECKSUM_MISMATCH", $"{path} 的 SHA-256 校验失败。");
    }
    private static void WriteEntry(ZipArchive archive, string name, byte[] content)
    { var entry = archive.CreateEntry(name, CompressionLevel.Optimal); using var stream = entry.Open(); stream.Write(content); }
    private static QuestionDraft ToDraft(PackageQuestion x) => new(x.Kind, x.Prompt, x.Options, x.CorrectAnswers, x.Explanation, x.Score, x.Difficulty, x.KnowledgePointId, x.SourceReferences, x.Status);
    private static bool TryProperty(JsonElement element, string name, out JsonElement value)
    { foreach (var property in element.EnumerateObject()) if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase)) { value = property.Value; return true; } value = default; return false; }
    private static string? Text(JsonElement element, string name) => TryProperty(element, name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static IEnumerable<string> ReadStringArray(JsonElement element, string name) => TryProperty(element, name, out var value) && value.ValueKind == JsonValueKind.Array
        ? value.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString() ?? "").Where(x => !string.IsNullOrWhiteSpace(x)) : [];
    private static string SafeName(string value) => string.Concat(value.Select(x => char.IsLetterOrDigit(x) || x is '-' or '_' ? x : '_'));
    private static PracticeDomainException Invalid(string message) => new(422, "PACKAGE_INVALID", message);
    private static PracticeDomainException Unsafe(string message) => new(422, "PACKAGE_ENTRY_UNSAFE", message);
    private static JsonSerializerOptions CreateJsonOptions()
    { var options = new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }; options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseUpper)); return options; }

    private sealed record PackageManifest(string SchemaVersion, string ProjectFile, string QuestionsFile, Dictionary<string, string> Sha256, DateTimeOffset ExportedAt);
    private sealed record PackageProject(string Name, string? SubjectCode, IReadOnlyList<Guid> MaterialIds, Guid? GraphId);
    private sealed record PackageQuestion(PracticeQuestionKind Kind, string Prompt, IReadOnlyList<QuestionOption> Options, IReadOnlyList<string> CorrectAnswers,
        string? Explanation, decimal Score, int Difficulty, Guid? KnowledgePointId, IReadOnlyList<SourceReference> SourceReferences, QuestionStatus Status);
}
