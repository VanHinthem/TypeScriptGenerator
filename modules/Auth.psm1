Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
Checks whether a value is an absolute URI.
.PARAMETER Value
URI text to validate.
.OUTPUTS
System.Boolean
#>
function Test-IsAbsoluteUri {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        return $false
    }

    return $true
}

<#
.SYNOPSIS
Checks whether a value is an absolute HTTP(S) URI.
.PARAMETER Value
URI text to validate.
.OUTPUTS
System.Boolean
#>
function Test-IsAbsoluteHttpUri {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        return $false
    }

    if ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https") {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($uri.Host)) {
        return $false
    }

    return $true
}

<#
.SYNOPSIS
Validates authentication inputs before MSAL login.
.DESCRIPTION
Provides focused error messages for common parameter mistakes, including
swapped TenantId/EnvironmentUrl and double-dash parameter typos.
.PARAMETER TenantId
Tenant identifier (organizations, GUID, or domain).
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER RedirectUri
Redirect URI configured on the app registration.
#>
function Assert-ValidDataverseAuthInput {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RedirectUri
    )

    if ($EnvironmentUrl.StartsWith("-") -and (Test-IsAbsoluteHttpUri -Value $TenantId)) {
        throw ("EnvironmentUrl and TenantId appear swapped. In PowerShell, use a single dash for parameters. Example: .\TypeScriptGenerator.ps1 -EnvironmentUrl ""{0}""" -f $TenantId)
    }

    if ($EnvironmentUrl.StartsWith("-")) {
        throw ("Invalid EnvironmentUrl '{0}'. In PowerShell use '-EnvironmentUrl', not '--EnvironmentUrl'." -f $EnvironmentUrl)
    }

    if (-not (Test-IsAbsoluteHttpUri -Value $EnvironmentUrl)) {
        throw ("Invalid EnvironmentUrl '{0}'. Expected an absolute http(s) URL like https://<org>.crm.dynamics.com." -f $EnvironmentUrl)
    }

    if (Test-IsAbsoluteUri -Value $TenantId) {
        throw ("Invalid TenantId '{0}'. Expected a tenant identifier like 'organizations', a GUID, or a tenant domain. Did you mean to pass this value to -EnvironmentUrl?" -f $TenantId)
    }

    if (-not (Test-IsAbsoluteUri -Value $RedirectUri)) {
        throw ("Invalid RedirectUri '{0}'. Expected an absolute URI like http://localhost." -f $RedirectUri)
    }
}

<#
.SYNOPSIS
Imports MSAL.PS, installing it if required.
.DESCRIPTION
Attempts module import first, then bootstraps NuGet and installs MSAL.PS for the
current user when missing.
#>
function Import-MsalModule {
    if (Get-Module -ListAvailable -Name "MSAL.PS") {
        Import-Module MSAL.PS -ErrorAction Stop | Out-Null
    }
    else {
        Write-Verbose "MSAL.PS is missing. Attempting automatic installation..."
        try {
            # Enforce TLS 1.2 on Windows PowerShell when possible for PSGallery access.
            if ($PSVersionTable.PSEdition -eq "Desktop") {
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                }
                catch {
                    Write-Verbose "Could not set TLS 1.2 explicitly. Continuing with default security protocol."
                }
            }

            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -Confirm:$false | Out-Null
            }

            Install-Module -Name MSAL.PS -Scope CurrentUser -Force -AllowClobber -Confirm:$false -ErrorAction Stop
            Import-Module MSAL.PS -ErrorAction Stop | Out-Null
        }
        catch {
            throw ("MSAL.PS is missing and automatic installation failed: {0}. Install manually with: Install-Module MSAL.PS -Scope CurrentUser -Force" -f $_.Exception.Message)
        }
    }

    if (-not (Get-Command -Module MSAL.PS -Name Get-MsalToken -ErrorAction SilentlyContinue)) {
        throw "MSAL.PS was imported, but command 'Get-MsalToken' is not available."
    }
}

<#
.SYNOPSIS
Performs interactive login and returns an access token.
.PARAMETER TenantId
Tenant identifier.
.PARAMETER ClientId
App registration client id.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER RedirectUri
Redirect URI configured on the app registration.
.OUTPUTS
System.String
#>
function Get-AccessTokenInteractive {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RedirectUri
    )

    # Dataverse scope is tied to the environment host.
    $normalizedEnvironmentUrl = $EnvironmentUrl.TrimEnd("/")
    $scopes = @("$normalizedEnvironmentUrl/user_impersonation")

    Write-Verbose ("Starting interactive authentication for tenant '{0}' and client '{1}'." -f $TenantId, $ClientId)
    try {
        $tokenResponse = Get-MsalToken `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -Interactive `
            -Scopes $scopes `
            -RedirectUri $RedirectUri `
            -ErrorAction Stop
    }
    catch {
        throw ("Interactive login failed for tenant '{0}' and client '{1}': {2}" -f $TenantId, $ClientId, $_.Exception.Message)
    }

    if ([string]::IsNullOrWhiteSpace([string]$tokenResponse.AccessToken)) {
        throw "No access token was returned from interactive login."
    }

    Write-Verbose "Interactive authentication succeeded."

    return $tokenResponse.AccessToken
}

<#
.SYNOPSIS
Gets a Dataverse access token for the configured tenant/app.
.PARAMETER TenantId
Tenant identifier.
.PARAMETER ClientId
App registration client id.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER RedirectUri
Redirect URI configured on the app registration.
.OUTPUTS
System.String
#>
function Get-DataverseAccessToken {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,

        [ValidateNotNullOrEmpty()]
        [string]$RedirectUri = "http://localhost"
    )

    Write-Verbose "Validating Dataverse authentication input..."
    Assert-ValidDataverseAuthInput `
        -TenantId $TenantId `
        -EnvironmentUrl $EnvironmentUrl `
        -RedirectUri $RedirectUri

    Write-Verbose "Ensuring MSAL.PS module is available..."
    Import-MsalModule

    return Get-AccessTokenInteractive `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -EnvironmentUrl $EnvironmentUrl `
        -RedirectUri $RedirectUri
}

Export-ModuleMember -Function Get-DataverseAccessToken
