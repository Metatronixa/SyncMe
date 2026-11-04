#Requires -Version 5.1
<#
.SYNOPSIS
  SyncMe ModuleEntra — certificate (preferred) app auth, Graph permission fingerprint,
  Sites.Selected preference, and credential-compromise playbook helpers.
  Additive identity/health only; rclone OneDrive remains the restic cloud backend.
#>

function ConvertTo-SyncMeEntraBool {
    param($Value, [bool]$Default = $false)
    if (Get-Command ConvertTo-SyncMeOptionBool -ErrorAction SilentlyContinue) {
        return [bool](ConvertTo-SyncMeOptionBool -Value $Value -Default $Default)
    }
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ($s -in @('1', 'true', 'yes', 'on')) { return $true }
    if ($s -in @('0', 'false', 'no', 'off')) { return $false }
    return $Default
}

function Get-SyncMeEntraConfigPath {
    param([Parameter(Mandatory)][string]$ScriptRoot)
    return (Join-Path $ScriptRoot 'Config\Entra.json')
}

function Get-SyncMeEntraDangerousAppRoles {
    return @(
        'Sites.ReadWrite.All',
        'Sites.FullControl.All',
        'Mail.ReadWrite',
        'Mail.ReadWrite.All',
        'Directory.Read.All',
        'Directory.ReadWrite.All',
        'User.ReadWrite.All',
        'Group.ReadWrite.All',
        'Application.ReadWrite.All',
        'AppRoleAssignment.ReadWrite.All',
        'RoleManagement.ReadWrite.Directory',
        'Files.ReadWrite.All'
    )
}

function Get-SyncMeEntraDefaultConfig {
    return [ordered]@{
        EntraEnabled             = $false
        TenantId                 = ''
        ClientId                 = ''
        CertThumbprint           = ''
        CertStore                = 'CurrentUser\My'
        UseClientSecret          = $false
        ClientSecretTargetName   = ''
        Workloads                = @()
        ExpectedAppRoles         = @()
        ExpectedDelegatedScopes  = @()
        SelectedSiteIds          = @()
    }
}

function ConvertTo-SyncMeEntraStringList {
    param($Value)
    $list = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        foreach ($p in ($Value -split '[,;\s]+')) {
            if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$list.Add($p.Trim()) }
        }
        return @($list)
    }
    foreach ($item in @($Value)) {
        $s = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$list.Add($s.Trim()) }
    }
    return @($list)
}

function Get-SyncMeEntraConfig {
    param([Parameter(Mandatory)][string]$ScriptRoot)
    $defaults = Get-SyncMeEntraDefaultConfig
    $path = Get-SyncMeEntraConfigPath -ScriptRoot $ScriptRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]$defaults
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json
        foreach ($k in @('TenantId', 'ClientId', 'CertThumbprint', 'CertStore', 'ClientSecretTargetName')) {
            if ($null -ne $obj.PSObject.Properties[$k]) {
                $defaults[$k] = [string]$obj.$k
            }
        }
        if ($null -ne $obj.PSObject.Properties['EntraEnabled']) {
            $defaults['EntraEnabled'] = (ConvertTo-SyncMeEntraBool -Value $obj.EntraEnabled -Default $false)
        }
        if ($null -ne $obj.PSObject.Properties['UseClientSecret']) {
            $defaults['UseClientSecret'] = (ConvertTo-SyncMeEntraBool -Value $obj.UseClientSecret -Default $false)
        }
        foreach ($lk in @('Workloads', 'ExpectedAppRoles', 'ExpectedDelegatedScopes', 'SelectedSiteIds')) {
            if ($null -ne $obj.PSObject.Properties[$lk]) {
                $defaults[$lk] = ConvertTo-SyncMeEntraStringList -Value $obj.$lk
            }
        }
    } catch { }
    return [pscustomobject]$defaults
}

function Save-SyncMeEntraConfig {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [object]$EntraEnabled,
        [string]$TenantId,
        [string]$ClientId,
        [string]$CertThumbprint,
        [string]$CertStore,
        [object]$UseClientSecret,
        [string]$ClientSecretTargetName,
        $Workloads,
        $ExpectedAppRoles,
        $ExpectedDelegatedScopes,
        $SelectedSiteIds
    )
    $dir = Join-Path $ScriptRoot 'Config'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $current = Get-SyncMeEntraConfig -ScriptRoot $ScriptRoot
    $payload = [ordered]@{
        EntraEnabled            = $(if ($PSBoundParameters.ContainsKey('EntraEnabled')) { (ConvertTo-SyncMeEntraBool -Value $EntraEnabled -Default $false) } else { [bool]$current.EntraEnabled })
        TenantId                = $(if ($PSBoundParameters.ContainsKey('TenantId')) { [string]$TenantId.Trim() } else { [string]$current.TenantId })
        ClientId                = $(if ($PSBoundParameters.ContainsKey('ClientId')) { [string]$ClientId.Trim() } else { [string]$current.ClientId })
        CertThumbprint          = $(if ($PSBoundParameters.ContainsKey('CertThumbprint')) { [string]$CertThumbprint.Trim() } else { [string]$current.CertThumbprint })
        CertStore               = $(if ($PSBoundParameters.ContainsKey('CertStore')) { $(if ([string]::IsNullOrWhiteSpace($CertStore)) { 'CurrentUser\My' } else { [string]$CertStore.Trim() }) } else { [string]$current.CertStore })
        UseClientSecret         = $(if ($PSBoundParameters.ContainsKey('UseClientSecret')) { (ConvertTo-SyncMeEntraBool -Value $UseClientSecret -Default $false) } else { [bool]$current.UseClientSecret })
        ClientSecretTargetName  = $(if ($PSBoundParameters.ContainsKey('ClientSecretTargetName')) { [string]$ClientSecretTargetName.Trim() } else { [string]$current.ClientSecretTargetName })
        Workloads               = $(if ($PSBoundParameters.ContainsKey('Workloads')) { ConvertTo-SyncMeEntraStringList -Value $Workloads } else { @($current.Workloads) })
        ExpectedAppRoles        = $(if ($PSBoundParameters.ContainsKey('ExpectedAppRoles')) { ConvertTo-SyncMeEntraStringList -Value $ExpectedAppRoles } else { @($current.ExpectedAppRoles) })
        ExpectedDelegatedScopes = $(if ($PSBoundParameters.ContainsKey('ExpectedDelegatedScopes')) { ConvertTo-SyncMeEntraStringList -Value $ExpectedDelegatedScopes } else { @($current.ExpectedDelegatedScopes) })
        SelectedSiteIds         = $(if ($PSBoundParameters.ContainsKey('SelectedSiteIds')) { ConvertTo-SyncMeEntraStringList -Value $SelectedSiteIds } else { @($current.SelectedSiteIds) })
    }
    if ($payload.UseClientSecret) {
        try {
            Write-SyncMeStructuredLog -ScriptRoot $ScriptRoot -Level SECURITY -Message 'Entra client secret auth enabled (compat only; prefer certificate)' -Fields @{ clientId = $payload.ClientId }
        } catch { }
    }
    $path = Get-SyncMeEntraConfigPath -ScriptRoot $ScriptRoot
    $json = ($payload | ConvertTo-Json -Depth 6)
    [IO.File]::WriteAllText($path, $json + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    return [pscustomobject]$payload
}

function Get-SyncMeEntraCertificate {
    param(
        [Parameter(Mandatory)][string]$Thumbprint,
        [string]$CertStore = 'CurrentUser\My'
    )
    if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
        throw 'CertThumbprint is required for certificate auth.'
    }
    $storePath = if ([string]::IsNullOrWhiteSpace($CertStore)) { 'CurrentUser\My' } else { $CertStore.Trim() }
    $norm = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    $path = "Cert:\$storePath"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Certificate store not found: $storePath"
    }
    $cert = Get-ChildItem -LiteralPath $path | Where-Object {
        (([string]$_.Thumbprint) -replace '[^0-9A-Fa-f]', '').ToUpperInvariant() -eq $norm
    } | Select-Object -First 1
    if (-not $cert) {
        throw "Certificate with thumbprint $Thumbprint not found in $storePath."
    }
    if (-not $cert.HasPrivateKey) {
        throw 'Certificate does not have a private key available to this identity.'
    }
    return $cert
}

function New-SyncMeEntraClientAssertion {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)]$Certificate
    )
    $now = [DateTimeOffset]::UtcNow
    $exp = $now.AddMinutes(9)
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = [Convert]::ToBase64String($Certificate.GetCertHash()).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $payload = @{
        aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString('n')
        nbf = $now.ToUnixTimeSeconds()
        exp = $exp.ToUnixTimeSeconds()
    }
    function Encode-JwtPart([object]$Obj) {
        $json = ($Obj | ConvertTo-Json -Compress)
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
    $h = Encode-JwtPart $header
    $p = Encode-JwtPart $payload
    $unsigned = "$h.$p"
    $data = [Text.Encoding]::UTF8.GetBytes($unsigned)
    $csp = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $csp) { throw 'Unable to access RSA private key for client assertion.' }
    $sigBytes = $csp.SignData($data, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $sig = [Convert]::ToBase64String($sigBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "$unsigned.$sig"
}

function Get-SyncMeEntraAccessToken {
    <#
      Client-assertion (X.509) preferred. Client secret is allowed only as WARNING-path compat.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$ScriptRoot = '',
        [string]$Scope = 'https://graph.microsoft.com/.default'
    )
    if ([string]::IsNullOrWhiteSpace([string]$Config.TenantId) -or [string]::IsNullOrWhiteSpace([string]$Config.ClientId)) {
        throw 'TenantId and ClientId are required.'
    }
    $tokenUrl = "https://login.microsoftonline.com/$($Config.TenantId)/oauth2/v2.0/token"
    $body = @{
        client_id  = [string]$Config.ClientId
        scope      = $Scope
        grant_type = 'client_credentials'
    }
    if ([bool]$Config.UseClientSecret) {
        if ($ScriptRoot) {
            try {
                Write-SyncMeStructuredLog -ScriptRoot $ScriptRoot -Level SECURITY -Message 'Acquiring Entra token with client secret (compat; prefer certificate)' -Fields @{ clientId = [string]$Config.ClientId }
            } catch { }
        }
        $secret = ''
        $target = [string]$Config.ClientSecretTargetName
        if ([string]::IsNullOrWhiteSpace($target)) { $target = 'SyncMeEntraClientSecret' }
        if (Get-Command Get-GenericCredentialPassword -ErrorAction SilentlyContinue) {
            $secret = Get-GenericCredentialPassword -TargetName $target
        }
        if ([string]::IsNullOrWhiteSpace($secret)) {
            throw "Client secret not found in Credential Manager target '$target'."
        }
        $body['client_secret'] = $secret
    } else {
        $cert = Get-SyncMeEntraCertificate -Thumbprint ([string]$Config.CertThumbprint) -CertStore ([string]$Config.CertStore)
        $assertion = New-SyncMeEntraClientAssertion -TenantId ([string]$Config.TenantId) -ClientId ([string]$Config.ClientId) -Certificate $cert
        $body['client_assertion_type'] = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        $body['client_assertion'] = $assertion
    }
    $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    if (-not $resp.access_token) { throw 'Entra token response missing access_token.' }
    return [string]$resp.access_token
}

function Invoke-SyncMeGraphGet {
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$Uri
    )
    $headers = @{ Authorization = "Bearer $AccessToken"; Accept = 'application/json' }
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -ErrorAction Stop
}

function Get-SyncMeEntraGrantedAppRoles {
    <#
      Resolves app-only Graph role values granted to the app's service principal.
      Accepts -GrantedRoleValues for unit tests (skips Graph).
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$AccessToken = '',
        [string[]]$GrantedRoleValues = $null
    )
    if ($null -ne $GrantedRoleValues) {
        return @(ConvertTo-SyncMeEntraStringList -Value $GrantedRoleValues)
    }
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        throw 'AccessToken required to query Graph permissions.'
    }
    $appId = [uri]::EscapeDataString([string]$Config.ClientId)
    $spUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$appId'&`$select=id,appId,displayName"
    $spResp = Invoke-SyncMeGraphGet -AccessToken $AccessToken -Uri $spUri
    $sp = @($spResp.value) | Select-Object -First 1
    if (-not $sp -or -not $sp.id) {
        throw 'Service principal for ClientId not found in tenant.'
    }
    $graphSpUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles"
    $graphSpResp = Invoke-SyncMeGraphGet -AccessToken $AccessToken -Uri $graphSpUri
    $graphSp = @($graphSpResp.value) | Select-Object -First 1
    if (-not $graphSp) { throw 'Microsoft Graph service principal not found.' }
    $roleIdToValue = @{}
    foreach ($role in @($graphSp.appRoles)) {
        if ($role.id -and $role.value) {
            $roleIdToValue[[string]$role.id] = [string]$role.value
        }
    }
    $assignUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments"
    $assignResp = Invoke-SyncMeGraphGet -AccessToken $AccessToken -Uri $assignUri
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @($assignResp.value)) {
        $rid = [string]$a.appRoleId
        if ($roleIdToValue.ContainsKey($rid)) {
            [void]$values.Add($roleIdToValue[$rid])
        }
    }
    return @($values | Sort-Object -Unique)
}

function Compare-SyncMeEntraPermissionFingerprint {
    param(
        [string[]]$ExpectedAppRoles = @(),
        [string[]]$GrantedAppRoles = @(),
        [string[]]$Workloads = @(),
        [string[]]$SelectedSiteIds = @()
    )
    $expected = @(ConvertTo-SyncMeEntraStringList -Value $ExpectedAppRoles)
    $granted = @(ConvertTo-SyncMeEntraStringList -Value $GrantedAppRoles)
    $workloads = @(ConvertTo-SyncMeEntraStringList -Value $Workloads)
    $dangerous = Get-SyncMeEntraDangerousAppRoles
    $missing = @()
    $extra = @()
    $overPerm = @()
    $notes = [System.Collections.Generic.List[string]]::new()

    $grantedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($g in $granted) { [void]$grantedSet.Add($g) }
    $expectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $expected) { [void]$expectedSet.Add($e) }

    foreach ($e in $expected) {
        if (-not $grantedSet.Contains($e)) { $missing += $e }
    }
    foreach ($g in $granted) {
        if ($expected.Count -gt 0 -and -not $expectedSet.Contains($g)) { $extra += $g }
        foreach ($d in $dangerous) {
            if ($g -eq $d) { $overPerm += $g }
        }
    }

    $sharePointOn = $false
    foreach ($w in $workloads) {
        if ($w -match '(?i)^sharepoint$') { $sharePointOn = $true; break }
    }
    if ($sharePointOn) {
        if (-not $grantedSet.Contains('Sites.Selected') -and -not $expectedSet.Contains('Sites.Selected')) {
            [void]$notes.Add('SharePoint workload enabled: prefer Sites.Selected in ExpectedAppRoles (do not force for rclone-only installs).')
        }
        if ($grantedSet.Contains('Sites.ReadWrite.All') -or $grantedSet.Contains('Sites.FullControl.All')) {
            [void]$notes.Add('Tenant-wide Sites.*Write* granted; prefer Sites.Selected with SelectedSiteIds.')
        }
        if ($grantedSet.Contains('Sites.Selected') -and (@(ConvertTo-SyncMeEntraStringList -Value $SelectedSiteIds).Count -eq 0)) {
            [void]$notes.Add('Sites.Selected granted but SelectedSiteIds is empty — configure site IDs to probe.')
        }
    }

    $drift = ($missing.Count -gt 0) -or ($extra.Count -gt 0) -or ($overPerm.Count -gt 0)
    $status = 'ok'
    if ($overPerm.Count -gt 0) { $status = 'warn' }
    elseif ($drift) { $status = 'warn' }
    elseif ($notes.Count -gt 0) { $status = 'warn' }

    return [pscustomobject]@{
        Status           = $status
        Drift            = [bool]$drift
        MissingExpected  = @($missing)
        ExtraGranted     = @($extra)
        OverPermissioned = @($overPerm | Sort-Object -Unique)
        Notes            = @($notes)
        GrantedAppRoles  = @($granted)
        ExpectedAppRoles = @($expected)
        SharePointWorkload = $sharePointOn
    }
}

function Test-SyncMeEntraSelectedSites {
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [string[]]$SelectedSiteIds = @()
    )
    $ids = @(ConvertTo-SyncMeEntraStringList -Value $SelectedSiteIds)
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ids) {
        $ok = $false
        $detail = ''
        try {
            $enc = [uri]::EscapeDataString($id)
            $null = Invoke-SyncMeGraphGet -AccessToken $AccessToken -Uri "https://graph.microsoft.com/v1.0/sites/$enc`?`$select=id,displayName,webUrl"
            $ok = $true
            $detail = 'reachable'
        } catch {
            $detail = $_.Exception.Message
        }
        [void]$results.Add([ordered]@{ siteId = $id; ok = $ok; detail = $detail })
    }
    return @($results)
}

function Get-SyncMeEntraCompromisePlaybook {
    return [ordered]@{
        title = 'Credential Compromised — Entra emergency procedure'
        note  = 'SyncMe does not call Entra admin revoke APIs. A tenant administrator must perform revocation in Microsoft Entra.'
        steps = @(
            'Disable or delete the compromised certificate credential (or client secret) on the app registration in Entra.',
            'If necessary, disable the service principal until replacement credentials are ready.',
            'Remove excess Graph application permissions; restore only the expected fingerprint (prefer Sites.Selected for SharePoint).',
            'Generate and upload a replacement certificate; update SyncMe CertThumbprint (or rotate MI/WIF outside SyncMe).',
            'Clear UseClientSecret if it was enabled; store no plaintext secrets in Config files.',
            'Update SelectedSiteIds if SharePoint Sites.Selected assignments changed.',
            'Run Entra health check from Operations — auth + fingerprint must pass before resuming Graph-dependent work.',
            'Resume backup only after fingerprint Status is ok (rclone OneDrive backend is independent of ModuleEntra).'
        )
    }
}

function Test-SyncMeEntraHealth {
    <#
      Returns a health check object: status skipped|ok|warn|fail.
      -GrantedRoleValues mocks Graph for tests.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [string[]]$GrantedRoleValues = $null,
        [switch]$SkipTokenAcquire
    )
    $cfg = Get-SyncMeEntraConfig -ScriptRoot $ScriptRoot
    if (-not [bool]$cfg.EntraEnabled) {
        return [ordered]@{
            name    = 'entra'
            status  = 'skipped'
            detail  = 'EntraEnabled=false'
            fingerprint = $null
            sites   = @()
        }
    }

    $detailParts = [System.Collections.Generic.List[string]]::new()
    $token = ''
    if (-not $SkipTokenAcquire -and $null -eq $GrantedRoleValues) {
        try {
            $token = Get-SyncMeEntraAccessToken -Config $cfg -ScriptRoot $ScriptRoot
            [void]$detailParts.Add('token=ok')
        } catch {
            try {
                Write-SyncMeStructuredLog -ScriptRoot $ScriptRoot -Level SECURITY -Message 'Entra token acquire failed' -Fields @{ error = $_.Exception.Message }
            } catch { }
            return [ordered]@{
                name   = 'entra'
                status = 'fail'
                detail = ('auth failed: ' + $_.Exception.Message)
                fingerprint = $null
                sites  = @()
            }
        }
    } elseif ($SkipTokenAcquire) {
        [void]$detailParts.Add('token=skipped')
    }

    $granted = @()
    try {
        $granted = Get-SyncMeEntraGrantedAppRoles -Config $cfg -AccessToken $token -GrantedRoleValues $GrantedRoleValues
    } catch {
        try {
            Write-SyncMeStructuredLog -ScriptRoot $ScriptRoot -Level SECURITY -Message 'Entra Graph permission query failed' -Fields @{ error = $_.Exception.Message }
        } catch { }
        return [ordered]@{
            name   = 'entra'
            status = 'warn'
            detail = ('permission query failed: ' + $_.Exception.Message)
            fingerprint = $null
            sites  = @()
        }
    }

    $fp = Compare-SyncMeEntraPermissionFingerprint `
        -ExpectedAppRoles @($cfg.ExpectedAppRoles) `
        -GrantedAppRoles $granted `
        -Workloads @($cfg.Workloads) `
        -SelectedSiteIds @($cfg.SelectedSiteIds)

    if ($fp.Drift -or $fp.OverPermissioned.Count -gt 0) {
        try {
            Write-SyncMeStructuredLog -ScriptRoot $ScriptRoot -Level SECURITY -Message 'Entra permission fingerprint drift or over-permission' -Fields @{
                status = $fp.Status
                missing = ($fp.MissingExpected -join ',')
                over = ($fp.OverPermissioned -join ',')
            }
        } catch { }
    }

    $siteResults = @()
    if ($fp.SharePointWorkload -and @($cfg.SelectedSiteIds).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($token)) {
        try {
            $siteResults = Test-SyncMeEntraSelectedSites -AccessToken $token -SelectedSiteIds @($cfg.SelectedSiteIds)
            $bad = @($siteResults | Where-Object { -not $_.ok })
            if ($bad.Count -gt 0) {
                [void]$detailParts.Add(('sitesFail=' + $bad.Count))
                if ($fp.Status -eq 'ok') { $fp.Status = 'warn' }
            } else {
                [void]$detailParts.Add('sites=ok')
            }
        } catch {
            [void]$detailParts.Add('sitesProbeFailed')
        }
    }

    [void]$detailParts.Add(('granted=' + ($granted -join '+')))
    if ($fp.Notes.Count -gt 0) { [void]$detailParts.Add(($fp.Notes -join '; ')) }

    return [ordered]@{
        name        = 'entra'
        status      = [string]$fp.Status
        detail      = ($detailParts -join ' | ')
        fingerprint = $fp
        sites       = @($siteResults)
    }
}
