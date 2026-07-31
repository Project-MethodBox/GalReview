using System.Text.Json;
using KnowledgeService.API.Contracts;
using KnowledgeService.API.Infrastructure;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging.Abstractions;

namespace KnowledgeService.Tests.Features;

public sealed class ApiExceptionMiddlewareTests
{
    [Fact]
    public async Task Json_binding_bad_request_uses_contract_400_envelope()
    {
        var middleware = new ApiExceptionMiddleware(
            _ => throw new BadHttpRequestException(
                "JSON 枚举值无效。",
                StatusCodes.Status400BadRequest),
            NullLogger<ApiExceptionMiddleware>.Instance);
        var context = new DefaultHttpContext
        {
            TraceIdentifier = "json-binding-trace"
        };
        context.Response.Body = new MemoryStream();

        await middleware.InvokeAsync(context);

        Assert.Equal(
            StatusCodes.Status400BadRequest,
            context.Response.StatusCode);
        context.Response.Body.Position = 0;
        using var document = await JsonDocument.ParseAsync(
            context.Response.Body);
        var root = document.RootElement;
        Assert.Equal(
            JsonValueKind.Null,
            root.GetProperty("data").ValueKind);
        Assert.Equal(
            "VALIDATION_ERROR",
            root.GetProperty("error").GetProperty("code").GetString());
        Assert.Empty(
            root
                .GetProperty("error")
                .GetProperty("details")
                .EnumerateObject());
        Assert.Equal(
            "json-binding-trace",
            root.GetProperty("traceId").GetString());
    }

    [Theory]
    [InlineData("0")]
    [InlineData("999")]
    public async Task Numeric_enum_json_exception_uses_contract_400(
        string numericValue)
    {
        var options = new JsonSerializerOptions(
            JsonSerializerDefaults.Web);
        KnowledgeJsonOptions.Configure(options);
        var json =
            $$"""
              {
                "materialId": "10000000-0000-0000-0000-000000000001",
                "segmentationMode": {{numericValue}}
              }
              """;
        var middleware = new ApiExceptionMiddleware(
            _ =>
            {
                var ignored =
                    JsonSerializer.Deserialize<GraphBuildRequest>(
                    json,
                    options);
                return Task.CompletedTask;
            },
            NullLogger<ApiExceptionMiddleware>.Instance);
        var context = new DefaultHttpContext
        {
            TraceIdentifier = "numeric-enum-trace"
        };
        context.Response.Body = new MemoryStream();

        await middleware.InvokeAsync(context);

        Assert.Equal(
            StatusCodes.Status400BadRequest,
            context.Response.StatusCode);
        context.Response.Body.Position = 0;
        using var document = await JsonDocument.ParseAsync(
            context.Response.Body);
        Assert.Equal(
            "VALIDATION_ERROR",
            document.RootElement
                .GetProperty("error")
                .GetProperty("code")
                .GetString());
    }
}
