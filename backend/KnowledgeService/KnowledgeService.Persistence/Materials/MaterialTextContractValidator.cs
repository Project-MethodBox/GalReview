using System.Security.Cryptography;
using System.Text;
using KnowledgeService.Application.Exceptions;
using KnowledgeService.Domain.Materials;

namespace KnowledgeService.Persistence.Materials;

internal static class MaterialTextContractValidator
{
    private static readonly UTF8Encoding StrictUtf8 = new(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true);

    public static MaterialTextDocument Validate(
        MaterialTextResponse response,
        Guid expectedMaterialId,
        Guid expectedOwnerUserId,
        string correlationId)
    {
        if (response.MaterialId is null ||
            response.MaterialId.Value == Guid.Empty ||
            response.MaterialId.Value != expectedMaterialId)
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The materialId in the extracted-text response does not match the request.");
        }

        if (response.OwnerUserId is null ||
            response.OwnerUserId.Value == Guid.Empty)
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted-text response is missing ownerUserId.");
        }

        if (response.OwnerUserId.Value != expectedOwnerUserId)
        {
            throw new KnowledgeServiceException(
                403,
                "MATERIAL_ACCESS_DENIED",
                "The requested material does not belong to the graph owner.",
                new Dictionary<string, object?>
                {
                    ["materialId"] = expectedMaterialId,
                    ["correlationId"] = correlationId
                });
        }

        if (!string.Equals(response.Status, "READY", StringComparison.OrdinalIgnoreCase))
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "A successful extracted-text response must have status READY.");
        }

        if (response.Text is null)
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted-text response is missing text.");
        }

        if (!string.Equals(response.Encoding, "utf-8", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(response.Encoding, "utf8", StringComparison.OrdinalIgnoreCase))
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted-text response must declare UTF-8 encoding.");
        }

        if (!string.Equals(response.Normalization, "NFC", StringComparison.OrdinalIgnoreCase))
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted-text response must declare NFC normalization.");
        }

        if (!string.Equals(response.LineEnding, "LF", StringComparison.OrdinalIgnoreCase))
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted-text response must declare LF line endings.");
        }

        if (response.Text.IndexOf('\r') >= 0)
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted text contains a CR character; only LF line endings are allowed.");
        }

        if (response.Text.StartsWith('\uFEFF') ||
            response.Text.IndexOf('\0') >= 0)
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted text must not contain a BOM or NUL character.");
        }

        if (!response.Text.IsNormalized(NormalizationForm.FormC))
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted text is not NFC-normalized.");
        }

        byte[] textBytes;
        try
        {
            textBytes = StrictUtf8.GetBytes(response.Text);
        }
        catch (EncoderFallbackException exception)
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted text cannot be encoded as valid UTF-8.",
                exception);
        }

        if (!IsSha256(response.TextChecksum))
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted-text response contains an invalid SHA-256 checksum.");
        }

        var actualChecksum = Convert.ToHexStringLower(SHA256.HashData(textBytes));
        if (!string.Equals(
                actualChecksum,
                response.TextChecksum,
                StringComparison.OrdinalIgnoreCase))
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted text does not match textChecksum.");
        }

        if (response.TextLength is null || response.TextLength.Value < 0)
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted-text response contains an invalid textLength.");
        }

        var actualUtf16Length = (long)response.Text.Length;
        if (actualUtf16Length != response.TextLength.Value)
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted text UTF-16 code-unit length does not match textLength.");
        }

        if (string.IsNullOrWhiteSpace(response.ParserVersion))
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted-text response is missing parserVersion.");
        }

        if (response.CreatedAt is null)
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted-text response is missing createdAt.");
        }

        if (!string.Equals(
                response.SourceMapVersion,
                "1",
                StringComparison.Ordinal))
        {
            throw ContractInvalid(
                expectedMaterialId,
                correlationId,
                "The extracted-text response must use sourceMapVersion 1.");
        }

        var sourceMap = ValidateSourceMap(
            response,
            expectedMaterialId,
            correlationId);
        var blocks = ValidateBlocks(
            response,
            sourceMap,
            expectedMaterialId,
            correlationId);
        var language = string.IsNullOrWhiteSpace(response.Language)
            ? "und"
            : response.Language.Trim();

        return new MaterialTextDocument(
            expectedMaterialId,
            expectedOwnerUserId,
            response.Text,
            actualChecksum,
            response.ParserVersion.Trim(),
            language,
            sourceMap,
            blocks,
            response.CreatedAt.Value);
    }

    public static KnowledgeServiceException ContractInvalid(
        Guid materialId,
        string correlationId,
        string message,
        Exception? innerException = null)
    {
        return new KnowledgeServiceException(
            502,
            "MATERIAL_TEXT_CONTRACT_INVALID",
            message,
            new Dictionary<string, object?>
            {
                ["materialId"] = materialId,
                ["correlationId"] = correlationId
            },
            innerException);
    }

    private static bool IsSha256(string? checksum)
    {
        if (checksum is null || checksum.Length != 64)
        {
            return false;
        }

        foreach (var character in checksum)
        {
            if (!Uri.IsHexDigit(character))
            {
                return false;
            }
        }

        return true;
    }

    private static IReadOnlyList<MaterialSourceSpan> ValidateSourceMap(
        MaterialTextResponse response,
        Guid materialId,
        string correlationId)
    {
        if (response.SourceMap is null || response.SourceMap.Count == 0)
        {
            throw ContractInvalid(
                materialId,
                correlationId,
                "The extracted-text response is missing sourceMap entries.");
        }

        var result = new MaterialSourceSpan[response.SourceMap.Count];
        long previousEnd = 0;
        for (var index = 0; index < response.SourceMap.Count; index++)
        {
            result[index] = ValidateSpan(
                response.SourceMap[index],
                response.Text!.Length,
                previousEnd,
                $"sourceMap[{index}]",
                materialId,
                correlationId);
            previousEnd = result[index].EndOffset;
        }

        return result;
    }

    private static IReadOnlyList<MaterialTextBlock> ValidateBlocks(
        MaterialTextResponse response,
        IReadOnlyList<MaterialSourceSpan> sourceMap,
        Guid materialId,
        string correlationId)
    {
        if (response.Blocks is null || response.Blocks.Count == 0)
        {
            throw ContractInvalid(
                materialId,
                correlationId,
                "The extracted-text response is missing blocks.");
        }

        var result = new MaterialTextBlock[response.Blocks.Count];
        long previousEnd = 0;
        for (var index = 0; index < response.Blocks.Count; index++)
        {
            var block = response.Blocks[index];
            if (block is null)
            {
                throw ContractInvalid(
                    materialId,
                    correlationId,
                    $"blocks[{index}] is null.");
            }

            if (string.IsNullOrWhiteSpace(block.Kind))
            {
                throw ContractInvalid(
                    materialId,
                    correlationId,
                    $"blocks[{index}].kind is missing.");
            }

            if (block.Text is null || block.Source is null)
            {
                throw ContractInvalid(
                    materialId,
                    correlationId,
                    $"blocks[{index}] is missing text or source.");
            }

            if (block.Level is < 1 or > 6)
            {
                throw ContractInvalid(
                    materialId,
                    correlationId,
                    $"blocks[{index}].level must be between 1 and 6.");
            }

            var source = ValidateSpan(
                block.Source,
                response.Text!.Length,
                previousEnd,
                $"blocks[{index}].source",
                materialId,
                correlationId);
            previousEnd = source.EndOffset;

            var sourceLength = checked((int)(source.EndOffset - source.StartOffset));
            var sourceText = response.Text.AsSpan(
                checked((int)source.StartOffset),
                sourceLength);
            if (!sourceText.SequenceEqual(block.Text.AsSpan()))
            {
                throw ContractInvalid(
                    materialId,
                    correlationId,
                    $"blocks[{index}].text does not match its source range.");
            }

            if (!sourceMap.Contains(source))
            {
                throw ContractInvalid(
                    materialId,
                    correlationId,
                    $"blocks[{index}].source is not present in sourceMap.");
            }

            result[index] = new MaterialTextBlock(
                block.Kind.Trim().ToUpperInvariant(),
                block.Level,
                block.Text,
                source);
        }

        return result;
    }

    private static MaterialSourceSpan ValidateSpan(
        MaterialTextSourceSpanResponse? span,
        int textLength,
        long previousEnd,
        string fieldName,
        Guid materialId,
        string correlationId)
    {
        if (span is null)
        {
            throw ContractInvalid(
                materialId,
                correlationId,
                $"{fieldName} is null.");
        }

        if (span.StartOffset < previousEnd ||
            span.EndOffset <= span.StartOffset ||
            span.EndOffset > textLength)
        {
            throw ContractInvalid(
                materialId,
                correlationId,
                $"{fieldName} is outside the text or is not ordered.");
        }

        if (span.PageNumber is <= 0)
        {
            throw ContractInvalid(
                materialId,
                correlationId,
                $"{fieldName}.pageNumber must be positive.");
        }

        if (span.ParagraphIndex is < 0)
        {
            throw ContractInvalid(
                materialId,
                correlationId,
                $"{fieldName}.paragraphIndex must not be negative.");
        }

        return new MaterialSourceSpan(
            span.StartOffset,
            span.EndOffset,
            span.PageNumber,
            span.ParagraphIndex,
            string.IsNullOrWhiteSpace(span.SourceLabel)
                ? null
                : span.SourceLabel.Trim());
    }
}
