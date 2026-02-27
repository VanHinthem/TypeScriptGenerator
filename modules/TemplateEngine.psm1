Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
Converts an input object into a hashtable template context.
.PARAMETER InputObject
Source object or dictionary.
.OUTPUTS
System.Collections.Hashtable
#>
function Get-TemplateContextFromObject {
    param(
        [AllowNull()]
        [object]$InputObject
    )

    $context = @{}

    if ($null -eq $InputObject) {
        return $context
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $context[[string]$key] = $InputObject[$key]
        }

        return $context
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if ($null -eq $property) {
            continue
        }

        $context[[string]$property.Name] = $property.Value
    }

    return $context
}

<#
.SYNOPSIS
Merges template contexts where override keys replace base keys.
.PARAMETER BaseContext
Original context.
.PARAMETER OverrideContext
Context whose keys should override the base.
.OUTPUTS
System.Collections.Hashtable
#>
function Join-TemplateContext {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$BaseContext,

        [Parameter(Mandatory = $true)]
        [hashtable]$OverrideContext
    )

    $merged = @{}

    foreach ($key in $BaseContext.Keys) {
        $merged[$key] = $BaseContext[$key]
    }

    foreach ($key in $OverrideContext.Keys) {
        $merged[$key] = $OverrideContext[$key]
    }

    return $merged
}

<#
.SYNOPSIS
Resolves a dot-path token from a template context.
.DESCRIPTION
Traverses hashtable/dictionary keys and object properties case-insensitively.
.PARAMETER Context
Template context map.
.PARAMETER Path
Dot-separated token path.
.OUTPUTS
PSCustomObject with `Found` and `Value`.
#>
function Get-TemplateValueByPath {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $segments = @($Path -split "\." | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -eq 0) {
        return [pscustomobject]@{
            Found = $false
            Value = $null
        }
    }

    $current = $Context
    foreach ($segment in $segments) {
        if ($null -eq $current) {
            return [pscustomobject]@{
                Found = $false
                Value = $null
            }
        }

        if ($current -is [System.Collections.IDictionary]) {
            $dictionaryResult = ObjectTraversal\Get-DictionaryValueCaseInsensitive -Dictionary $current -Key $segment
            if (-not $dictionaryResult.Found) {
                return [pscustomobject]@{
                    Found = $false
                    Value = $null
                }
            }

            $current = $dictionaryResult.Value
            continue
        }

        $propertyResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $current -PropertyName $segment
        if (-not $propertyResult.Found) {
            return [pscustomobject]@{
                Found = $false
                Value = $null
            }
        }

        $current = $propertyResult.Value
    }

    return [pscustomobject]@{
        Found = $true
        Value = $current
    }
}

<#
.SYNOPSIS
Infers a singular alias name from a collection path.
.DESCRIPTION
Examples: `Entities` -> `Entity`, `Options` -> `Option`.
.PARAMETER CollectionPath
Collection token path used in a loop.
.OUTPUTS
System.String
#>
function Get-CollectionItemAlias {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionPath
    )

    $segments = @($CollectionPath -split "\." | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -eq 0) {
        return ""
    }

    $leaf = $segments[$segments.Count - 1]
    if ($leaf -match "(?i)ies$") {
        return ($leaf.Substring(0, $leaf.Length - 3) + "y")
    }

    if ($leaf -match "(?i)s$") {
        return $leaf.Substring(0, $leaf.Length - 1)
    }

    return $leaf
}

<#
.SYNOPSIS
Extracts display text from Dataverse label objects.
.DESCRIPTION
Prefers `UserLocalizedLabel.Label`, then falls back to the first available
entry in `LocalizedLabels`.
.PARAMETER LabelObject
Dataverse label object.
.OUTPUTS
System.String
#>
function Get-DisplayLabelText {
    param(
        [AllowNull()]
        [object]$LabelObject
    )

    if ($null -eq $LabelObject) {
        return ""
    }

    $userLocalizedLabelResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $LabelObject -PropertyName "UserLocalizedLabel"
    if ($userLocalizedLabelResult.Found -and $null -ne $userLocalizedLabelResult.Value) {
        $userLabelResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $userLocalizedLabelResult.Value -PropertyName "Label"
        if ($userLabelResult.Found -and -not [string]::IsNullOrWhiteSpace([string]$userLabelResult.Value)) {
            return [string]$userLabelResult.Value
        }
    }

    $localizedLabelsResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $LabelObject -PropertyName "LocalizedLabels"
    if (-not $localizedLabelsResult.Found -or $null -eq $localizedLabelsResult.Value) {
        return ""
    }

    foreach ($localizedLabel in @($localizedLabelsResult.Value)) {
        if ($null -eq $localizedLabel) {
            continue
        }

        $labelResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $localizedLabel -PropertyName "Label"
        if ($labelResult.Found -and -not [string]::IsNullOrWhiteSpace([string]$labelResult.Value)) {
            return [string]$labelResult.Value
        }
    }

    return ""
}

<#
.SYNOPSIS
Converts scalar template values to text.
.DESCRIPTION
Booleans are emitted as lowercase `true`/`false` for TypeScript templates.
.PARAMETER Value
Input value.
.OUTPUTS
System.String
#>
function Convert-TemplateValueToString {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return "true"
        }

        return "false"
    }

    return [string]$Value
}

<#
.SYNOPSIS
Renders template content using loop and token expansion.
.DESCRIPTION
Expands loops first (`{{#Collection}}...{{/Collection}}`), then resolves scalar
tokens (`{{Path.To.Value}}`).
.PARAMETER TemplateContent
Template text.
.PARAMETER Context
Template context map.
.OUTPUTS
System.String
#>
function Convert-TemplateContent {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$TemplateContent,

        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $templateContext = $Context
    $loopPattern = [regex]"{{#([A-Za-z0-9_.]+)}}([\s\S]*?){{/\1}}"

    # Expand collection loops first, then resolve scalar tokens.
    $withLoops = $loopPattern.Replace($TemplateContent, {
            param($match)

            $collectionName = [string]$match.Groups[1].Value
            $loopBody = [string]$match.Groups[2].Value

            $collectionResult = Get-TemplateValueByPath -Context $templateContext -Path $collectionName
            if (-not $collectionResult.Found) {
                throw ("Unknown template loop collection '{0}'." -f $collectionName)
            }

            $collection = $collectionResult.Value
            if ($null -eq $collection) {
                throw ("Template loop collection '{0}' resolved to null." -f $collectionName)
            }

            if ($collection -is [string]) {
                throw ("Template loop collection '{0}' resolved to a string. Expected a collection." -f $collectionName)
            }

            if (-not ($collection -is [System.Collections.IEnumerable])) {
                throw ("Template loop collection '{0}' resolved to non-collection type '{1}'." -f $collectionName, $collection.GetType().FullName)
            }

            $builder = New-Object System.Text.StringBuilder
            $items = @($collection)

            foreach ($item in $items) {
                # Item fields override root fields for the current loop iteration.
                $itemContext = Get-TemplateContextFromObject -InputObject $item
                $mergedContext = Join-TemplateContext -BaseContext $templateContext -OverrideContext $itemContext
                $collectionItemAlias = Get-CollectionItemAlias -CollectionPath $collectionName
                if (-not [string]::IsNullOrWhiteSpace($collectionItemAlias)) {
                    # If a nested alias property exists, prefer it over the raw item.
                    $aliasValue = $item
                    $nestedAliasResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $item -PropertyName $collectionItemAlias
                    if ($nestedAliasResult.Found) {
                        $aliasValue = $nestedAliasResult.Value
                    }
                    $mergedContext[$collectionItemAlias] = $aliasValue
                }
                $renderedItem = Convert-TemplateContent -TemplateContent $loopBody -Context $mergedContext
                [void]$builder.Append($renderedItem)
            }

            return $builder.ToString()
        })

    $tokenPattern = [regex]"{{([A-Za-z0-9_.]+)}}"

    $withTokens = $tokenPattern.Replace($withLoops, {
            param($match)

            $tokenName = [string]$match.Groups[1].Value
            $tokenResult = Get-TemplateValueByPath -Context $templateContext -Path $tokenName
            if (-not $tokenResult.Found) {
                throw ("Unknown template token '{0}'." -f $tokenName)
            }

            if ($null -ne $tokenResult.Value -and
                $tokenResult.Value -is [System.Collections.IEnumerable] -and
                -not ($tokenResult.Value -is [string])) {
                throw ("Template token '{0}' resolved to a non-scalar value. Use a concrete leaf field." -f $tokenName)
            }

            return Convert-TemplateValueToString -Value $tokenResult.Value
        })

    return $withTokens
}

<#
.SYNOPSIS
Converts free-form text into a PascalCase identifier.
.DESCRIPTION
Removes diacritics, strips unsupported characters, and ensures the result is a
valid TypeScript identifier.
.PARAMETER Text
Source text.
.PARAMETER Fallback
Fallback identifier when conversion yields an empty value.
.OUTPUTS
System.String
#>
function Convert-ToPascalIdentifier {
    param(
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Fallback
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Fallback
    }

    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $diacriticFreeBuilder = New-Object System.Text.StringBuilder

    foreach ($character in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$diacriticFreeBuilder.Append($character)
        }
    }

    $diacriticFreeText = $diacriticFreeBuilder.ToString()
    $parts = [regex]::Split($diacriticFreeText, "[^A-Za-z0-9]+")
    $identifierBuilder = New-Object System.Text.StringBuilder

    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }

        $segment = $part.Trim()
        if ($segment.Length -eq 1) {
            [void]$identifierBuilder.Append($segment.ToUpperInvariant())
        }
        else {
            [void]$identifierBuilder.Append($segment.Substring(0, 1).ToUpperInvariant())
            [void]$identifierBuilder.Append($segment.Substring(1))
        }
    }

    $identifier = $identifierBuilder.ToString()
    if ([string]::IsNullOrWhiteSpace($identifier)) {
        $identifier = $Fallback
    }

    if ([char]::IsDigit($identifier[0])) {
        $identifier = "_" + $identifier
    }

    return $identifier
}

<#
.SYNOPSIS
Converts a value into a safe identifier suffix.
.DESCRIPTION
Only alphanumeric characters are retained; separators become underscores.
.PARAMETER Value
Input value.
.OUTPUTS
System.String
#>
function Convert-ToIdentifierSuffix {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return "Value"
    }

    $raw = [string]$Value
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return "Value"
    }

    $suffix = [regex]::Replace($raw, "[^A-Za-z0-9]+", "_").Trim("_")
    if ([string]::IsNullOrWhiteSpace($suffix)) {
        return "Value"
    }

    return $suffix
}

<#
.SYNOPSIS
Converts an option value to a TypeScript literal string.
.DESCRIPTION
Numbers and booleans are emitted without quotes; text values are escaped and
quoted.
.PARAMETER Value
Input value.
.OUTPUTS
System.String
#>
function Convert-ToNumericOrLiteral {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return "null"
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return "true"
        }

        return "false"
    }

    if ($Value -is [sbyte] -or
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64] -or
        $Value -is [single] -or
        $Value -is [double] -or
        $Value -is [decimal]) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0}", $Value)
    }

    $escaped = ([string]$Value).Replace("\", "\\").Replace('"', '\"')
    return ('"{0}"' -f $escaped)
}

<#
.SYNOPSIS
Builds normalized option item models for template rendering.
.DESCRIPTION
Generates stable keys, resolves collisions, and sets `Comma` for non-final
items.
.PARAMETER Options
Raw option entries from Dataverse metadata.
.OUTPUTS
System.Object[]
#>
function Get-OptionItemModel {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Options
    )

    $rawItems = New-Object System.Collections.Generic.List[object]

    # Build raw option rows first, then resolve naming collisions.
    foreach ($option in @($Options)) {
        $value = $option.Value
        $label = [string]$option.Label

        if ([string]::IsNullOrWhiteSpace($label)) {
            $label = "Value_$value"
        }

        $baseKey = Convert-ToPascalIdentifier -Text $label -Fallback ("Value_" + (Convert-ToIdentifierSuffix -Value $value))

        [void]$rawItems.Add([pscustomobject]@{
                Label = $label
                RawValue = [string]$value
                Value = Convert-ToNumericOrLiteral -Value $value
                KeyBase = $baseKey
                Source = $option
            })
    }

    $counts = @{}
    foreach ($item in $rawItems.ToArray()) {
        $countKey = $item.KeyBase.ToLowerInvariant()
        if ($counts.ContainsKey($countKey)) {
            $counts[$countKey] = [int]$counts[$countKey] + 1
        }
        else {
            $counts[$countKey] = 1
        }
    }

    $result = New-Object System.Collections.Generic.List[object]
    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    for ($index = 0; $index -lt $rawItems.Count; $index++) {
        $item = $rawItems[$index]
        $baseKey = [string]$item.KeyBase
        $countKey = $baseKey.ToLowerInvariant()

        $resolvedKey = $baseKey
        if ($counts[$countKey] -gt 1) {
            # Colliding labels are disambiguated by raw value suffix.
            $resolvedKey = "{0}_{1}" -f $baseKey, (Convert-ToIdentifierSuffix -Value $item.RawValue)
        }

        if (-not $seenKeys.Add($resolvedKey)) {
            # As a final guard, append a numeric dedupe index when needed.
            $dedupeIndex = 2
            while (-not $seenKeys.Add(("{0}_{1}" -f $resolvedKey, $dedupeIndex))) {
                $dedupeIndex++
            }

            $resolvedKey = "{0}_{1}" -f $resolvedKey, $dedupeIndex
        }

        $comma = ""
        if ($index -lt ($rawItems.Count - 1)) {
            $comma = ","
        }

        $optionContext = [pscustomobject]@{
            Label = $item.Label
            Key = $resolvedKey
            RawValue = $item.RawValue
            Value = $item.Value
            Comma = $comma
        }

        $sourceContext = Get-TemplateContextFromObject -InputObject $item.Source
        foreach ($sourceKey in @($sourceContext.Keys)) {
            if (-not $optionContext.PSObject.Properties.Match([string]$sourceKey)) {
                Add-Member -InputObject $optionContext -MemberType NoteProperty -Name ([string]$sourceKey) -Value $sourceContext[$sourceKey]
            }
        }

        [void]$result.Add([pscustomobject]@{
                Label = $optionContext.Label
                Key = $optionContext.Key
                RawValue = $optionContext.RawValue
                Value = $optionContext.Value
                Comma = $optionContext.Comma
                Option = $optionContext
            })
    }

    return $result.ToArray()
}

<#
.SYNOPSIS
Builds normalized option set models for template rendering.
.DESCRIPTION
Sorts option sets by attribute logical name and sets `Comma` for non-final
entries.
.PARAMETER EntityLogicalName
Owning entity logical name.
.PARAMETER OptionSetDefinitions
Raw option set definitions from Dataverse metadata.
.OUTPUTS
System.Object[]
#>
function Get-OptionSetModel {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntityLogicalName,

        [AllowEmptyCollection()]
        [object[]]$OptionSetDefinitions = @()
    )

    $rawOptionSets = New-Object System.Collections.Generic.List[object]

    foreach ($optionSetDefinition in @($OptionSetDefinitions)) {
        $attributeLogicalName = [string]$optionSetDefinition.AttributeLogicalName
        if ([string]::IsNullOrWhiteSpace($attributeLogicalName)) {
            continue
        }

        $isGlobal = $false
        if ($null -ne $optionSetDefinition.IsGlobal) {
            try {
                $isGlobal = [bool]$optionSetDefinition.IsGlobal
            }
            catch {
                $isGlobal = $false
            }
        }

        $optionSetName = [string]$optionSetDefinition.OptionSetName
        $options = @($optionSetDefinition.Options)
        $optionItemModels = @(Get-OptionItemModel -Options $options)

        $optionSetContext = [pscustomobject]@{
            EntityLogicalName = $EntityLogicalName
            AttributeLogicalName = $attributeLogicalName
            AttributeKey = $attributeLogicalName
            Name = $optionSetName
            IsGlobal = $isGlobal
            Comma = ""
            Options = $optionItemModels
        }

        $sourceContext = Get-TemplateContextFromObject -InputObject $optionSetDefinition
        foreach ($sourceKey in @($sourceContext.Keys)) {
            if (-not $optionSetContext.PSObject.Properties.Match([string]$sourceKey)) {
                Add-Member -InputObject $optionSetContext -MemberType NoteProperty -Name ([string]$sourceKey) -Value $sourceContext[$sourceKey]
            }
        }

        [void]$rawOptionSets.Add([pscustomobject]@{
                EntityLogicalName             = $optionSetContext.EntityLogicalName
                OptionSetAttributeLogicalName = $optionSetContext.AttributeLogicalName
                OptionSetAttributeKey         = $optionSetContext.AttributeKey
                OptionSetName                 = $optionSetContext.Name
                IsGlobal                      = $optionSetContext.IsGlobal
                Options                       = $optionItemModels
                OptionSet                     = $optionSetContext
            })
    }

    $sortedOptionSets = @($rawOptionSets.ToArray() | Sort-Object OptionSetAttributeLogicalName)
    $optionSetModels = New-Object System.Collections.Generic.List[object]

    for ($index = 0; $index -lt $sortedOptionSets.Count; $index++) {
        $optionSet = $sortedOptionSets[$index]
        $comma = ""
        if ($index -lt ($sortedOptionSets.Count - 1)) {
            $comma = ","
        }

        $optionSetContext = $optionSet.OptionSet
        if ($null -ne $optionSetContext) {
            # Keep parent and nested context in sync for template token access.
            if ($optionSetContext.PSObject.Properties.Match("Comma")) {
                $optionSetContext.Comma = $comma
            }
            else {
                Add-Member -InputObject $optionSetContext -MemberType NoteProperty -Name "Comma" -Value $comma
            }
        }

        [void]$optionSetModels.Add([pscustomobject]@{
                EntityLogicalName             = $optionSet.EntityLogicalName
                OptionSetAttributeLogicalName = $optionSet.OptionSetAttributeLogicalName
                OptionSetAttributeKey         = $optionSet.OptionSetAttributeKey
                OptionSetName                 = $optionSet.OptionSetName
                IsGlobal                      = $optionSet.IsGlobal
                Comma                         = $comma
                Options                       = @($optionSet.Options)
                OptionSet                     = $optionSetContext
            })
    }

    return $optionSetModels.ToArray()
}

<#
.SYNOPSIS
Renders final TypeScript content for a single entity based on the selected template.
.PARAMETER TemplateContent
Template text.
.PARAMETER EntityLogicalName
Entity logical name.
.PARAMETER EntitySchemaName
Entity schema name.
.PARAMETER EntityMetadata
Raw entity metadata object used for additional tokens.
.PARAMETER Attributes
Attribute metadata items.
.PARAMETER OptionSetDefinitions
Option set metadata items.
.OUTPUTS
System.String
#>
function Convert-EntityTypeScriptContent {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$TemplateContent,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntityLogicalName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntitySchemaName,

        [AllowNull()]
        [object]$EntityMetadata = $null,

        [AllowEmptyCollection()]
        [object[]]$Attributes = @(),

        [AllowEmptyCollection()]
        [object[]]$OptionSetDefinitions = @()
    )

    $rawAttributes = New-Object System.Collections.Generic.List[object]

    foreach ($attribute in @($Attributes)) {
        $attributeLogicalName = [string]$attribute.LogicalName
        if ([string]::IsNullOrWhiteSpace($attributeLogicalName)) {
            continue
        }

        $attributeSchemaName = [string]$attribute.SchemaName
        if ([string]::IsNullOrWhiteSpace($attributeSchemaName)) {
            $attributeSchemaName = $attributeLogicalName
        }

        $attributeContext = [pscustomobject]@{
            LogicalName = $attributeLogicalName
            SchemaName = $attributeSchemaName
            Key = $attributeLogicalName
            Comma = ""
        }

        $sourceContext = Get-TemplateContextFromObject -InputObject $attribute
        foreach ($sourceKey in @($sourceContext.Keys)) {
            if (-not $attributeContext.PSObject.Properties.Match([string]$sourceKey)) {
                Add-Member -InputObject $attributeContext -MemberType NoteProperty -Name ([string]$sourceKey) -Value $sourceContext[$sourceKey]
            }
        }

        [void]$rawAttributes.Add([pscustomobject]@{
                LogicalName = $attributeContext.LogicalName
                SchemaName  = $attributeContext.SchemaName
                Key         = $attributeContext.Key
                Attribute   = $attributeContext
            })
    }

    $sortedAttributes = @($rawAttributes.ToArray() | Sort-Object LogicalName)
    $attributeModels = New-Object System.Collections.Generic.List[object]

    for ($index = 0; $index -lt $sortedAttributes.Count; $index++) {
        $attribute = $sortedAttributes[$index]
        $comma = ""
        if ($index -lt ($sortedAttributes.Count - 1)) {
            $comma = ","
        }

        $attributeContext = $attribute.Attribute
        if ($null -ne $attributeContext) {
            if ($attributeContext.PSObject.Properties.Match("Comma")) {
                $attributeContext.Comma = $comma
            }
            else {
                Add-Member -InputObject $attributeContext -MemberType NoteProperty -Name "Comma" -Value $comma
            }
        }

        [void]$attributeModels.Add([pscustomobject]@{
                LogicalName = $attribute.LogicalName
                SchemaName  = $attribute.SchemaName
                Key         = $attribute.Key
                Comma       = $comma
                Attribute   = $attributeContext
            })
    }

    $optionSetModels = @(Get-OptionSetModel -EntityLogicalName $EntityLogicalName -OptionSetDefinitions $OptionSetDefinitions)

    $entityDisplayName = ""
    if ($null -ne $EntityMetadata) {
        $displayNameResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $EntityMetadata -PropertyName "DisplayName"
        if ($displayNameResult.Found) {
            $entityDisplayName = Get-DisplayLabelText -LabelObject $displayNameResult.Value
        }
    }

    $entityContext = [pscustomobject]@{
        LogicalName = $EntityLogicalName
        SchemaName = $EntitySchemaName
        DisplayName = $entityDisplayName
    }

    if ($null -ne $EntityMetadata) {
        $entitySourceContext = Get-TemplateContextFromObject -InputObject $EntityMetadata
        foreach ($entityKey in @($entitySourceContext.Keys)) {
            if (-not $entityContext.PSObject.Properties.Match([string]$entityKey)) {
                Add-Member -InputObject $entityContext -MemberType NoteProperty -Name ([string]$entityKey) -Value $entitySourceContext[$entityKey]
            }
        }
    }

    $entityModels = @([pscustomobject]@{
            LogicalName = $entityContext.LogicalName
            SchemaName  = $entityContext.SchemaName
            DisplayName = $entityContext.DisplayName
            Entity      = $entityContext
        })

    $context = @{
        Entity = $entityContext
        Entities          = $entityModels
        Attributes        = $attributeModels.ToArray()
        OptionSets        = $optionSetModels
    }

    return Convert-TemplateContent -TemplateContent $TemplateContent -Context $context
}

Export-ModuleMember -Function Convert-EntityTypeScriptContent
