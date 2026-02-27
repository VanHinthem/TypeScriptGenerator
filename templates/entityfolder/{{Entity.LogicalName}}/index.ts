export { {{Entity.LogicalName}} } from "./{{Entity.LogicalName}}";
export { {{Entity.LogicalName}}OptionSets } from "./{{Entity.LogicalName}}.optionset";
{{#OptionSets}}export { {{Entity.LogicalName}}OptionSet_{{OptionSet.AttributeLogicalName}} } from "./{{Entity.LogicalName}}.optionset";
{{/OptionSets}}