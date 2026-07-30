using System.Text.Json.Serialization;
using MongoDB.Bson.Serialization.Attributes;

public sealed record Material(string MaterialId, string OwnerUserId, string DisplayName, string OriginalFileName, string MediaType, long SizeBytes, string Checksum, string Status, string? LatestIngestionJobId, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt);
public sealed record MaterialPage(IReadOnlyList<Material> Items, string? NextCursor);
public sealed record CreateIngestionJobRequest(string? ParserVersion, bool Force = false, bool EnableOcr = false, string? OcrMode = null);
[BsonIgnoreExtraElements]
public sealed record IngestionJob(string JobId, string MaterialId, string Status, int Progress, string ParserVersion, ApiError? Error, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt, bool EnableOcr = false, string OcrMode = "standard", bool OcrUsed = false);
public sealed record CreateAccessGrantRequest(string Purpose);
public sealed record AccessGrant(string Url, DateTimeOffset ExpiresAt);
public sealed record TextSourceSpan(long StartOffset, long EndOffset, int? PageNumber, int? ParagraphIndex, string? SourceLabel);
public sealed record TextDocumentBlock(string Kind, int? Level, string Text, TextSourceSpan Source);
public sealed record ExtractedTextDocument(string MaterialId, string OwnerUserId, string Status, string Text, string Encoding, string Normalization, string LineEnding, string TextChecksum, long TextLength, string ParserVersion, string SourceMapVersion, IReadOnlyList<TextSourceSpan> SourceMap, IReadOnlyList<TextDocumentBlock> Blocks, DateTimeOffset CreatedAt);
public sealed record ApiError(string Code, string Message, object Details);
public sealed record ApiSuccess(object Data, object Meta, string TraceId) { public static ApiSuccess Create(object data, string traceId) => new(data, new { }, traceId); }
public sealed record ApiFailure(object? Data, ApiError Error, string TraceId) { public static ApiFailure Create(string code, string message, string traceId) => new(null, new(code, message, new { }), traceId); }

public sealed record StoredMaterial(Material Material, string ContentPath, string? SubjectCode, ExtractedTextDocument? ExtractedText);
