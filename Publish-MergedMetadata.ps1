[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$FolderA,
    [Parameter(Mandatory = $true)]
    [string]$FolderB,
    [Parameter(Mandatory = $true)]
    [string]$Target,
    [switch]$Clean,
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
trap {
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $message = $_.Exception.Message
    Write-Error ("Unhandled error on line {0}: {1}" -f $lineNumber, $message)
    break
}

function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path cannot be empty."
    }

    if (Test-Path -LiteralPath $Path) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Location).Path -ChildPath $Path))
}

$resolvedFolderA = Resolve-AbsolutePath -Path $FolderA
$resolvedFolderB = Resolve-AbsolutePath -Path $FolderB
$resolvedTarget = Resolve-AbsolutePath -Path $Target

if (-not (Test-Path -LiteralPath $resolvedFolderA -PathType Container)) {
    throw ("FolderA not found: {0}" -f $resolvedFolderA)
}

if ([string]::Equals($resolvedFolderA, $resolvedFolderB, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "FolderA and FolderB must be different paths."
}

if ([string]::Equals($resolvedFolderA, $resolvedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Target cannot be the same path as FolderA."
}

if ([string]::Equals($resolvedFolderB, $resolvedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Target cannot be the same path as FolderB."
}

Write-Output ("FolderA (source): {0}" -f $resolvedFolderA)
Write-Output ("FolderB (remove): {0}" -f $resolvedFolderB)
Write-Output ("Target: {0}" -f $resolvedTarget)
Write-Output ("Clean target: {0}" -f $Clean.IsPresent)
Write-Output ("Overwrite target files: {0}" -f $Overwrite.IsPresent)

if (Test-Path -LiteralPath $resolvedFolderB -PathType Container) {
    if ($PSCmdlet.ShouldProcess($resolvedFolderB, "Remove FolderB")) {
        Remove-Item -LiteralPath $resolvedFolderB -Recurse -Force
        Write-Output ("Removed FolderB: {0}" -f $resolvedFolderB)
    }
}
else {
    Write-Warning ("FolderB not found, nothing to remove: {0}" -f $resolvedFolderB)
}

if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Container)) {
    if ($PSCmdlet.ShouldProcess($resolvedTarget, "Create target folder")) {
        New-Item -Path $resolvedTarget -ItemType Directory -Force | Out-Null
    }
}

$targetItems = @(Get-ChildItem -LiteralPath $resolvedTarget -Force -ErrorAction SilentlyContinue)
if ($targetItems.Count -gt 0) {
    if ($Clean.IsPresent) {
        if ($PSCmdlet.ShouldProcess($resolvedTarget, "Clean target folder")) {
            foreach ($item in $targetItems) {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force
            }
            Write-Output ("Cleaned target folder: {0}" -f $resolvedTarget)
        }
    }
    elseif (-not $Overwrite.IsPresent) {
        throw ("Target is not empty: {0}. Use -Clean to clear it first or -Overwrite to allow replacing existing files." -f $resolvedTarget)
    }
}

$sourceItems = @(Get-ChildItem -LiteralPath $resolvedFolderA -Force)
if ($PSCmdlet.ShouldProcess($resolvedTarget, "Copy FolderA contents to target")) {
    foreach ($item in $sourceItems) {
        Copy-Item -LiteralPath $item.FullName -Destination $resolvedTarget -Recurse -Force:$Overwrite.IsPresent
    }
    Write-Output ("Copied FolderA contents to target: {0}" -f $resolvedTarget)
}

if ($PSCmdlet.ShouldProcess($resolvedFolderA, "Remove FolderA")) {
    Remove-Item -LiteralPath $resolvedFolderA -Recurse -Force
    Write-Output ("Removed FolderA: {0}" -f $resolvedFolderA)
}

Write-Output "Operation completed."
