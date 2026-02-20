Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DataverseSolutionsSelect {
    return "solutionid,uniquename"
}

function Get-DataverseSolutionComponentsSelect {
    return "objectid,componenttype"
}

function Get-DataverseEntityDefinitionDefaultSelect {
    return "LogicalName,SchemaName,DisplayName"
}

function Get-DataverseEntityDefinitionLogicalNameSelect {
    return "LogicalName"
}

function Get-DataverseEntityAttributesDefaultSelect {
    return "LogicalName,SchemaName"
}

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

function Get-NormalizedDataverseEnvironmentUrl {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentUrl
    )

    return $EnvironmentUrl.TrimEnd("/")
}

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
    $escapedSolutionUniqueName = $SolutionUniqueName.Replace("'", "''")
    return "$normalizedEnvironmentUrl/api/data/v9.2/solutions?`$select=$select&`$filter=uniquename eq '$escapedSolutionUniqueName'"
}

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
    $escapedEntityName = $EntityLogicalName.Replace("'", "''")
    return "$normalizedEnvironmentUrl/api/data/v9.2/EntityDefinitions(LogicalName='$escapedEntityName')?`$select=$Select"
}

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
    $escapedEntityName = $EntityLogicalName.Replace("'", "''")
    return "$normalizedEnvironmentUrl/api/data/v9.2/EntityDefinitions(LogicalName='$escapedEntityName')/Attributes?`$select=$Select"
}

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
    $escapedEntityName = $EntityLogicalName.Replace("'", "''")
    $uri = "$normalizedEnvironmentUrl/api/data/v9.2/EntityDefinitions(LogicalName='$escapedEntityName')/Attributes/Microsoft.Dynamics.CRM.$($TypeName)?`$select=$Select"
    if ($ExpandOptionSet.IsPresent) {
        $uri += "&`$expand=OptionSet"
    }

    return $uri
}

Export-ModuleMember -Function Get-DataverseSolutionsByUniqueNameUri, Get-DataverseSolutionComponentsEntityUri, Get-DataverseEntityDefinitionByMetadataIdUri, Get-DataverseEntityDefinitionByMetadataIdFilterUri, Get-DataverseEntityDefinitionByLogicalNameUri, Get-DataverseEntityDefinitionsUri, Get-DataverseEntityAttributesUri, Get-DataverseEntityTypedAttributesUri
