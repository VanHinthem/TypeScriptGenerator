Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
Normalizes a candidate entity logical name.
.PARAMETER Name
Candidate name value.
.OUTPUTS
System.String
#>
function Get-NormalizedEntityLogicalName {
    param(
        [object]$Name
    )

    if ($null -eq $Name) {
        return $null
    }

    $nameText = [string]$Name
    if ([string]::IsNullOrWhiteSpace($nameText)) {
        return $null
    }

    return $nameText.Trim()
}

<#
.SYNOPSIS
Reads entity logical names from a file.
.DESCRIPTION
Supports comments (lines starting with #) and comma/semicolon separated entries.
.PARAMETER Path
Entity list file path.
.OUTPUTS
System.String[]
#>
function Get-EntityLogicalNamesFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $entityNames = New-Object System.Collections.Generic.List[string]
    $entityNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $lines = Get-Content -LiteralPath $Path
    foreach ($line in $lines) {
        $normalizedLine = Get-NormalizedEntityLogicalName -Name $line
        if ([string]::IsNullOrWhiteSpace($normalizedLine)) {
            continue
        }

        if ($normalizedLine.StartsWith("#")) {
            continue
        }

        # Support inline comments after entity names.
        $noComment = ($normalizedLine.Split("#", 2)[0]).Trim()
        if ([string]::IsNullOrWhiteSpace($noComment)) {
            continue
        }

        $parts = $noComment -split "[,;]"
        foreach ($part in $parts) {
            $entityName = Get-NormalizedEntityLogicalName -Name $part
            if ([string]::IsNullOrWhiteSpace($entityName)) {
                continue
            }

            if ($entityNameSet.Add($entityName)) {
                [void]$entityNames.Add($entityName)
            }
        }
    }

    return $entityNames.ToArray()
}

<#
.SYNOPSIS
Adds logical names to the target list once, case-insensitively.
.PARAMETER SourceNames
Names to process.
.PARAMETER TargetNames
Ordered target list.
.PARAMETER SeenNames
Case-insensitive set used for deduplication.
.OUTPUTS
System.Int32
#>
function Add-UniqueEntityLogicalName {
    param(
        [AllowNull()]
        [object[]]$SourceNames,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [ValidateNotNull()]
        [System.Collections.Generic.List[string]]$TargetNames,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [ValidateNotNull()]
        [System.Collections.Generic.HashSet[string]]$SeenNames
    )

    if (-not $SourceNames) {
        return 0
    }

    $added = 0
    foreach ($name in $SourceNames) {
        $trimmed = Get-NormalizedEntityLogicalName -Name $name
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($SeenNames.Add($trimmed)) {
            [void]$TargetNames.Add($trimmed)
            $added++
        }
    }

    return $added
}

<#
.SYNOPSIS
Resolves the final set of entity logical names to process.
.DESCRIPTION
Combines entity names from parameters, entity list file, and optional solution membership.
Deduplicates values case-insensitively while preserving first-seen order.
.PARAMETER EntityLogicalNames
Explicit entity names.
.PARAMETER EntityListPath
Optional entity list file path.
.PARAMETER SolutionUniqueName
Optional solution unique name.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER Headers
HTTP headers including Authorization.
.OUTPUTS
System.String[]
#>
function Resolve-SelectedEntityLogicalNames {
    param(
        [AllowNull()]
        [object[]]$EntityLogicalNames,
        [string]$EntityListPath,
        [string]$SolutionUniqueName,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$Headers
    )

    $selectedEntityLogicalNamesList = New-Object System.Collections.Generic.List[string]
    $selectedEntityLogicalNamesSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    if ($EntityLogicalNames -and $EntityLogicalNames.Count -gt 0) {
        $addedFromParameter = Add-UniqueEntityLogicalName `
            -SourceNames $EntityLogicalNames `
            -TargetNames $selectedEntityLogicalNamesList `
            -SeenNames $selectedEntityLogicalNamesSet
        if ($addedFromParameter -gt 0) {
            Write-Verbose ("Entities added from parameter: {0}" -f $addedFromParameter)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($EntityListPath)) {
        if (Test-Path -LiteralPath $EntityListPath -PathType Leaf) {
            $entitiesFromFile = Get-EntityLogicalNamesFromFile -Path $EntityListPath
            $addedFromFile = Add-UniqueEntityLogicalName `
                -SourceNames $entitiesFromFile `
                -TargetNames $selectedEntityLogicalNamesList `
                -SeenNames $selectedEntityLogicalNamesSet
            if ($addedFromFile -gt 0) {
                Write-Verbose ("Entities added from file ({0}): {1}" -f $EntityListPath, $addedFromFile)
            }
        }
        else {
            Write-Verbose ("Entity list file not found, skipping: {0}" -f $EntityListPath)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SolutionUniqueName)) {
        $entitiesFromSolution = Get-EntityLogicalNamesFromSolution `
            -EnvironmentUrl $EnvironmentUrl `
            -Headers $Headers `
            -SolutionUniqueName $SolutionUniqueName
        $addedFromSolution = Add-UniqueEntityLogicalName `
            -SourceNames $entitiesFromSolution `
            -TargetNames $selectedEntityLogicalNamesList `
            -SeenNames $selectedEntityLogicalNamesSet
        Write-Verbose ("Entities added from solution '{0}': {1}" -f $SolutionUniqueName, $addedFromSolution)
    }

    return $selectedEntityLogicalNamesList.ToArray()
}

Export-ModuleMember -Function Resolve-SelectedEntityLogicalNames
