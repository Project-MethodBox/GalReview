using MediatR;
using Microsoft.AspNetCore.Diagnostics;
using ModelService.API;
using ModelService.Application;
using ModelService.Domain;
using ModelService.Persistence;
using System.Text.Json.Serialization;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
builder.Services.Configure<Microsoft.AspNetCore.Routing.RouteHandlerOptions>(options =>
    options.ThrowOnBadRequest = true);
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase;
    options.SerializerOptions.Converters.Add(new JsonStringEnumConverter(
        System.Text.Json.JsonNamingPolicy.SnakeCaseUpper, false));
});
builder.Services.AddMediatR(configuration =>
    configuration.RegisterServicesFromAssembly(typeof(AdjudicateFacetsCommand).Assembly));
builder.Services.AddModelPersistence(builder.Configuration, builder.Environment.ContentRootPath);
var gatewayKey = builder.Configuration["Gateway:ServiceKey"] ??
    throw new InvalidOperationException("Gateway:ServiceKey must be configured.");

var app = builder.Build();
app.UseExceptionHandler(handler => handler.Run(async context =>
{
    var exception = context.Features.Get<IExceptionHandlerFeature>()?.Error;
    var trace = context.TraceIdentifier;
    if (exception is ModelServiceException domain)
    {
        context.Response.StatusCode = domain.StatusCode;
        await context.Response.WriteAsJsonAsync(ApiFailure.Create(
            domain.Code, domain.Message, trace, domain.Details));
        return;
    }
    if (exception is BadHttpRequestException bad)
    {
        context.Response.StatusCode = 400;
        await context.Response.WriteAsJsonAsync(ApiFailure.Create(
            "VALIDATION_ERROR", bad.Message, trace));
        return;
    }
    app.Logger.LogError(exception, "Unhandled ModelService error; traceId={TraceId}", trace);
    context.Response.StatusCode = 500;
    await context.Response.WriteAsJsonAsync(ApiFailure.Create(
        "INTERNAL_ERROR", "模型服务暂时无法完成请求。", trace));
}));

app.MapGet("/healthz", () => Results.Ok(new
{
    status = "ok",
    service = "ModelService"
}));

app.MapGet("/readyz", async (ISender sender, CancellationToken cancellationToken) =>
{
    var readiness = await sender.Send(new GetModelReadinessQuery(), cancellationToken);
    return readiness.Status == "ready"
        ? Results.Ok(readiness)
        : Results.Json(readiness, statusCode: 503);
});

app.MapPost("/internal/v1/model-inference/facet-adjudications", async (
    AdjudicateFacetsRequest request,
    HttpContext context,
    ISender sender,
    CancellationToken cancellationToken) =>
{
    RequestIdentity.RequireService(context, gatewayKey, "PracticeService");
    var result = await sender.Send(new AdjudicateFacetsCommand(
        request.Answer ?? string.Empty,
        request.Facets ?? []), cancellationToken);
    return Results.Ok(new ApiSuccess<object>(result, new { }, context.TraceIdentifier));
});

app.Run();

public partial class Program;
