FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ModelService.Domain/ModelService.Domain.csproj ModelService.Domain/
COPY ModelService.Application/ModelService.Application.csproj ModelService.Application/
COPY ModelService.Persistence/ModelService.Persistence.csproj ModelService.Persistence/
COPY ModelService.API/ModelService.API.csproj ModelService.API/
RUN dotnet restore ModelService.API/ModelService.API.csproj
COPY . .
RUN test -f Resources/Models/multilingual-minilm-nli/model.onnx \
    && test -f Resources/Models/multilingual-minilm-nli/sentencepiece.bpe.model \
    && test -f Resources/cn_synonym.txt
RUN dotnet publish ModelService.API/ModelService.API.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app .
USER $APP_UID
EXPOSE 5109
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=6 \
    CMD curl --fail --silent http://127.0.0.1:5109/readyz > /dev/null || exit 1
ENTRYPOINT ["dotnet", "ModelService.API.dll"]
