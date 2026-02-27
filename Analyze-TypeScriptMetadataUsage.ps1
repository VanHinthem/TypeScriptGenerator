[CmdletBinding()]
param(
    [string[]]$SourceFolders,

    [ValidateSet("auto", "default", "onefile")]
    [string]$Template = "auto",

    [string]$GeneratedMetadataPath = ".\generated",
    [bool]$DefaultRecursive = $true,
    [switch]$PruneMetadata,
    [string]$SettingsPath = ".\Analyze-TypeScriptMetadataUsage.settings.psd1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
trap {
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $lineText = $_.InvocationInfo.Line
    $message = $_.Exception.Message
    Write-Error ("Unhandled error on line {0}: {1}" -f $lineNumber, $message)
    if (-not [string]::IsNullOrWhiteSpace($lineText)) {
        Write-Error ("Line: {0}" -f $lineText.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-Error ("Stack: {0}" -f $_.ScriptStackTrace)
    }
    break
}

<#
.SYNOPSIS
Creates a case-insensitive HashSet[string].
#>
function Get-StringSet {
    return ,(New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase))
}

<#
.SYNOPSIS
Returns a safe count for scalar, collection, or null values.
#>
function Get-CountSafe {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 0 }
    if ($Value -is [System.Collections.ICollection]) { return $Value.Count }
    return (@($Value | ForEach-Object { $_ })).Count
}

<#
.SYNOPSIS
Safely checks set membership for dynamic set/value input.
#>
function Test-SetMembership {
    param(
        [AllowNull()]
        [object]$Set,
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Set -or $null -eq $Value) { return $false }
    try {
        return [bool]$Set.Contains($Value)
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
Normalizes string or enumerable input into a case-insensitive string set.
#>
function Convert-ToStringSet {
    param([AllowNull()][object]$Value)

    $set = Get-StringSet
    if ($null -eq $Value) { return ,$set }

    if ($Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            [void]$set.Add($Value.Trim())
        }
        return ,$set
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($entry in $Value) {
            if ($null -eq $entry) { continue }
            $entryText = [string]$entry
            if (-not [string]::IsNullOrWhiteSpace($entryText)) {
                [void]$set.Add($entryText.Trim())
            }
        }

        return ,$set
    }

    $single = [string]$Value
    if (-not [string]::IsNullOrWhiteSpace($single)) {
        [void]$set.Add($single.Trim())
    }

    return ,$set
}

function Get-SettingsPropertyValue {
    param(
        [AllowNull()]
        [object]$Settings,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Settings) { return $null }

    if ($Settings -is [System.Collections.IDictionary]) {
        foreach ($key in $Settings.Keys) {
            if ([string]$key -ieq $Name) {
                return $Settings[$key]
            }
        }

        return $null
    }

    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Convert-ToStringArray {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value.Trim())
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $Value) {
            if ($null -eq $entry) { continue }
            $entryText = [string]$entry
            if (-not [string]::IsNullOrWhiteSpace($entryText)) {
                [void]$items.Add($entryText.Trim())
            }
        }
        return $items.ToArray()
    }

    $singleText = [string]$Value
    if ([string]::IsNullOrWhiteSpace($singleText)) { return @() }
    return @($singleText.Trim())
}

function Convert-ToBool {
    param(
        [AllowNull()]
        [object]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if ($null -eq $Value) {
        throw ("Value for '{0}' is null." -f $Context)
    }

    if ($Value -is [bool]) { return [bool]$Value }
    return Convert-StringToBool -Value ([string]$Value) -Context $Context
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BasePath -ChildPath $Path))
}

function Convert-StringToBool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $v = $Value.Trim().ToLowerInvariant()
    if ($v -in @("true", "1", "yes", "y")) { return $true }
    if ($v -in @("false", "0", "no", "n")) { return $false }
    throw ("Invalid boolean '{0}' in {1}. Use true/false." -f $Value, $Context)
}

<#
.SYNOPSIS
Parses and validates source folder scan entries in format '<path>|<recursive>'.
#>
function Convert-ScanTargetEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Entries,
        [Parameter(Mandatory = $true)]
        [bool]$DefaultRecursive,
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $Entries) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $separatorIndex = $entry.IndexOf("|", [System.StringComparison]::Ordinal)
        $rawPath = if ($separatorIndex -ge 0) { $entry.Substring(0, $separatorIndex).Trim() } else { $entry.Trim() }
        if ([string]::IsNullOrWhiteSpace($rawPath)) {
            throw ("SourceFolders entry has no path: '{0}'." -f $entry)
        }

        $resolvedPath = Resolve-AbsolutePath -Path $rawPath -BasePath $BasePath
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
            throw ("Source folder not found: {0}" -f $resolvedPath)
        }

        $recursive = $DefaultRecursive
        if ($separatorIndex -ge 0) {
            $recursiveText = $entry.Substring($separatorIndex + 1).Trim()
            $recursive = Convert-StringToBool -Value $recursiveText -Context ("SourceFolders entry '{0}'" -f $entry)
        }

        [void]$items.Add([pscustomobject]@{
                Path      = $resolvedPath
                Recursive = $recursive
            })
    }

    return $items.ToArray()
}

function Test-IsChildPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ParentPath
    )

    $p = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd("\", "/")
    return $p.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Find-CloseBrace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [int]$OpenBraceIndex
    )

    $depth = 0
    for ($i = $OpenBraceIndex; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "{") { $depth++; continue }
        if ($Text[$i] -eq "}") {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }

    return -1
}

function Get-ObjectAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $m = [regex]::Match($Text, $Pattern)
    if (-not $m.Success) { return $null }

    $openOffset = $m.Value.LastIndexOf("{", [System.StringComparison]::Ordinal)
    if ($openOffset -lt 0) { throw ("No opening brace for pattern: {0}" -f $Pattern) }

    $open = $m.Index + $openOffset
    $close = Find-CloseBrace -Text $Text -OpenBraceIndex $open
    if ($close -lt 0) { throw ("No matching closing brace for pattern: {0}" -f $Pattern) }

    return [pscustomobject]@{
        MatchStart = $m.Index
        MatchLength = $m.Length
        Open  = $open
        Close = $close
        Body  = $Text.Substring($open + 1, $close - $open - 1)
    }
}

function Get-TextWithoutObjectAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Assignment
    )

    $lineStart = 0
    if ($Assignment.MatchStart -gt 0) {
        $prevLineBreak = $Text.LastIndexOf("`n", $Assignment.MatchStart - 1)
        if ($prevLineBreak -ge 0) {
            $lineStart = $prevLineBreak + 1
        }
    }

    $removeEnd = [Math]::Min($Assignment.Close + 1, $Text.Length)
    if ($removeEnd -lt $Text.Length) {
        $tail = $Text.Substring($removeEnd)
        $tailMatch = [regex]::Match($tail, "^[ \t]*(?:as\s+const[ \t]*)?;[ \t]*(?:\r?\n)?")
        if ($tailMatch.Success) {
            $removeEnd += $tailMatch.Length
        }
    }

    if ($lineStart -lt 0) { $lineStart = 0 }
    if ($removeEnd -lt $lineStart) { $removeEnd = $lineStart }
    if ($removeEnd -gt $Text.Length) { $removeEnd = $Text.Length }

    return $Text.Substring(0, $lineStart) + $Text.Substring($removeEnd)
}

function Get-BraceDelta {
    param([Parameter(Mandatory = $true)][string]$Line)
    return (([regex]::Matches($Line, "\{")).Count - ([regex]::Matches($Line, "\}")).Count)
}

function Get-TopLevelEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Body,
        [Parameter(Mandatory = $true)]
        [string]$NewLine
    )

    $entries = New-Object System.Collections.Generic.List[object]
    $lines = $Body.Replace("`r", "") -split "`n", -1

    $inEntry = $false
    $depth = 0
    $key = ""
    $entryLines = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if (-not $inEntry) {
            if ($line -match "^\s*(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*:") {
                $inEntry = $true
                $key = $matches["key"]
                $depth = 0
                $entryLines.Clear()
                [void]$entryLines.Add($line)
                $depth += Get-BraceDelta -Line $line
                if ($depth -le 0) {
                    [void]$entries.Add([pscustomobject]@{ Key = $key; Text = ($entryLines -join $NewLine).TrimEnd() })
                    $inEntry = $false
                    $entryLines.Clear()
                }
            }
            continue
        }

        [void]$entryLines.Add($line)
        $depth += Get-BraceDelta -Line $line
        if ($depth -le 0) {
            [void]$entries.Add([pscustomobject]@{ Key = $key; Text = ($entryLines -join $NewLine).TrimEnd() })
            $inEntry = $false
            $entryLines.Clear()
        }
    }

    return $entries.ToArray()
}

function Get-ObjectKeysByPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $set = Get-StringSet
    $obj = Get-ObjectAssignment -Text $Text -Pattern $Pattern
    if ($null -eq $obj) { return ,$set }

    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    foreach ($entry in (Get-TopLevelEntry -Body $obj.Body -NewLine $nl)) {
        [void]$set.Add($entry.Key)
    }

    return ,$set
}

function Get-NamedImportSpecifier {
    param([Parameter(Mandatory = $true)][string]$Clause)

    # Intentionally parses only named import clauses: { A, B as C }.
    # Namespace/default import forms are handled separately by higher-level binding logic when needed.
    $m = [regex]::Match($Clause, "(?ms)\{(?<named>[\s\S]*?)\}")
    if (-not $m.Success) { return @() }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($part in ($m.Groups["named"].Value -split ",")) {
        $s = [regex]::Replace($part, "/\*[\s\S]*?\*/", "").Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $sm = [regex]::Match($s, "^(?:type\s+)?(?<imported>[A-Za-z_$][A-Za-z0-9_$]*)(?:\s+as\s+(?<local>[A-Za-z_$][A-Za-z0-9_$]*))?$")
        if (-not $sm.Success) { continue }
        $imported = $sm.Groups["imported"].Value
        $local = $sm.Groups["local"].Value
        if ([string]::IsNullOrWhiteSpace($local)) { $local = $imported }
        [void]$items.Add([pscustomobject]@{ Imported = $imported; Local = $local })
    }

    return $items.ToArray()
}

function Get-ImportLeaf {
    param([Parameter(Mandatory = $true)][string]$Source)
    if ([string]::IsNullOrWhiteSpace($Source)) { return "" }
    $s = $Source.Replace("\", "/")
    $i = $s.LastIndexOf("/")
    $leaf = if ($i -ge 0) { $s.Substring($i + 1) } else { $s }
    foreach ($suffix in @(".d.ts", ".tsx", ".ts", ".jsx", ".js", ".mjs", ".cjs")) {
        if ($leaf.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $leaf.Substring(0, $leaf.Length - $suffix.Length)
        }
    }
    return $leaf
}

function Get-EntityLogicalNameFromEntityMetadataFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Fallback
    )

    $logicalNameMatch = [regex]::Match($Content, '(?im)\bpublic\s+static\s+EntityLogicalName\s*=\s*["''](?<name>[^"'']+)["'']')
    if ($logicalNameMatch.Success) {
        $logicalName = [string]$logicalNameMatch.Groups["name"].Value
        if (-not [string]::IsNullOrWhiteSpace($logicalName)) {
            return $logicalName.Trim()
        }
    }

    $classMatch = [regex]::Match($Content, '(?im)^\s*export\s+class\s+(?<name>[A-Za-z_$][A-Za-z0-9_$]*)\b')
    if ($classMatch.Success) {
        $className = [string]$classMatch.Groups["name"].Value
        if (-not [string]::IsNullOrWhiteSpace($className)) {
            return $className.Trim()
        }
    }

    return $Fallback
}

function Get-EntityClassNameFromEntityMetadataFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Fallback
    )

    $classMatch = [regex]::Match($Content, '(?im)^\s*export\s+class\s+(?<name>[A-Za-z_$][A-Za-z0-9_$]*)\b')
    if ($classMatch.Success) {
        $className = [string]$classMatch.Groups["name"].Value
        if (-not [string]::IsNullOrWhiteSpace($className)) {
            return $className.Trim()
        }
    }

    return $Fallback
}

function Get-EntityLogicalNameFromOptionSetMetadataFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [AllowEmptyString()]
        [Parameter(Mandatory = $true)]
        [string]$Fallback
    )

    $mapMatch = [regex]::Match($Content, '(?im)^\s*export\s+const\s+(?<name>[A-Za-z_$][A-Za-z0-9_$]*)OptionSets\s*=')
    if ($mapMatch.Success) {
        $logicalName = [string]$mapMatch.Groups["name"].Value
        if (-not [string]::IsNullOrWhiteSpace($logicalName)) {
            return $logicalName.Trim()
        }
    }

    return $Fallback
}

function Get-AttrsFromEntityAlias {
    param([Parameter(Mandatory = $true)][string]$Content, [Parameter(Mandatory = $true)][string]$Alias)
    $set = Get-StringSet
    $a = [regex]::Escape($Alias)
    $dot = "(?<![A-Za-z0-9_$]){0}\s*(?:\?\.|\.)\s*attributes\s*(?:\?\.|\.)\s*(?<attr>[A-Za-z_][A-Za-z0-9_]*)" -f $a
    $bracket = "(?<![A-Za-z0-9_$]){0}\s*(?:\?\.|\.)\s*attributes\s*(?:\?\.)?\s*\[\s*['""](?<attr>[^'""]+)['""]\s*\]" -f $a
    $destructure = "(?ms)(?:const|let|var)\s*\{(?<fields>[^}]+)\}\s*=\s*" + $a + "\s*(?:\?\.|\.)\s*attributes\b"

    foreach ($m in [regex]::Matches($Content, $dot)) { [void]$set.Add($m.Groups["attr"].Value) }
    foreach ($m in [regex]::Matches($Content, $bracket)) { [void]$set.Add($m.Groups["attr"].Value) }
    foreach ($m in [regex]::Matches($Content, $destructure)) {
        foreach ($field in ($m.Groups["fields"].Value -split ",")) {
            $f = $field.Trim()
            if ([string]::IsNullOrWhiteSpace($f) -or $f.StartsWith("...")) { continue }
            $f = [regex]::Replace($f, "\s*=.*$", "").Trim()
            $left = ($f -split ":", 2)[0].Trim()
            if ($left -match "^[A-Za-z_][A-Za-z0-9_]*$") { [void]$set.Add($left) }
        }
    }

    return @($set)
}

function Get-AttrsFromOptionSetAlias {
    param([Parameter(Mandatory = $true)][string]$Content, [Parameter(Mandatory = $true)][string]$Alias)
    $set = Get-StringSet
    $a = [regex]::Escape($Alias)
    $dot = "(?<![A-Za-z0-9_$]){0}\s*(?:\?\.|\.)\s*(?<attr>[A-Za-z_][A-Za-z0-9_]*)" -f $a
    $bracket = "(?<![A-Za-z0-9_$]){0}\s*(?:\?\.)?\s*\[\s*['""](?<attr>[^'""]+)['""]\s*\]" -f $a
    foreach ($m in [regex]::Matches($Content, $dot)) { [void]$set.Add($m.Groups["attr"].Value) }
    foreach ($m in [regex]::Matches($Content, $bracket)) { [void]$set.Add($m.Groups["attr"].Value) }
    return @($set)
}

function Get-OptionSetsFromEntityAlias {
    param([Parameter(Mandatory = $true)][string]$Content, [Parameter(Mandatory = $true)][string]$Alias)
    $set = Get-StringSet
    $a = [regex]::Escape($Alias)
    $dot = "(?<![A-Za-z0-9_$]){0}\s*(?:\?\.|\.)\s*optionsets\s*(?:\?\.|\.)\s*(?<attr>[A-Za-z_][A-Za-z0-9_]*)" -f $a
    $bracket = "(?<![A-Za-z0-9_$]){0}\s*(?:\?\.|\.)\s*optionsets\s*(?:\?\.)?\s*\[\s*['""](?<attr>[^'""]+)['""]\s*\]" -f $a
    $destructure = "(?ms)(?:const|let|var)\s*\{(?<fields>[^}]+)\}\s*=\s*" + $a + "\s*(?:\?\.|\.)\s*optionsets\b"

    foreach ($m in [regex]::Matches($Content, $dot)) { [void]$set.Add($m.Groups["attr"].Value) }
    foreach ($m in [regex]::Matches($Content, $bracket)) { [void]$set.Add($m.Groups["attr"].Value) }
    foreach ($m in [regex]::Matches($Content, $destructure)) {
        foreach ($field in ($m.Groups["fields"].Value -split ",")) {
            $f = $field.Trim()
            if ([string]::IsNullOrWhiteSpace($f) -or $f.StartsWith("...")) { continue }
            $f = [regex]::Replace($f, "\s*=.*$", "").Trim()
            $left = ($f -split ":", 2)[0].Trim()
            if ($left -match "^[A-Za-z_][A-Za-z0-9_]*$") { [void]$set.Add($left) }
        }
    }

    return @($set)
}

function Set-EntryTrailingComma {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$EntryText,
        [Parameter(Mandatory = $true)]
        [bool]$HasTrailingComma,
        [Parameter(Mandatory = $true)]
        [string]$NewLine
    )

    $lines = $EntryText.Replace("`r", "") -split "`n", -1
    $lastNonEmptyLineIndex = -1
    for ($lineIndex = $lines.Length - 1; $lineIndex -ge 0; $lineIndex--) {
        if (-not [string]::IsNullOrWhiteSpace($lines[$lineIndex])) {
            $lastNonEmptyLineIndex = $lineIndex
            break
        }
    }

    if ($lastNonEmptyLineIndex -lt 0) {
        return $EntryText
    }

    $targetLine = $lines[$lastNonEmptyLineIndex].TrimEnd()
    if ($HasTrailingComma) {
        if (-not $targetLine.EndsWith(",")) {
            $targetLine += ","
        }
    }
    else {
        $targetLine = $targetLine -replace ",+$", ""
    }

    $lines[$lastNonEmptyLineIndex] = $targetLine
    return [string]::Join($NewLine, $lines)
}

function Get-NormalizedTopLevelEntryTexts {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries,
        [Parameter(Mandatory = $true)]
        [string]$NewLine
    )

    $texts = New-Object System.Collections.Generic.List[string]
    for ($entryIndex = 0; $entryIndex -lt $Entries.Count; $entryIndex++) {
        $entryText = [string]$Entries[$entryIndex].Text
        $hasTrailingComma = $entryIndex -lt ($Entries.Count - 1)
        $normalizedText = Set-EntryTrailingComma -EntryText $entryText -HasTrailingComma $hasTrailingComma -NewLine $NewLine
        [void]$texts.Add($normalizedText)
    }

    return $texts.ToArray()
}

function Select-ObjectByKeepKey {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [AllowNull()][object]$Keep,
        [bool]$RemoveAssignmentWhenEmpty = $false
    )

    $keepSet = Convert-ToStringSet -Value $Keep

    # Locate object assignment block once, then keep/remove top-level entries by key.
    $obj = Get-ObjectAssignment -Text $Text -Pattern $Pattern
    if ($null -eq $obj) {
        return [pscustomobject]@{
            Found = $false; Text = $Text; Existing = @(); Kept = @(); Removed = @()
        }
    }

    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $entries = Get-TopLevelEntry -Body $obj.Body -NewLine $nl
    $kept = New-Object System.Collections.Generic.List[object]
    $existingKeys = @($entries | ForEach-Object { $_.Key })
    $keptKeys = New-Object System.Collections.Generic.List[string]
    $removedKeys = New-Object System.Collections.Generic.List[string]

    foreach ($e in $entries) {
        if ($keepSet.Contains($e.Key)) {
            [void]$kept.Add($e)
            [void]$keptKeys.Add($e.Key)
        }
        else {
            [void]$removedKeys.Add($e.Key)
        }
    }

    if ($RemoveAssignmentWhenEmpty -and $kept.Count -eq 0) {
        $newText = Get-TextWithoutObjectAssignment -Text $Text -Assignment $obj
        return [pscustomobject]@{
            Found = $true; Text = $newText; Existing = $existingKeys; Kept = $keptKeys.ToArray(); Removed = $removedKeys.ToArray()
        }
    }

    $newBody = $nl
    if ($kept.Count -gt 0) {
        $normalizedKeptTexts = @(Get-NormalizedTopLevelEntryTexts -Entries @($kept.ToArray()) -NewLine $nl)
        $newBody = $nl + ($normalizedKeptTexts -join $nl) + $nl
    }

    $closingIndent = ""
    if ($obj.Close -gt 0) {
        $previousNewLineIndex = $Text.LastIndexOf("`n", $obj.Close - 1)
        if ($previousNewLineIndex -ge 0) {
            $indentStart = $previousNewLineIndex + 1
            if ($indentStart -le $obj.Close) {
                $candidateIndent = $Text.Substring($indentStart, $obj.Close - $indentStart)
                if ($candidateIndent -match "^[ \t]*$") {
                    $closingIndent = $candidateIndent
                }
            }
        }
    }

    $newText = $Text.Substring(0, $obj.Open + 1) + $newBody + $closingIndent + $Text.Substring($obj.Close)
    return [pscustomobject]@{
        Found = $true; Text = $newText; Existing = $existingKeys; Kept = $keptKeys.ToArray(); Removed = $removedKeys.ToArray()
    }
}

function Get-TextWithoutOptionSetConstant {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Entity,
        [Parameter(Mandatory = $true)][string[]]$Attributes
    )

    $newText = $Text
    foreach ($attr in $Attributes) {
        $constName = $Entity + "OptionSet_" + $attr
        $pattern = "(?ms)^export\s+const\s+" + [regex]::Escape($constName) + "\s*=\s*\{[\s\S]*?\}\s+as\s+const;\s*(?:\r?\n)?"
        $newText = [regex]::Replace($newText, $pattern, "")
    }

    return $newText
}

function Invoke-PrunePass {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Entities,

        [Parameter(Mandatory = $true)]
        [hashtable]$EntityFiles,

        [Parameter(Mandatory = $true)]
        [hashtable]$OptionSetFiles,

        [Parameter(Mandatory = $true)]
        [hashtable]$UsedAttrsByEntity,

        [Parameter(Mandatory = $true)]
        [hashtable]$UsedOptionSetsByEntity,

        [Parameter(Mandatory = $true)]
        [bool]$ScanEntityOptionSets,

        [Parameter(Mandatory = $true)]
        [bool]$ScanSeparateOptionSetFiles
    )

    # Prune each entity file first, then optional separate optionset file.
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($entity in (@($Entities) | Sort-Object)) {
        if (-not $EntityFiles.ContainsKey($entity)) { continue }

        $keepAttrs = Get-StringSet
        if ($UsedAttrsByEntity.ContainsKey($entity) -and $null -ne $UsedAttrsByEntity[$entity]) {
            foreach ($a in $UsedAttrsByEntity[$entity]) {
                if ($null -ne $a) {
                    [void]$keepAttrs.Add([string]$a)
                }
            }
        }

        $keepOptionSets = Get-StringSet
        if ($UsedOptionSetsByEntity.ContainsKey($entity) -and $null -ne $UsedOptionSetsByEntity[$entity]) {
            foreach ($o in $UsedOptionSetsByEntity[$entity]) {
                if ($null -ne $o) {
                    [void]$keepOptionSets.Add([string]$o)
                }
            }
        }

        $entityContent = Get-Content -LiteralPath $EntityFiles[$entity] -Raw
        $attrResult = Select-ObjectByKeepKey -Text $entityContent -Pattern "public\s+static\s+attributes\s*=\s*\{" -Keep $keepAttrs -RemoveAssignmentWhenEmpty $true
        $entityContent = $attrResult.Text

        $optInClassResult = [pscustomobject]@{
            Existing = @()
            Kept = @()
            Removed = @()
            Text = $entityContent
        }
        if ($ScanEntityOptionSets) {
            $optInClassResult = Select-ObjectByKeepKey -Text $entityContent -Pattern "public\s+static\s+optionsets\s*=\s*\{" -Keep $keepOptionSets -RemoveAssignmentWhenEmpty $true
            $entityContent = $optInClassResult.Text
        }

        $entityChanged = $entityContent -ne (Get-Content -LiteralPath $EntityFiles[$entity] -Raw)
        if ($entityChanged) { Write-Utf8NoBom -Path $EntityFiles[$entity] -Content $entityContent }

        [void]$items.Add([pscustomobject]@{
                EntityLogicalName = $entity
                Target = "EntityFile"
                FilePath = $EntityFiles[$entity]
                Changed = $entityChanged
                AttributeExistingCount = $attrResult.Existing.Count
                AttributeKeptCount = $attrResult.Kept.Count
                AttributeRemovedCount = $attrResult.Removed.Count
                OptionSetExistingCount = $optInClassResult.Existing.Count
                OptionSetKeptCount = $optInClassResult.Kept.Count
                OptionSetRemovedCount = $optInClassResult.Removed.Count
            })

        if ($ScanSeparateOptionSetFiles -and $OptionSetFiles.ContainsKey($entity)) {
            $osPath = $OptionSetFiles[$entity]
            $originalOsContent = Get-Content -LiteralPath $osPath -Raw
            $osContent = $originalOsContent
            $mapPattern = "export\s+const\s+" + [regex]::Escape($entity + "OptionSets") + "\s*=\s*\{"
            $mapResult = Select-ObjectByKeepKey -Text $osContent -Pattern $mapPattern -Keep $keepOptionSets -RemoveAssignmentWhenEmpty $true
            $osContent = $mapResult.Text
            $osDeleted = $false
            $osChanged = $false

            if ($mapResult.Found -and $mapResult.Kept.Count -eq 0) {
                if (Test-Path -LiteralPath $osPath -PathType Leaf) {
                    Remove-Item -LiteralPath $osPath -Force
                    $osDeleted = $true
                    $osChanged = $true
                }
            }
            else {
                if ($mapResult.Removed.Count -gt 0) {
                    $osContent = Get-TextWithoutOptionSetConstant -Text $osContent -Entity $entity -Attributes @($mapResult.Removed)
                }

                $osChanged = $osContent -ne $originalOsContent
                if ($osChanged) { Write-Utf8NoBom -Path $osPath -Content $osContent }
            }

            [void]$items.Add([pscustomobject]@{
                    EntityLogicalName = $entity
                    Target = "OptionSetFile"
                    FilePath = $osPath
                    Changed = $osChanged
                    Deleted = $osDeleted
                    OptionSetExistingCount = $mapResult.Existing.Count
                    OptionSetKeptCount = $mapResult.Kept.Count
                    OptionSetRemovedCount = $mapResult.Removed.Count
                })
        }
    }

    return $items.ToArray()
}

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$resolvedSettingsPath = Resolve-AbsolutePath -Path $SettingsPath -BasePath $scriptRoot
if (-not $resolvedSettingsPath.EndsWith(".psd1", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("SettingsPath must point to a .psd1 file. Current value: {0}" -f $resolvedSettingsPath)
}

$settingsPathExplicitlyProvided = $PSBoundParameters.ContainsKey("SettingsPath")
$settings = $null

if (Test-Path -LiteralPath $resolvedSettingsPath -PathType Leaf) {
    try {
        $settings = Import-PowerShellDataFile -LiteralPath $resolvedSettingsPath -ErrorAction Stop
    }
    catch {
        throw ("Could not parse settings file '{0}': {1}" -f $resolvedSettingsPath, $_.Exception.Message)
    }
}
elseif ($settingsPathExplicitlyProvided) {
    throw ("Settings file not found: {0}" -f $resolvedSettingsPath)
}

# Settings precedence: command args override settings values.
if ((Get-CountSafe -Value $SourceFolders) -eq 0) {
    $settingsSourceFolders = Convert-ToStringArray -Value (Get-SettingsPropertyValue -Settings $settings -Name "SourceFolders")
    if ((Get-CountSafe -Value $settingsSourceFolders) -gt 0) {
        $SourceFolders = $settingsSourceFolders
    }
}

if ((Get-CountSafe -Value $SourceFolders) -eq 0) {
    throw ("No SourceFolders provided. Use -SourceFolders or set SourceFolders in '{0}'." -f $resolvedSettingsPath)
}

if (-not $PSBoundParameters.ContainsKey("Template")) {
    $settingsTemplate = [string](Get-SettingsPropertyValue -Settings $settings -Name "Template")
    if (-not [string]::IsNullOrWhiteSpace($settingsTemplate)) {
        $Template = $settingsTemplate.Trim().ToLowerInvariant()
    }
}

if ($Template -notin @("auto", "default", "onefile")) {
    throw ("Invalid Template value '{0}'. Allowed values: auto, default, onefile." -f $Template)
}

if (-not $PSBoundParameters.ContainsKey("GeneratedMetadataPath")) {
    $settingsGeneratedPath = [string](Get-SettingsPropertyValue -Settings $settings -Name "GeneratedMetadataPath")
    if (-not [string]::IsNullOrWhiteSpace($settingsGeneratedPath)) {
        $GeneratedMetadataPath = $settingsGeneratedPath.Trim()
    }
}

if (-not $PSBoundParameters.ContainsKey("DefaultRecursive")) {
    $settingsDefaultRecursive = Get-SettingsPropertyValue -Settings $settings -Name "DefaultRecursive"
    if ($null -ne $settingsDefaultRecursive) {
        $DefaultRecursive = Convert-ToBool -Value $settingsDefaultRecursive -Context "DefaultRecursive"
    }
}

$pruneEnabled = [bool]$PruneMetadata
if (-not $PSBoundParameters.ContainsKey("PruneMetadata")) {
    $settingsPrune = Get-SettingsPropertyValue -Settings $settings -Name "PruneMetadata"
    if ($null -ne $settingsPrune) {
        $pruneEnabled = Convert-ToBool -Value $settingsPrune -Context "PruneMetadata"
    }
}

$generatedPath = Resolve-AbsolutePath -Path $GeneratedMetadataPath -BasePath $scriptRoot
if (-not (Test-Path -LiteralPath $generatedPath -PathType Container)) {
    throw ("Generated metadata folder not found: {0}" -f $generatedPath)
}

$targets = @(Convert-ScanTargetEntries -Entries $SourceFolders -DefaultRecursive $DefaultRecursive -BasePath $scriptRoot)
if ($targets.Count -eq 0) { throw "No valid source folders found." }

$templateMode = if ([string]::IsNullOrWhiteSpace($Template)) { "auto" } else { $Template.ToLowerInvariant() }
$scanEntityOptionSets = $false
$scanSeparateOptionSetFiles = $false
switch ($templateMode) {
    "default" {
        $scanSeparateOptionSetFiles = $true
        break
    }
    "onefile" {
        $scanEntityOptionSets = $true
        break
    }
    default {
        $scanEntityOptionSets = $true
        $scanSeparateOptionSetFiles = $true
        break
    }
}

$entityFiles = @{}
$optionSetFiles = @{}
$availableAttrsByEntity = @{}
$availableOptionSetsByEntity = @{}
$entityByImportLeaf = @{}
$optionSetEntityByImportLeaf = @{}
$entityClassNameByEntity = @{}

foreach ($f in (Get-ChildItem -LiteralPath $generatedPath -File -Recurse -Filter "*.ts")) {
    if ($f.Name.EndsWith(".d.ts", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    $content = Get-Content -LiteralPath $f.FullName -Raw

    $fallbackOptionSetEntity = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
    $entityFromOptionSetMap = Get-EntityLogicalNameFromOptionSetMetadataFile -Content $content -Fallback ""
    $isOptionSetFile = -not [string]::IsNullOrWhiteSpace($entityFromOptionSetMap)
    if (-not $isOptionSetFile -and $f.Name.EndsWith(".optionset.ts", [System.StringComparison]::OrdinalIgnoreCase)) {
        $entityFromOptionSetMap = Get-EntityLogicalNameFromOptionSetMetadataFile -Content $content -Fallback $fallbackOptionSetEntity
        $isOptionSetFile = $true
    }

    if ($isOptionSetFile) {
        $entity = $entityFromOptionSetMap
        if ($optionSetFiles.ContainsKey($entity) -and -not [string]::Equals([string]$optionSetFiles[$entity], [string]$f.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("Duplicate optionset metadata detected for entity '{0}': '{1}' and '{2}'." -f $entity, $optionSetFiles[$entity], $f.FullName)
        }
        $optionSetFiles[$entity] = $f.FullName

        $importLeaf = Get-ImportLeaf -Source $f.Name
        if (-not [string]::IsNullOrWhiteSpace($importLeaf)) {
            if ($optionSetEntityByImportLeaf.ContainsKey($importLeaf) -and -not [string]::Equals([string]$optionSetEntityByImportLeaf[$importLeaf], [string]$entity, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ("Ambiguous optionset import leaf '{0}' maps to multiple entities ('{1}', '{2}')." -f $importLeaf, $optionSetEntityByImportLeaf[$importLeaf], $entity)
            }
            $optionSetEntityByImportLeaf[$importLeaf] = $entity
        }
        continue
    }

    $fallbackEntity = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    $entity = Get-EntityLogicalNameFromEntityMetadataFile -Content $content -Fallback $fallbackEntity
    if ($entityFiles.ContainsKey($entity) -and -not [string]::Equals([string]$entityFiles[$entity], [string]$f.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Duplicate entity metadata detected for entity '{0}': '{1}' and '{2}'." -f $entity, $entityFiles[$entity], $f.FullName)
    }
    $entityFiles[$entity] = $f.FullName
    $entityClassNameByEntity[$entity] = Get-EntityClassNameFromEntityMetadataFile -Content $content -Fallback $entity

    $importLeaf = Get-ImportLeaf -Source $f.Name
    if (-not [string]::IsNullOrWhiteSpace($importLeaf)) {
        if ($entityByImportLeaf.ContainsKey($importLeaf) -and -not [string]::Equals([string]$entityByImportLeaf[$importLeaf], [string]$entity, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("Ambiguous entity import leaf '{0}' maps to multiple entities ('{1}', '{2}')." -f $importLeaf, $entityByImportLeaf[$importLeaf], $entity)
        }
        $entityByImportLeaf[$importLeaf] = $entity
    }
}

if ($entityFiles.Count -eq 0) {
    throw ("No entity metadata files found in: {0}" -f $generatedPath)
}

foreach ($entity in $entityFiles.Keys) {
    $content = Get-Content -LiteralPath $entityFiles[$entity] -Raw
    $attrSet = Get-ObjectKeysByPattern -Text $content -Pattern "public\s+static\s+attributes\s*=\s*\{"
    $optionSetSet = if ($scanEntityOptionSets) {
        Get-ObjectKeysByPattern -Text $content -Pattern "public\s+static\s+optionsets\s*=\s*\{"
    }
    else {
        Get-StringSet
    }

    $availableAttrsByEntity[$entity] = $attrSet
    $availableOptionSetsByEntity[$entity] = $optionSetSet
}

if ($scanSeparateOptionSetFiles) {
    foreach ($entity in $optionSetFiles.Keys) {
        $osContent = Get-Content -LiteralPath $optionSetFiles[$entity] -Raw
        $mapPattern = "export\s+const\s+" + [regex]::Escape($entity + "OptionSets") + "\s*=\s*\{"
        $mapSet = Get-ObjectKeysByPattern -Text $osContent -Pattern $mapPattern

        if (-not $availableOptionSetsByEntity.ContainsKey($entity) -or $null -eq $availableOptionSetsByEntity[$entity]) {
            $availableOptionSetsByEntity[$entity] = Get-StringSet
        }

        foreach ($key in $mapSet) {
            [void]$availableOptionSetsByEntity[$entity].Add($key)
        }
    }
}

$sourceSet = Get-StringSet
$targetReport = New-Object System.Collections.Generic.List[object]
foreach ($target in $targets) {
    # Enumerate candidate TS/TSX files and filter out generated metadata tree.
    $all = if ($target.Recursive) { @(Get-ChildItem -LiteralPath $target.Path -Recurse -File) } else { @(Get-ChildItem -LiteralPath $target.Path -File) }
    $count = 0
    foreach ($file in $all) {
        if ($file.Name.EndsWith(".d.ts", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not ($file.Name.EndsWith(".ts", [System.StringComparison]::OrdinalIgnoreCase) -or $file.Name.EndsWith(".tsx", [System.StringComparison]::OrdinalIgnoreCase))) { continue }
        if (Test-IsChildPath -Path $file.FullName -ParentPath $generatedPath) { continue }
        if ($sourceSet.Add($file.FullName)) { $count++ }
    }

    [void]$targetReport.Add([pscustomobject]@{
            Path = $target.Path; Recursive = $target.Recursive; SourceFileCount = $count
        })
}

$sourceFiles = @(@($sourceSet) | Sort-Object)
if ($sourceFiles.Count -eq 0) {
    throw "No TypeScript source files found after filtering."
}

$importFilesByEntity = @{}
$usedAttrsByEntity = @{}
$usedOptionSetsByEntity = @{}
$attrUsageFilesByEntity = @{}
$optionSetUsageFilesByEntity = @{}

$importPattern = '(?ms)^\s*import\s+(?<clause>[\s\S]*?)\s+from\s+["''](?<source>[^"'']+)["'']\s*;?'

foreach ($sourceFile in $sourceFiles) {
    $content = Get-Content -LiteralPath $sourceFile -Raw
    $imports = [regex]::Matches($content, $importPattern)
    if ($imports.Count -eq 0) { continue }

    $bindings = New-Object System.Collections.Generic.List[object]

    # Build resolved import bindings to entity metadata models before symbol scanning.
    foreach ($imp in $imports) {
        $leaf = Get-ImportLeaf -Source $imp.Groups["source"].Value
        if ([string]::IsNullOrWhiteSpace($leaf)) { continue }

        $entity = ""
        $isOptionSet = $false
        if ($optionSetEntityByImportLeaf.ContainsKey($leaf)) {
            if (-not $scanSeparateOptionSetFiles) { continue }
            $isOptionSet = $true
            $entity = [string]$optionSetEntityByImportLeaf[$leaf]
            if ([string]::IsNullOrWhiteSpace($entity) -or -not $optionSetFiles.ContainsKey($entity)) { continue }
        }
        elseif ($entityByImportLeaf.ContainsKey($leaf)) {
            $entity = [string]$entityByImportLeaf[$leaf]
            if ([string]::IsNullOrWhiteSpace($entity) -or -not $entityFiles.ContainsKey($entity)) { continue }
        }
        else { continue }

        $specs = Get-NamedImportSpecifier -Clause $imp.Groups["clause"].Value
        foreach ($spec in $specs) {
            if ($isOptionSet) {
                $mapName = $entity + "OptionSets"
                if ([string]::Equals($spec.Imported, $mapName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$bindings.Add([pscustomobject]@{ Entity = $entity; Alias = $spec.Local; Kind = "OptionSetMap"; Attr = $null })
                    continue
                }

                $prefix = $entity + "OptionSet_"
                if ($spec.Imported.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $attr = $spec.Imported.Substring($prefix.Length)
                    if (-not [string]::IsNullOrWhiteSpace($attr)) {
                        [void]$bindings.Add([pscustomobject]@{ Entity = $entity; Alias = $spec.Local; Kind = "OptionSetSingle"; Attr = $attr })
                    }
                }

                continue
            }

            $entityClassName = if ($entityClassNameByEntity.ContainsKey($entity)) { [string]$entityClassNameByEntity[$entity] } else { "" }
            if ([string]::Equals($spec.Imported, $entity, [System.StringComparison]::OrdinalIgnoreCase) -or
                (-not [string]::IsNullOrWhiteSpace($entityClassName) -and [string]::Equals($spec.Imported, $entityClassName, [System.StringComparison]::OrdinalIgnoreCase))) {
                [void]$bindings.Add([pscustomobject]@{ Entity = $entity; Alias = $spec.Local; Kind = "EntityClass"; Attr = $null })
            }
        }
    }

    if ($bindings.Count -eq 0) { continue }

    foreach ($b in $bindings) {
        if (-not $importFilesByEntity.ContainsKey($b.Entity)) { $importFilesByEntity[$b.Entity] = Get-StringSet }
        [void]$importFilesByEntity[$b.Entity].Add($sourceFile)
    }

    foreach ($b in $bindings) {
        if (-not $usedAttrsByEntity.ContainsKey($b.Entity)) { $usedAttrsByEntity[$b.Entity] = Get-StringSet }
        if (-not $usedOptionSetsByEntity.ContainsKey($b.Entity)) { $usedOptionSetsByEntity[$b.Entity] = Get-StringSet }
        if (-not $attrUsageFilesByEntity.ContainsKey($b.Entity)) { $attrUsageFilesByEntity[$b.Entity] = @{} }
        if (-not $optionSetUsageFilesByEntity.ContainsKey($b.Entity)) { $optionSetUsageFilesByEntity[$b.Entity] = @{} }

        $foundAttrs = @()
        $foundOptionSets = @()
        switch ($b.Kind) {
            "EntityClass" {
                $foundAttrs = Get-AttrsFromEntityAlias -Content $content -Alias $b.Alias
                if ($scanEntityOptionSets) {
                    $foundOptionSets = Get-OptionSetsFromEntityAlias -Content $content -Alias $b.Alias
                }
                break
            }
            "OptionSetMap" { $foundOptionSets = Get-AttrsFromOptionSetAlias -Content $content -Alias $b.Alias; break }
            "OptionSetSingle" {
                if (-not [string]::IsNullOrWhiteSpace([string]$b.Attr)) { $foundOptionSets = @([string]$b.Attr) }
                break
            }
        }

        $availableAttrSet = if ($availableAttrsByEntity.ContainsKey($b.Entity)) {
            Convert-ToStringSet -Value $availableAttrsByEntity[$b.Entity]
        }
        else {
            Get-StringSet
        }
        foreach ($attr in $foundAttrs) {
            if ($null -eq $attr) { continue }
            $norm = $attr.Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($norm)) { continue }
            if ($availableAttrSet.Count -gt 0 -and -not $availableAttrSet.Contains($norm)) { continue }

            [void]$usedAttrsByEntity[$b.Entity].Add($norm)
            if (-not $attrUsageFilesByEntity[$b.Entity].ContainsKey($norm)) { $attrUsageFilesByEntity[$b.Entity][$norm] = Get-StringSet }
            [void]$attrUsageFilesByEntity[$b.Entity][$norm].Add($sourceFile)
        }

        $availableOptionSetSet = if ($availableOptionSetsByEntity.ContainsKey($b.Entity)) {
            Convert-ToStringSet -Value $availableOptionSetsByEntity[$b.Entity]
        }
        else {
            Get-StringSet
        }
        foreach ($optionSetKey in $foundOptionSets) {
            if ($null -eq $optionSetKey) { continue }
            $norm = $optionSetKey.Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($norm)) { continue }
            if ($availableOptionSetSet.Count -gt 0 -and -not $availableOptionSetSet.Contains($norm)) { continue }

            [void]$usedOptionSetsByEntity[$b.Entity].Add($norm)
            if (-not $optionSetUsageFilesByEntity[$b.Entity].ContainsKey($norm)) { $optionSetUsageFilesByEntity[$b.Entity][$norm] = Get-StringSet }
            [void]$optionSetUsageFilesByEntity[$b.Entity][$norm].Add($sourceFile)
        }
    }
}

$entitySet = Get-StringSet
foreach ($k in $importFilesByEntity.Keys) { [void]$entitySet.Add($k) }
foreach ($k in $usedAttrsByEntity.Keys) { [void]$entitySet.Add($k) }
foreach ($k in $usedOptionSetsByEntity.Keys) { [void]$entitySet.Add($k) }

$entityReports = New-Object System.Collections.Generic.List[object]
foreach ($entity in (@($entitySet) | Sort-Object)) {
    $importFiles = if ($importFilesByEntity.ContainsKey($entity)) { @($importFilesByEntity[$entity] | Sort-Object) } else { @() }
    $usedAttrSet = if ($usedAttrsByEntity.ContainsKey($entity) -and $null -ne $usedAttrsByEntity[$entity]) { Convert-ToStringSet -Value $usedAttrsByEntity[$entity] } else { Get-StringSet }
    $usedOptionSetSet = if ($usedOptionSetsByEntity.ContainsKey($entity) -and $null -ne $usedOptionSetsByEntity[$entity]) { Convert-ToStringSet -Value $usedOptionSetsByEntity[$entity] } else { Get-StringSet }
    $usedAttrs = @($usedAttrSet | Sort-Object)
    $usedOptionSets = @($usedOptionSetSet | Sort-Object)
    $availableAttrSet = if ($availableAttrsByEntity.ContainsKey($entity) -and $null -ne $availableAttrsByEntity[$entity]) { Convert-ToStringSet -Value $availableAttrsByEntity[$entity] } else { Get-StringSet }
    $availableOptionSetSet = if ($availableOptionSetsByEntity.ContainsKey($entity) -and $null -ne $availableOptionSetsByEntity[$entity]) { Convert-ToStringSet -Value $availableOptionSetsByEntity[$entity] } else { Get-StringSet }
    $availableAttrs = @($availableAttrSet | Sort-Object)
    $availableOptionSets = @($availableOptionSetSet | Sort-Object)

    # Compare available metadata keys against observed usage from source files.
    $unusedAttrs = @()
    foreach ($a in $availableAttrs) { if (-not (Test-SetMembership -Set $usedAttrSet -Value $a)) { $unusedAttrs += $a } }

    $unusedOptionSets = @()
    foreach ($o in $availableOptionSets) { if (-not (Test-SetMembership -Set $usedOptionSetSet -Value $o)) { $unusedOptionSets += $o } }

    $attrUsage = New-Object System.Collections.Generic.List[object]
    foreach ($a in $usedAttrs) {
        $files = if ($attrUsageFilesByEntity.ContainsKey($entity) -and $attrUsageFilesByEntity[$entity].ContainsKey($a)) { @(@($attrUsageFilesByEntity[$entity][$a] | Sort-Object)) } else { @() }
        [void]$attrUsage.Add([pscustomobject]@{ AttributeLogicalName = $a; FileCount = (Get-CountSafe -Value $files); Files = $files })
    }

    $optionSetUsage = New-Object System.Collections.Generic.List[object]
    foreach ($o in $usedOptionSets) {
        $files = if ($optionSetUsageFilesByEntity.ContainsKey($entity) -and $optionSetUsageFilesByEntity[$entity].ContainsKey($o)) { @(@($optionSetUsageFilesByEntity[$entity][$o] | Sort-Object)) } else { @() }
        [void]$optionSetUsage.Add([pscustomobject]@{ OptionSetLogicalName = $o; FileCount = (Get-CountSafe -Value $files); Files = $files })
    }

    [void]$entityReports.Add([pscustomobject]@{
            EntityLogicalName = $entity
            ImportFileCount = (Get-CountSafe -Value $importFiles)
            ImportFiles = $importFiles
            UsedAttributeCount = (Get-CountSafe -Value $usedAttrs)
            UsedAttributes = $usedAttrs
            UnusedAttributeCount = (Get-CountSafe -Value $unusedAttrs)
            UnusedAttributes = $unusedAttrs
            UsedOptionSetCount = (Get-CountSafe -Value $usedOptionSets)
            UsedOptionSets = $usedOptionSets
            UnusedOptionSetCount = (Get-CountSafe -Value $unusedOptionSets)
            UnusedOptionSets = $unusedOptionSets
            AttributeUsageByFile = $attrUsage.ToArray()
            OptionSetUsageByFile = $optionSetUsage.ToArray()
        })
}

$pruneSummary = @()
$pruneExecuted = $false
if ($pruneEnabled) {
    $pruneSummary = Invoke-PrunePass `
        -Entities @($entitySet) `
        -EntityFiles $entityFiles `
        -OptionSetFiles $optionSetFiles `
        -UsedAttrsByEntity $usedAttrsByEntity `
        -UsedOptionSetsByEntity $usedOptionSetsByEntity `
        -ScanEntityOptionSets $scanEntityOptionSets `
        -ScanSeparateOptionSetFiles $scanSeparateOptionSetFiles
    $pruneExecuted = $true
}

$attributeRemovalMode = if ($pruneExecuted) { "will be removed" } else { "can be removed" }
foreach ($entityReport in (@($entityReports.ToArray()) | Sort-Object EntityLogicalName)) {
    if ($entityReport.UnusedAttributeCount -gt 0) {
        $unusedAttributeNames = @($entityReport.UnusedAttributes | Sort-Object)
        Write-Verbose ("{0}: attributes that {1} ({2}): {3}" -f $entityReport.EntityLogicalName, $attributeRemovalMode, $entityReport.UnusedAttributeCount, ($unusedAttributeNames -join ", "))
    }
    else {
        Write-Verbose ("{0}: no removable attributes." -f $entityReport.EntityLogicalName)
    }
}

Write-Output ("Scanned source files: {0}" -f $sourceFiles.Count)
Write-Output ("Entities found: {0}" -f $entityReports.Count)
Write-Output ("Template mode: {0}" -f $templateMode)
if ($targetReport.Count -gt 0) {
    Write-Output "Source folder scan summary:"
    @($targetReport.ToArray() | Sort-Object Path) | Format-Table -AutoSize Path, Recursive, SourceFileCount
}
if ($pruneExecuted) {
    Write-Output ("Prune mode enabled. Updated files: {0}" -f ((@($pruneSummary | Where-Object { $_.Changed })).Count))
}

$removableColumnName = if ($pruneExecuted) { "AttributesWillBeRemoved" } else { "AttributesCanBeRemoved" }
$removableOptionSetColumnName = if ($pruneExecuted) { "OptionSetsWillBeRemoved" } else { "OptionSetsCanBeRemoved" }
$entitySummaryRows = @($entityReports.ToArray() | Sort-Object EntityLogicalName | Select-Object `
        @{Name = "Entity"; Expression = { $_.EntityLogicalName } }, `
        @{Name = "ImportFiles"; Expression = { $_.ImportFileCount } }, `
        @{Name = $removableColumnName; Expression = { $_.UnusedAttributeCount } }, `
        @{Name = $removableOptionSetColumnName; Expression = { $_.UnusedOptionSetCount } })

if ($entitySummaryRows.Count -gt 0) {
    $entitySummaryRows | Format-Table -AutoSize
}
else {
    Write-Output "No matching metadata entities were imported in scanned source files."
}

if (-not $pruneExecuted) {
    $totalRemovableAttributes = 0
    $totalRemovableOptionSets = 0
    foreach ($entityReport in $entityReports.ToArray()) {
        $totalRemovableAttributes += [int]$entityReport.UnusedAttributeCount
        $totalRemovableOptionSets += [int]$entityReport.UnusedOptionSetCount
    }

    if ($totalRemovableAttributes -gt 0 -or $totalRemovableOptionSets -gt 0) {
        $entitiesWithRemovable = (@($entityReports.ToArray() | Where-Object { $_.UnusedAttributeCount -gt 0 -or $_.UnusedOptionSetCount -gt 0 })).Count
        $answer = ""
        try {
            $answer = Read-Host ("{0} attributes and {1} option sets can be removed across {2} entities. Do you want to prune now? [y/N]" -f $totalRemovableAttributes, $totalRemovableOptionSets, $entitiesWithRemovable)
        }
        catch {
            $answer = ""
        }

        $normalizedAnswer = if ($null -eq $answer) { "" } else { $answer.Trim().ToLowerInvariant() }
        if ($normalizedAnswer -in @("y", "yes")) {
            $pruneSummary = Invoke-PrunePass `
                -Entities @($entitySet) `
                -EntityFiles $entityFiles `
                -OptionSetFiles $optionSetFiles `
                -UsedAttrsByEntity $usedAttrsByEntity `
                -UsedOptionSetsByEntity $usedOptionSetsByEntity `
                -ScanEntityOptionSets $scanEntityOptionSets `
                -ScanSeparateOptionSetFiles $scanSeparateOptionSetFiles

            $updatedFileCount = (@($pruneSummary | Where-Object { $_.Changed })).Count
            Write-Output ("Prune completed. Updated files: {0}" -f $updatedFileCount)
        }
        else {
            Write-Output "Prune skipped."
        }
    }
}
