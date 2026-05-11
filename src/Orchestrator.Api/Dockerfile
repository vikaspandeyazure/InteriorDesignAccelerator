FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY ["src/Orchestrator.Api/Orchestrator.Api.csproj", "src/Orchestrator.Api/"]
COPY ["src/Shared.Contracts/Shared.Contracts.csproj", "src/Shared.Contracts/"]
RUN dotnet restore "src/Orchestrator.Api/Orchestrator.Api.csproj"
COPY . .
WORKDIR /src/src/Orchestrator.Api
RUN dotnet publish -c Release -o /app /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
# libfontconfig1 is the only Debian dep the PDFium native binary (used by
# PDFtoImage at /api/catalog/page-rendered) needs to load fonts. Without it
# PDFium throws an InvalidOperationException on the first render call.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libfontconfig1 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /app .
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "InteriorDesign.Orchestrator.Api.dll"]
