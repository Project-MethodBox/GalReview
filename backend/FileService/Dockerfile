FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY GalGame.FileService.csproj ./
RUN dotnet restore GalGame.FileService.csproj
COPY . .
RUN dotnet publish GalGame.FileService.csproj --configuration Release \
    --output /app/publish --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/publish .
ENV ASPNETCORE_URLS=http://+:5103
EXPOSE 5103
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=6 \
  CMD curl --fail --silent http://127.0.0.1:5103/readyz > /dev/null || exit 1
USER app
ENTRYPOINT ["dotnet", "GalGame.FileService.dll"]
