using KnowledgeService.API.Background;
using KnowledgeService.API.Endpoints;
using KnowledgeService.API.Infrastructure;
using KnowledgeService.Application.Extraction;
using KnowledgeService.Application.Features.Builds;
using KnowledgeService.Application.Materials;
using KnowledgeService.Application.Mastery;
using KnowledgeService.Application.Persistence;
using KnowledgeService.Application.Planning;
using KnowledgeService.Application.Segmentation;
using KnowledgeService.Application.Time;
using KnowledgeService.Persistence.Materials;
using KnowledgeService.Persistence.Neo4j;
using KnowledgeService.Persistence.Options;
using KnowledgeService.Persistence.Repositories;
using Neo4j.Driver;

var builder = WebApplication.CreateBuilder(args);

var neo4jOptions = builder.Configuration
    .GetSection(Neo4jOptions.SectionName)
    .Get<Neo4jOptions>() ?? new Neo4jOptions();
var materialTextOptions = builder.Configuration
    .GetSection(GatewayMaterialTextOptions.SectionName)
    .Get<GatewayMaterialTextOptions>() ?? new GatewayMaterialTextOptions();
var gatewayTrustOptions = builder.Configuration
    .GetSection(GatewayTrustOptions.SectionName)
    .Get<GatewayTrustOptions>() ?? new GatewayTrustOptions();
neo4jOptions.Validate();
materialTextOptions.Validate();
gatewayTrustOptions.Validate();

builder.Services.ConfigureHttpJsonOptions(options =>
{
    KnowledgeJsonOptions.Configure(options.SerializerOptions);
});
builder.Services.Configure<Microsoft.AspNetCore.Routing.RouteHandlerOptions>(
    options => options.ThrowOnBadRequest = true);
builder.Services.AddMediatR(configuration =>
    configuration.RegisterServicesFromAssemblyContaining<
        CreateGraphBuildCommand>());

builder.Services.AddSingleton(neo4jOptions);
builder.Services.AddSingleton(materialTextOptions);
builder.Services.AddSingleton(gatewayTrustOptions);
builder.Services.AddSingleton<IDriver>(_ =>
    Neo4jDriverFactory.Create(neo4jOptions));
builder.Services.AddSingleton<IKnowledgeRepository, Neo4jKnowledgeRepository>();
builder.Services.AddHttpClient<IMaterialTextClient, GatewayMaterialTextClient>();

builder.Services.AddSingleton<ISystemClock, SystemClock>();
builder.Services.AddSingleton<IChapterSegmenter, ChapterSegmenter>();
builder.Services.AddSingleton<IKnowledgeExtractor, RuleBasedKnowledgeExtractor>();
builder.Services.AddSingleton<AssessmentPlanner>();
builder.Services.AddSingleton<LearningPlanner>();
builder.Services.AddSingleton<MasteryEvidenceUpdater>();

builder.Services.AddSingleton<IGraphBuildQueue, GraphBuildQueue>();
builder.Services.AddHostedService<Neo4jSchemaInitializer>();
builder.Services.AddHostedService<GraphBuildWorker>();

var app = builder.Build();
app.UseMiddleware<TraceContextMiddleware>();
app.UseMiddleware<ApiExceptionMiddleware>();
app.UseMiddleware<GatewayTrustMiddleware>();

app.MapGet("/", () => Results.Ok(new
{
    service = "KnowledgeService",
    status = "running"
}));
app.MapHealthEndpoints();
app.MapGraphBuildEndpoints();
app.MapKnowledgeGraphEndpoints();
app.MapReviewPlanEndpoints();

app.Run();

public partial class Program;
