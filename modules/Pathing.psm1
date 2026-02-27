Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
Resolves a path relative to the script root.
.DESCRIPTION
Supports absolute, relative, environment-variable, and home-prefixed (~) paths.
.PARAMETER Path
Input path to resolve.
.PARAMETER ScriptRoot
Base directory used for relative paths.
.OUTPUTS
System.String
#>
function Resolve-ScriptRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptRoot
    )

    # Expand environment variables before normalization and combination.
    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    $expandedScriptRoot = [Environment]::ExpandEnvironmentVariables($ScriptRoot.Trim())

    try {
        $normalizedScriptRoot = [System.IO.Path]::GetFullPath($expandedScriptRoot)
    }
    catch {
        throw ("Invalid ScriptRoot '{0}': {1}" -f $ScriptRoot, $_.Exception.Message)
    }

    # Let PowerShell resolve home-relative paths via provider resolution.
    if ($expandedPath.StartsWith("~")) {
        try {
            return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($expandedPath)
        }
        catch {
            throw ("Invalid path '{0}': {1}" -f $Path, $_.Exception.Message)
        }
    }

    # Absolute paths are normalized and returned as-is.
    if ([System.IO.Path]::IsPathRooted($expandedPath)) {
        try {
            return [System.IO.Path]::GetFullPath($expandedPath)
        }
        catch {
            throw ("Invalid path '{0}': {1}" -f $Path, $_.Exception.Message)
        }
    }

    # Relative paths are resolved against the script root, not current location.
    try {
        return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($normalizedScriptRoot, $expandedPath))
    }
    catch {
        throw ("Could not resolve path '{0}' relative to '{1}': {2}" -f $Path, $ScriptRoot, $_.Exception.Message)
    }
}

Export-ModuleMember -Function Resolve-ScriptRelativePath
