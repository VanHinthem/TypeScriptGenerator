Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
Returns the default `$select list for Dataverse solution lookups.
#>
function Get-DataverseSolutionsSelect {
    return "solutionid,uniquename"
}

<#
.SYNOPSIS
Returns the `$select list for Dataverse solution component lookups.
#>
function Get-DataverseSolutionComponentsSelect {
    return "objectid,componenttype"
}

<#
.SYNOPSIS
Returns the default `$select list for Dataverse entity definition lookups.
#>
function Get-DataverseEntityDefinitionDefaultSelect {
    return "LogicalName,SchemaName,DisplayName"
}

<#
.SYNOPSIS
Returns the minimal `$select list to resolve an entity logical name.
#>
function Get-DataverseEntityDefinitionLogicalNameSelect {
    return "LogicalName"
}

<#
.SYNOPSIS
Returns the default `$select list for Dataverse attribute lookups.
#>
function Get-DataverseEntityAttributesDefaultSelect {
    return "LogicalName,SchemaName"
}

<#
.SYNOPSIS
Returns the `$select list for typed attribute queries.
.DESCRIPTION
Boolean attributes need TrueOption/FalseOption fields in addition to LogicalName.
.PARAMETER TypeName
Dataverse metadata type name.
.OUTPUTS
System.String
#>
function Get-DataverseTypedAttributesSelect {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TypeName
    )

    if ($TypeName -eq "BooleanAttributeMetadata") {
        return "LogicalName,TrueOption,FalseOption"
    }

    return "LogicalName"
}

<#
.SYNOPSIS
Normalizes an environment URL by trimming trailing slashes.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.OUTPUTS
System.String
#>
function Get-NormalizedDataverseEnvironmentUrl {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl
    )

    return $EnvironmentUrl.TrimEnd("/")
}

<#
.SYNOPSIS
Builds the URI to look up a solution by unique name.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER SolutionUniqueName
Unique solution name.
.OUTPUTS
System.String
#>
function Get-DataverseSolutionsByUniqueNameUri {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SolutionUniqueName
    )

    $normalizedEnvironmentUrl = Get-NormalizedDataverseEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
    $select = Get-DataverseSolutionsSelect
    # Escape single quotes for OData string literal safety.
    $escapedSolutionUniqueName = $SolutionUniqueName.Replace("'", "''")
    return "$normalizedEnvironmentUrl/api/data/v9.2/solutions?`$select=$select&`$filter=uniquename eq '$escapedSolutionUniqueName'"
}

<#
.SYNOPSIS
Builds the URI to query entity components in a solution.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER SolutionId
Solution GUID.
.PARAMETER UseGuidLiteral
Uses explicit guid'<value>' OData literal in filter.
.OUTPUTS
System.String
#>
function Get-DataverseSolutionComponentsEntityUri {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SolutionId,
        [switch]$UseGuidLiteral
    )

    $normalizedEnvironmentUrl = Get-NormalizedDataverseEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
    $select = Get-DataverseSolutionComponentsSelect
    $solutionIdFilterValue = if ($UseGuidLiteral.IsPresent) { "guid'$SolutionId'" } else { $SolutionId }
    return "$normalizedEnvironmentUrl/api/data/v9.2/solutioncomponents?`$select=$select&`$filter=_solutionid_value eq $solutionIdFilterValue and componenttype eq 1"
}

<#
.SYNOPSIS
Builds the URI to query an entity definition by metadata id path form.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER MetadataId
Entity metadata id GUID.
.OUTPUTS
System.String
#>
function Get-DataverseEntityDefinitionByMetadataIdUri {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$MetadataId
    )

    $normalizedEnvironmentUrl = Get-NormalizedDataverseEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
    $select = Get-DataverseEntityDefinitionLogicalNameSelect
    return "$normalizedEnvironmentUrl/api/data/v9.2/EntityDefinitions($MetadataId)?`$select=$select"
}

<#
.SYNOPSIS
Builds the URI to query an entity definition by metadata id filter form.
.DESCRIPTION
Used as a compatibility fallback where key-segment lookup fails.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER MetadataId
Entity metadata id GUID.
.OUTPUTS
System.String
#>
function Get-DataverseEntityDefinitionByMetadataIdFilterUri {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$MetadataId
    )

    $normalizedEnvironmentUrl = Get-NormalizedDataverseEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
    $select = Get-DataverseEntityDefinitionLogicalNameSelect
    return "$normalizedEnvironmentUrl/api/data/v9.2/EntityDefinitions?`$select=$select&`$filter=MetadataId eq guid'$MetadataId'"
}

<#
.SYNOPSIS
Builds the URI to query an entity definition by logical name.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER EntityLogicalName
Entity logical name.
.PARAMETER Select
Optional select projection.
.OUTPUTS
System.String
#>
function Get-DataverseEntityDefinitionByLogicalNameUri {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntityLogicalName,
        [string]$Select
    )

    $normalizedEnvironmentUrl = Get-NormalizedDataverseEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
    if ([string]::IsNullOrWhiteSpace($Select)) {
        $Select = Get-DataverseEntityDefinitionDefaultSelect
    }
    # Escape single quotes for OData string literal safety.
    $escapedEntityName = $EntityLogicalName.Replace("'", "''")
    return "$normalizedEnvironmentUrl/api/data/v9.2/EntityDefinitions(LogicalName='$escapedEntityName')?`$select=$Select"
}

<#
.SYNOPSIS
Builds the URI to query entity definitions.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER Select
Optional select projection.
.PARAMETER Filter
Optional OData filter expression.
.OUTPUTS
System.String
#>
function Get-DataverseEntityDefinitionsUri {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [string]$Select,
        [string]$Filter
    )

    $normalizedEnvironmentUrl = Get-NormalizedDataverseEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
    if ([string]::IsNullOrWhiteSpace($Select)) {
        $Select = Get-DataverseEntityDefinitionDefaultSelect
    }
    $uri = "$normalizedEnvironmentUrl/api/data/v9.2/EntityDefinitions?`$select=$Select"
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $uri += "&`$filter=$Filter"
    }

    return $uri
}

<#
.SYNOPSIS
Builds the URI to query attributes for a specific entity.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER EntityLogicalName
Entity logical name.
.PARAMETER Select
Optional select projection.
.OUTPUTS
System.String
#>
function Get-DataverseEntityAttributesUri {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntityLogicalName,
        [string]$Select
    )

    $normalizedEnvironmentUrl = Get-NormalizedDataverseEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
    if ([string]::IsNullOrWhiteSpace($Select)) {
        $Select = Get-DataverseEntityAttributesDefaultSelect
    }
    # Escape single quotes for OData string literal safety.
    $escapedEntityName = $EntityLogicalName.Replace("'", "''")
    return "$normalizedEnvironmentUrl/api/data/v9.2/EntityDefinitions(LogicalName='$escapedEntityName')/Attributes?`$select=$Select"
}

<#
.SYNOPSIS
Builds the URI to query typed attributes for a specific entity.
.PARAMETER EnvironmentUrl
Dataverse organization URL.
.PARAMETER EntityLogicalName
Entity logical name.
.PARAMETER TypeName
Dataverse metadata type name, for example PicklistAttributeMetadata.
.PARAMETER Select
Optional select projection.
.PARAMETER ExpandOptionSet
Adds `$expand=OptionSet`.
.OUTPUTS
System.String
#>
function Get-DataverseEntityTypedAttributesUri {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntityLogicalName,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TypeName,
        [string]$Select,
        [switch]$ExpandOptionSet
    )

    $normalizedEnvironmentUrl = Get-NormalizedDataverseEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
    if ([string]::IsNullOrWhiteSpace($Select)) {
        $Select = Get-DataverseTypedAttributesSelect -TypeName $TypeName
    }
    # Escape single quotes for OData string literal safety.
    $escapedEntityName = $EntityLogicalName.Replace("'", "''")
    $uri = "$normalizedEnvironmentUrl/api/data/v9.2/EntityDefinitions(LogicalName='$escapedEntityName')/Attributes/Microsoft.Dynamics.CRM.$($TypeName)?`$select=$Select"
    if ($ExpandOptionSet.IsPresent) {
        $uri += "&`$expand=OptionSet"
    }

    return $uri
}

Export-ModuleMember -Function Get-DataverseSolutionsByUniqueNameUri, Get-DataverseSolutionComponentsEntityUri, Get-DataverseEntityDefinitionByMetadataIdUri, Get-DataverseEntityDefinitionByMetadataIdFilterUri, Get-DataverseEntityDefinitionByLogicalNameUri, Get-DataverseEntityDefinitionsUri, Get-DataverseEntityAttributesUri, Get-DataverseEntityTypedAttributesUri
