FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["CreditService.Domain/CreditService.Domain.csproj", "CreditService.Domain/"]
COPY ["CreditService.Application/CreditService.Application.csproj", "CreditService.Application/"]
COPY ["CreditService.Persistence/CreditService.Persistence.csproj", "CreditService.Persistence/"]
COPY ["CreditService.API/CreditService.API.csproj", "CreditService.API/"]
RUN dotnet restore CreditService.API/CreditService.API.csproj
COPY . .
RUN dotnet publish CreditService.API/CreditService.API.csproj -c Release -o /app/publish --no-restore
FROM mcr.microsoft.com/dotnet/aspnet:10.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/publish .
USER $APP_UID
EXPOSE 5108
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=6 \
    CMD curl --fail --silent http://127.0.0.1:5108/readyz > /dev/null || exit 1
ENTRYPOINT ["dotnet","CreditService.API.dll"]
