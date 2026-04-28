# az-settings-fetch

A PowerShell utility that pulls Azure App Service and Function App settings down to your local machine — ready to run.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and logged in (`az login`)

## Usage

```powershell
.\fetch-settings.ps1
```

1. **Pick a resource group** — all RGs in your active subscription are listed; select by number.
   > Don't see your RG? Switch subscriptions first: `az account set --subscription <id>`
2. **Select apps** — an interactive menu lists all Function Apps and Web Apps in the RG, sorted by type then name. Use arrow keys to navigate, `SPACE` to toggle, `ENTER` to confirm. Multiple apps can be selected.
3. **Settings are fetched and saved** — Key Vault references are automatically resolved to their real values.

## Output

Files are written to `output/<yyyy-MM-dd_HH-mm>_<rg-name>/<app-name>/`:

| App type     | File                                                                      |
| ------------ | ------------------------------------------------------------------------- |
| Function App | `local.settings.json`                                                     |
| Web App      | `appsettings.json` (keys with `__` separators expanded into nested JSON)  |

Settings are sorted alphabetically. The `output/` directory is gitignored so secrets are never accidentally committed.
