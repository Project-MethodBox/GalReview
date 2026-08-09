FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
EXPOSE 8080
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG BUILD_CONFIGURATION=Release
WORKDIR /src
COPY ["KnowledgeService.Domain/KnowledgeService.Domain.csproj", "KnowledgeService.Domain/"]
COPY ["KnowledgeService.Application/KnowledgeService.Application.csproj", "KnowledgeService.Application/"]
COPY ["KnowledgeService.Persistence/KnowledgeService.Persistence.csproj", "KnowledgeService.Persistence/"]
COPY ["KnowledgeService.API/KnowledgeService.API.csproj", "KnowledgeService.API/"]
RUN dotnet restore "KnowledgeService.API/KnowledgeService.API.csproj"
COPY . .
RUN dotnet publish "KnowledgeService.API/KnowledgeService.API.csproj" \
    --configuration "$BUILD_CONFIGURATION" \
    --output /app/publish \
    /p:UseAppHost=false

FROM runtime AS final
USER $APP_UID
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080
COPY --from=build /app/publish .
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=5 \
    CMD curl --fail --silent http://127.0.0.1:8080/readyz > /dev/null || exit 1
ENTRYPOINT ["dotnet", "KnowledgeService.API.dll"]
