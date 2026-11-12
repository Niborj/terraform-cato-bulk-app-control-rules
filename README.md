# terraform-cato-bulk-app-control-rules

Bulk-manages the Cato **Application Control (CASB — applicationControl)**
policy from a single JSON export: sections and rules (flat policy — no
sub-policies exist for this type), with ordering and publishing via
`cato_bulk_apc_move_rule`.

## Usage

### Basic Example

```hcl
module "apc_rules" {
  source                   = "catonetworks/bulk-apc-rules/cato"
  apc_rules_json_file_path = "${path.module}/config_data/all_apc_rules_and_sections.json"
}
```

### JSON Configuration Structure

Generate the input JSON with:

```bash
catocli export apc_rules --json-filename all_apc_rules_and_sections.json
```

Root: `data.policy.applicationControl.policy` with `sections[]`, `rules[]`
(wrappers `{audit, rule, properties}`, ids retained for brownfield import),
and `rules_in_sections[]`. SYSTEM/LOCKED rules are excluded by the exporter.

Each rule carries `ruleType` (`APPLICATION` | `DATA` | `FILE`) and exactly one
matching typed body (`applicationRule` / `dataRule` / `fileRule`) — the module
emits the corresponding single variant block on `cato_application_control_rule`.
Shared body fields: `action`, `severity`, `application` (singular API ref,
wrapped into the TF set shape by the module), `applicationActivity[]` (+
`applicationActivitySatisfy`), `accessMethod[]` rows
(`{access_method, operator, value|valueSet}`), `device[]`, `schedule`,
`source` (14 selectors, each emitted only when non-empty), `tracking`,
`actionConfig.userNotification`. Type-specific: `fileAttribute[]` (+ satisfy)
on FILE, `dlpProfile{contentProfile[], edmProfile[]}` on DATA.

#### Key Fields:

- `sections[]` — flat sections (`section_index`, `section_name`, `section_id`)
- `rules[]` — rule wrappers (`{audit, rule, properties}`); `rule` carries
  `ruleType` and exactly one matching typed variant (`applicationRule` /
  `dataRule` / `fileRule`)
- `rules_in_sections[]` — ordering rows (`index_in_section`, `section_name`,
  `rule_name`); rows with `section_name: ""` are unordered (see below)

#### Resources Managed

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_application_control_section.sections` | `section_name` | created `LAST_IN_POLICY`; ordered by the move resource |
| `cato_application_control_rule.rules` | rule name | placement: managed section → `LAST_IN_SECTION`; sectionless → `LAST_IN_POLICY` |
| `cato_bulk_apc_move_rule.all_apc_rules` | — | orders sections (`section_index`) and rules (`index_in_section`) and **publishes** |

**Publishing:** the rule/section resources save to the draft policy only —
`cato_bulk_apc_move_rule` is the Application Control stack's single publisher.
Without it, applies never go live.

#### Selection fidelity (provider ≥ 1.5.0-prerelease.3)

- **Type/criteria-selected rules** (e.g. "all CLOUD_APPLICATIONs supporting PCI
  DSS") deploy faithfully: `application.applicationType` maps to the resource's
  `application_type`, and rule-level `applicationCriteria`/`Satisfy` map to
  `application_criteria`/`application_criteria_satisfy` (ANY-valued attributes
  are filtered — ANY is the API default for an omitted key).
- **Activity granular conditions** (`field`/`operator`/`value`/`valueSet`, e.g.
  Full Path URL CONTAINS …) and **CONTENT_TYPE file-attribute refs**
  (`contentTypeValues`/`contentTypeGroupValues`) pass through; `value` is
  omitted for CONTENT_TYPE rows (the API requires it null there).
- Activity refs map **BY ID** (catalog-global); everything else stays
  name-first. Country `"Any"` source refs are filtered (pseudo-entity).
- Rules whose export has **no application selector at all** are skipped and
  reported via the `skipped_rules` output — creating them would silently
  broaden scope.

### How Rule Ordering Works

`rules_in_sections[]` drives actual policy ordering, not the position of
entries in `sections[]`/`rules[]`. Each row's `section_index` (via the
section it names) and `index_in_section` are fed to
`cato_bulk_apc_move_rule.all_apc_rules`, which orders both sections and
rules and publishes the result. Rows with `section_name: ""` (rules at the
policy root with no managed section to order within) are excluded from the
move resource — their order is creation order, and they're surfaced via the
`unordered_rules` output for visibility.

### Parameters

- `apc_rules_json_file_path` — path to the Application Control JSON export
  produced by `catocli export apc_rules` (required)
- `allow_empty_policy` — safety guard: set `true` to allow planning against a
  0-rule policy JSON (intentional greenfield/teardown only); defaults to
  `false` so a truncated or wrong-tenant export can't destroy a live policy

## Working with Existing Rules (Brownfield Deployments)

### Installing and Configuring Cato CLI

1. **Install the Cato CLI:**
   ```bash
   pip3 install catocli
   ```

2. **Configure the CLI with your Cato credentials:**
   ```bash
   catocli configure set
   ```
   This will prompt you for your Cato Management Application credentials and account information.

### Exporting Existing Rules

To export your existing Application Control rules and sections into the JSON format required by this module:

```bash
catocli export apc_rules --json-filename all_apc_rules_and_sections.json
```

This command will generate a JSON file containing all your existing Application Control rules and sections in the correct format for this Terraform module.

### Importing Existing Rules into Terraform State (native import blocks)

Two ways to adopt existing state. All of this module's `for_each` state
addresses are keyed by name (`section_name`, rule name), which is exactly
what lets both options below line up directly against the exported JSON.

<details>
<summary>Option A (recommended) — native Terraform import blocks (migration.tf)</summary>

Requires Terraform >= 1.7. Create a one-shot `migration.tf` file beside your
module call with one `import` block per resource type:

<details>
<summary>migration.tf — import blocks for Application Control</summary>

```hcl
locals {
  apc = jsondecode(file("./config_data/all_apc_rules_and_sections.json")).data.policy.applicationControl.policy

  apc_sections = { for s in local.apc.sections : s.section_name => s }
  apc_rules    = { for r in local.apc.rules : r.rule.name => r.rule }
}

import {
  for_each = local.apc_sections
  to       = module.apc_rules.cato_application_control_section.sections[each.key]
  id       = each.value.section_id
}

import {
  for_each = local.apc_rules
  to       = module.apc_rules.cato_application_control_rule.rules[each.key]
  id       = each.value.id
}

# cato_bulk_apc_move_rule.all_apc_rules is plan-time ordering orchestration
# AND the stack's publisher (see "Publishing" above) — it has no live
# object of its own, so it is never imported; it's created (and publishes)
# on the first apply after the resources above are adopted. This module has
# no sub-policy support, so there is nothing else to import.
```

</details>

Preview before anything touches state:

```bash
terraform plan
```

Expect `N to import, 0 to add, 0 to change, 0 to destroy` (plus
`cato_bulk_apc_move_rule` showing as `1 to add`, since it's never imported —
see note above). Any non-zero "to change" means the JSON export is stale
relative to the live policy — **re-export**
(`catocli export apc_rules`) and regenerate the locals above, rather than
letting `terraform apply` overwrite the live policy with stale config.

Once the plan looks right, adopt into state:

```bash
terraform apply
```

Then delete `migration.tf` — its job is done, and leaving it in place just
re-runs the same (no-op) import blocks on every future plan.

</details>

<details>
<summary>Option B — catocli import apc_rules_to_tf (imperative alternative)</summary>

An imperative alternative to Option A, for when native import blocks aren't
practical (e.g. scripting a fully automated onboarding pipeline). Unlike
Option A, this mutates Terraform state immediately — there is no plan
preview before the import happens.

```bash
catocli import apc_rules_to_tf config_data/all_apc_rules_and_sections.json \
  --module-name module.apc_rules --auto-approve
terraform plan   # expect: only cato_bulk_apc_move_rule to add
```

</details>

### Typical Brownfield Workflow

1. **Export existing rules:**
   ```bash
   catocli export apc_rules --json-filename all_apc_rules_and_sections.json
   ```

2. **Create your Terraform configuration** pointing `apc_rules_json_file_path`
   at the exported file (see Basic Example above).

3. **Adopt existing state (Option A — recommended):** create `migration.tf`
   with the import blocks shown above, then:
   ```bash
   terraform plan    # preview: expect only "to import"
   terraform apply   # adopt into state
   ```
   Delete `migration.tf` afterwards. (Option B:
   `catocli import apc_rules_to_tf config_data/all_apc_rules_and_sections.json --module-name module.apc_rules --auto-approve`
   — imperative, no plan preview.)

4. **Run Terraform plan to verify:**
   ```bash
   terraform plan
   ```
   This should show no changes if the import was successful.

### Backup and Restore Workflow

If unintended changes are made directly to rules and sections in the Cato
Management Application, you can restore to the last known good state:

1. **Apply your last known good configuration:**
   ```bash
   terraform apply
   ```
   This will restore rules and sections to match your Terraform configuration.

2. **Alternatively, re-export and compare:**
   ```bash
   catocli export apc_rules --json-filename all_apc_rules_and_sections.json
   # Compare with your existing JSON file to identify drift
   ```

## Using Module Outputs

```hcl
# Quick reference for rule and section IDs
output "quick_reference" {
  description = "Quick reference maps for rules and sections"
  value = {
    section_ids = module.apc_rules.section_ids
    rule_ids    = module.apc_rules.rule_ids
  }
}

# Deployment overview
output "deployment_info" {
  description = "Counts of managed Application Control objects"
  value       = module.apc_rules.deployment_summary
}

# Rows the move resource couldn't order (section_name "")
output "unordered_rules_report" {
  description = "Ordering rows excluded from cato_bulk_apc_move_rule; order is creation order"
  value       = module.apc_rules.unordered_rules
}
```

### Output Use Cases

- **`deployment_summary`**: section/rule counts for a deployment dashboard
- **`section_ids`**: ID lookups for referencing sections from other modules
- **`rule_ids`**: ID lookups for referencing rules from other modules
- **`unordered_rules`**: audit which ordering rows (root-level rules with
  `section_name: ""`) are creation-order only, not move-resource-ordered

## Known limitations

- Ordering rows with `section_name: ""` are excluded from the move resource
  and surfaced via `unordered_rules`; their order is creation order.
- `source` sub-selectors with provider `SizeAtLeast(1)` validators are only
  emitted when non-empty — an empty list in the export is equivalent to
  omitting the selector.
- Run applies with `-parallelism=1` when several module instances share an
  account.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cato"></a> [cato](#requirement\_cato) | >= 1.3.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cato"></a> [cato](#provider\_cato) | 1.3.1 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cato_application_control_rule.rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/application_control_rule) | resource |
| [cato_application_control_section.sections](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/application_control_section) | resource |
| [cato_bulk_apc_move_rule.all_apc_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/bulk_apc_move_rule) | resource |
| [terraform_data.guard_empty_policy](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allow_empty_policy"></a> [allow\_empty\_policy](#input\_allow\_empty\_policy) | Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown. | `bool` | `false` | no |
| <a name="input_apc_rules_json_file_path"></a> [apc\_rules\_json\_file\_path](#input\_apc\_rules\_json\_file\_path) | Path to the Application Control JSON export produced by `catocli export apc_rules` (data.policy.applicationControl.policy root). | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_summary"></a> [deployment\_summary](#output\_deployment\_summary) | Counts of managed Application Control objects. |
| <a name="output_rule_ids"></a> [rule\_ids](#output\_rule\_ids) | Map of rule name to rule id. |
| <a name="output_section_ids"></a> [section\_ids](#output\_section\_ids) | Map of section name to section id. |
| <a name="output_unordered_rules"></a> [unordered\_rules](#output\_unordered\_rules) | rules\_in\_sections rows excluded from cato\_bulk\_apc\_move\_rule (no managed section to order within). |
<!-- END_TF_DOCS -->
