$rgs = az group list --query "[].name" --output json | ConvertFrom-Json | Sort-Object

for ($i = 0; $i -lt $rgs.Count; $i++) {
    Write-Host "$($i + 1). $($rgs[$i])"
}

Write-Host "`nDon't see your resource group? You may need to change your subscription (az account set --subscription <id>)." -ForegroundColor Yellow

$rgSelection = $null
while ($true) {
    $rgInput = Read-Host "Select a resource group number"
    $rgSelectionInt = $rgInput -as [int]
    if ($null -ne $rgSelectionInt -and $rgSelectionInt -ge 1 -and $rgSelectionInt -le $rgs.Count) {
        $rgSelection = $rgs[$rgSelectionInt - 1]
        break
    }
    Write-Host "Invalid selection." -ForegroundColor Red
}

$rgName = $rgSelection
Write-Host "Selected rg: $rgName"

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$outDir = Join-Path $PSScriptRoot "output\${timestamp}_${rgName}"
New-Item -ItemType Directory -Path $outDir | Out-Null
Write-Host "Output directory: $outDir"

function Invoke-GrantKvAccess {
    param([string]$vaultName)

    if ($script:fixedVaults.ContainsKey($vaultName)) { return $script:fixedVaults[$vaultName] }

    $confirm = Read-Host "  Attempt to auto-assign Key Vault access for '$vaultName'? (y/N)"
    if ($confirm -notmatch '^[Yy]') {
        $script:fixedVaults[$vaultName] = $false
        return $false
    }

    $vaultId = az keyvault show --name $vaultName --query id --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultId)) {
        Write-Host "  Could not retrieve vault '$vaultName' — you may not have Reader access to it." -ForegroundColor Red
        $script:fixedVaults[$vaultName] = $false
        return $false
    }

    Write-Host "  Trying RBAC role assignment (Key Vault Secrets User)..." -ForegroundColor Cyan
    az role assignment create --role "Key Vault Secrets User" --assignee $script:currentUserId --scope $vaultId --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Role assigned. Waiting for propagation..." -ForegroundColor Green
        $script:fixedVaults[$vaultName] = $true
        return $true
    }

    Write-Host "  RBAC failed, trying access policy..." -ForegroundColor Cyan
    az keyvault set-policy --name $vaultName --object-id $script:currentUserId --secret-permissions get list --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Access policy set. Waiting for propagation..." -ForegroundColor Green
        $script:fixedVaults[$vaultName] = $true
        return $true
    }

    Write-Host "  Could not assign access automatically — you may need elevated permissions to modify this vault." -ForegroundColor Red
    $script:fixedVaults[$vaultName] = $false
    return $false
}

function ConvertTo-NestedHashtable($flat) {
    $root = [ordered]@{}
    foreach ($key in $flat.Keys) {
        $parts = $key -split "__"
        $node = $root
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            if (-not $node.Contains($parts[$i])) {
                $node[$parts[$i]] = [ordered]@{}
            }
            $node = $node[$parts[$i]]
        }
        $node[$parts[-1]] = $flat[$key]
    }
    return $root
}

$webApps = az webapp list --resource-group $rgName --query "[].{Name:name, Type:kind}" --output json | ConvertFrom-Json
$funcApps = az functionapp list --resource-group $rgName --query "[].{Name:name, Type:kind}" --output json | ConvertFrom-Json

$all = @($webApps) + @($funcApps)

$appList = @($all | ForEach-Object {
    $type = if ($_.Type -like "*functionapp*") { "function" } else { "web" }
    [PSCustomObject]@{ Name = $_.Name; Type = $type }
} | Sort-Object Type, Name)

Write-Host "Select apps to fetch (SPACE to toggle, ENTER to confirm):" -ForegroundColor Cyan
Write-Host "  [UP/DOWN] Navigate  [SPACE] Toggle  [ENTER] Confirm" -ForegroundColor DarkGray
Write-Host ""

$selected = @($false) * $appList.Count
$cursor = 0

function Show-AppMenu {
    param($appList, $selected, $cursor)
    for ($i = 0; $i -lt $appList.Count; $i++) {
        $check  = if ($selected[$i]) { "[X]" } else { "[ ]" }
        $color  = if ($i -eq $cursor) { "Yellow" } else { "White" }
        $prefix = if ($i -eq $cursor) { "> " } else { "  " }
        $label  = "$($appList[$i].Name)  ($($appList[$i].Type))"
        Write-Host "$prefix$check $label" -ForegroundColor $color
    }
}

[Console]::CursorVisible = $false
Show-AppMenu $appList $selected $cursor

while ($true) {
    $key = [Console]::ReadKey($true)

    $redraw = $false
    switch ($key.Key) {
        'UpArrow'   { if ($cursor -gt 0)                    { $cursor--; $redraw = $true } }
        'DownArrow' { if ($cursor -lt $appList.Count - 1)   { $cursor++; $redraw = $true } }
        'Spacebar'  { $selected[$cursor] = -not $selected[$cursor]; $redraw = $true }
        'Enter'     { break }
    }
    if ($key.Key -eq 'Enter') { break }

    if ($redraw) {
        [Console]::SetCursorPosition(0, [Console]::CursorTop - $appList.Count)
        Show-AppMenu $appList $selected $cursor
    }
}

[Console]::CursorVisible = $true
Write-Host ""

$toFetch = for ($i = 0; $i -lt $appList.Count; $i++) {
    if ($selected[$i]) { $appList[$i] }
}

if (-not $toFetch) {
    Write-Host "No apps selected. Exiting." -ForegroundColor Yellow
    exit
}

$currentUserId = az ad signed-in-user show --query id --output tsv 2>$null
$fixedVaults = @{}

foreach ($app in $toFetch) {
    Write-Host "Fetching settings for $($app.Name)..." -ForegroundColor Cyan

    if ($app.Type -eq "function") {
        $rawSettings = az functionapp config appsettings list --name $app.Name --resource-group $rgName --output json | ConvertFrom-Json
    } else {
        $rawSettings = az webapp config appsettings list --name $app.Name --resource-group $rgName --output json | ConvertFrom-Json
    }

    # Resolve KV references
    $resolved = foreach ($s in $rawSettings) {
        if ($s.value -match "@Microsoft\.KeyVault\(") {
            if ($s.value -match "SecretUri=([^;)]+)") {
                $secretUri = $Matches[1]
                $kvValue = az keyvault secret show --id $secretUri --query "value" --output tsv 2>$null
                if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kvValue)) {
                    Write-Host "  WARNING: could not read KV secret for '$($s.name)' (SecretUri)." -ForegroundColor DarkYellow
                    if ($secretUri -match "https://([^.]+)\.vault\.azure\.net") {
                        if (Invoke-GrantKvAccess $Matches[1]) {
                            Start-Sleep -Seconds 10
                            $kvValue = az keyvault secret show --id $secretUri --query "value" --output tsv 2>$null
                        }
                    }
                    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kvValue)) {
                        $kvValue = "(KV_ACCESS_FAILED: $secretUri)"
                    }
                }
            } elseif ($s.value -match "VaultName=([^;)]+).*SecretName=([^;)]+)") {
                $vaultName = $Matches[1]
                $secretName = $Matches[2]
                $kvValue = az keyvault secret show --vault-name $vaultName --name $secretName --query "value" --output tsv 2>$null
                if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kvValue)) {
                    Write-Host "  WARNING: could not read KV secret '$secretName' from vault '$vaultName' for '$($s.name)'." -ForegroundColor DarkYellow
                    if (Invoke-GrantKvAccess $vaultName) {
                        Start-Sleep -Seconds 10
                        $kvValue = az keyvault secret show --vault-name $vaultName --name $secretName --query "value" --output tsv 2>$null
                    }
                    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kvValue)) {
                        $kvValue = "(KV_ACCESS_FAILED: $vaultName/$secretName)"
                    }
                }
            } else {
                Write-Host "  WARNING: could not parse KV reference for '$($s.name)': $($s.value)" -ForegroundColor DarkYellow
                $kvValue = "(KV_PARSE_FAILED: $($s.value))"
            }
            [PSCustomObject]@{ Name = $s.name; Value = $kvValue }
        } else {
            [PSCustomObject]@{ Name = $s.name; Value = $s.value }
        }
    }

    $values = [ordered]@{}
    foreach ($s in $resolved | Sort-Object Name) { $values[$s.Name] = $s.Value }

    $appOutDir = Join-Path $outDir $app.Name
    New-Item -ItemType Directory -Path $appOutDir | Out-Null

    if ($app.Type -eq "function") {
        $json = [PSCustomObject]@{
            IsEncrypted = $false
            Values      = $values
            Host        = [PSCustomObject]@{
                LocalHttpPort = 7071
                CORS          = "*"
            }
        } | ConvertTo-Json -Depth 5
        $outFile = Join-Path $appOutDir "local.settings.json"
    } else {
        $nested = ConvertTo-NestedHashtable $values
        $json   = $nested | ConvertTo-Json -Depth 10
        $outFile = Join-Path $appOutDir "appsettings.json"
    }

    $json | Out-File -FilePath $outFile -Encoding utf8
    Write-Host "Saved to: $outFile" -ForegroundColor Green
}
 