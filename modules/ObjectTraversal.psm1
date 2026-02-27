Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
Reads a dictionary value using case-insensitive key comparison.
.PARAMETER Dictionary
Dictionary to search.
.PARAMETER Key
Target key.
.OUTPUTS
PSCustomObject with `Found` and `Value`.
#>
function Get-DictionaryValueCaseInsensitive {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Dictionary,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Key
    )

    if ($Dictionary.Contains($Key)) {
        return [pscustomobject]@{
            Found = $true
            Value = $Dictionary[$Key]
        }
    }

    foreach ($candidateKey in $Dictionary.Keys) {
        if ([string]$candidateKey -ieq $Key) {
            return [pscustomobject]@{
                Found = $true
                Value = $Dictionary[$candidateKey]
            }
        }
    }

    return [pscustomobject]@{
        Found = $false
        Value = $null
    }
}

<#
.SYNOPSIS
Reads an object property value using case-insensitive property comparison.
.PARAMETER InputObject
Object to inspect.
.PARAMETER PropertyName
Property name to search.
.OUTPUTS
PSCustomObject with `Found` and `Value`.
#>
function Get-ObjectPropertyValueCaseInsensitive {
    param(
        [AllowNull()]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return [pscustomobject]@{
            Found = $false
            Value = $null
        }
    }

    try {
        $property = $InputObject.PSObject.Properties[$PropertyName]
        if ($null -ne $property) {
            return [pscustomobject]@{
                Found = $true
                Value = $property.Value
            }
        }

        foreach ($candidate in $InputObject.PSObject.Properties) {
            if ($null -eq $candidate) {
                continue
            }

            if ([string]$candidate.Name -ieq $PropertyName) {
                return [pscustomobject]@{
                    Found = $true
                    Value = $candidate.Value
                }
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Found = $false
            Value = $null
        }
    }

    return [pscustomobject]@{
        Found = $false
        Value = $null
    }
}

Export-ModuleMember -Function Get-DictionaryValueCaseInsensitive, Get-ObjectPropertyValueCaseInsensitive
