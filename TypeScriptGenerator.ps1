[CmdletBinding()]
param(
    [string]$EnvironmentUrl,

    [string]$TenantId,
    [string]$ClientId,
    [string]$RedirectUri,

    [string]$Template,
    [string]$TypeScriptOutputPath,
    [bool]$Clean = $true,
    [bool]$Overwrite = $true,
    [switch]$NoClean,
    [switch]$NoOverwrite,
    [Nullable[int]]$OptionSetLabelLcid,
    [int]$MaxParallelEntities = 4,
    [string[]]$EntityLogicalNames,
    [string]$EntityListPath,
    [string]$SolutionUniqueName,
    [string]$SettingsPath = ".\settings.psd1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
Resolves and validates an output file path derived from a tokenized template pattern.
#>
function Resolve-OutputRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntityLogicalName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntitySchemaName,

        [AllowNull()]
        [object]$EntityMetadata = $null
    )

    $relativePath = Resolve-EntityPatternValue `
        -Pattern $Pattern `
        -EntityLogicalName $EntityLogicalName `
        -EntitySchemaName $EntitySchemaName `
        -EntityMetadata $EntityMetadata

    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        throw "Output path pattern resolved to an empty value."
    }

    $normalizedRelativePath = $relativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar).Replace("\", [System.IO.Path]::DirectorySeparatorChar).Trim()
    if ([System.IO.Path]::IsPathRooted($normalizedRelativePath)) {
        throw ("Output path pattern must resolve to a relative path: {0}" -f $normalizedRelativePath)
    }

    $segments = @($normalizedRelativePath -split "[\\/]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -eq 0) {
        throw ("Output path pattern resolved to an empty relative path: {0}" -f $normalizedRelativePath)
    }

    foreach ($segment in $segments) {
        if ($segment -eq "." -or $segment -eq "..") {
            throw ("Output path pattern cannot contain traversal segments '.' or '..': {0}" -f $normalizedRelativePath)
        }

        if ($segment.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw ("Output path contains invalid characters in segment '{0}': {1}" -f $segment, $normalizedRelativePath)
        }
    }

    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    return [string]::Join($separator, $segments)
}

<#
.SYNOPSIS
Converts a template file path into its relative output path pattern within the template set.
#>
function Get-TemplateOutputRelativePathPattern {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateSetPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResolvedTemplatePath
    )

    $normalizedTemplateSetPath = [System.IO.Path]::GetFullPath($TemplateSetPath).TrimEnd("\", "/")
    $normalizedTemplatePath = [System.IO.Path]::GetFullPath($ResolvedTemplatePath)

    $prefix = $normalizedTemplateSetPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $normalizedTemplatePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Template path is not inside template set folder. TemplateSetPath='{0}', TemplatePath='{1}'" -f $normalizedTemplateSetPath, $normalizedTemplatePath)
    }

    $relativePathPattern = $normalizedTemplatePath.Substring($prefix.Length)
    if ([string]::IsNullOrWhiteSpace($relativePathPattern)) {
        throw ("Could not determine output path pattern from template path: {0}" -f $normalizedTemplatePath)
    }

    return $relativePathPattern
}

<#
.SYNOPSIS
Resolves template set folder and returns all template files.
#>
function Resolve-TemplateSetFile {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateSetName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptRoot
    )

    $templatesRootPath = Resolve-ScriptRelativePath -Path ".\templates" -ScriptRoot $ScriptRoot
    $templateSetPath = Join-Path -Path $templatesRootPath -ChildPath $TemplateSetName

    if (-not (Test-Path -LiteralPath $templateSetPath -PathType Container)) {
        throw ("Template folder not found: {0}" -f $templateSetPath)
    }

    $templateFiles = @(Get-ChildItem -LiteralPath $templateSetPath -File -Recurse | Sort-Object FullName)
    if ($templateFiles.Count -eq 0) {
        throw ("Template folder is empty: {0}" -f $templateSetPath)
    }

    return [pscustomobject]@{
        TemplateSetPath = [System.IO.Path]::GetFullPath($templateSetPath)
        TemplateFiles   = @($templateFiles | ForEach-Object { $_.FullName })
    }
}

<#
.SYNOPSIS
Resolves {{Entity.*}} output path tokens and sanitizes resulting path fragments.
#>
function Resolve-EntityPatternValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntityLogicalName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntitySchemaName,

        [AllowNull()]
        [object]$EntityMetadata = $null
    )

    $entityLogicalNameValue = $EntityLogicalName
    $entitySchemaNameValue = $EntitySchemaName
    $entityMetadataValue = $EntityMetadata

    $tokenPattern = [regex]"{{\s*(?<token>[A-Za-z0-9_.]+)\s*}}"
    try {
        $value = $tokenPattern.Replace($Pattern, {
                param($match)
                $tokenName = [string]$match.Groups["token"].Value
                $tokenValue = Resolve-EntityPathTokenValue `
                    -TokenName $tokenName `
                    -EntityLogicalName $entityLogicalNameValue `
                    -EntitySchemaName $entitySchemaNameValue `
                    -EntityMetadata $entityMetadataValue

                return Convert-ToSafePathTokenValue -Value $tokenValue
            })
    }
    catch {
        throw ("Could not resolve output path pattern '{0}'. {1}" -f $Pattern, $_.Exception.Message)
    }

    return $value.Trim()
}

<#
.SYNOPSIS
Resolves a dotted property path on an object or dictionary using case-insensitive matching.
#>
function Get-PathValueCaseInsensitive {
    param(
        [AllowNull()]
        [object]$Root,
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

    $current = $Root
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
Gets a display label from entity metadata with fallback to logical name.
#>
function Get-EntityDisplayNameText {
    param(
        [AllowNull()]
        [object]$EntityMetadata,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Fallback
    )

    if ($null -eq $EntityMetadata) {
        return $Fallback
    }

    $displayNameResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $EntityMetadata -PropertyName "DisplayName"
    if (-not $displayNameResult.Found -or $null -eq $displayNameResult.Value) {
        return $Fallback
    }

    $displayNameObject = $displayNameResult.Value
    $userLocalizedLabelResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $displayNameObject -PropertyName "UserLocalizedLabel"
    if ($userLocalizedLabelResult.Found -and $null -ne $userLocalizedLabelResult.Value) {
        $labelResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $userLocalizedLabelResult.Value -PropertyName "Label"
        if ($labelResult.Found -and -not [string]::IsNullOrWhiteSpace([string]$labelResult.Value)) {
            return [string]$labelResult.Value
        }
    }

    $localizedLabelsResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $displayNameObject -PropertyName "LocalizedLabels"
    if ($localizedLabelsResult.Found -and $null -ne $localizedLabelsResult.Value) {
        foreach ($localizedLabel in @($localizedLabelsResult.Value)) {
            if ($null -eq $localizedLabel) {
                continue
            }

            $labelResult = ObjectTraversal\Get-ObjectPropertyValueCaseInsensitive -InputObject $localizedLabel -PropertyName "Label"
            if ($labelResult.Found -and -not [string]::IsNullOrWhiteSpace([string]$labelResult.Value)) {
                return [string]$labelResult.Value
            }
        }
    }

    return $Fallback
}

<#
.SYNOPSIS
Sanitizes token output to be safe for file and folder names.
#>
function Convert-ToSafePathTokenValue {
    param(
        [AllowNull()]
        [object]$Value
    )

    $textValue = if ($null -eq $Value) { "" } else { [string]$Value }
    if ([string]::IsNullOrWhiteSpace($textValue)) {
        return "_"
    }

    $invalidCharacters = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $textValue.Trim().ToCharArray()) {
        if ($invalidCharacters -contains $character -or
            $character -eq [System.IO.Path]::DirectorySeparatorChar -or
            $character -eq [System.IO.Path]::AltDirectorySeparatorChar) {
            [void]$builder.Append("_")
            continue
        }

        [void]$builder.Append($character)
    }

    $sanitized = $builder.ToString()
    $sanitized = [regex]::Replace($sanitized, "\s+", "_")
    $sanitized = [regex]::Replace($sanitized, "_{2,}", "_")
    $sanitized = $sanitized.Trim("_")
    $sanitized = $sanitized.TrimEnd(".", " ")

    if ([string]::IsNullOrWhiteSpace($sanitized) -or $sanitized -eq "." -or $sanitized -eq "..") {
        return "_"
    }

    return $sanitized
}

<#
.SYNOPSIS
Resolves a single output path token value from entity metadata context.
#>
function Resolve-EntityPathTokenValue {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TokenName,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntityLogicalName,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntitySchemaName,
        [AllowNull()]
        [object]$EntityMetadata = $null
    )

    if ($TokenName.StartsWith("Entity.", [System.StringComparison]::OrdinalIgnoreCase)) {
        $entityDisplayName = Get-EntityDisplayNameText -EntityMetadata $EntityMetadata -Fallback $EntityLogicalName
        $entityContext = [pscustomobject]@{
            LogicalName = $EntityLogicalName
            SchemaName = $EntitySchemaName
            DisplayName = $entityDisplayName
        }

        if ($null -ne $EntityMetadata) {
            foreach ($property in $EntityMetadata.PSObject.Properties) {
                if ($null -eq $property) {
                    continue
                }

                if (-not $entityContext.PSObject.Properties.Match([string]$property.Name)) {
                    Add-Member -InputObject $entityContext -MemberType NoteProperty -Name ([string]$property.Name) -Value $property.Value
                }
            }
        }

        $path = $TokenName.Substring("Entity.".Length)
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw ("Invalid output path token '{0}'." -f $TokenName)
        }

        $result = Get-PathValueCaseInsensitive -Root $entityContext -Path $path
        if (-not $result.Found) {
            throw ("Unknown output path token '{0}'." -f $TokenName)
        }

        if ($null -eq $result.Value) {
            return ""
        }

        if ($result.Value -is [System.Collections.IEnumerable] -and -not ($result.Value -is [string])) {
            throw ("Output path token '{0}' resolved to a non-scalar value. Use a concrete leaf field." -f $TokenName)
        }

        return [string]$result.Value
    }

    throw ("Unknown output path token '{0}'. Supported: {{Entity.<field>}} (for example {{Entity.LogicalName}}, {{Entity.SchemaName}}, {{Entity.DisplayName}})." -f $TokenName)
}

function Get-SettingsPropertyValue {
    param(
        [AllowNull()]
        [object]$Settings,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    if ($null -eq $Settings) {
        return $null
    }

    if ($Settings -is [System.Collections.IDictionary]) {
        foreach ($key in $Settings.Keys) {
            if ([string]$key -ieq $Name) {
                return $Settings[$key]
            }
        }

        return $null
    }

    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Convert-ToStringArray {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[string]

    if ($Value -is [string]) {
        $parts = [string]$Value -split "[,;`r`n]+"
        foreach ($part in $parts) {
            $trimmedPart = [string]$part
            if (-not [string]::IsNullOrWhiteSpace($trimmedPart)) {
                [void]$items.Add($trimmedPart.Trim())
            }
        }

        return $items.ToArray()
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($entry in $Value) {
            $entryText = [string]$entry
            if (-not [string]::IsNullOrWhiteSpace($entryText)) {
                [void]$items.Add($entryText.Trim())
            }
        }

        return $items.ToArray()
    }

    $singleValueText = [string]$Value
    if (-not [string]::IsNullOrWhiteSpace($singleValueText)) {
        [void]$items.Add($singleValueText.Trim())
    }

    return $items.ToArray()
}

function Convert-ToBooleanValue {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SettingName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SettingsPath
    )

    if ($null -eq $Value) {
        throw ("Setting '{0}' is null in settings file '{1}'." -f $SettingName, $SettingsPath)
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $valueText = [string]$Value
    if ([string]::IsNullOrWhiteSpace($valueText)) {
        throw ("Setting '{0}' is empty in settings file '{1}'." -f $SettingName, $SettingsPath)
    }

    $normalized = $valueText.Trim().ToLowerInvariant()
    if ($normalized -eq "true" -or $normalized -eq "1" -or $normalized -eq "yes") {
        return $true
    }

    if ($normalized -eq "false" -or $normalized -eq "0" -or $normalized -eq "no") {
        return $false
    }

    throw ("Invalid boolean value for setting '{0}' in '{1}': {2}. Expected true/false." -f $SettingName, $SettingsPath, $valueText)
}

function Convert-LineEnding {
    param(
        [AllowNull()]
        [string]$Text,

        [ValidateSet("CRLF", "LF")]
        [string]$LineEnding = "CRLF"
    )

    if ($null -eq $Text) {
        return ""
    }

    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($LineEnding -eq "LF") {
        return $normalized
    }

    return $normalized.Replace("`n", "`r`n")
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [AllowNull()]
        [string]$Content,

        [ValidateSet("CRLF", "LF")]
        [string]$LineEnding = "CRLF"
    )

    $normalizedContent = Convert-LineEnding -Text $Content -LineEnding $LineEnding
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalizedContent, $encoding)
}

# Import required modules from the local modules folder to keep path behavior deterministic.
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleFiles = @(
    "Pathing.psm1",
    "ObjectTraversal.psm1",
    "Auth.psm1",
    "DataverseQueries.psm1",
    "DataverseApi.psm1",
    "EntitySelection.psm1",
    "TemplateEngine.psm1"
)

foreach ($moduleFile in $moduleFiles) {
    $modulePath = Join-Path -Path $scriptRoot -ChildPath ("modules\" + $moduleFile)
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "Required module is missing: $modulePath"
    }

    $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($moduleFile)
    Remove-Module -Name $moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $modulePath -Force -DisableNameChecking -ErrorAction Stop
}

$resolvedSettingsPath = Resolve-ScriptRelativePath -Path $SettingsPath -ScriptRoot $scriptRoot
if (-not $resolvedSettingsPath.EndsWith(".psd1", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("SettingsPath must point to a .psd1 file. Current value: {0}" -f $resolvedSettingsPath)
}

if (-not (Test-Path -LiteralPath $resolvedSettingsPath -PathType Leaf)) {
    throw ("Settings file not found: {0}" -f $resolvedSettingsPath)
}

try {
    $settings = Import-PowerShellDataFile -LiteralPath $resolvedSettingsPath -ErrorAction Stop
}
catch {
    throw ("Could not read settings file '{0}': {1}" -f $resolvedSettingsPath, $_.Exception.Message)
}

if (-not $PSBoundParameters.ContainsKey("TenantId")) {
    $TenantId = [string](Get-SettingsPropertyValue -Settings $settings -Name "TenantId")
}

# Settings precedence: explicit parameters override settings file values.
if (-not $PSBoundParameters.ContainsKey("EnvironmentUrl")) {
    $EnvironmentUrl = [string](Get-SettingsPropertyValue -Settings $settings -Name "EnvironmentUrl")
}
if (-not $PSBoundParameters.ContainsKey("ClientId")) {
    $ClientId = [string](Get-SettingsPropertyValue -Settings $settings -Name "ClientId")
}
if (-not $PSBoundParameters.ContainsKey("RedirectUri")) {
    $RedirectUri = [string](Get-SettingsPropertyValue -Settings $settings -Name "RedirectUri")
}
if (-not $PSBoundParameters.ContainsKey("Template")) {
    $Template = [string](Get-SettingsPropertyValue -Settings $settings -Name "Template")
}
if (-not $PSBoundParameters.ContainsKey("TypeScriptOutputPath")) {
    $TypeScriptOutputPath = [string](Get-SettingsPropertyValue -Settings $settings -Name "TypeScriptOutputPath")
}
if (-not $PSBoundParameters.ContainsKey("Clean")) {
    $cleanFromSettings = Get-SettingsPropertyValue -Settings $settings -Name "Clean"
    if ($null -ne $cleanFromSettings) {
        $Clean = Convert-ToBooleanValue -Value $cleanFromSettings -SettingName "Clean" -SettingsPath $resolvedSettingsPath
    }
}
if (-not $PSBoundParameters.ContainsKey("Overwrite")) {
    $overwriteFromSettings = Get-SettingsPropertyValue -Settings $settings -Name "Overwrite"
    if ($null -ne $overwriteFromSettings) {
        $Overwrite = Convert-ToBooleanValue -Value $overwriteFromSettings -SettingName "Overwrite" -SettingsPath $resolvedSettingsPath
    }
}
if (-not $PSBoundParameters.ContainsKey("EntityListPath")) {
    $EntityListPath = [string](Get-SettingsPropertyValue -Settings $settings -Name "EntityListPath")
}
if (-not $PSBoundParameters.ContainsKey("SolutionUniqueName")) {
    $SolutionUniqueName = [string](Get-SettingsPropertyValue -Settings $settings -Name "SolutionUniqueName")
}
if (-not $PSBoundParameters.ContainsKey("EntityLogicalNames")) {
    $entityLogicalNamesFromSettings = @(Convert-ToStringArray -Value (Get-SettingsPropertyValue -Settings $settings -Name "EntityLogicalNames"))
    if (@($entityLogicalNamesFromSettings).Count -gt 0) {
        $EntityLogicalNames = $entityLogicalNamesFromSettings
    }
}
if (-not $PSBoundParameters.ContainsKey("OptionSetLabelLcid")) {
    $lcidValueFromSettings = Get-SettingsPropertyValue -Settings $settings -Name "OptionSetLabelLcid"
    if ($null -ne $lcidValueFromSettings -and -not [string]::IsNullOrWhiteSpace([string]$lcidValueFromSettings)) {
        $parsedLcid = 0
        if (-not [int]::TryParse([string]$lcidValueFromSettings, [ref]$parsedLcid)) {
            throw ("Invalid OptionSetLabelLcid in settings file '{0}': {1}" -f $resolvedSettingsPath, [string]$lcidValueFromSettings)
        }

        $OptionSetLabelLcid = $parsedLcid
    }
}
if (-not $PSBoundParameters.ContainsKey("MaxParallelEntities")) {
    $maxParallelEntitiesFromSettings = Get-SettingsPropertyValue -Settings $settings -Name "MaxParallelEntities"
    if ($null -ne $maxParallelEntitiesFromSettings -and -not [string]::IsNullOrWhiteSpace([string]$maxParallelEntitiesFromSettings)) {
        $parsedMaxParallelEntities = 0
        if (-not [int]::TryParse([string]$maxParallelEntitiesFromSettings, [ref]$parsedMaxParallelEntities)) {
            throw ("Invalid MaxParallelEntities in settings file '{0}': {1}" -f $resolvedSettingsPath, [string]$maxParallelEntitiesFromSettings)
        }

        $MaxParallelEntities = $parsedMaxParallelEntities
    }
}

if ($NoClean.IsPresent -and $PSBoundParameters.ContainsKey("Clean")) {
    throw "Use either -Clean or -NoClean, not both."
}

if ($NoOverwrite.IsPresent -and $PSBoundParameters.ContainsKey("Overwrite")) {
    throw "Use either -Overwrite or -NoOverwrite, not both."
}

if ($NoClean.IsPresent) {
    $Clean = $false
}

if ($NoOverwrite.IsPresent) {
    $Overwrite = $false
}

if ([string]::IsNullOrWhiteSpace($EnvironmentUrl)) {
    throw "EnvironmentUrl is required. Set it in settings file or pass -EnvironmentUrl."
}

if ([string]::IsNullOrWhiteSpace($TenantId)) {
    throw "TenantId is required. Set it in settings file or pass -TenantId."
}

if ([string]::IsNullOrWhiteSpace($ClientId)) {
    throw "ClientId is required. Set it in settings file or pass -ClientId."
}

if ([string]::IsNullOrWhiteSpace($RedirectUri)) {
    throw "RedirectUri is required. Set it in settings file or pass -RedirectUri."
}

if ([string]::IsNullOrWhiteSpace($Template)) {
    throw "Template is required. Set it in settings file or pass -Template."
}

if ([string]::IsNullOrWhiteSpace($TypeScriptOutputPath)) {
    throw "TypeScriptOutputPath is required. Set it in settings file or pass -TypeScriptOutputPath."
}

if ($null -eq $OptionSetLabelLcid -or [string]::IsNullOrWhiteSpace([string]$OptionSetLabelLcid)) {
    throw "OptionSetLabelLcid is required. Set it in settings file or pass -OptionSetLabelLcid."
}

$resolvedOptionSetLabelLcid = 0
if (-not [int]::TryParse([string]$OptionSetLabelLcid, [ref]$resolvedOptionSetLabelLcid)) {
    throw ("OptionSetLabelLcid must be a valid integer. Current value: {0}" -f [string]$OptionSetLabelLcid)
}

if ($resolvedOptionSetLabelLcid -lt 1) {
    throw ("OptionSetLabelLcid must be >= 1. Current value: {0}" -f $resolvedOptionSetLabelLcid)
}

$resolvedMaxParallelEntities = 0
if (-not [int]::TryParse([string]$MaxParallelEntities, [ref]$resolvedMaxParallelEntities)) {
    throw ("MaxParallelEntities must be a valid integer. Current value: {0}" -f [string]$MaxParallelEntities)
}

if ($resolvedMaxParallelEntities -lt 1) {
    throw ("MaxParallelEntities must be >= 1. Current value: {0}" -f $resolvedMaxParallelEntities)
}

# Convert relative output/input paths relative to this script location.
$TypeScriptOutputPath = Resolve-ScriptRelativePath -Path $TypeScriptOutputPath -ScriptRoot $scriptRoot
if (-not [string]::IsNullOrWhiteSpace($EntityListPath)) {
    $EntityListPath = Resolve-ScriptRelativePath -Path $EntityListPath -ScriptRoot $scriptRoot
}

$templateSetFiles = Resolve-TemplateSetFile -TemplateSetName $Template -ScriptRoot $scriptRoot
$templateDefinitions = New-Object System.Collections.Generic.List[object]
foreach ($templateFilePath in @($templateSetFiles.TemplateFiles)) {
    $templateContent = Get-Content -LiteralPath $templateFilePath -Raw
    $outputRelativePathPattern = Get-TemplateOutputRelativePathPattern `
        -TemplateSetPath $templateSetFiles.TemplateSetPath `
        -ResolvedTemplatePath $templateFilePath

    [void]$templateDefinitions.Add([pscustomobject]@{
        TemplatePath               = $templateFilePath
        TemplateContent            = $templateContent
        OutputRelativePathPattern  = $outputRelativePathPattern
    })
}

Write-Verbose ("Template set '{0}' loaded with {1} template file(s)." -f $Template, $templateDefinitions.Count)

$normalizedEnvironmentUrl = $EnvironmentUrl.TrimEnd("/")

# Prepare output folder, optionally clearing existing generated files.
if (-not (Test-Path -LiteralPath $TypeScriptOutputPath)) {
    New-Item -ItemType Directory -Path $TypeScriptOutputPath -Force | Out-Null
}
elseif ($Clean) {
    $existingItems = @(Get-ChildItem -LiteralPath $TypeScriptOutputPath -Force -ErrorAction SilentlyContinue)
    foreach ($existingItem in $existingItems) {
        Remove-Item -LiteralPath $existingItem.FullName -Recurse -Force -ErrorAction Stop
    }
}

Write-Verbose "Retrieving access token..."
$token = Get-DataverseAccessToken `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -EnvironmentUrl $normalizedEnvironmentUrl `
    -RedirectUri $RedirectUri
Write-Verbose "Access token retrieved successfully."

$headers = @{
    Authorization      = "Bearer $token"
    Accept             = "application/json"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
}

# Resolve entity selection from parameters, list file, and/or solution membership.
$selectedEntityLogicalNames = @(Resolve-SelectedEntityLogicalNames `
    -EntityLogicalNames $EntityLogicalNames `
    -EntityListPath $EntityListPath `
    -SolutionUniqueName $SolutionUniqueName `
    -EnvironmentUrl $normalizedEnvironmentUrl `
    -Headers $headers)

Write-Verbose ("Selected entity names resolved: {0}" -f @($selectedEntityLogicalNames).Count)

if (@($selectedEntityLogicalNames).Count -eq 0) {
    Write-Verbose "No selection specified; retrieving all entities."
}

$normalizedSelectedEntityLogicalNames = @()
if ($null -ne $selectedEntityLogicalNames) {
    $normalizedSelectedEntityLogicalNames = @(
        foreach ($name in @($selectedEntityLogicalNames)) {
            if ($null -eq $name) {
                continue
            }

            $nameText = [string]$name
            if (-not [string]::IsNullOrWhiteSpace($nameText)) {
                $nameText.Trim()
            }
        }
    )
}

if (@($normalizedSelectedEntityLogicalNames).Count -gt 0) {
    $entitiesToProcess = New-Object System.Collections.Generic.List[object]
    foreach ($entityLogicalName in @($normalizedSelectedEntityLogicalNames)) {
        $entityLogicalNameText = [string]$entityLogicalName
        if ([string]::IsNullOrWhiteSpace($entityLogicalNameText)) {
            continue
        }

        try {
            Write-Verbose ("Retrieving metadata for selected entity '{0}'..." -f $entityLogicalNameText)
            $entityUri = DataverseQueries\Get-DataverseEntityDefinitionByLogicalNameUri `
                -EnvironmentUrl $normalizedEnvironmentUrl `
                -EntityLogicalName $entityLogicalNameText
            $entity = DataverseApi\Invoke-DataverseGet -Uri $entityUri -Headers $headers
            [void]$entitiesToProcess.Add($entity)
        }
        catch {
            $errorMessage = $_.Exception.Message
            $statusCode = $null

            if ($_.Exception -and $_.Exception.Response -and $_.Exception.Response.StatusCode) {
                try {
                    $statusCode = [int]$_.Exception.Response.StatusCode.value__
                }
                catch {
                    try {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                    }
                    catch {
                        $statusCode = $null
                    }
                }
            }

            if ($statusCode -eq 404 -or $errorMessage -match "(?i)not found|does not exist") {
                Write-Warning ("Entity '{0}' was not found and will be skipped." -f $entityLogicalNameText)
                continue
            }

            throw ("Could not retrieve entity definition for '{0}'. Error: {1}" -f $entityLogicalNameText, $errorMessage)
        }
    }

    $entitiesToProcess = $entitiesToProcess.ToArray()
}
else {
    # No explicit selection: process all public entities.
    $entitiesUri = DataverseQueries\Get-DataverseEntityDefinitionsUri `
        -EnvironmentUrl $normalizedEnvironmentUrl `
        -Filter "IsPrivate eq false"
    $entitiesToProcess = @(DataverseApi\Get-PagedItem -Uri $entitiesUri -Headers $headers)
}

Write-Verbose ("Entity count: {0}" -f $entitiesToProcess.Count)

$entityGenerationItems = New-Object System.Collections.Generic.List[object]

if ($entitiesToProcess.Count -gt 0) {
    $parallelWorkerCount = [Math]::Min($resolvedMaxParallelEntities, $entitiesToProcess.Count)
    if ($parallelWorkerCount -le 1) {
        foreach ($entity in $entitiesToProcess) {
            $entityLogicalName = [string]$entity.LogicalName
            $entitySchemaName = [string]$entity.SchemaName

            Write-Verbose ("Processing entity: {0}" -f $entityLogicalName)

            Write-Verbose ("Retrieving attributes for entity '{0}'..." -f $entityLogicalName)
            $attributes = DataverseApi\Get-EntityAttribute `
                -EnvironmentUrl $normalizedEnvironmentUrl `
                -Headers $headers `
                -EntityLogicalName $entityLogicalName

            try {
                Write-Verbose ("Retrieving option sets for entity '{0}' with LCID {1}..." -f $entityLogicalName, $resolvedOptionSetLabelLcid)
                $optionSetDefinitions = DataverseApi\Get-EntityOptionSetDefinition `
                    -EnvironmentUrl $normalizedEnvironmentUrl `
                    -Headers $headers `
                    -EntityLogicalName $entityLogicalName `
                    -LabelLcid $resolvedOptionSetLabelLcid
            }
            catch {
                throw ("Could not retrieve option sets for entity '{0}'. Error: {1}" -f $entityLogicalName, $_.Exception.Message)
            }

            if ($null -eq $optionSetDefinitions) {
                $optionSetDefinitions = @()
            }

            Write-Verbose ("Entity '{0}' metadata retrieved. Attributes={1}, OptionSets={2}" -f $entityLogicalName, @($attributes).Count, @($optionSetDefinitions).Count)

            [void]$entityGenerationItems.Add([pscustomobject]@{
                EntityLogicalName    = $entityLogicalName
                EntitySchemaName     = $entitySchemaName
                EntityMetadata       = $entity
                Attributes           = @($attributes)
                OptionSetDefinitions = @($optionSetDefinitions)
            })
        }
    }
    else {
        Write-Verbose ("Processing entity metadata in parallel. Workers={0}" -f $parallelWorkerCount)

        $dataverseQueriesModulePath = Join-Path -Path $scriptRoot -ChildPath "modules\DataverseQueries.psm1"
        $dataverseApiModulePath = Join-Path -Path $scriptRoot -ChildPath "modules\DataverseApi.psm1"

        $entityMetadataWorkerScript = {
            param(
                [Parameter(Mandatory = $true)]
                [string]$EntityLogicalName,
                [Parameter(Mandatory = $true)]
                [AllowEmptyString()]
                [string]$EntitySchemaName,
                [Parameter(Mandatory = $true)]
                [string]$EnvironmentUrl,
                [Parameter(Mandatory = $true)]
                [hashtable]$Headers,
                [Parameter(Mandatory = $true)]
                [int]$LabelLcid,
                [Parameter(Mandatory = $true)]
                [string]$DataverseQueriesModulePath,
                [Parameter(Mandatory = $true)]
                [string]$DataverseApiModulePath
            )

            Set-StrictMode -Version Latest
            $ErrorActionPreference = "Stop"

            Remove-Module -Name DataverseApi -Force -ErrorAction SilentlyContinue
            Remove-Module -Name DataverseQueries -Force -ErrorAction SilentlyContinue
            Import-Module -Name $DataverseQueriesModulePath -Force -DisableNameChecking -ErrorAction Stop | Out-Null
            Import-Module -Name $DataverseApiModulePath -Force -DisableNameChecking -ErrorAction Stop | Out-Null

            $attributes = DataverseApi\Get-EntityAttribute `
                -EnvironmentUrl $EnvironmentUrl `
                -Headers $Headers `
                -EntityLogicalName $EntityLogicalName

            try {
                $optionSetDefinitions = DataverseApi\Get-EntityOptionSetDefinition `
                    -EnvironmentUrl $EnvironmentUrl `
                    -Headers $Headers `
                    -EntityLogicalName $EntityLogicalName `
                    -LabelLcid $LabelLcid
            }
            catch {
                throw ("Could not retrieve option sets for entity '{0}'. Error: {1}" -f $EntityLogicalName, $_.Exception.Message)
            }

            if ($null -eq $optionSetDefinitions) {
                $optionSetDefinitions = @()
            }

            return [pscustomobject]@{
                EntityLogicalName    = $EntityLogicalName
                EntitySchemaName     = $EntitySchemaName
                Attributes           = @($attributes)
                OptionSetDefinitions = @($optionSetDefinitions)
            }
        }

        $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $parallelWorkerCount)
        $runspacePool.Open()

        $entityWorkItems = New-Object System.Collections.Generic.List[object]
        try {
            foreach ($entity in $entitiesToProcess) {
                $entityLogicalName = [string]$entity.LogicalName
                $entitySchemaName = [string]$entity.SchemaName
                if ([string]::IsNullOrWhiteSpace($entityLogicalName)) {
                    throw "Entity logical name is missing."
                }

                $worker = [PowerShell]::Create()
                $worker.RunspacePool = $runspacePool
                [void]$worker.AddScript($entityMetadataWorkerScript.ToString())
                [void]$worker.AddArgument($entityLogicalName)
                [void]$worker.AddArgument($entitySchemaName)
                [void]$worker.AddArgument($normalizedEnvironmentUrl)
                [void]$worker.AddArgument($headers)
                [void]$worker.AddArgument($resolvedOptionSetLabelLcid)
                [void]$worker.AddArgument($dataverseQueriesModulePath)
                [void]$worker.AddArgument($dataverseApiModulePath)

                $asyncResult = $worker.BeginInvoke()
                [void]$entityWorkItems.Add([pscustomobject]@{
                    EntityLogicalName = $entityLogicalName
                    EntitySchemaName  = $entitySchemaName
                    EntityMetadata    = $entity
                    Worker            = $worker
                    AsyncResult       = $asyncResult
                })
            }

            foreach ($workItem in @($entityWorkItems.ToArray())) {
                try {
                    $workerResults = @($workItem.Worker.EndInvoke($workItem.AsyncResult))
                    if ($workerResults.Count -eq 0) {
                        throw ("No metadata result was returned for entity '{0}'." -f $workItem.EntityLogicalName)
                    }

                    $workerResult = $workerResults[0]
                    Write-Verbose ("Entity '{0}' metadata retrieved. Attributes={1}, OptionSets={2}" -f $workItem.EntityLogicalName, @($workerResult.Attributes).Count, @($workerResult.OptionSetDefinitions).Count)

                    [void]$entityGenerationItems.Add([pscustomobject]@{
                        EntityLogicalName    = [string]$workerResult.EntityLogicalName
                        EntitySchemaName     = [string]$workerResult.EntitySchemaName
                        EntityMetadata       = $workItem.EntityMetadata
                        Attributes           = @($workerResult.Attributes)
                        OptionSetDefinitions = @($workerResult.OptionSetDefinitions)
                    })
                }
                catch {
                    throw ("Could not retrieve metadata for entity '{0}'. Error: {1}" -f $workItem.EntityLogicalName, $_.Exception.Message)
                }
                finally {
                    if ($null -ne $workItem.Worker) {
                        $workItem.Worker.Dispose()
                        $workItem.Worker = $null
                    }
                }
            }
        }
        finally {
            foreach ($workItem in @($entityWorkItems.ToArray())) {
                if ($null -ne $workItem.Worker) {
                    $workItem.Worker.Dispose()
                }
            }

            $runspacePool.Close()
            $runspacePool.Dispose()
        }
    }
}

if ($templateDefinitions.Count -eq 0) {
    throw ("No templates found in template set '{0}'." -f $Template)
}

$generatedOutputFilePathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$generatedFileCount = 0
$skippedExistingFileCount = 0
# Generate output for each (entity × template file) combination.

foreach ($entityGenerationItem in $entityGenerationItems) {
    $entityLogicalName = [string]$entityGenerationItem.EntityLogicalName
    $entitySchemaName = [string]$entityGenerationItem.EntitySchemaName

    Write-Output ("Generating entity: {0}" -f $entityLogicalName)

    foreach ($templateDefinition in @($templateDefinitions.ToArray())) {
        $generatedContent = Convert-EntityTypeScriptContent `
            -TemplateContent ([string]$templateDefinition.TemplateContent) `
            -EntityLogicalName $entityLogicalName `
            -EntitySchemaName $entitySchemaName `
            -EntityMetadata $entityGenerationItem.EntityMetadata `
            -Attributes @($entityGenerationItem.Attributes) `
            -OptionSetDefinitions @($entityGenerationItem.OptionSetDefinitions)

        $outputRelativePath = Resolve-OutputRelativePath `
            -Pattern ([string]$templateDefinition.OutputRelativePathPattern) `
            -EntityLogicalName $entityLogicalName `
            -EntitySchemaName $entitySchemaName `
            -EntityMetadata $entityGenerationItem.EntityMetadata

        $outputFilePath = Join-Path $TypeScriptOutputPath $outputRelativePath
        $outputFilePath = [System.IO.Path]::GetFullPath($outputFilePath)

        if (-not $generatedOutputFilePathSet.Add($outputFilePath)) {
            throw ("Duplicate output path generated: {0}. Check template file names/subfolders and token usage." -f $outputFilePath)
        }

        $outputDirectory = Split-Path -Path $outputFilePath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }

        if ((Test-Path -LiteralPath $outputFilePath) -and (-not $Overwrite)) {
            Write-Verbose ("Skipping existing file because Overwrite=false: {0}" -f $outputFilePath)
            $skippedExistingFileCount++
            continue
        }

        Write-Verbose ("Writing generated file: {0}" -f $outputFilePath)
        Write-Utf8NoBomFile -Path $outputFilePath -Content $generatedContent -LineEnding "CRLF"
        $generatedFileCount++
    }
}

Write-Output "Done. Template-based files were generated."
Write-Output ("Summary: Entities={0}, Templates={1}, FilesWritten={2}, FilesSkippedExisting={3}" -f $entityGenerationItems.Count, $templateDefinitions.Count, $generatedFileCount, $skippedExistingFileCount)
