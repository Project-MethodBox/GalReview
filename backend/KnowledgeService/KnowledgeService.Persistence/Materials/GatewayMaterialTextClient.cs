using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Materials;
using KnowledgeService.Domain.Materials;
using KnowledgeService.Persistence.Options;

namespace KnowledgeService.Persistence.Materials;

public sealed class GatewayMaterialTextClient : IMaterialTextClient
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };

    private static readonly UTF8Encoding StrictUtf8 = new(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true);

    private readonly HttpClient _httpClient;
    private readonly GatewayMaterialTextOptions _options;
    private readonly Uri _baseUri;

    public GatewayMaterialTextClient(
        HttpClient httpClient,
        GatewayMaterialTextOptions options)
    {
        ArgumentNullException.ThrowIfNull(httpClient);
        ArgumentNullException.ThrowIfNull(options);

        options.Validate();

        _httpClient = httpClient;
        _options = options;
        _baseUri = new Uri(
            options.BaseUrl.EndsWith("/", StringComparison.Ordinal)
                ? options.BaseUrl
                : $"{options.BaseUrl}/",
            UriKind.Absolute);
    }

    public async Task<MaterialTextDocument> GetExtractedTextAsync(
        Guid materialId,
        string correlationId,
        CancellationToken cancellationToken)
    {
        if (materialId == Guid.Empty)
        {
            throw new ArgumentException("materialId must not be empty.", nameof(materialId));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(correlationId);

        using var request = CreateRequest(materialId, correlationId);
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        timeoutSource.CancelAfter(_options.Timeout);

        try
        {
            using var response = await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                timeoutSource.Token);

            if (!response.IsSuccessStatusCode)
            {
                throw MapHttpFailure(
                    response.StatusCode,
                    materialId,
                    correlationId);
            }

            var payload = await ReadPayloadAsync(
                response,
                materialId,
                correlationId,
                timeoutSource.Token);

            return MaterialTextContractValidator.Validate(
                payload,
                materialId,
                correlationId);
        }
        catch (KnowledgeServiceException)
        {
            throw;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException exception)
        {
            throw Unavailable(
                materialId,
                correlationId,
                "Timed out while reading normalized text from FileService.",
                exception);
        }
        catch (HttpRequestException exception)
        {
            throw Unavailable(
                materialId,
                correlationId,
                "FileService is unavailable while reading normalized text.",
                exception);
        }
        catch (IOException exception)
        {
            throw Unavailable(
                materialId,
                correlationId,
                "The FileService response stream ended unexpectedly.",
                exception);
        }
    }

    private HttpRequestMessage CreateRequest(Guid materialId, string correlationId)
    {
        var requestUri = new Uri(
            _baseUri,
            $"internal/v1/materials/{materialId:D}/extracted-text");
        var request = new HttpRequestMessage(HttpMethod.Get, requestUri);

        request.Headers.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.Accept.Add(
            new MediaTypeWithQualityHeaderValue("text/plain", 0.5));
        request.Headers.TryAddWithoutValidation("X-Correlation-Id", correlationId);
        request.Headers.TryAddWithoutValidation("X-Service-Name", _options.ServiceName);

        if (!string.IsNullOrWhiteSpace(_options.ServiceKey))
        {
            request.Headers.TryAddWithoutValidation("X-Service-Key", _options.ServiceKey);
        }

        return request;
    }

    private static async Task<MaterialTextResponse> ReadPayloadAsync(
        HttpResponseMessage response,
        Guid materialId,
        string correlationId,
        CancellationToken cancellationToken)
    {
        var mediaType = response.Content.Headers.ContentType?.MediaType;
        if (string.Equals(mediaType, "text/plain", StringComparison.OrdinalIgnoreCase))
        {
            return await ReadPlainTextPayloadAsync(
                response,
                materialId,
                correlationId,
                cancellationToken);
        }

        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(
                cancellationToken);
            using var document = await JsonDocument.ParseAsync(
                stream,
                cancellationToken: cancellationToken);

            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw MaterialTextContractValidator.ContractInvalid(
                    materialId,
                    correlationId,
                    "The extracted-text JSON response must be an object.");
            }

            JsonElement payload;
            if (root.TryGetProperty("data", out var data))
            {
                if (data.ValueKind != JsonValueKind.Object)
                {
                    throw MaterialTextContractValidator.ContractInvalid(
                        materialId,
                        correlationId,
                        "The extracted-text success envelope contains invalid data.");
                }

                payload = data;
            }
            else
            {
                payload = root;
            }

            var result = payload.Deserialize<MaterialTextResponse>(JsonOptions);
            return result ??
                throw MaterialTextContractValidator.ContractInvalid(
                    materialId,
                    correlationId,
                    "The extracted-text JSON payload is empty.");
        }
        catch (KnowledgeServiceException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw MaterialTextContractValidator.ContractInvalid(
                materialId,
                correlationId,
                "FileService returned malformed extracted-text JSON.",
                exception);
        }
        catch (NotSupportedException exception)
        {
            throw MaterialTextContractValidator.ContractInvalid(
                materialId,
                correlationId,
                "FileService returned an unsupported extracted-text JSON shape.",
                exception);
        }
    }

    private static async Task<MaterialTextResponse> ReadPlainTextPayloadAsync(
        HttpResponseMessage response,
        Guid materialId,
        string correlationId,
        CancellationToken cancellationToken)
    {
        var charset = response.Content.Headers.ContentType?.CharSet;
        if (!string.IsNullOrWhiteSpace(charset) &&
            !string.Equals(
                charset.Trim().Trim('"'),
                "utf-8",
                StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(
                charset.Trim().Trim('"'),
                "utf8",
                StringComparison.OrdinalIgnoreCase))
        {
            throw MaterialTextContractValidator.ContractInvalid(
                materialId,
                correlationId,
                "A text/plain extracted-text response must use UTF-8.");
        }

        string text;
        try
        {
            var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            text = StrictUtf8.GetString(bytes);
        }
        catch (DecoderFallbackException exception)
        {
            throw MaterialTextContractValidator.ContractInvalid(
                materialId,
                correlationId,
                "The text/plain extracted-text response is not valid UTF-8.",
                exception);
        }

        return new MaterialTextResponse
        {
            MaterialId = ReadGuidHeader(response, "X-Material-Id") ?? materialId,
            Status = ReadHeader(response, "X-Material-Status") ?? "READY",
            Text = text,
            Encoding = ReadHeader(response, "X-Text-Encoding") ?? "utf-8",
            Normalization = ReadHeader(response, "X-Text-Normalization"),
            LineEnding = ReadHeader(response, "X-Text-Line-Ending"),
            TextChecksum = ReadChecksumHeader(response),
            TextLength = ReadInt64Header(response, "X-Text-Length"),
            ParserVersion = ReadHeader(response, "X-Parser-Version"),
            Language = ReadHeader(response, "X-Text-Language") ??
                response.Content.Headers.ContentLanguage.FirstOrDefault(),
            CreatedAt = ReadDateHeader(response, "X-Extracted-At") ??
                response.Content.Headers.LastModified
        };
    }

    private static string? ReadChecksumHeader(HttpResponseMessage response)
    {
        var checksum = ReadHeader(response, "X-Text-Checksum");
        if (!string.IsNullOrWhiteSpace(checksum))
        {
            return checksum;
        }

        return response.Headers.ETag?.Tag.Trim('"');
    }

    private static string? ReadHeader(
        HttpResponseMessage response,
        string headerName)
    {
        if (response.Headers.TryGetValues(headerName, out var responseValues))
        {
            return responseValues.FirstOrDefault();
        }

        if (response.Content.Headers.TryGetValues(headerName, out var contentValues))
        {
            return contentValues.FirstOrDefault();
        }

        return null;
    }

    private static Guid? ReadGuidHeader(
        HttpResponseMessage response,
        string headerName)
    {
        return Guid.TryParse(
            ReadHeader(response, headerName),
            out var value)
            ? value
            : null;
    }

    private static long? ReadInt64Header(
        HttpResponseMessage response,
        string headerName)
    {
        return long.TryParse(
            ReadHeader(response, headerName),
            NumberStyles.None,
            CultureInfo.InvariantCulture,
            out var value)
            ? value
            : null;
    }

    private static DateTimeOffset? ReadDateHeader(
        HttpResponseMessage response,
        string headerName)
    {
        return DateTimeOffset.TryParse(
            ReadHeader(response, headerName),
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind,
            out var value)
            ? value
            : null;
    }

    private static KnowledgeServiceException MapHttpFailure(
        HttpStatusCode statusCode,
        Guid materialId,
        string correlationId)
    {
        var downstreamStatus = (int)statusCode;
        return statusCode switch
        {
            HttpStatusCode.NotFound => Failure(
                404,
                "MATERIAL_NOT_FOUND",
                "The requested material does not exist.",
                materialId,
                correlationId,
                downstreamStatus),
            HttpStatusCode.Conflict => Failure(
                409,
                "MATERIAL_TEXT_NOT_READY",
                "The requested material text is not ready.",
                materialId,
                correlationId,
                downstreamStatus),
            HttpStatusCode.UnprocessableEntity => Failure(
                422,
                "MATERIAL_TEXT_EXTRACTION_FAILED",
                "Text extraction failed for the requested material.",
                materialId,
                correlationId,
                downstreamStatus),
            HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden => Failure(
                503,
                "FILE_SERVICE_AUTH_FAILED",
                "FileService rejected the KnowledgeService identity.",
                materialId,
                correlationId,
                downstreamStatus),
            >= HttpStatusCode.InternalServerError => Failure(
                503,
                "FILE_SERVICE_UNAVAILABLE",
                "FileService is unavailable while reading normalized text.",
                materialId,
                correlationId,
                downstreamStatus),
            _ => Failure(
                502,
                "FILE_SERVICE_BAD_RESPONSE",
                "FileService returned an unexpected HTTP status.",
                materialId,
                correlationId,
                downstreamStatus)
        };
    }

    private static KnowledgeServiceException Unavailable(
        Guid materialId,
        string correlationId,
        string message,
        Exception innerException)
    {
        return new KnowledgeServiceException(
            503,
            "FILE_SERVICE_UNAVAILABLE",
            message,
            new Dictionary<string, object?>
            {
                ["materialId"] = materialId,
                ["correlationId"] = correlationId
            },
            innerException);
    }

    private static KnowledgeServiceException Failure(
        int statusCode,
        string code,
        string message,
        Guid materialId,
        string correlationId,
        int downstreamStatus)
    {
        return new KnowledgeServiceException(
            statusCode,
            code,
            message,
            new Dictionary<string, object?>
            {
                ["materialId"] = materialId,
                ["correlationId"] = correlationId,
                ["downstreamStatus"] = downstreamStatus
            });
    }
}
