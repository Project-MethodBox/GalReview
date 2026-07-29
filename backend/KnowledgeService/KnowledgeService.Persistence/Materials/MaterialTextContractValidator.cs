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

        var language = string.IsNullOrWhiteSpace(response.Language)
            ? "und"
            : response.Language.Trim();

        return new MaterialTextDocument(
            expectedMaterialId,
            response.Text,
            actualChecksum,
            response.ParserVersion.Trim(),
            language,
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
}
