Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
Normalizes Dataverse environment URL by removing trailing slash.
#>
function Get-NormalizedEnvironmentUrl {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl
    )

    return $EnvironmentUrl.TrimEnd("/")
}

<#
.SYNOPSIS
Performs a GET call against Dataverse Web API.
#>
function Invoke-DataverseGet {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$Headers
    )

    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
}

<#
.SYNOPSIS
Retrieves all items from an OData endpoint with @odata.nextLink pagination.
#>
function Get-PagedItem {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$Headers
    )

    $items = New-Object System.Collections.Generic.List[object]
    $nextLink = $Uri
    $pageNumber = 0

    while ($nextLink) {
        $pageNumber++
        Write-Verbose ("Dataverse page fetch #{0}: {1}" -f $pageNumber, $nextLink)
        $response = Invoke-DataverseGet -Uri $nextLink -Headers $Headers

        if ($null -eq $response) {
            break
        }

        $valueProperty = $response.PSObject.Properties["value"]
        if ($null -ne $valueProperty -and $null -ne $valueProperty.Value) {
            foreach ($entry in @($valueProperty.Value)) {
                [void]$items.Add($entry)
            }
        }
        elseif ($response -is [System.Collections.IEnumerable] -and -not ($response -is [string])) {
            foreach ($entry in @($response)) {
                [void]$items.Add($entry)
            }
        }

        # Continue until Dataverse no longer returns @odata.nextLink.
        $nextLinkProperty = $response.PSObject.Properties["@odata.nextLink"]
        if ($null -ne $nextLinkProperty -and -not [string]::IsNullOrWhiteSpace([string]$nextLinkProperty.Value)) {
            $nextLink = [string]$nextLinkProperty.Value
        }
        else {
            $nextLink = $null
        }
    }

    Write-Verbose ("Dataverse pagination completed. Pages={0}, Items={1}" -f $pageNumber, $items.Count)

    return $items.ToArray()
}

<#
.SYNOPSIS
Reads a property value from PSObject or dictionary input.
#>
function Get-PropertyValue {
    param(
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    try {
        $properties = $InputObject.PSObject.Properties
        if ($null -ne $properties) {
            foreach ($candidate in $properties) {
                if ($null -eq $candidate) {
                    continue
                }

                if ([string]$candidate.Name -eq $PropertyName) {
                    return $candidate.Value
                }
            }
        }
    }
    catch {
        Write-Verbose ("Could not read PSObject properties for '{0}'. Falling back to dictionary lookup." -f $PropertyName)
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]$key -eq $PropertyName) {
                try {
                    return $InputObject[$key]
                }
                catch {
                    return $null
                }
            }
        }
    }

    return $null
}

<#
.SYNOPSIS
Converts dynamic API payloads to plain objects for stable property access.
#>
function Convert-ToPlainObject {
    param(
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    try {
        $json = $InputObject | ConvertTo-Json -Depth 100 -Compress
        if ([string]::IsNullOrWhiteSpace($json)) {
            return $null
        }

        return $json | ConvertFrom-Json -Depth 100
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
Resolves localized label text with LCID preference and fallbacks.
#>
function Get-LocalizedLabelText {
    param(
        [object]$LabelObject,
        [int]$LabelLcid = 1033
    )

    if ($null -eq $LabelObject) {
        return $null
    }

    $userLocalizedLabel = Get-PropertyValue -InputObject $LabelObject -PropertyName "UserLocalizedLabel"
    $userLocalizedLabelText = [string](Get-PropertyValue -InputObject $userLocalizedLabel -PropertyName "Label")
    if (-not [string]::IsNullOrWhiteSpace($userLocalizedLabelText)) {
        return $userLocalizedLabelText
    }

    $localizedLabelsValue = Get-PropertyValue -InputObject $LabelObject -PropertyName "LocalizedLabels"
    $localizedLabels = @()
    if ($null -ne $localizedLabelsValue) {
        $localizedLabels = @($localizedLabelsValue)
    }

    if ($localizedLabels.Count -eq 0) {
        return $null
    }

    $selectedLabel = $null
    foreach ($localizedLabel in $localizedLabels) {
        $languageCodeValue = Get-PropertyValue -InputObject $localizedLabel -PropertyName "LanguageCode"
        if ($null -eq $languageCodeValue) {
            continue
        }

        $languageCode = 0
        if ([int]::TryParse([string]$languageCodeValue, [ref]$languageCode) -and $languageCode -eq $LabelLcid) {
            $selectedLabel = $localizedLabel
            break
        }
    }

    if ($null -eq $selectedLabel) {
        $selectedLabel = $localizedLabels[0]
    }

    $selectedText = [string](Get-PropertyValue -InputObject $selectedLabel -PropertyName "Label")
    if ([string]::IsNullOrWhiteSpace($selectedText)) {
        return $null
    }

    return $selectedText
}

<#
.SYNOPSIS
Extracts option values/labels from OptionSet metadata.
#>
function Get-OptionChoicesFromOptionSetMetadata {
    param(
        [object]$OptionSetMetadata,
        [int]$LabelLcid = 1033
    )

    if ($null -eq $OptionSetMetadata) {
        return @()
    }

    $choices = New-Object System.Collections.Generic.List[object]
    $options = @()
    try {
        $optionsValue = Get-PropertyValue -InputObject $OptionSetMetadata -PropertyName "Options"
        if ($null -eq $optionsValue) {
            $plainOptionSetMetadata = Convert-ToPlainObject -InputObject $OptionSetMetadata
            $optionsValue = Get-PropertyValue -InputObject $plainOptionSetMetadata -PropertyName "Options"
        }

        if ($null -ne $optionsValue) {
            $options = @($optionsValue)
        }

        foreach ($option in $options) {
            $optionValue = $option
            $value = Get-PropertyValue -InputObject $optionValue -PropertyName "Value"
            $labelObject = Get-PropertyValue -InputObject $optionValue -PropertyName "Label"

            if ($null -eq $value) {
                $plainOption = Convert-ToPlainObject -InputObject $optionValue
                if ($null -ne $plainOption) {
                    $value = Get-PropertyValue -InputObject $plainOption -PropertyName "Value"
                    if ($null -eq $labelObject) {
                        $labelObject = Get-PropertyValue -InputObject $plainOption -PropertyName "Label"
                    }
                }
            }

            if ($null -eq $value) {
                continue
            }

            $label = Get-LocalizedLabelText -LabelObject $labelObject -LabelLcid $LabelLcid
            if ([string]::IsNullOrWhiteSpace($label)) {
                $label = "Value_$value"
            }

            [void]$choices.Add([pscustomobject]@{
                Label = $label
                Value = $value
            })
        }
    }
    catch {
        return @()
    }

    return $choices.ToArray()
}

<#
.SYNOPSIS
Extracts option values/labels from Boolean attribute metadata.
#>
function Get-OptionChoicesFromBooleanMetadata {
    param(
        [object]$AttributeMetadata,
        [int]$LabelLcid = 1033
    )

    if ($null -eq $AttributeMetadata) {
        return @()
    }

    $choices = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($propertyName in @("FalseOption", "TrueOption")) {
            $option = Get-PropertyValue -InputObject $AttributeMetadata -PropertyName $propertyName
            if ($null -eq $option) {
                $plainAttributeMetadata = Convert-ToPlainObject -InputObject $AttributeMetadata
                $option = Get-PropertyValue -InputObject $plainAttributeMetadata -PropertyName $propertyName
            }

            if ($null -eq $option) {
                continue
            }

            $value = Get-PropertyValue -InputObject $option -PropertyName "Value"
            $labelObject = Get-PropertyValue -InputObject $option -PropertyName "Label"
            if ($null -eq $value) {
                $plainOption = Convert-ToPlainObject -InputObject $option
                if ($null -ne $plainOption) {
                    $value = Get-PropertyValue -InputObject $plainOption -PropertyName "Value"
                    if ($null -eq $labelObject) {
                        $labelObject = Get-PropertyValue -InputObject $plainOption -PropertyName "Label"
                    }
                }
            }

            if ($null -eq $value) {
                continue
            }

            $label = Get-LocalizedLabelText -LabelObject $labelObject -LabelLcid $LabelLcid
            if ([string]::IsNullOrWhiteSpace($label)) {
                $label = "Value_$value"
            }

            [void]$choices.Add([pscustomobject]@{
                Label = $label
                Value = $value
            })
        }
    }
    catch {
        return @()
    }

    return $choices.ToArray()
}

<#
.SYNOPSIS
Gets entity logical names included in a Dataverse solution.
#>
function Get-EntityLogicalNamesFromSolution {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$Headers,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SolutionUniqueName
    )

    $normalizedEnvironmentUrl = Get-NormalizedEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
    $solutionsUri = DataverseQueries\Get-DataverseSolutionsByUniqueNameUri `
        -EnvironmentUrl $normalizedEnvironmentUrl `
        -SolutionUniqueName $SolutionUniqueName
    $solutions = @(Get-PagedItem -Uri $solutionsUri -Headers $Headers)

    if ($solutions.Count -eq 0) {
        throw ("Solution not found: {0}" -f $SolutionUniqueName)
    }

    $solutionId = [string](Get-PropertyValue -InputObject $solutions[0] -PropertyName "solutionid")
    if ([string]::IsNullOrWhiteSpace($solutionId)) {
        throw ("Solution was found but solutionid is missing for: {0}" -f $SolutionUniqueName)
    }

    $componentsUri = DataverseQueries\Get-DataverseSolutionComponentsEntityUri `
        -EnvironmentUrl $normalizedEnvironmentUrl `
        -SolutionId $solutionId `
        -UseGuidLiteral
    try {
        $components = @(Get-PagedItem -Uri $componentsUri -Headers $Headers)
    }
    catch {
        $componentsUriFallback = DataverseQueries\Get-DataverseSolutionComponentsEntityUri `
            -EnvironmentUrl $normalizedEnvironmentUrl `
            -SolutionId $solutionId
        $components = @(Get-PagedItem -Uri $componentsUriFallback -Headers $Headers)
    }

    if ($components.Count -eq 0) {
        return @()
    }

    $metadataIds = New-Object System.Collections.Generic.List[string]
    $metadataIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($component in $components) {
        $metadataId = [string](Get-PropertyValue -InputObject $component -PropertyName "objectid")
        $parsedGuid = [Guid]::Empty
        if (-not [Guid]::TryParse($metadataId, [ref]$parsedGuid)) {
            continue
        }

        if ($metadataIdSet.Add($metadataId)) {
            [void]$metadataIds.Add($metadataId)
        }
    }

    $logicalNames = New-Object System.Collections.Generic.List[string]
    $logicalNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    # Resolve each solution component metadata id to an entity logical name.
    foreach ($metadataId in $metadataIds) {
        try {
            $entityUri = DataverseQueries\Get-DataverseEntityDefinitionByMetadataIdUri `
                -EnvironmentUrl $normalizedEnvironmentUrl `
                -MetadataId $metadataId
            $entityDefinition = Invoke-DataverseGet -Uri $entityUri -Headers $Headers
            $logicalName = [string](Get-PropertyValue -InputObject $entityDefinition -PropertyName "LogicalName")
            if (-not [string]::IsNullOrWhiteSpace($logicalName) -and $logicalNameSet.Add($logicalName)) {
                [void]$logicalNames.Add($logicalName)
            }
        }
        catch {
            try {
                $entityUriFallback = DataverseQueries\Get-DataverseEntityDefinitionByMetadataIdFilterUri `
                    -EnvironmentUrl $normalizedEnvironmentUrl `
                    -MetadataId $metadataId
                $entityDefinitionFallback = @(Get-PagedItem -Uri $entityUriFallback -Headers $Headers)
                if ($entityDefinitionFallback.Count -gt 0) {
                    $logicalName = [string](Get-PropertyValue -InputObject $entityDefinitionFallback[0] -PropertyName "LogicalName")
                    if (-not [string]::IsNullOrWhiteSpace($logicalName) -and $logicalNameSet.Add($logicalName)) {
                        [void]$logicalNames.Add($logicalName)
                    }
                }
            }
            catch {
                Write-Warning ("Could not retrieve entity metadata for component objectid {0}: {1}" -f $metadataId, $_.Exception.Message)
            }
        }
    }

    return @($logicalNames.ToArray() | Sort-Object)
}

<#
.SYNOPSIS
Gets normalized attribute metadata (logical/schema name) for an entity.
#>
function Get-EntityAttribute {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$Headers,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntityLogicalName
    )

    $normalizedEnvironmentUrl = Get-NormalizedEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
    $attributesUri = DataverseQueries\Get-DataverseEntityAttributesUri `
        -EnvironmentUrl $normalizedEnvironmentUrl `
        -EntityLogicalName $EntityLogicalName
    $rawAttributes = @(Get-PagedItem -Uri $attributesUri -Headers $Headers)

    $normalizedAttributes = New-Object System.Collections.Generic.List[object]
    foreach ($rawAttribute in $rawAttributes) {
        $logicalName = [string](Get-PropertyValue -InputObject $rawAttribute -PropertyName "LogicalName")
        if ([string]::IsNullOrWhiteSpace($logicalName)) {
            continue
        }

        $schemaName = [string](Get-PropertyValue -InputObject $rawAttribute -PropertyName "SchemaName")
        if ([string]::IsNullOrWhiteSpace($schemaName)) {
            $schemaName = $logicalName
        }

        [void]$normalizedAttributes.Add([pscustomobject]@{
            LogicalName = $logicalName
            SchemaName  = $schemaName
        })
    }

    return @($normalizedAttributes.ToArray() | Sort-Object LogicalName)
}

<#
.SYNOPSIS
Gets option set definitions for supported attribute metadata types.
#>
function Get-EntityOptionSetDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$Headers,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntityLogicalName,
        [ValidateRange(1, 2147483647)]
        [int]$LabelLcid = 1033
    )

    $normalizedEnvironmentUrl = Get-NormalizedEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
    $attributeTypeDefinitions = @(
        [pscustomobject]@{
            TypeName  = "PicklistAttributeMetadata"
            IsBoolean = $false
        },
        [pscustomobject]@{
            TypeName  = "MultiSelectPicklistAttributeMetadata"
            IsBoolean = $false
        },
        [pscustomobject]@{
            TypeName  = "StateAttributeMetadata"
            IsBoolean = $false
        },
        [pscustomobject]@{
            TypeName  = "StatusAttributeMetadata"
            IsBoolean = $false
        },
        [pscustomobject]@{
            TypeName  = "BooleanAttributeMetadata"
            IsBoolean = $true
        }
    )

    $optionSetDefinitions = New-Object System.Collections.Generic.List[object]
    $attributeLogicalNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    # Query each Dataverse attribute metadata type separately.
    foreach ($typeDefinition in $attributeTypeDefinitions) {
        $typeName = [string]$typeDefinition.TypeName
        $isBooleanType = [bool]$typeDefinition.IsBoolean
        $attributesUri = DataverseQueries\Get-DataverseEntityTypedAttributesUri `
            -EnvironmentUrl $normalizedEnvironmentUrl `
            -EntityLogicalName $EntityLogicalName `
            -TypeName $typeName `
            -ExpandOptionSet

        $typedAttributes = @()
        try {
            $typedAttributes = @(Get-PagedItem -Uri $attributesUri -Headers $Headers)
        }
        catch {
            if ($typeName -eq "BooleanAttributeMetadata") {
                Write-Verbose ("Could not retrieve {0} for entity '{1}': {2}" -f $typeName, $EntityLogicalName, $_.Exception.Message)
            }
            else {
                Write-Warning ("Could not retrieve {0} for entity '{1}': {2}" -f $typeName, $EntityLogicalName, $_.Exception.Message)
            }
            continue
        }

        foreach ($attributeDetails in $typedAttributes) {
            $currentStep = "initialize"
            $optionSetMetadata = $null

            try {
                $currentStep = "normalize-attribute"
                $normalizedAttributeDetails = Convert-ToPlainObject -InputObject $attributeDetails
                if ($null -eq $normalizedAttributeDetails) {
                    $normalizedAttributeDetails = $attributeDetails
                }

                $currentStep = "read-logical-name"
                $attributeLogicalName = [string](Get-PropertyValue -InputObject $normalizedAttributeDetails -PropertyName "LogicalName")
                if ([string]::IsNullOrWhiteSpace($attributeLogicalName)) {
                    $attributeLogicalName = [string](Get-PropertyValue -InputObject $attributeDetails -PropertyName "LogicalName")
                }

                if ([string]::IsNullOrWhiteSpace($attributeLogicalName)) {
                    continue
                }

                $currentStep = "deduplicate-attribute"
                if (-not $attributeLogicalNameSet.Add($attributeLogicalName)) {
                    continue
                }

                $currentStep = "read-optionset"
                $optionSetMetadata = Get-PropertyValue -InputObject $normalizedAttributeDetails -PropertyName "OptionSet"
                if ($null -eq $optionSetMetadata) {
                    $optionSetMetadata = Get-PropertyValue -InputObject $attributeDetails -PropertyName "OptionSet"
                }

                $currentStep = "extract-options"
                $options = @(Get-OptionChoicesFromOptionSetMetadata -OptionSetMetadata $optionSetMetadata -LabelLcid $LabelLcid)
                if ($options.Count -eq 0 -and $isBooleanType) {
                    $options = @(Get-OptionChoicesFromBooleanMetadata -AttributeMetadata $normalizedAttributeDetails -LabelLcid $LabelLcid)
                    if ($options.Count -eq 0) {
                        $options = @(Get-OptionChoicesFromBooleanMetadata -AttributeMetadata $attributeDetails -LabelLcid $LabelLcid)
                    }
                }

                if ($options.Count -eq 0) {
                    continue
                }

                $currentStep = "read-optionset-flags"
                $optionSetName = [string](Get-PropertyValue -InputObject $optionSetMetadata -PropertyName "Name")
                $isGlobalValue = Get-PropertyValue -InputObject $optionSetMetadata -PropertyName "IsGlobal"
                $isGlobal = $false
                if ($null -ne $isGlobalValue) {
                    try {
                        $isGlobal = [bool]$isGlobalValue
                    }
                    catch {
                        $isGlobal = $false
                    }
                }

                $currentStep = "add-result"
                [void]$optionSetDefinitions.Add([pscustomobject]@{
                    EntityLogicalName    = $EntityLogicalName
                    AttributeLogicalName = $attributeLogicalName
                    IsGlobal             = $isGlobal
                    OptionSetName        = $optionSetName
                    Options              = @($options)
                })
            }
            catch {
                $attributeNameForWarning = [string](Get-PropertyValue -InputObject $attributeDetails -PropertyName "LogicalName")
                if ([string]::IsNullOrWhiteSpace($attributeNameForWarning)) {
                    $attributeNameForWarning = "<unknown>"
                }

                Write-Verbose ("Skipping option set metadata for '{0}.{1}' ({2}) at step '{3}': {4}" -f $EntityLogicalName, $attributeNameForWarning, $typeName, $currentStep, $_.Exception.Message)
            }
        }
    }

    if ($optionSetDefinitions.Count -eq 0) {
        return @()
    }

    $sortedOptionSetDefinitions = @($optionSetDefinitions.ToArray() | Sort-Object AttributeLogicalName)
    return $sortedOptionSetDefinitions
}

Export-ModuleMember -Function Invoke-DataverseGet, Get-PagedItem, Get-EntityLogicalNamesFromSolution, Get-EntityAttribute, Get-EntityOptionSetDefinition
