FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY GalGame.UserService.csproj ./
RUN dotnet restore GalGame.UserService.csproj
COPY . .
RUN dotnet publish GalGame.UserService.csproj --configuration Release \
    --output /app/publish --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/publish .
ENV ASPNETCORE_URLS=http://+:5101
EXPOSE 5101
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=5 \
  CMD curl --fail --silent http://127.0.0.1:5101/readyz > /dev/null || exit 1
ENTRYPOINT ["dotnet", "GalGame.UserService.dll"]
