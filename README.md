# TypeScriptGenerator

Generate TypeScript metadata from Dataverse.

For each selected entity, the script renders every template file found in `templates/<Template>/` and writes output into `generated/` using the same relative path structure.

No `index.ts` is generated.

## Project Files

- `TypeScriptGenerator.ps1`: main script
- `modules/Auth.psm1`: interactive authentication
- `modules/DataverseApi.psm1`: Dataverse Web API calls
- `modules/DataverseQueries.psm1`: centralized Dataverse Web API query/URI builders
- `modules/EntitySelection.psm1`: entity selection and deduplication
- `modules/TemplateEngine.psm1`: template rendering
- `modules/Pathing.psm1`: script-relative path resolution
- `modules/ObjectTraversal.psm1`: shared case-insensitive object/dictionary traversal helpers
- `settings.json`: default configuration values
- `entity.txt`: optional entity list
- `templates/default/{{Entity.LogicalName}}.ts`: template for entity metadata output name pattern
- `templates/default/{{Entity.LogicalName}}.optionset.ts`: template for entity option set output name pattern
- `templates/onefile/{{Entity.LogicalName}}.ts`: one-file template (entity + attributes + optionsets)

## Requirements

- PowerShell 5.1+ or PowerShell 7+
- Dataverse user with metadata read access
- `MSAL.PS` module (auto-install is attempted when missing)

Defaults:

Defaults are read from `settings.json`.
Command-line parameters override values from `settings.json`.

`settings.json` (example):

```json
{
  "EnvironmentUrl": "https://<org>.crm4.dynamics.com",
  "TenantId": "organizations",
  "ClientId": "51f81489-12ee-4a9e-aaae-a2591f45987d",
  "RedirectUri": "http://localhost",
  "Template": "default",
  "TypeScriptOutputPath": ".\\generated",
  "Clean": true,
  "Overwrite": true,
  "OptionSetLabelLcid": 1033,
  "MaxParallelEntities": 4,
  "EntityListPath": ".\\entity.txt",
  "EntityLogicalNames": [],
  "SolutionUniqueName": ""
}
```

Optional script parameter:

- `-SettingsPath` (default: `.\settings.json`)
- `-MaxParallelEntities` (default: `4`)

`EnvironmentUrl` can come from `settings.json` or from `-EnvironmentUrl`. One of both is required.

Path parameters are resolved relative to the script location when you pass a relative path.
The template set folder is `.\templates\<Template>\`.
Template discovery and output mapping:

- all template files are discovered recursively (subfolders supported)
- each template file generates one output file per selected entity
- output relative path pattern = template file relative path inside the template set
- folder names and file names may contain tokens

Template file names can contain tokens and are used as output file name patterns:

- `{{Entity.LogicalName}}`
- `{{Entity.SchemaName}}`
- `{{Entity.DisplayName}}`
- `{{Entity.<AnyAvailableEntityField>}}`

Notes:

- path tokens are resolved per entity when generating output file paths
- token values are sanitized to safe file/folder segment text (invalid filename chars are replaced)

Implementation notes:

- entity selection is resolved through `Resolve-SelectedEntityLogicalNames`
- Dataverse paging is handled by `Get-PagedItem`
- template rendering entrypoint is `Convert-EntityTypeScriptContent`

## Quick Start

```powershell
.\TypeScriptGenerator.ps1 `
  -SolutionUniqueName "contoso_core"
```

## Common Usage

Examples below assume `EnvironmentUrl` is set in `settings.json` or passed explicitly with `-EnvironmentUrl`.

Use explicit entities:

```powershell
.\TypeScriptGenerator.ps1 `
  -EntityLogicalNames "account","contact"
```

Use `entity.txt`:

```text
account
contact
```

Supported in entity list files:

- one entity per line
- comma/semicolon separated values (`account,contact` or `account;contact`)
- `#` comments (full line or inline)

```powershell
.\TypeScriptGenerator.ps1
```

Use a custom entity list file:

```powershell
.\TypeScriptGenerator.ps1 `
  -EntityListPath ".\\my-entities.txt"
```

Use a different output folder:

```powershell
.\TypeScriptGenerator.ps1 `
  -TypeScriptOutputPath ".\\generated"
```

Control clean/overwrite behavior:

```powershell
.\TypeScriptGenerator.ps1 `
  -Clean $true `
  -Overwrite $true
```

Convenience switches:

```powershell
.\TypeScriptGenerator.ps1 `
  -NoClean `
  -NoOverwrite
```

Behavior:

- `Clean=$true` clears the target output folder before generation.
- `Overwrite=$true` overwrites existing files.
- `Overwrite=$false` keeps existing files and skips writing those files.

Use custom templates:

```powershell
.\TypeScriptGenerator.ps1 `
  -Template "default"
```

Use onefile template set:

```powershell
.\TypeScriptGenerator.ps1 `
  -Template "onefile"
```

Use another template set folder:

```powershell
.\TypeScriptGenerator.ps1 `
  -Template "schema"
```

In `templates/schema`, use file names with `Entity.SchemaName`:

- `{{Entity.SchemaName}}.ts`
- `{{Entity.SchemaName}}.optionset.ts`

For a schema-based onefile set, use only:

- `{{Entity.SchemaName}}.ts`

Use tokenized subfolders:

```text
templates/custom/
  entities/{{Entity.LogicalName}}.ts
  optionsets/{{Entity.SchemaName}}/{{Entity.LogicalName}}.optionset.ts
```

This generates:

```text
generated/entities/account.ts
generated/optionsets/Account/account.optionset.ts
```

Set label language (LCID):

```powershell
.\TypeScriptGenerator.ps1 `
  -OptionSetLabelLcid 1043
```

Control parallel metadata retrieval workers:

```powershell
.\TypeScriptGenerator.ps1 `
  -MaxParallelEntities 6
```

## Entity Selection Rules

The script combines these sources:

- `-EntityLogicalNames`
- `entity.txt` (or `-EntityListPath`)
- `-SolutionUniqueName`

Duplicates are removed case-insensitively.
If no sources provide entities, all non-private entities are processed.
Unknown entity logical names are skipped with a warning.

## Template Syntax

Templates support plain placeholders and loops.

Placeholder syntax:

- `{{TokenName}}`
- `{{Parent.ChildToken}}` (dot notation)

Loop syntax:

- `{{#CollectionName}} ... {{/CollectionName}}`
- `{{#Parent.CollectionName}} ... {{/Parent.CollectionName}}`

Inside a loop, the singular alias of the collection is available automatically:

- `Entities` -> `Entity`
- `Attributes` -> `Attribute`
- `OptionSets` -> `OptionSet`
- `Options` -> `Option`

Template validation behavior:

- Unknown placeholder tokens cause generation to fail.
- Unknown loop collections cause generation to fail.
- Tokens that resolve to non-scalar values cause generation to fail.

### Entity Template Tokens

Top-level:

- `{{Entity.LogicalName}}`
- `{{Entity.SchemaName}}`
- `{{Entity.DisplayName}}`
- `{{Entity.<AnyAvailableEntityField>}}`

Inside `{{#Entities}}`:

- `{{Entity.LogicalName}}`
- `{{Entity.SchemaName}}`
- `{{Entity.DisplayName}}`
- `{{Entity.<AnyAvailableEntityField>}}`

Inside `{{#Attributes}}`:

- `{{Attribute.LogicalName}}`
- `{{Attribute.SchemaName}}`
- `{{Attribute.Key}}`
- `{{Attribute.<AnyAvailableAttributeField>}}`

### Option Sets Template Tokens

Top-level:

- `{{Entity.LogicalName}}`

Inside `{{#OptionSets}}`:

- `{{OptionSet.AttributeLogicalName}}`
- `{{OptionSet.AttributeKey}}`
- `{{OptionSet.Name}}`
- `{{OptionSet.IsGlobal}}`
- `{{OptionSet.<AnyAvailableOptionSetField>}}`

Inside nested `{{#Options}}` (within an option set):

- `{{Option.Label}}`
- `{{Option.Key}}`
- `{{Option.RawValue}}`
- `{{Option.Value}}`
- `{{Option.Comma}}`
- `{{Option.<AnyAvailableOptionField>}}`

These same `OptionSets`/`Options` tokens are available in every template file.

If multiple template files resolve to the same output path for the selected entities, generation stops with a duplicate path error.

## Duplicate Option Labels

If an option label appears more than once in the same option set, all duplicates get a value suffix:

- `Active_0`
- `Active_99099091`

## Analyze TypeScript Usage

Use the separate script `Analyze-TypeScriptMetadataUsage.ps1` to scan TypeScript source files and inventory:

- which generated entities are imported
- which attributes are used
- which option sets are used
- which attributes and option sets are unused in generated metadata

The script prints a console summary per entity and can optionally prune unused attributes and option sets from generated metadata files.

### Parameters

- `-SourceFolders` (required): one or more entries in format `path|true/false`
  - `path` = source folder
  - `true/false` = recursive per folder
- `-Template` (default: `auto`): `auto`, `default`, or `onefile`
  - `default`: analyze separate `.optionset.ts` files
  - `onefile`: analyze `optionsets` inside entity metadata classes
  - `auto`: analyze both patterns
- `-GeneratedMetadataPath` (default: `.\generated`)
- `-PruneMetadata` (optional): remove unused attributes and option sets from generated files
- `-SettingsPath` (default: `.\Analyze-TypeScriptMetadataUsage.settings.json`)
- `-Verbose` (optional): show which attributes are removable per entity

Parameter precedence:

- script parameters override values from `Analyze-TypeScriptMetadataUsage.settings.json`
- if `-SourceFolders` is omitted, `SourceFolders` from settings is used
- if `-PruneMetadata` is omitted, `PruneMetadata` from settings controls prune mode

When `-PruneMetadata` is not set and removable attributes are found, the script asks at the end if prune should run now.

### Examples

Scan multiple folders with mixed recursive behavior:

```powershell
.\Analyze-TypeScriptMetadataUsage.ps1 `
  -Template "auto" `
  -SourceFolders @(".\src|true", ".\tests|false", ".\webresources|true")
```

Scan and prune generated metadata:

```powershell
.\Analyze-TypeScriptMetadataUsage.ps1 `
  -Template "default" `
  -SourceFolders @(".\src|true", ".\tests|false") `
  -GeneratedMetadataPath ".\generated" `
  -PruneMetadata
```

Run from settings file only:

```powershell
.\Analyze-TypeScriptMetadataUsage.ps1
```

Use an explicit settings file:

```powershell
.\Analyze-TypeScriptMetadataUsage.ps1 `
  -SettingsPath ".\Analyze-TypeScriptMetadataUsage.settings.json"
```

Show removable attribute names:

```powershell
.\Analyze-TypeScriptMetadataUsage.ps1 -Verbose
```

Note: detection is based on static usage patterns such as:

- `entity.attributes.attributeName`
- `entity.attributes["attributeName"]`
- `const { attributeName } = entity.attributes`
- `entity.optionsets.optionSetName` (onefile)
- `entityOptionSets.attributeName`

## Troubleshooting

If you get `AADSTS50011`, provide a redirect URI that matches your app registration:

```powershell
.\TypeScriptGenerator.ps1 `
  -EnvironmentUrl "https://<org>.crm4.dynamics.com" `
  -RedirectUri "http://localhost"
```

For detailed metadata diagnostics, run with `-Verbose`.

If you see an authority/tenant error right at login, verify parameter syntax: in PowerShell use `-EnvironmentUrl` (single dash), not `--EnvironmentUrl`.

