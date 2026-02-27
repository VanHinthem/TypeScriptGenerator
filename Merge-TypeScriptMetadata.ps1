[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FolderA,
    [Parameter(Mandatory = $true)]
    [string]$FolderB
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
trap {
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $message = $_.Exception.Message
    Write-Error ("Unhandled error on line {0}: {1}" -f $lineNumber, $message)
    break
}

<#
.SYNOPSIS
Writes text as UTF-8 without BOM.
#>
function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

<#
.SYNOPSIS
Resolves a path to an absolute canonical path.
#>
function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path cannot be empty."
    }

    if (Test-Path -LiteralPath $Path) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $combined = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Location).Path -ChildPath $Path))
    }

    return $combined
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
Counts opening/closing brace delta on a line.
#>
function Get-BraceDelta {
    param([Parameter(Mandatory = $true)][string]$Line)
    return (([regex]::Matches($Line, "\{")).Count - ([regex]::Matches($Line, "\}")).Count)
}

<#
.SYNOPSIS
Finds the matching close brace index for an opening brace index.
#>
function Find-CloseBrace {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$OpenBraceIndex
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

<#
.SYNOPSIS
Finds an object-assignment block and returns indexes and body.
#>
function Get-ObjectAssignment {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $m = [regex]::Match($Text, $Pattern)
    if (-not $m.Success) { return $null }

    $openOffset = $m.Value.LastIndexOf("{", [System.StringComparison]::Ordinal)
    if ($openOffset -lt 0) { throw ("No opening brace for pattern: {0}" -f $Pattern) }

    $open = $m.Index + $openOffset
    $close = Find-CloseBrace -Text $Text -OpenBraceIndex $open
    if ($close -lt 0) { throw ("No matching closing brace for pattern: {0}" -f $Pattern) }

    return [pscustomobject]@{
        MatchStart  = $m.Index
        MatchLength = $m.Length
        Open        = $open
        Close       = $close
        Body        = $Text.Substring($open + 1, $close - $open - 1)
    }
}

<#
.SYNOPSIS
Extracts top-level object entries (key + raw text) from an object body.
#>
function Get-TopLevelEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)][string]$NewLine
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

<#
.SYNOPSIS
Ensures last entry has no trailing comma and intermediate entries do.
#>
function Set-EntryTrailingComma {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$EntryText,
        [Parameter(Mandatory = $true)][bool]$HasTrailingComma,
        [Parameter(Mandatory = $true)][string]$NewLine
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

<#
.SYNOPSIS
Normalizes trailing comma state across top-level entry texts.
#>
function Get-NormalizedTopLevelEntryTexts {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory = $true)][string]$NewLine
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

<#
.SYNOPSIS
Replaces object body text while preserving opening/closing syntax.
#>
function Replace-ObjectAssignmentBody {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][pscustomobject]$Assignment,
        [Parameter(Mandatory = $true)][string]$NewBody
    )

    $closingIndent = ""
    if ($Assignment.Close -gt 0) {
        $previousNewLineIndex = $Text.LastIndexOf("`n", $Assignment.Close - 1)
        if ($previousNewLineIndex -ge 0) {
            $indentStart = $previousNewLineIndex + 1
            if ($indentStart -le $Assignment.Close) {
                $candidateIndent = $Text.Substring($indentStart, $Assignment.Close - $indentStart)
                if ($candidateIndent -match "^[ \t]*$") {
                    $closingIndent = $candidateIndent
                }
            }
        }
    }

    return $Text.Substring(0, $Assignment.Open + 1) + $NewBody + $closingIndent + "}" + $Text.Substring($Assignment.Close + 1)
}

<#
.SYNOPSIS
Merges top-level object entries by key (A preferred, missing keys added from B).
#>
function Merge-ObjectAssignmentByUnion {
    param(
        [Parameter(Mandatory = $true)][string]$TextA,
        [Parameter(Mandatory = $true)][string]$TextB,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $objA = Get-ObjectAssignment -Text $TextA -Pattern $Pattern
    if ($null -eq $objA) {
        return [pscustomobject]@{ Text = $TextA; Changed = $false; AddedKeys = @() }
    }

    $objB = Get-ObjectAssignment -Text $TextB -Pattern $Pattern
    if ($null -eq $objB) {
        return [pscustomobject]@{ Text = $TextA; Changed = $false; AddedKeys = @() }
    }

    $nl = if ($TextA.Contains("`r`n")) { "`r`n" } else { "`n" }
    $entriesA = @(Get-TopLevelEntry -Body $objA.Body -NewLine $nl)
    $entriesB = @(Get-TopLevelEntry -Body $objB.Body -NewLine $nl)

    $keySet = Get-StringSet
    $merged = New-Object System.Collections.Generic.List[object]
    $addedKeys = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $entriesA) {
        [void]$keySet.Add([string]$entry.Key)
        [void]$merged.Add($entry)
    }

    foreach ($entry in $entriesB) {
        $key = [string]$entry.Key
        if ($keySet.Contains($key)) { continue }
        [void]$keySet.Add($key)
        $normalizedText = (($entry.Text -replace "`r`n", "`n") -replace "`n", $nl).TrimEnd()
        [void]$merged.Add([pscustomobject]@{ Key = $key; Text = $normalizedText })
        [void]$addedKeys.Add($key)
    }

    $newBody = $nl
    if ($merged.Count -gt 0) {
        $normalized = Get-NormalizedTopLevelEntryTexts -Entries @($merged.ToArray()) -NewLine $nl
        $newBody = $nl + ($normalized -join $nl) + $nl
    }

    $newText = Replace-ObjectAssignmentBody -Text $TextA -Assignment $objA -NewBody $newBody
    return [pscustomobject]@{
        Text      = $newText
        Changed   = ($newText -ne $TextA)
        AddedKeys = $addedKeys.ToArray()
    }
}

<#
.SYNOPSIS
Gets map keys from an object assignment.
#>
function Get-ObjectKeysByPattern {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $obj = Get-ObjectAssignment -Text $Text -Pattern $Pattern
    if ($null -eq $obj) { return @() }

    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    return @((Get-TopLevelEntry -Body $obj.Body -NewLine $nl) | ForEach-Object { [string]$_.Key })
}

<#
.SYNOPSIS
Parses optionset constant blocks from an optionset metadata file.
#>
function Get-OptionSetConstantBlocks {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$EntityLogicalName
    )

    $prefix = [regex]::Escape($EntityLogicalName + "OptionSet_")
    $pattern = '(?ms)^\s*export\s+const\s+' + $prefix + '(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{[\s\S]*?\}\s+as\s+const;\s*(?:\r?\n)?'
    $matches = [regex]::Matches($Text, $pattern)

    $ordered = New-Object System.Collections.Generic.List[string]
    $byKey = @{}
    foreach ($m in $matches) {
        $key = [string]$m.Groups["key"].Value
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($byKey.ContainsKey($key)) { continue }
        $byKey[$key] = [string]$m.Value
        [void]$ordered.Add($key)
    }

    return [pscustomobject]@{
        OrderedKeys = $ordered.ToArray()
        ByKey       = $byKey
        Pattern     = $pattern
    }
}

<#
.SYNOPSIS
Merges optionset file content (map + per-key constants). A wins on conflicts.
#>
function Merge-OptionSetContent {
    param(
        [Parameter(Mandatory = $true)][string]$TextA,
        [Parameter(Mandatory = $true)][string]$TextB,
        [Parameter(Mandatory = $true)][string]$EntityLogicalName
    )

    $mapPattern = "export\s+const\s+" + [regex]::Escape($EntityLogicalName + "OptionSets") + "\s*=\s*\{"
    $mapMerge = Merge-ObjectAssignmentByUnion -TextA $TextA -TextB $TextB -Pattern $mapPattern
    $mapMergedText = [string]$mapMerge.Text

    $mapObj = Get-ObjectAssignment -Text $mapMergedText -Pattern $mapPattern
    if ($null -eq $mapObj) {
        return [pscustomobject]@{
            Text              = $TextA
            Changed           = $false
            AddedMapKeys      = @()
            AddedConstantKeys = @()
        }
    }

    $nl = if ($TextA.Contains("`r`n")) { "`r`n" } else { "`n" }
    $mapKeys = @(Get-ObjectKeysByPattern -Text $mapMergedText -Pattern $mapPattern)
    $constantsA = Get-OptionSetConstantBlocks -Text $TextA -EntityLogicalName $EntityLogicalName
    $constantsB = Get-OptionSetConstantBlocks -Text $TextB -EntityLogicalName $EntityLogicalName

    $constantBlocks = New-Object System.Collections.Generic.List[string]
    $addedConstantKeys = New-Object System.Collections.Generic.List[string]
    foreach ($key in $mapKeys) {
        if ($constantsA.ByKey.ContainsKey($key)) {
            $block = [string]$constantsA.ByKey[$key]
            $normalized = (($block -replace "`r`n", "`n") -replace "`n", $nl).TrimEnd()
            [void]$constantBlocks.Add($normalized)
            continue
        }

        if ($constantsB.ByKey.ContainsKey($key)) {
            $block = [string]$constantsB.ByKey[$key]
            $normalized = (($block -replace "`r`n", "`n") -replace "`n", $nl).TrimEnd()
            [void]$constantBlocks.Add($normalized)
            [void]$addedConstantKeys.Add($key)
            continue
        }

        Write-Warning ("No constant block found for optionset key '{0}' on entity '{1}'." -f $key, $EntityLogicalName)
    }

    $constRegex = [regex]::new($constantsA.Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $prefix = $mapMergedText.Substring(0, $mapObj.MatchStart)
    $prefixWithoutConstants = $constRegex.Replace($prefix, "")
    $prefixWithoutConstants = $prefixWithoutConstants.TrimEnd()

    $mapAndTail = $mapMergedText.Substring($mapObj.MatchStart)
    $newContent = ""
    if ($constantBlocks.Count -gt 0) {
        $constantsSection = [string]::Join($nl + $nl, $constantBlocks.ToArray()) + $nl + $nl
        if ([string]::IsNullOrWhiteSpace($prefixWithoutConstants)) {
            $newContent = $constantsSection + $mapAndTail.TrimStart()
        }
        else {
            $newContent = $prefixWithoutConstants + $nl + $nl + $constantsSection + $mapAndTail.TrimStart()
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($prefixWithoutConstants)) {
            $newContent = $mapAndTail.TrimStart()
        }
        else {
            $newContent = $prefixWithoutConstants + $nl + $nl + $mapAndTail.TrimStart()
        }
    }

    if (-not $newContent.EndsWith($nl)) {
        $newContent += $nl
    }

    return [pscustomobject]@{
        Text              = $newContent
        Changed           = ($newContent -ne $TextA)
        AddedMapKeys      = @($mapMerge.AddedKeys)
        AddedConstantKeys = $addedConstantKeys.ToArray()
    }
}

<#
.SYNOPSIS
Returns metadata file maps (entity and optionset) from a generated folder.
#>
function Get-MetadataFileMap {
    param([Parameter(Mandatory = $true)][string]$GeneratedFolder)

    $entityFiles = @{}
    $optionSetFiles = @{}
    $entityIndexFiles = @{}

    foreach ($file in (Get-ChildItem -LiteralPath $GeneratedFolder -File -Recurse -Filter "*.ts")) {
        if ($file.Name.EndsWith(".d.ts", [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        $content = Get-Content -LiteralPath $file.FullName -Raw
        $hasEntityLogicalNameConst = [regex]::IsMatch($content, '(?im)\bpublic\s+static\s+EntityLogicalName\s*=\s*["''][^"'']+["'']')
        $hasAttributesMap = [regex]::IsMatch($content, '(?im)\bpublic\s+static\s+attributes\s*=\s*\{')
        $optionSetMapMatch = [regex]::Match($content, '(?im)^\s*export\s+const\s+(?<entity>[A-Za-z_$][A-Za-z0-9_$]*)OptionSets\s*=\s*\{')

        if ($optionSetMapMatch.Success) {
            $entity = [string]$optionSetMapMatch.Groups["entity"].Value
            if (-not [string]::IsNullOrWhiteSpace($entity) -and -not $optionSetFiles.ContainsKey($entity)) {
                $optionSetFiles[$entity] = $file.FullName
            }
            continue
        }

        if ($hasEntityLogicalNameConst -and $hasAttributesMap) {
            $logicalNameMatch = [regex]::Match($content, '(?im)\bpublic\s+static\s+EntityLogicalName\s*=\s*["''](?<name>[^"'']+)["'']')
            $entity = if ($logicalNameMatch.Success) { [string]$logicalNameMatch.Groups["name"].Value } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
            if (-not [string]::IsNullOrWhiteSpace($entity) -and -not $entityFiles.ContainsKey($entity)) {
                $entityFiles[$entity] = $file.FullName
                $entityDir = Split-Path -Path $file.FullName -Parent
                $entityIndexPath = Join-Path -Path $entityDir -ChildPath "index.ts"
                if (Test-Path -LiteralPath $entityIndexPath -PathType Leaf) {
                    $entityIndexFiles[$entity] = $entityIndexPath
                }
            }
        }
    }

    return [pscustomobject]@{
        EntityFiles      = $entityFiles
        OptionSetFiles   = $optionSetFiles
        EntityIndexFiles = $entityIndexFiles
    }
}

<#
.SYNOPSIS
Returns relative path from base folder to child path.
#>
function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$ChildPath
    )

    $base = [System.IO.Path]::GetFullPath($BasePath).TrimEnd("\", "/")
    $child = [System.IO.Path]::GetFullPath($ChildPath)
    if (-not $child.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Path '{0}' is not under base '{1}'." -f $child, $base)
    }

    $relative = $child.Substring($base.Length).TrimStart("\", "/")
    return $relative
}

<#
.SYNOPSIS
Copies one file from source root into destination root using relative path.
#>
function Copy-ByRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$SourceFile,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    $relative = Get-RelativePath -BasePath $SourceRoot -ChildPath $SourceFile
    $dest = Join-Path -Path $DestinationRoot -ChildPath $relative
    $destDir = Split-Path -Path $dest -Parent
    if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $SourceFile -Destination $dest -Force
    return $dest
}

<#
.SYNOPSIS
Gets import path like "./account.optionset" for one file relative to another.
#>
function Get-ImportPath {
    param(
        [Parameter(Mandatory = $true)][string]$FromDirectory,
        [Parameter(Mandatory = $true)][string]$TargetFile
    )

    $from = [System.IO.Path]::GetFullPath($FromDirectory)
    $to = [System.IO.Path]::GetFullPath($TargetFile)

    if (-not $from.EndsWith("\")) {
        $from += "\"
    }

    $fromUri = [System.Uri]$from
    $toUri = [System.Uri]$to
    $relative = [System.Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString()).Replace("\", "/")

    $relativeNoExt = [System.IO.Path]::ChangeExtension($relative, $null)
    if (-not $relativeNoExt.StartsWith(".")) {
        $relativeNoExt = "./" + $relativeNoExt
    }

    return $relativeNoExt
}

<#
.SYNOPSIS
Rewrites entity-level index.ts based on merged files.
#>
function Update-EntityIndex {
    param(
        [Parameter(Mandatory = $true)][string]$EntityLogicalName,
        [Parameter(Mandatory = $true)][string]$EntityFilePath,
        [AllowNull()][string]$OptionSetFilePath
    )

    $entityDir = Split-Path -Path $EntityFilePath -Parent
    $entityIndexPath = Join-Path -Path $entityDir -ChildPath "index.ts"

    # Skip for flat layouts where entity file lives in root (root index is handled separately).
    if ([string]::Equals([System.IO.Path]::GetFullPath($entityDir).TrimEnd("\"), [System.IO.Path]::GetFullPath($resolvedFolderA).TrimEnd("\"), [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $entityIndexPath -PathType Leaf)) {
        return $false
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $entityImport = Get-ImportPath -FromDirectory $entityDir -TargetFile $EntityFilePath
    [void]$lines.Add('export { ' + $EntityLogicalName + ' } from "' + $entityImport + '";')

    if (-not [string]::IsNullOrWhiteSpace($OptionSetFilePath) -and (Test-Path -LiteralPath $OptionSetFilePath -PathType Leaf)) {
        $optionSetContent = Get-Content -LiteralPath $OptionSetFilePath -Raw
        $mapPattern = "export\s+const\s+" + [regex]::Escape($EntityLogicalName + "OptionSets") + "\s*=\s*\{"
        $optionSetKeys = @(Get-ObjectKeysByPattern -Text $optionSetContent -Pattern $mapPattern)
        $optionSetImport = Get-ImportPath -FromDirectory $entityDir -TargetFile $OptionSetFilePath

        [void]$lines.Add('export { ' + $EntityLogicalName + 'OptionSets } from "' + $optionSetImport + '";')
        foreach ($optionSetKey in @($optionSetKeys | Sort-Object)) {
            [void]$lines.Add('export { ' + $EntityLogicalName + 'OptionSet_' + $optionSetKey + ' } from "' + $optionSetImport + '";')
        }
    }

    $nl = "`r`n"
    $newContent = [string]::Join($nl, $lines.ToArray()) + $nl
    $existing = Get-Content -LiteralPath $entityIndexPath -Raw
    if ($newContent -ne $existing) {
        Write-Utf8NoBom -Path $entityIndexPath -Content $newContent
        return $true
    }

    return $false
}

<#
.SYNOPSIS
Rewrites root index.ts based on merged entities.
#>
function Update-RootIndex {
    param(
        [Parameter(Mandatory = $true)][hashtable]$EntityFiles,
        [Parameter(Mandatory = $true)][hashtable]$OptionSetFiles
    )

    $rootIndexPath = Join-Path -Path $resolvedFolderA -ChildPath "index.ts"
    if (-not (Test-Path -LiteralPath $rootIndexPath -PathType Leaf)) {
        return $false
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $entities = @($EntityFiles.Keys | Sort-Object)
    for ($entityIndex = 0; $entityIndex -lt $entities.Count; $entityIndex++) {
        $entity = [string]$entities[$entityIndex]
        $entityFile = [string]$EntityFiles[$entity]
        if ([string]::IsNullOrWhiteSpace($entityFile) -or -not (Test-Path -LiteralPath $entityFile -PathType Leaf)) { continue }

        $entityDir = Split-Path -Path $entityFile -Parent
        $rootDir = [System.IO.Path]::GetFullPath($resolvedFolderA).TrimEnd("\")
        $currentDir = [System.IO.Path]::GetFullPath($entityDir).TrimEnd("\")

        $importPath = ""
        if ([string]::Equals($currentDir, $rootDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            $importPath = "./" + [System.IO.Path]::GetFileNameWithoutExtension($entityFile)
        }
        else {
            $relativeDir = Get-RelativePath -BasePath $resolvedFolderA -ChildPath $entityDir
            $importPath = "./" + $relativeDir.Replace("\", "/")
        }

        $line = 'export { ' + $entity
        if ($OptionSetFiles.ContainsKey($entity)) {
            $optionSetPath = [string]$OptionSetFiles[$entity]
            if (Test-Path -LiteralPath $optionSetPath -PathType Leaf) {
                $line += ', ' + $entity + 'OptionSets'
                $mapPattern = "export\s+const\s+" + [regex]::Escape($entity + "OptionSets") + "\s*=\s*\{"
                $keys = @(Get-ObjectKeysByPattern -Text (Get-Content -LiteralPath $optionSetPath -Raw) -Pattern $mapPattern | Sort-Object)
                foreach ($key in $keys) {
                    $line += ', ' + $entity + 'OptionSet_' + $key
                }
            }
        }

        $line += ' } from "' + $importPath + '";'
        [void]$lines.Add($line)
        if ($entityIndex -lt ($entities.Count - 1)) {
            [void]$lines.Add("")
        }
    }

    $nl = "`r`n"
    $newContent = if ($lines.Count -gt 0) { [string]::Join($nl, $lines.ToArray()) + $nl } else { "" }
    $existing = Get-Content -LiteralPath $rootIndexPath -Raw
    if ($newContent -ne $existing) {
        Write-Utf8NoBom -Path $rootIndexPath -Content $newContent
        return $true
    }

    return $false
}

$resolvedFolderA = Resolve-AbsolutePath -Path $FolderA
$resolvedFolderB = Resolve-AbsolutePath -Path $FolderB

if (-not (Test-Path -LiteralPath $resolvedFolderA -PathType Container)) {
    throw ("FolderA not found: {0}" -f $resolvedFolderA)
}
if (-not (Test-Path -LiteralPath $resolvedFolderB -PathType Container)) {
    throw ("FolderB not found: {0}" -f $resolvedFolderB)
}

Write-Output ("FolderA (target): {0}" -f $resolvedFolderA)
Write-Output ("FolderB (source): {0}" -f $resolvedFolderB)
Write-Output "Conflict policy: Prefer FolderA values; add missing keys from FolderB."

$mapA = Get-MetadataFileMap -GeneratedFolder $resolvedFolderA
$mapB = Get-MetadataFileMap -GeneratedFolder $resolvedFolderB

$entityFilesA = $mapA.EntityFiles
$optionSetFilesA = $mapA.OptionSetFiles
$entityIndexFilesA = $mapA.EntityIndexFiles

$entityFilesB = $mapB.EntityFiles
$optionSetFilesB = $mapB.OptionSetFiles
$entityIndexFilesB = $mapB.EntityIndexFiles

$allEntities = @((@($entityFilesA.Keys) + @($entityFilesB.Keys)) | Sort-Object -Unique)

$stats = [pscustomobject]@{
    AddedEntityFiles         = 0
    AddedOptionSetFiles      = 0
    UpdatedEntityFiles       = 0
    UpdatedOptionSetFiles    = 0
    UpdatedEntityIndexes     = 0
    UpdatedRootIndex         = 0
    AddedAttributeKeys       = 0
    AddedEntityOptionSetKeys = 0
    AddedSeparateOptionSetKeys = 0
}

foreach ($entity in $allEntities) {
    $hasEntityA = $entityFilesA.ContainsKey($entity)
    $hasEntityB = $entityFilesB.ContainsKey($entity)

    if (-not $hasEntityA -and $hasEntityB) {
        $copiedEntityPath = Copy-ByRelativePath -SourceFile ([string]$entityFilesB[$entity]) -SourceRoot $resolvedFolderB -DestinationRoot $resolvedFolderA
        $entityFilesA[$entity] = $copiedEntityPath
        $stats.AddedEntityFiles++

        if ($optionSetFilesB.ContainsKey($entity)) {
            $copiedOptionSetPath = Copy-ByRelativePath -SourceFile ([string]$optionSetFilesB[$entity]) -SourceRoot $resolvedFolderB -DestinationRoot $resolvedFolderA
            $optionSetFilesA[$entity] = $copiedOptionSetPath
            $stats.AddedOptionSetFiles++
        }

        if ($entityIndexFilesB.ContainsKey($entity)) {
            $copiedEntityIndexPath = Copy-ByRelativePath -SourceFile ([string]$entityIndexFilesB[$entity]) -SourceRoot $resolvedFolderB -DestinationRoot $resolvedFolderA
            $entityIndexFilesA[$entity] = $copiedEntityIndexPath
        }

        continue
    }

    if (-not $hasEntityA -or -not $hasEntityB) {
        continue
    }

    $entityPathA = [string]$entityFilesA[$entity]
    $entityPathB = [string]$entityFilesB[$entity]
    $entityContentA = Get-Content -LiteralPath $entityPathA -Raw
    $entityContentB = Get-Content -LiteralPath $entityPathB -Raw

    $attrMerge = Merge-ObjectAssignmentByUnion -TextA $entityContentA -TextB $entityContentB -Pattern "public\s+static\s+attributes\s*=\s*\{"
    $mergedEntityContent = [string]$attrMerge.Text
    $stats.AddedAttributeKeys += @($attrMerge.AddedKeys).Count

    $optMerge = Merge-ObjectAssignmentByUnion -TextA $mergedEntityContent -TextB $entityContentB -Pattern "public\s+static\s+optionsets\s*=\s*\{"
    $mergedEntityContent = [string]$optMerge.Text
    $stats.AddedEntityOptionSetKeys += @($optMerge.AddedKeys).Count

    if ($mergedEntityContent -ne $entityContentA) {
        Write-Utf8NoBom -Path $entityPathA -Content $mergedEntityContent
        $stats.UpdatedEntityFiles++
    }

    $hasOptionSetA = $optionSetFilesA.ContainsKey($entity)
    $hasOptionSetB = $optionSetFilesB.ContainsKey($entity)

    if (-not $hasOptionSetA -and $hasOptionSetB) {
        $copiedOptionSetPath = Copy-ByRelativePath -SourceFile ([string]$optionSetFilesB[$entity]) -SourceRoot $resolvedFolderB -DestinationRoot $resolvedFolderA
        $optionSetFilesA[$entity] = $copiedOptionSetPath
        $stats.AddedOptionSetFiles++
    }
    elseif ($hasOptionSetA -and $hasOptionSetB) {
        $osPathA = [string]$optionSetFilesA[$entity]
        $osPathB = [string]$optionSetFilesB[$entity]
        $osContentA = Get-Content -LiteralPath $osPathA -Raw
        $osContentB = Get-Content -LiteralPath $osPathB -Raw
        $osMerge = Merge-OptionSetContent -TextA $osContentA -TextB $osContentB -EntityLogicalName $entity
        $stats.AddedSeparateOptionSetKeys += @($osMerge.AddedMapKeys).Count
        if ($osMerge.Changed) {
            Write-Utf8NoBom -Path $osPathA -Content ([string]$osMerge.Text)
            $stats.UpdatedOptionSetFiles++
        }
    }
}

foreach ($entity in @($entityFilesA.Keys | Sort-Object)) {
    $entityFile = [string]$entityFilesA[$entity]
    $optionSetFile = if ($optionSetFilesA.ContainsKey($entity)) { [string]$optionSetFilesA[$entity] } else { $null }
    if (Update-EntityIndex -EntityLogicalName $entity -EntityFilePath $entityFile -OptionSetFilePath $optionSetFile) {
        $stats.UpdatedEntityIndexes++
    }
}

if (Update-RootIndex -EntityFiles $entityFilesA -OptionSetFiles $optionSetFilesA) {
    $stats.UpdatedRootIndex = 1
}

Write-Output ""
Write-Output "Merge completed."
Write-Output ("Entities in FolderA: {0}" -f $entityFilesA.Count)
Write-Output ("Added entity files: {0}" -f $stats.AddedEntityFiles)
Write-Output ("Updated entity files: {0}" -f $stats.UpdatedEntityFiles)
Write-Output ("Added optionset files: {0}" -f $stats.AddedOptionSetFiles)
Write-Output ("Updated optionset files: {0}" -f $stats.UpdatedOptionSetFiles)
Write-Output ("Added attribute keys: {0}" -f $stats.AddedAttributeKeys)
Write-Output ("Added in-class optionset keys: {0}" -f $stats.AddedEntityOptionSetKeys)
Write-Output ("Added separate optionset keys: {0}" -f $stats.AddedSeparateOptionSetKeys)
Write-Output ("Updated entity index files: {0}" -f $stats.UpdatedEntityIndexes)
Write-Output ("Updated root index file: {0}" -f $stats.UpdatedRootIndex)

