ARG DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0@sha256:72dd743782f2ae7e5476fd64f6a460045e3998dc862218b80e6944cba79a01b0
ARG DOTNET_ASPNET_IMAGE=mcr.microsoft.com/dotnet/aspnet:10.0@sha256:f1126d438ccc359f51cc6d4701a8deae513856cf10f5fe645d29ea6403dcac6b

FROM ${DOTNET_SDK_IMAGE} AS build
WORKDIR /src
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    NUGET_XMLDOC_MODE=skip

COPY GalGame.GalGameService.csproj ./
RUN dotnet restore GalGame.GalGameService.csproj

COPY . .
RUN dotnet publish GalGame.GalGameService.csproj --configuration Release \
    --output /app/publish --no-restore \
    /p:UseAppHost=false \
    /p:ContinuousIntegrationBuild=true \
    /p:Deterministic=true \
    /p:DebugSymbols=false \
    /p:DebugType=None

FROM ${DOTNET_ASPNET_IMAGE} AS final
WORKDIR /app
COPY --from=build /app/publish .
ENV ASPNETCORE_URLS=http://+:5105 \
    DOTNET_EnableDiagnostics=0
EXPOSE 5105

USER $APP_UID

HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=6 \
  CMD ["/bin/bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/5105 && printf 'GET /readyz HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n' >&3 && IFS=' ' read -r _ status _ <&3 && [ \"$status\" = 200 ]"]

ENTRYPOINT ["dotnet", "GalGame.GalGameService.dll"]
