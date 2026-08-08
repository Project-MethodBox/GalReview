FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY PracticeService.Domain/PracticeService.Domain.csproj PracticeService.Domain/
COPY PracticeService.Application/PracticeService.Application.csproj PracticeService.Application/
COPY PracticeService.Persistence/PracticeService.Persistence.csproj PracticeService.Persistence/
COPY PracticeService.API/PracticeService.API.csproj PracticeService.API/
RUN dotnet restore PracticeService.API/PracticeService.API.csproj
COPY . .
RUN test -f Resources/Models/sbert.onnx \
    && test -f Resources/Models/xgboost_qvalue.onnx \
    && test -f Resources/tokenizer.json \
    && test -f Resources/vocab.txt
RUN dotnet publish PracticeService.API/PracticeService.API.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app .
USER $APP_UID
EXPOSE 5107
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=6 \
    CMD curl --fail --silent http://127.0.0.1:5107/readyz > /dev/null || exit 1
ENTRYPOINT ["dotnet", "PracticeService.API.dll"]
