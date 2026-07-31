using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;

public interface IFileStore
{
    Task<StoredMaterial> CreateAsync(string ownerUserId, IFormFile file, string displayName, string? subjectCode, CancellationToken cancellationToken);
    Material? GetMaterial(string materialId);
    IReadOnlyList<Material> List(string ownerUserId, string? cursor, int limit, string? status, string? subjectCode, out string? nextCursor);
    bool TryDelete(string materialId, string ownerUserId, out Material? material);
    IngestionJob? GetJob(string jobId);
    IngestionJob? GetLatestJob(string materialId);
    IngestionJob CreateJob(string materialId, string parserVersion, bool enableOcr, string ocrMode);
    Task ProcessJobAsync(string jobId, CancellationToken cancellationToken);
    Stream? OpenContent(string materialId);
    ExtractedTextDocument? GetExtractedText(string materialId);
}

public sealed class LocalFileStore : IFileStore
{
    private readonly ConcurrentDictionary<string, StoredMaterial> _materials = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, IngestionJob> _jobs = new(StringComparer.Ordinal);
    private readonly string _contentRoot;
    private readonly ILogger<LocalFileStore> _logger;

    public LocalFileStore(IConfiguration configuration, IWebHostEnvironment environment, ILogger<LocalFileStore> logger)
    {
        _logger = logger;
        var configured = configuration["FileStorage:RootPath"] ?? "data";
        _contentRoot = Path.GetFullPath(Path.Combine(environment.ContentRootPath, configured, "content"));
        Directory.CreateDirectory(_contentRoot);
    }

    public async Task<StoredMaterial> CreateAsync(string ownerUserId, IFormFile file, string displayName, string? subjectCode, CancellationToken cancellationToken)
    {
        var id = Guid.NewGuid().ToString(); var now = DateTimeOffset.UtcNow;
        var filePath = Path.Combine(_contentRoot, id + ".bin");
        string checksum;
        await using (var target = new FileStream(filePath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true))
        await using (var source = file.OpenReadStream())
        using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
        {
            var buffer = new byte[81920]; int read;
            while ((read = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken)) > 0)
            { await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken); hash.AppendData(buffer, 0, read); }
            checksum = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        }
        var material = new Material(id, ownerUserId, displayName, Path.GetFileName(file.FileName), string.IsNullOrWhiteSpace(file.ContentType) ? "application/octet-stream" : file.ContentType, file.Length, checksum, "UPLOADED", null, now, now);
        var stored = new StoredMaterial(material, filePath, subjectCode, null); _materials[id] = stored; return stored;
    }
    public Material? GetMaterial(string materialId) => _materials.TryGetValue(materialId, out var stored) ? stored.Material : null;
    public IReadOnlyList<Material> List(string ownerUserId, string? cursor, int limit, string? status, string? subjectCode, out string? nextCursor)
    {
        var records = _materials.Values.Where(x => x.Material.OwnerUserId == ownerUserId && x.Material.Status != "DELETED" && (status is null || x.Material.Status == status) && (subjectCode is null || x.SubjectCode == subjectCode)).Select(x => x.Material).OrderByDescending(x => x.CreatedAt).ThenByDescending(x => x.MaterialId).ToArray();
        var start = 0; if (!string.IsNullOrWhiteSpace(cursor)) start = Array.FindIndex(records, x => x.MaterialId == cursor) + 1; if (start <= 0 && !string.IsNullOrWhiteSpace(cursor)) start = records.Length;
        var items = records.Skip(start).Take(limit).ToArray(); nextCursor = start + items.Length < records.Length ? items[^1].MaterialId : null; return items;
    }
    public bool TryDelete(string materialId, string ownerUserId, out Material? material)
    {
        material = null; if (!_materials.TryGetValue(materialId, out var stored) || stored.Material.OwnerUserId != ownerUserId || stored.Material.Status == "DELETED") return false;
        if (stored.Material.Status == "PROCESSING" || GetLatestJob(materialId)?.Status is "QUEUED" or "RUNNING") return false;
        var deleted = stored.Material with { Status = "DELETED", UpdatedAt = DateTimeOffset.UtcNow }; _materials[materialId] = stored with { Material = deleted }; material = deleted; return true;
    }
    public IngestionJob? GetJob(string jobId) => _jobs.TryGetValue(jobId, out var job) ? job : null;
    public IngestionJob? GetLatestJob(string materialId) => _jobs.Values.Where(x => x.MaterialId == materialId).OrderByDescending(x => x.CreatedAt).FirstOrDefault();
    public IngestionJob CreateJob(string materialId, string parserVersion, bool enableOcr, string ocrMode)
    {
        var now = DateTimeOffset.UtcNow; var job = new IngestionJob(Guid.NewGuid().ToString(), materialId, "QUEUED", 0, parserVersion, null, now, now, enableOcr, ocrMode); _jobs[job.JobId] = job;
        var stored = _materials[materialId]; _materials[materialId] = stored with { Material = stored.Material with { Status = "PROCESSING", LatestIngestionJobId = job.JobId, UpdatedAt = now } }; return job;
    }
    public async Task ProcessJobAsync(string jobId, CancellationToken cancellationToken)
    {
        if (!_jobs.TryGetValue(jobId, out var job) || !_materials.TryGetValue(job.MaterialId, out var stored)) return;
        _jobs[jobId] = job = job with { Status = "RUNNING", Progress = 10, UpdatedAt = DateTimeOffset.UtcNow };
        try
        {
            if (!stored.Material.MediaType.StartsWith("text/", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Only text/* extraction is available in this M0 parser; PDF/DOCX parser adapter is pending.");
            string raw; await using (var stream = File.OpenRead(stored.ContentPath)) using (var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true)) raw = await reader.ReadToEndAsync(cancellationToken);
            var text = raw.Normalize(NormalizationForm.FormC).Replace("\r\n", "\n").Replace("\r", "\n");
            var checksum = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
            var sourceMap = text.Length == 0 ? Array.Empty<TextSourceSpan>() : [new TextSourceSpan(0, text.Length, null, null, null)];
            var blocks = text.Length == 0 ? Array.Empty<TextDocumentBlock>() : [new TextDocumentBlock("PARAGRAPH", null, text, sourceMap[0])];
            var document = new ExtractedTextDocument(job.MaterialId, stored.Material.OwnerUserId, "READY", text, "utf-8", "NFC", "LF", checksum, text.Length, job.ParserVersion, "1", sourceMap, blocks, DateTimeOffset.UtcNow);
            var now = DateTimeOffset.UtcNow; var succeeded = job with { Status = "SUCCEEDED", Progress = 100, UpdatedAt = now };
            _jobs[jobId] = succeeded;
            // Store text before publishing READY: internal readers can never observe READY without its document.
            _materials[job.MaterialId] = stored with { ExtractedText = document, Material = stored.Material with { Status = "READY", LatestIngestionJobId = jobId, UpdatedAt = now } };
            _logger.LogInformation("MaterialTextReady v1 prepared for {MaterialId}; checksum {Checksum}", job.MaterialId, checksum);
        }
        catch (Exception exception)
        {
            var now = DateTimeOffset.UtcNow; var error = new ApiError("MATERIAL_TEXT_EXTRACTION_FAILED", "Text extraction failed.", new { });
            _jobs[jobId] = job with { Status = "FAILED", Progress = 100, Error = error, UpdatedAt = now };
            _materials[job.MaterialId] = stored with { Material = stored.Material with { Status = "FAILED", UpdatedAt = now } };
            _logger.LogWarning(exception, "Extraction failed for material {MaterialId}", job.MaterialId);
        }
    }
    public Stream? OpenContent(string materialId) => _materials.TryGetValue(materialId, out var stored) && stored.Material.Status != "DELETED" && File.Exists(stored.ContentPath) ? File.OpenRead(stored.ContentPath) : null;
    public ExtractedTextDocument? GetExtractedText(string materialId) => _materials.TryGetValue(materialId, out var stored) ? stored.ExtractedText : null;
}
