using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Wordprocessing;
using HtmlAgilityPack;
using MongoDB.Bson;
using MongoDB.Driver;
using MongoDB.Driver.GridFS;
using UglyToad.PdfPig;

public sealed class MongoFileStore : IFileStore
{
    private readonly IMongoCollection<MaterialDocument> _materials;
    private readonly IMongoCollection<IngestionJob> _jobs;
    private readonly GridFSBucket _files;
    private readonly IMongoDatabase _database;
    private readonly ILogger<MongoFileStore> _logger;
    private readonly IHttpClientFactory _httpClientFactory;

    public MongoFileStore(IConfiguration configuration, ILogger<MongoFileStore> logger, IHttpClientFactory httpClientFactory)
    {
        _logger = logger;
        _httpClientFactory = httpClientFactory;
        var connectionString = configuration.GetConnectionString("FileDatabase") ?? "mongodb://127.0.0.1:27017";
        var databaseName = configuration["MongoDb:Database"] ?? "moonstone_file";
        _database = new MongoClient(connectionString).GetDatabase(databaseName);
        _materials = _database.GetCollection<MaterialDocument>("materials");
        _jobs = _database.GetCollection<IngestionJob>("ingestion_jobs");
        _files = new GridFSBucket(_database, new GridFSBucketOptions { BucketName = "material_content" });
        _materials.Indexes.CreateOne(new CreateIndexModel<MaterialDocument>(Builders<MaterialDocument>.IndexKeys.Ascending(x => x.Material.OwnerUserId).Descending(x => x.Material.CreatedAt)));
        _materials.Indexes.CreateOne(new CreateIndexModel<MaterialDocument>(Builders<MaterialDocument>.IndexKeys.Ascending(x => x.Material.OwnerUserId).Ascending(x => x.SubjectCode).Descending(x => x.Material.CreatedAt)));
        _jobs.Indexes.CreateOne(new CreateIndexModel<IngestionJob>(Builders<IngestionJob>.IndexKeys.Ascending(x => x.MaterialId).Descending(x => x.CreatedAt)));
    }

    public bool IsReady()
    {
        try { _database.RunCommand<BsonDocument>(new BsonDocument("ping", 1)); return true; }
        catch (Exception exception) { _logger.LogWarning(exception, "MongoDB health check failed"); return false; }
    }

    public async Task RecoverIncompleteJobsAsync(CancellationToken cancellationToken)
    {
        var activeJobs = await _jobs.Find(job => job.Status == "QUEUED" || job.Status == "RUNNING").ToListAsync(cancellationToken);
        foreach (var job in activeJobs)
        {
            var material = FindMaterial(job.MaterialId);
            if (material?.Material.Status == "PROCESSING") await ProcessJobAsync(job.JobId, cancellationToken);
        }
    }

    public async Task<StoredMaterial> CreateAsync(string ownerUserId, IFormFile file, string displayName, string? subjectCode, CancellationToken cancellationToken)
    {
        string checksum;
        await using (var checksumStream = file.OpenReadStream()) checksum = Convert.ToHexString(await SHA256.HashDataAsync(checksumStream, cancellationToken)).ToLowerInvariant();
        var id = Guid.NewGuid().ToString(); var now = DateTimeOffset.UtcNow;
        ObjectId gridFsId;
        await using (var uploadStream = file.OpenReadStream())
        {
            gridFsId = await _files.UploadFromStreamAsync(Path.GetFileName(file.FileName), uploadStream,
                new GridFSUploadOptions { Metadata = new BsonDocument { { "materialId", id }, { "ownerUserId", ownerUserId }, { "checksum", checksum }, { "mediaType", file.ContentType } } }, cancellationToken);
        }
        var originalFileName = Path.GetFileName(file.FileName);
        var material = new Material(id, ownerUserId, displayName, originalFileName, DetectMediaType(originalFileName, file.ContentType), file.Length, checksum, "UPLOADED", null, now, now);
        try { await _materials.InsertOneAsync(new MaterialDocument { Material = material, GridFsId = gridFsId.ToString(), SubjectCode = subjectCode }, cancellationToken: cancellationToken); }
        catch { await _files.DeleteAsync(gridFsId, cancellationToken); throw; }
        return new StoredMaterial(material, gridFsId.ToString(), subjectCode, null);
    }

    public Material? GetMaterial(string materialId) => FindMaterial(materialId)?.Material;
    public IReadOnlyList<Material> List(string ownerUserId, string? cursor, int limit, string? status, string? subjectCode, out string? nextCursor)
    {
        var filter = Builders<MaterialDocument>.Filter.Eq(x => x.Material.OwnerUserId, ownerUserId) & Builders<MaterialDocument>.Filter.Ne(x => x.Material.Status, "DELETED");
        if (!string.IsNullOrWhiteSpace(status)) filter &= Builders<MaterialDocument>.Filter.Eq(x => x.Material.Status, status);
        if (!string.IsNullOrWhiteSpace(subjectCode)) filter &= Builders<MaterialDocument>.Filter.Eq(x => x.SubjectCode, subjectCode);
        var records = _materials.Find(filter).SortByDescending(x => x.Material.CreatedAt).ThenByDescending(x => x.Material.MaterialId).ToList();
        var start = string.IsNullOrWhiteSpace(cursor) ? 0 : records.FindIndex(x => x.Material.MaterialId == cursor) + 1;
        if (!string.IsNullOrWhiteSpace(cursor) && start == 0) start = records.Count;
        var items = records.Skip(start).Take(limit).Select(x => x.Material).ToArray(); nextCursor = start + items.Length < records.Count ? items[^1].MaterialId : null; return items;
    }
    public bool TryDelete(string materialId, string ownerUserId, out Material? material)
    {
        material = null; var stored = FindMaterial(materialId); if (stored is null || stored.Material.OwnerUserId != ownerUserId || stored.Material.Status == "DELETED") return false;
        if (GetLatestJob(materialId)?.Status is "QUEUED" or "RUNNING") return false;
        var deleted = stored.Material with { Status = "DELETED", UpdatedAt = DateTimeOffset.UtcNow };
        _materials.ReplaceOne(x => x.Material.MaterialId == materialId, stored with { Material = deleted }); material = deleted;
        if (ObjectId.TryParse(stored.GridFsId, out var gridFsId)) _files.Delete(gridFsId); return true;
    }
    public IngestionJob? GetJob(string jobId) => _jobs.Find(x => x.JobId == jobId).FirstOrDefault();
    public IngestionJob? GetLatestJob(string materialId) => _jobs.Find(x => x.MaterialId == materialId).SortByDescending(x => x.CreatedAt).FirstOrDefault();
    public IngestionJob CreateJob(string materialId, string parserVersion, bool enableOcr, string ocrMode)
    {
        var now = DateTimeOffset.UtcNow; var job = new IngestionJob(Guid.NewGuid().ToString(), materialId, "QUEUED", 0, parserVersion, null, now, now, enableOcr, ocrMode); _jobs.InsertOne(job);
        var stored = FindMaterial(materialId)!; _materials.ReplaceOne(x => x.Material.MaterialId == materialId, stored with { Material = stored.Material with { Status = "PROCESSING", LatestIngestionJobId = job.JobId, UpdatedAt = now } }); return job;
    }
    public async Task ProcessJobAsync(string jobId, CancellationToken cancellationToken)
    {
        var job = GetJob(jobId); if (job is null) return; var stored = FindMaterial(job.MaterialId); if (stored is null) return;
        _jobs.ReplaceOne(x => x.JobId == jobId, job = job with { Status = "RUNNING", Progress = 10, UpdatedAt = DateTimeOffset.UtcNow });
        try
        {
            if (!IsSupportedParserInput(stored.Material)) throw new InvalidOperationException("Only TXT, Markdown, HTML, DOCX, PDF, JPG and PNG extraction is available.");
            if (!ObjectId.TryParse(stored.GridFsId, out var gridFsId)) throw new InvalidOperationException("Invalid GridFS file ID.");
            await using var bytes = new MemoryStream(); await _files.DownloadToStreamAsync(gridFsId, bytes, cancellationToken: cancellationToken); bytes.Position = 0;
            var extraction = await ExtractAsync(stored.Material, bytes, _httpClientFactory.CreateClient("ocr"), job.EnableOcr, job.OcrMode, job.JobId, cancellationToken);
            var text = extraction.Text; if (string.IsNullOrWhiteSpace(text)) throw new InvalidOperationException("No extractable text was found. Scanned PDFs require an OCR parser.");
            var checksum = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
            var sourceMap = extraction.SourceMap; var now = DateTimeOffset.UtcNow;
            var document = new ExtractedTextDocument(job.MaterialId, stored.Material.OwnerUserId, "READY", text, "utf-8", "NFC", "LF", checksum, text.Length, job.ParserVersion, "1", sourceMap, extraction.Blocks, now);
            // Text and READY status reside in one Mongo document, so READY cannot be observed without a complete text document.
            _materials.ReplaceOne(x => x.Material.MaterialId == job.MaterialId, stored with { ExtractedText = document, Material = stored.Material with { Status = "READY", LatestIngestionJobId = jobId, UpdatedAt = now } });
            _jobs.ReplaceOne(x => x.JobId == jobId, job with { Status = "SUCCEEDED", Progress = 100, OcrUsed = extraction.OcrUsed, UpdatedAt = now });
        }
        catch (Exception exception)
        {
            var now = DateTimeOffset.UtcNow; var error = new ApiError("MATERIAL_TEXT_EXTRACTION_FAILED", "Text extraction failed.", new Dictionary<string, string>());
            _jobs.ReplaceOne(x => x.JobId == jobId, job with { Status = "FAILED", Progress = 100, Error = error, UpdatedAt = now });
            _materials.UpdateOne(x => x.Material.MaterialId == job.MaterialId, Builders<MaterialDocument>.Update.Set(x => x.Material, stored.Material with { Status = "FAILED", UpdatedAt = now }));
            _logger.LogWarning(exception, "Extraction failed for material {MaterialId}", job.MaterialId);
        }
    }
    public Stream? OpenContent(string materialId)
    {
        var stored = FindMaterial(materialId); if (stored is null || stored.Material.Status == "DELETED" || !ObjectId.TryParse(stored.GridFsId, out var gridFsId)) return null;
        var stream = new MemoryStream(); _files.DownloadToStream(gridFsId, stream); stream.Position = 0; return stream;
    }
    public ExtractedTextDocument? GetExtractedText(string materialId) => FindMaterial(materialId)?.ExtractedText;
    private MaterialDocument? FindMaterial(string materialId) => _materials.Find(x => x.Material.MaterialId == materialId).FirstOrDefault();
    private static bool IsSupportedParserInput(Material material) => material.MediaType.StartsWith("text/", StringComparison.OrdinalIgnoreCase) || material.MediaType.Equals("image/jpeg", StringComparison.OrdinalIgnoreCase) || material.MediaType.Equals("image/png", StringComparison.OrdinalIgnoreCase) || material.MediaType.Equals("application/pdf", StringComparison.OrdinalIgnoreCase) || material.MediaType.Equals("application/vnd.openxmlformats-officedocument.wordprocessingml.document", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(material.OriginalFileName).Equals(".txt", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(material.OriginalFileName).Equals(".md", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(material.OriginalFileName).Equals(".html", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(material.OriginalFileName).Equals(".htm", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(material.OriginalFileName).Equals(".pdf", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(material.OriginalFileName).Equals(".docx", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(material.OriginalFileName).Equals(".jpg", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(material.OriginalFileName).Equals(".jpeg", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(material.OriginalFileName).Equals(".png", StringComparison.OrdinalIgnoreCase);
    private static string DetectMediaType(string fileName, string? submittedType) => Path.GetExtension(fileName).ToLowerInvariant() switch
    {
        ".txt" when string.IsNullOrWhiteSpace(submittedType) || submittedType.Equals("application/octet-stream", StringComparison.OrdinalIgnoreCase) => "text/plain",
        ".md" when string.IsNullOrWhiteSpace(submittedType) || submittedType.Equals("application/octet-stream", StringComparison.OrdinalIgnoreCase) => "text/markdown",
        ".html" or ".htm" when string.IsNullOrWhiteSpace(submittedType) || submittedType.Equals("application/octet-stream", StringComparison.OrdinalIgnoreCase) => "text/html",
        ".jpg" or ".jpeg" when string.IsNullOrWhiteSpace(submittedType) || submittedType.Equals("application/octet-stream", StringComparison.OrdinalIgnoreCase) => "image/jpeg",
        ".png" when string.IsNullOrWhiteSpace(submittedType) || submittedType.Equals("application/octet-stream", StringComparison.OrdinalIgnoreCase) => "image/png",
        _ => string.IsNullOrWhiteSpace(submittedType) ? "application/octet-stream" : submittedType
    };
    private static async Task<ExtractionResult> ExtractAsync(Material material, Stream content, HttpClient ocrClient, bool enableOcr, string ocrMode, string ocrJobId, CancellationToken cancellationToken)
    {
        content.Position = 0;
        var extension = Path.GetExtension(material.OriginalFileName).ToLowerInvariant();
        if (extension is ".jpg" or ".jpeg" or ".png")
        {
            if (!enableOcr) throw new InvalidOperationException("OCR is disabled. Enable OCR before parsing image files.");
            return await ExtractOcrAsync(material, content, ocrClient, ocrMode, ocrJobId, cancellationToken);
        }
        if (extension == ".pdf")
        {
            var pdf = ExtractStructuredPdf(content);
            if (!string.IsNullOrWhiteSpace(pdf.Text)) return pdf;
            if (!enableOcr) throw new InvalidOperationException("No embedded PDF text was found. Enable OCR to parse a scanned PDF.");
            return await ExtractOcrAsync(material, content, ocrClient, ocrMode, ocrJobId, cancellationToken);
        }
        return extension switch
        {
            ".docx" => ExtractStructuredDocx(content),
            ".md" => await ExtractMarkdownAsync(content, cancellationToken),
            ".html" or ".htm" => await ExtractHtmlAsync(content, cancellationToken),
            _ => await ExtractTextAsync(content, cancellationToken)
        };
    }
    private static async Task<ExtractionResult> ExtractOcrAsync(Material material, Stream content, HttpClient ocrClient, string ocrMode, string ocrJobId, CancellationToken cancellationToken)
    {
        content.Position = 0;
        using var request = new HttpRequestMessage(HttpMethod.Post, "v1/ocr"); request.Headers.Add("X-Ocr-Job-Id", ocrJobId); request.Headers.Add("X-Ocr-Mode", ocrMode);
        using var form = new MultipartFormDataContent();
        using var file = new StreamContent(content);
        file.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(material.MediaType);
        form.Add(file, "file", material.OriginalFileName); request.Content = form;
        using var response = await ocrClient.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"OCR service failed ({(int)response.StatusCode}): {body}");
        var result = JsonSerializer.Deserialize<OcrResponse>(body, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new InvalidOperationException("OCR service returned an invalid response.");
        return BuildStructuredText(result.Pages.SelectMany(page => page.Lines.Select((line, lineIndex) => new StructuredSegment(line, "PARAGRAPH", null, page.PageNumber, lineIndex, $"OCR page {page.PageNumber}")))) with { OcrUsed = true };
    }
    private static async Task<ExtractionResult> ExtractTextAsync(Stream content, CancellationToken cancellationToken)
    {
        using var reader = new StreamReader(content, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, leaveOpen: true);
        var text = Normalize(await reader.ReadToEndAsync(cancellationToken));
        var sourceMap = text.Length == 0 ? Array.Empty<TextSourceSpan>() : [new TextSourceSpan(0, text.Length, null, null, null)];
        var blocks = text.Length == 0 ? Array.Empty<TextDocumentBlock>() : [new TextDocumentBlock("PARAGRAPH", null, text, sourceMap[0])];
        return new ExtractionResult(text, sourceMap, blocks);
    }
    private static ExtractionResult ExtractDocx(Stream content)
    {
        using var document = WordprocessingDocument.Open(content, false);
        var paragraphs = document.MainDocumentPart?.Document?.Body?.Descendants<Paragraph>().Select(paragraph => paragraph.InnerText) ?? Enumerable.Empty<string>();
        return BuildMappedText(paragraphs.Select((text, index) => new ExtractedSegment(text, null, index, null)));
    }
    private static ExtractionResult ExtractPdf(Stream content)
    {
        using var document = PdfDocument.Open(content);
        return BuildMappedText(document.GetPages().Select(page => new ExtractedSegment(page.Text, page.Number, null, $"第 {page.Number} 页")));
    }
    private static ExtractionResult BuildMappedText(IEnumerable<ExtractedSegment> segments)
    {
        var text = new StringBuilder(); var sourceMap = new List<TextSourceSpan>(); var blocks = new List<TextDocumentBlock>();
        foreach (var segment in segments)
        {
            var normalized = Normalize(segment.Text); if (normalized.Length == 0) continue;
            if (text.Length > 0) text.Append('\n');
            var start = text.Length; text.Append(normalized); var source = new TextSourceSpan(start, text.Length, segment.PageNumber, segment.ParagraphIndex, segment.SourceLabel); sourceMap.Add(source); blocks.Add(new TextDocumentBlock("PARAGRAPH", null, normalized, source));
        }
        return new ExtractionResult(text.ToString(), sourceMap, blocks);
    }
    private static ExtractionResult ExtractStructuredDocx(Stream content)
    {
        using var document = WordprocessingDocument.Open(content, false);
        var body = document.MainDocumentPart?.Document?.Body;
        if (body is null) return new ExtractionResult(string.Empty, [], []);

        var segments = new List<StructuredSegment>(); var paragraphIndex = 0;
        foreach (var element in body.ChildElements)
        {
            if (element is Paragraph paragraph)
            {
                var text = paragraph.InnerText; var styleId = paragraph.ParagraphProperties?.ParagraphStyleId?.Val?.Value ?? string.Empty;
                var headingLevel = GetHeadingLevel(styleId); var isList = paragraph.ParagraphProperties?.NumberingProperties is not null;
                var kind = headingLevel is not null ? "HEADING" : isList ? "LIST_ITEM" : "PARAGRAPH";
                if (isList && !string.IsNullOrWhiteSpace(text)) text = "• " + text;
                segments.Add(new StructuredSegment(text, kind, headingLevel, null, paragraphIndex++, headingLevel is not null ? $"Heading {headingLevel}" : isList ? "List item" : "Paragraph"));
            }
            else if (element is Table table)
            {
                var rows = table.Elements<TableRow>().Select(row => string.Join(" | ", row.Elements<TableCell>().Select(cell => Normalize(cell.InnerText).Replace("\n", " ").Trim())));
                segments.Add(new StructuredSegment(string.Join("\n", rows), "TABLE", null, null, paragraphIndex++, "Table"));
            }
        }
        return BuildStructuredText(segments);
    }
    private static ExtractionResult ExtractStructuredPdf(Stream content)
    {
        using var document = PdfDocument.Open(content);
        return BuildStructuredText(document.GetPages().Select(page => new StructuredSegment(page.Text, "PARAGRAPH", null, page.Number, null, $"PDF page {page.Number}")));
    }
    private static async Task<ExtractionResult> ExtractMarkdownAsync(Stream content, CancellationToken cancellationToken)
    {
        using var reader = new StreamReader(content, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, leaveOpen: true);
        var lines = (await reader.ReadToEndAsync(cancellationToken)).Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');
        var segments = new List<StructuredSegment>(); var inCodeBlock = false; var index = 0;
        foreach (var line in lines)
        {
            if (Regex.IsMatch(line, @"^\s*```")) { inCodeBlock = !inCodeBlock; continue; }
            if (string.IsNullOrWhiteSpace(line)) continue;
            if (inCodeBlock) { segments.Add(new StructuredSegment(line, "CODE", null, null, index++, "Code block")); continue; }
            if (Regex.IsMatch(line, @"^\s*\|?\s*:?-{3,}")) continue;
            var heading = Regex.Match(line, @"^\s*(#{1,6})\s+(.+)$");
            if (heading.Success) { segments.Add(new StructuredSegment(ToPlainMarkdown(heading.Groups[2].Value), "HEADING", heading.Groups[1].Value.Length, null, index++, $"Heading {heading.Groups[1].Value.Length}")); continue; }
            var unordered = Regex.Match(line, @"^\s*[-+*]\s+(.+)$");
            var ordered = Regex.Match(line, @"^\s*\d+[.)]\s+(.+)$");
            if (unordered.Success || ordered.Success) { var item = (unordered.Success ? unordered : ordered).Groups[1].Value; segments.Add(new StructuredSegment("• " + ToPlainMarkdown(item), "LIST_ITEM", null, null, index++, "List item")); continue; }
            var kind = line.Contains('|') ? "TABLE" : "PARAGRAPH";
            segments.Add(new StructuredSegment(ToPlainMarkdown(line), kind, null, null, index++, kind == "TABLE" ? "Table" : "Paragraph"));
        }
        return BuildStructuredText(segments);
    }
    private static async Task<ExtractionResult> ExtractHtmlAsync(Stream content, CancellationToken cancellationToken)
    {
        using var reader = new StreamReader(content, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, leaveOpen: true);
        var html = await reader.ReadToEndAsync(cancellationToken);
        var document = new HtmlDocument(); document.LoadHtml(html);
        var root = document.DocumentNode.SelectSingleNode("//body") ?? document.DocumentNode;
        foreach (var ignored in (root.SelectNodes(".//script|.//style|.//noscript|.//template|.//svg")?.Cast<HtmlNode>() ?? Enumerable.Empty<HtmlNode>())) ignored.Remove();

        var nodes = root.SelectNodes(".//h1|.//h2|.//h3|.//h4|.//h5|.//h6|.//p|.//li|.//pre|.//table|.//blockquote")?.Cast<HtmlNode>() ?? Enumerable.Empty<HtmlNode>();
        var segments = new List<StructuredSegment>(); var index = 0;
        foreach (var node in nodes)
        {
            var name = node.Name.ToLowerInvariant();
            var kind = "PARAGRAPH"; int? level = null; string text;
            if (name == "table")
            {
                var rows = node.SelectNodes(".//tr")?.Cast<HtmlNode>().Select(row => string.Join(" | ", (row.SelectNodes("./th|./td")?.Cast<HtmlNode>() ?? Enumerable.Empty<HtmlNode>()).Select(cell => HtmlText(cell.InnerText)))) ?? Enumerable.Empty<string>();
                text = string.Join("\n", rows); kind = "TABLE";
            }
            else
            {
                text = HtmlText(node.InnerText);
                if (name.Length == 2 && name[0] == 'h' && char.IsDigit(name[1])) { kind = "HEADING"; level = name[1] - '0'; }
                else if (name == "li") { kind = "LIST_ITEM"; if (text.Length > 0) text = "• " + text; }
                else if (name == "pre") kind = "CODE";
                else if (name == "blockquote") kind = "QUOTE";
            }
            if (text.Length > 0) segments.Add(new StructuredSegment(text, kind, level, null, index++, kind switch { "HEADING" => $"Heading {level}", "LIST_ITEM" => "List item", "TABLE" => "Table", "CODE" => "Code block", "QUOTE" => "Quote", _ => "Paragraph" }));
        }
        return BuildStructuredText(segments);
    }
    private static ExtractionResult BuildStructuredText(IEnumerable<StructuredSegment> segments)
    {
        var text = new StringBuilder(); var sourceMap = new List<TextSourceSpan>(); var blocks = new List<TextDocumentBlock>();
        foreach (var segment in segments)
        {
            var normalized = Normalize(segment.Text); if (normalized.Length == 0) continue;
            if (text.Length > 0) text.Append('\n');
            var start = text.Length; text.Append(normalized); var source = new TextSourceSpan(start, text.Length, segment.PageNumber, segment.ParagraphIndex, segment.SourceLabel);
            sourceMap.Add(source); blocks.Add(new TextDocumentBlock(segment.Kind, segment.Level, normalized, source));
        }
        return new ExtractionResult(text.ToString(), sourceMap, blocks);
    }
    private static int? GetHeadingLevel(string styleId)
    {
        var match = Regex.Match(styleId, @"^Heading\s*([1-6])$", RegexOptions.IgnoreCase);
        return match.Success ? int.Parse(match.Groups[1].Value) : null;
    }
    private static string ToPlainMarkdown(string text)
    {
        var plain = Regex.Replace(text, @"!\[([^\]]*)\]\([^)]*\)", "$1");
        plain = Regex.Replace(plain, @"\[([^\]]+)\]\([^)]*\)", "$1");
        plain = Regex.Replace(plain, @"`([^`]*)`", "$1");
        plain = Regex.Replace(plain, @"(\*{1,3}|_{1,3}|~~)", string.Empty);
        plain = Regex.Replace(plain, @"^\s*>\s?", string.Empty);
        plain = Regex.Replace(plain, @"\s+#+\s*$", string.Empty);
        return plain.Replace("\\|", "|").Replace("\\*", "*").Trim();
    }
    private static string HtmlText(string text) => Regex.Replace(HtmlEntity.DeEntitize(text), @"\s+", " ").Trim();
    private static string Normalize(string text) => text.Normalize(NormalizationForm.FormC).Replace("\r\n", "\n").Replace("\r", "\n");
}

public sealed record ExtractionResult(string Text, IReadOnlyList<TextSourceSpan> SourceMap, IReadOnlyList<TextDocumentBlock> Blocks, bool OcrUsed = false);
public sealed record ExtractedSegment(string Text, int? PageNumber, int? ParagraphIndex, string? SourceLabel);
public sealed record StructuredSegment(string Text, string Kind, int? Level, int? PageNumber, int? ParagraphIndex, string? SourceLabel);
public sealed record OcrResponse(IReadOnlyList<OcrPage> Pages);
public sealed record OcrPage(int PageNumber, IReadOnlyList<string> Lines);
public sealed record OcrProgress(string Status, int CurrentPage, int TotalPages, string Phase);

public sealed record MaterialDocument
{
    public ObjectId Id { get; init; }
    public required Material Material { get; init; }
    public required string GridFsId { get; init; }
    public string? SubjectCode { get; init; }
    public ExtractedTextDocument? ExtractedText { get; init; }
}
