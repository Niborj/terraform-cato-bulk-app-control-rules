# terraform-cato-bulk-app-control-rules

Bulk-manages the Cato **Application Control (CASB — applicationControl)**
policy from a single JSON export: sections and rules (flat policy — no
sub-policies exist for this type), with ordering and publishing via
`cato_bulk_apc_move_rule`.

## Resources managed

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_application_control_section.sections` | `section_name` | created `LAST_IN_POLICY`; ordered by the move resource |
| `cato_application_control_rule.rules` | rule name | placement: managed section → `LAST_IN_SECTION`; sectionless → `LAST_IN_POLICY` |
| `cato_bulk_apc_move_rule.all_apc_rules` | — | orders sections (`section_index`) and rules (`index_in_section`) and **publishes** |

**Publishing:** the rule/section resources save to the draft policy only —
`cato_bulk_apc_move_rule` is the Application Control stack's single publisher.
Without it, applies never go live.

## Input JSON

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

## Usage

```hcl
module "apc_rules" {
  source                   = "catonetworks/bulk-apc-rules/cato"
  apc_rules_json_file_path = "${path.module}/config_data/all_apc_rules_and_sections.json"
}
```

## Brownfield import

```bash
catocli import apc_rules_to_tf config_data/all_apc_rules_and_sections.json \
  --module-name module.apc_rules --auto-approve
terraform plan   # expect: only cato_bulk_apc_move_rule to add
```

## Known limitations

- Ordering rows with `section_name: ""` are excluded from the move resource
  and surfaced via `unordered_rules`; their order is creation order.
- `source` sub-selectors with provider `SizeAtLeast(1)` validators are only
  emitted when non-empty — an empty list in the export is equivalent to
  omitting the selector.
- Run applies with `-parallelism=1` when several module instances share an
  account.
