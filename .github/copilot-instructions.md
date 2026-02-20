# TypeScriptGenerator - Copilot Instructions

This repository generates TypeScript metadata files from Microsoft Dataverse entities using PowerShell templating.

## Architecture Overview

### Core Pipeline

1. **Authentication** (`modules/Auth.psm1`) - Interactive MSAL.PS authentication to Dataverse
2. **Entity Selection** (`modules/EntitySelection.psm1`) - Combines entities from CLI args, `entity.txt`, or solution manifests; deduplicates case-insensitively (`Resolve-SelectedEntityLogicalNames`)
3. **Metadata Retrieval** (`modules/DataverseApi.psm1`) - Fetches entity metadata via Dataverse Web API with pagination support
4. **Template Rendering** (`modules/TemplateEngine.psm1`) - Custom template engine with `{{Token}}` placeholders and `{{#Collection}}...{{/Collection}}` loops (`Convert-EntityTypeScriptContent`)
5. **File Generation** - Each template × each entity = one output file in `generated/`

### Scripts

- **TypeScriptGenerator.ps1** - Main generation script
- **Analyze-TypeScriptMetadataUsage.ps1** - Scans TypeScript source to identify unused attributes/optionsets and optionally prunes them

### Modules

All modules use `Set-StrictMode -Version Latest` and `$ErrorActionPreference = "Stop"`.

- **Pathing.psm1** - Resolves paths relative to script location (not current directory)
- **ObjectTraversal.psm1** - Shared case-insensitive dictionary/object property traversal helpers
- **EntitySelection.psm1** - Handles entity list files (supports `#` comments, comma/semicolon separators)
- **DataverseQueries.psm1** - Centralized Dataverse URI/query construction helpers
- **DataverseApi.psm1** - `Get-PagedItem` handles OData `@odata.nextLink` pagination
- **TemplateEngine.psm1** - Recursive template rendering; `Convert-ToPascalIdentifier` handles label → TypeScript identifier conversion with diacritic removal
- **Auth.psm1** - Validates Dataverse URLs and handles MSAL token acquisition

### Template System

Templates live in `templates/<TemplateName>/` and support:

**Tokens:**
- `{{Entity.LogicalName}}`, `{{Entity.SchemaName}}`, `{{Entity.DisplayName}}` (also usable in file/folder names)
- `{{Attribute.LogicalName}}`, `{{Attribute.SchemaName}}`, `{{Attribute.Key}}`
- `{{OptionSet.AttributeLogicalName}}`, `{{OptionSet.Name}}`, `{{OptionSet.AttributeKey}}`
- `{{Option.Label}}`, `{{Option.Key}}`, `{{Option.RawValue}}`, `{{Option.Value}}`, `{{Option.Comma}}`

**Loops:**
- `{{#Entities}}...{{/Entities}}`
- `{{#Attributes}}...{{/Attributes}}`
- `{{#OptionSets}}...{{#Options}}...{{/Options}}...{{/OptionSets}}`

**Loop Aliases:**
- `Entities` -> `Entity`
- `Attributes` -> `Attribute`
- `OptionSets` -> `OptionSet`
- `Options` -> `Option`

**Template Sets:**
- `default` - Separate files: `{{Entity.LogicalName}}.ts` and `{{Entity.LogicalName}}.optionset.ts`
- `onefile` - Single file: `{{Entity.LogicalName}}.ts` with attributes + optionsets inline

**Output Path Resolution:**
- Template files can be nested in subfolders; output mirrors template structure
- Folder and file names support tokens (e.g., `entities/{{Entity.SchemaName}}/{{Entity.LogicalName}}.ts`)
- Output path token resolver currently supports `{{Entity.*}}` tokens for path segments
- All paths resolved relative to script location via `Resolve-ScriptRelativePath`

## Public Module APIs

Use only exported module functions across scripts:

- **Pathing.psm1**: `Resolve-ScriptRelativePath`
- **ObjectTraversal.psm1**: `Get-DictionaryValueCaseInsensitive`, `Get-ObjectPropertyValueCaseInsensitive`
- **Auth.psm1**: `Get-DataverseAccessToken`
- **DataverseQueries.psm1**: `Get-DataverseSolutionsByUniqueNameUri`, `Get-DataverseSolutionComponentsEntityUri`, `Get-DataverseEntityDefinitionByMetadataIdUri`, `Get-DataverseEntityDefinitionByMetadataIdFilterUri`, `Get-DataverseEntityDefinitionByLogicalNameUri`, `Get-DataverseEntityDefinitionsUri`, `Get-DataverseEntityAttributesUri`, `Get-DataverseEntityTypedAttributesUri`
- **DataverseApi.psm1**: `Invoke-DataverseGet`, `Get-PagedItem`, `Get-EntityLogicalNamesFromSolution`, `Get-EntityAttribute`, `Get-EntityOptionSetDefinition`
- **EntitySelection.psm1**: `Resolve-SelectedEntityLogicalNames`
- **TemplateEngine.psm1**: `Convert-EntityTypeScriptContent`

## Key Conventions

### Settings Hierarchy

1. `settings.json` - Default values
2. Command-line parameters - Override settings.json
3. `-NoClean` / `-NoOverwrite` switches - Override boolean flags

### Path Resolution

All relative paths (`-TypeScriptOutputPath`, `-EntityListPath`, `-Template`) are resolved relative to the **script's directory**, not the current working directory. Use `Resolve-ScriptRelativePath` from `Pathing.psm1`.

### Entity Deduplication

Entity names are deduplicated case-insensitively. Unknown entities produce warnings but don't halt execution.

### Option Label Deduplication

Duplicate option labels within the same optionset get suffixed with their numeric value (e.g., `Active_0`, `Active_999910000`).

### Clean/Overwrite Behavior

- `Clean=$true` - Deletes entire output folder before generation
- `Overwrite=$true` - Replaces existing files
- `Overwrite=$false` - Skips existing files (no update)

## Running Scripts

### Generate Metadata

```powershell
# From solution
.\TypeScriptGenerator.ps1 -SolutionUniqueName "contoso_core"

# Specific entities
.\TypeScriptGenerator.ps1 -EntityLogicalNames "account","contact"

# Use entity.txt (default)
.\TypeScriptGenerator.ps1

# Custom template
.\TypeScriptGenerator.ps1 -Template "onefile"
```

### Analyze Usage

```powershell
# Scan TypeScript source for unused metadata
.\Analyze-TypeScriptMetadataUsage.ps1 -SourceFolders @(".\src|true", ".\tests|false")

# Auto-prune unused attributes/optionsets
.\Analyze-TypeScriptMetadataUsage.ps1 -SourceFolders @(".\src|true") -PruneMetadata

# Show removable attribute names
.\Analyze-TypeScriptMetadataUsage.ps1 -Verbose
```

Analyzer notes:
- Source folder entries use `path|true/false` where the suffix controls per-folder recursion.
- `Template=auto` inspects both onefile and default metadata usage patterns.
- If `-PruneMetadata` is not supplied and removable metadata is found, the script prompts interactively to prune.

**Detection patterns:**
- `entity.attributes.attributeName`
- `entity.attributes["attributeName"]`
- `const { attributeName } = entity.attributes`
- `entity.optionsets.optionSetName` (onefile template)
- `entityOptionSets.attributeName` (default template)

## Testing

No automated tests exist. Manual testing:

1. Run generation against known Dataverse environment
2. Verify output files in `generated/` match entity metadata
3. Import generated files in TypeScript project and validate types

## Common Issues

**"AADSTS50011" error** - Redirect URI mismatch. Ensure `-RedirectUri` matches Azure app registration (typically `http://localhost`).

**"Template folder not found"** - Templates folder must exist at `.\templates\<TemplateName>\` relative to script location.

**Duplicate output path error** - Multiple templates resolving to same output file for an entity. Check template file names for conflicts.

**Empty entity list** - If no entities specified via any source, script processes **all non-private entities** in the environment (can be slow).
