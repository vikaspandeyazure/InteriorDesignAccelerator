# Deployment Guide — Interior Design Accelerator

End-to-end, copy-paste-able deployment instructions. Targets **Sweden Central** by default. Every step is idempotent.

---

## 0. Prerequisites

| Tool | Min version | Install |
| --- | --- | --- |
| Azure CLI | 2.62 | https://aka.ms/InstallAzureCli |
| Azure Developer CLI (`azd`, optional, for Foundry data-plane auth fallback) | 1.10 | `winget install microsoft.azd` |
| .NET SDK | 8.0 (or 9.0 with `global.json` rollForward) | https://dotnet.microsoft.com/download |
| PowerShell 7+ | 7.4 | `winget install Microsoft.PowerShell` |
| Bicep | 0.30 | `az bicep upgrade` |
| Docker (optional, for local image build) | 24+ | https://www.docker.com/products/docker-desktop/ |

Check everything in one shot:

```pwsh
az --version
azd version
dotnet --version
pwsh -v
az bicep version
docker --version   # optional
```

You also need:

- **Owner** or **Contributor + User Access Administrator** on the target subscription (the deployment creates RBAC role assignments).
- Your tenant's **Microsoft Foundry** quota approved for `gpt-5.1-mini` and `mai-image-2` in Sweden Central. If either model is not yet available there, override with `-FoundryLocation <other-region>` when calling `deploy.ps1`.

---

## 1. Get the source

```pwsh
# Already created at C:\git\InteriorDesignAccelerator
cd C:\git\InteriorDesignAccelerator
```

If you cloned from a fresh repo, restore + build to make sure your machine is healthy:

```pwsh
dotnet restore .\InteriorDesignAccelerator.slnx
dotnet build   .\InteriorDesignAccelerator.slnx
dotnet test    .\tests\Orchestrator.Tests\Orchestrator.Tests.csproj
```

You should see **Passed!  Failed: 0, Passed: 1**.

---

## 2. Stage the catalog files

Copy the supplied catalogs to your machine:

```text
C:\Bath Fittings Data\
   jaguar\
      jaguar-catalogue.pdf
      images\*.jpg
   parryware\
      parryware-catalogue.pdf
      images\*.jpg
```

The folder names matter — `deploy.ps1` reads `<root>\jaguar` and `<root>\parryware`. If your files are at the root with no brand subfolders, they'll be uploaded to `catalogs/misc/`.

---

## 3. `az login` and pick a subscription

```pwsh
az login
az account list --output table
az account set --subscription "<your-subscription-name-or-guid>"

# Optional but recommended (helps the Foundry data-plane scripts):
azd auth login
```

`deploy.ps1` will also prompt you to pick a subscription if you skip this — but doing it up front is cleaner.

---

## 4. (Optional) Reuse an existing Foundry account

`deploy.ps1` enumerates every `Microsoft.CognitiveServices/accounts` of kind `AIServices` in your subscription and lets you reuse one instead of creating a new one in the new resource group. If you already have a Foundry hub (e.g. shared across teams), just pick its index from the list when prompted. Otherwise press **N** to create a new one.

The reused account must:

- Be in a region that supports the chat & image models you want.
- Have `allowProjectManagement = true` (Foundry hubs do).
- Allow your user object id `Cognitive Services User` + `Azure AI Developer` role assignments (the script grants these).

---

## 5. (Optional) Reuse an existing resource group

When prompted for an RG name, type:

- the name of an **existing** RG in this subscription ? it will be reused, or
- a **new** name (default `rg-idabath-dev`) ? it will be created in `-Location swedencentral`.

---

## 6. Run the end-to-end deploy

```pwsh
# Dry-run first (no changes made):
pwsh .\infra\scripts\deploy.ps1 `
  -Workload idabath -Env dev `
  -Location swedencentral `
  -CatalogSourcePath "C:\Bath Fittings Data" `
  -WhatIf

# When happy, do the real thing:
pwsh .\infra\scripts\deploy.ps1 `
  -Workload idabath -Env dev `
  -Location swedencentral `
  -CatalogSourcePath "C:\Bath Fittings Data"
```

What happens, in order:

1. **Validates** `az`, `docker`, signed-in user.
2. **Picks subscription / RG / Foundry account** interactively.
3. **Sequentially deploys each Bicep module** under `infra/modules/*.bicep` via `az deployment group create` (one phase at a time, resumable). The provisioned resources are:
   - Resource Group · Log Analytics · App Insights
   - User-Assigned Managed Identity (used by every compute resource)
   - Storage account + `catalogs`, `products` and `generated` containers
   - Azure AI Search (`basic`, semantic enabled, AAD-only auth)
   - Microsoft Foundry account + project + `gpt-4.1-mini` and `MAI-Image-2` deployments + AI Search connection (project Knowledge)
   - Azure Container Apps environment + Orchestrator app (placeholder image first, then ACR build + update)
   - Linux App Service plan + Web App
   - APIM (Consumption) with `/design/generate` operation
4. Uploads catalog files to the `catalogs` blob container with **AAD auth**.
5. Creates the per-brand AI Search index schemas (`jaguar-catalog`, `parryware-catalog`).
6. **Phase 8d — Document Intelligence Layout** OCRs each PDF in `data/catalogs/{brand}/` and writes one product entry per page into `products/{brand}.json`.
7. **Phase 8e** creates the AI Search datasource + indexer that consumes `products/{brand}.json` (`jsonArray` parsing) into the brand index.
8. Creates the three **Foundry hosted agents** (chat / catalog-search / image-gen) via the New Foundry agents data plane (`services.ai.azure.com/agents/{name}/versions`) and wires their names into the Container App.
9. Publishes the Blazor Web UI to App Service via `az webapp deploy`.

Total wall-clock time: **~25-35 min** on a fresh subscription, ~10 min on a re-deploy.

---

## 7. Smoke test

```pwsh
$rg  = 'rg-idabath-dev'
$web = az webapp list -g $rg --query "[?starts_with(name,'app-web-')].defaultHostName | [0]" -o tsv
Start-Process "https://$web"
```

In the UI:

1. Leave the default prompt or type your own ("modern bathroom with Parryware rain shower and Jaguar matte black mixer").
2. Tick **Jaguar** + **Parryware** brands.
3. Click **Generate**.

You should see (within ~30 s):

- A photorealistic 1024×1024 bathroom render.
- A markdown narrative referencing each catalog product by name.
- An expandable **Agent trace** with one row per orchestrator step.

If anything fails, expand the trace — each failed agent is shown with its exception message.

---

## 8. Verifying each piece in isolation

| What | How |
| --- | --- |
| AI Search index has docs | Foundry Portal -> Search service -> Search explorer, query `*` against `jaguar-catalog` and `parryware-catalog` |
| Knowledge bound | Foundry Portal -> Project -> **Connections** -> `aoai-aisearch` shows source = AI Search |
| Hosted agents created | Foundry Portal -> Project -> **Agents** -> `chat-agent`, `catalog-search-agent`, `image-gen-agent` listed |
| Orchestrator running | `az containerapp logs show -g rg-idabath-dev -n ca-orch-idabath-dev-* --tail 50` |
| App Service up | `https://<webapp>.azurewebsites.net` returns the Blazor page |
| APIM gateway | `az apim list -g rg-idabath-dev --query "[].gatewayUrl"` then call `/design/health` with the subscription key |

---

## 9. Common issues

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Model gpt-5.1-mini not available in swedencentral` | Quota / region | Re-run with `-ChatModelName gpt-4.1-mini` or `-FoundryLocation eastus2` |
| `403` calling Search from orchestrator | RBAC propagation latency | Wait 5 min; `az role assignment list --assignee <appPrincipalId>` to confirm |
| Image returns empty | Image model deployment not yet ready | `az cognitiveservices account deployment show -g <rg> -n <foundry> --deployment-name mai-image-2` |
| `Knowledge create call failed` | Foundry data-plane API version drifted | Update `$apiVersion` in `infra/scripts/create-knowledge.ps1` |
| Container app shows placeholder text | Image build/push step skipped | Run `deploy.ps1` again (or build & push your own image and `az containerapp update --image ...`) |

---

## 10. Tear-down

```pwsh
az group delete -n rg-idabath-dev --yes --no-wait
# Foundry account purges:
az cognitiveservices account purge -g rg-idabath-dev -n aif-idabath-dev-* -l swedencentral
```

---

## 11. Hardening checklist (next iteration)

When you're ready to move past the demo:

- [ ] Add `infra/modules/network.bicep` (VNet + subnets + NSGs)
- [ ] Add **Private Endpoints** for: Storage (blob), Search, Foundry, Key Vault, Container Apps env, APIM
- [ ] Switch APIM to `Developer` or `Premium` SKU + **internal mode**
- [ ] Switch Storage `allowBlobPublicAccess` to `false`, serve images via SAS or reverse proxy
- [ ] Front App Service with **Front Door + WAF**
- [ ] Replace `DefaultAzureCredential` with `ManagedIdentityCredential` explicitly using the User-Assigned MI client id
- [ ] Add **Azure Monitor alerts** on container app 5xx, App Insights failure rate, Search query latency
- [ ] Move secrets/keys (if any) to **Key Vault** with `RBAC` and **CMK** for storage encryption
- [ ] Pin the Container Apps image to a digest in your own ACR; add CI to build & push on commit


