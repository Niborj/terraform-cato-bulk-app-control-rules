# terraform-cato-bulk-app-control-rules
#
# Bulk-manages the Cato Application Control (applicationControl) policy from
# one JSON export produced by `catocli export apc_rules`:
#   sections[]           flat sections ({section_index, section_name, section_id})
#   rules[]              rule wrappers ({audit, rule, properties}); rule carries
#                        ruleType (APPLICATION|DATA|FILE) and ONLY the matching
#                        typed-rule variant (applicationRule/dataRule/fileRule)
#   rules_in_sections[]  ordering rows
#
# Flat policy: no sub-policies. cato_application_control_rule publishes per
# mutation; cato_bulk_apc_move_rule applies ordering and republishes.
#
# Known terraform-surface limitations (fields present in exports but not
# manageable): applicationActivity rows keep only the activity ref (field/
# operator/value have no terraform attribute - updating such a rule through
# terraform would drop those conditions); applicationContext is dropped at
# export (the provider injects an empty input). application.applicationType
# and rule-level applicationCriteria/_Satisfy ARE managed (provider >=
# 1.5.0-prerelease.3 with the APC criteria surfaces).

locals {
  apc_json = jsondecode(file("${var.apc_rules_json_file_path}"))
  apc      = local.apc_json.data.policy.applicationControl.policy

  sections_data_raw      = try(local.apc.sections, [])
  rules_data_raw         = try(local.apc.rules, [])
  rules_in_sections_data = try(local.apc.rules_in_sections, [])

  sections_data = {
    for s in local.sections_data_raw : s.section_name => s
  }

  rules_by_name = {
    for rw in local.rules_data_raw : rw.rule.name => rw
  }

  move_section_data = {
    for name, s in local.sections_data : name => {
      section_index = s.section_index
    }
  }

  move_rule_data = {
    for row in local.rules_in_sections_data :
    row.rule_name => {
      index_in_section = row.index_in_section
      section_name     = row.section_name
    }
    if row.section_name != "" && contains(keys(local.sections_data), row.section_name) && !contains(keys(local.skipped_rules), row.rule_name)
  }

  unordered_rules_data = [
    for row in local.rules_in_sections_data : row
    if !contains(keys(local.move_rule_data), try(row.rule_name, "")) && !contains(keys(local.skipped_rules), try(row.rule_name, ""))
  ]

  # Active typed-rule variant per rule (export keeps exactly one).
  active_variant = {
    for name, rw in local.rules_by_name :
    name => lookup(rw.rule, {
      APPLICATION = "applicationRule"
      DATA        = "dataRule"
      FILE        = "fileRule"
    }[rw.rule.ruleType], null)
  }

  # ─── unrepresentable-rule detection ──────────────────────────────────────
  # The addRule API requires the application input to select EXACTLY ONE of
  # application/customApp/appCategory/customCategory/sanctionedAppsCategory/
  # applicationType -- a rule whose export carries none of them cannot be
  # created faithfully (and sending an empty application is rejected outright).
  # applicationType + rule-level applicationCriteria are full provider surfaces
  # as of 1.5.0-prerelease.3, so type/criteria-selected rules now deploy.
  rule_app_named = {
    for name, v in local.active_variant : name => (
      try(v.application.application, null) != null ||
      try(v.application.customApp, null) != null ||
      try(v.application.appCategory, null) != null ||
      try(v.application.customCategory, null) != null ||
      try(v.application.sanctionedAppsCategory, null) != null ||
      length(try(v.application.applicationType, [])) > 0
    )
  }
  rule_criteria_trivial = {
    for name, v in local.active_variant : name => (
      try(v.applicationCriteria, null) == null ? true : alltrue(concat(
        [for k, val in try(v.applicationCriteria.attributes.complianceAttributes, {}) : val == "ANY"],
        [for k, val in try(v.applicationCriteria.attributes.securityAttributes, {}) : val == "ANY"],
        [
          length(try(v.applicationCriteria.risk, [])) == 0,
          length(try(v.applicationCriteria.originCountry, [])) == 0,
          length(try(v.applicationCriteria.aiRisk, [])) == 0,
        ],
      ))
    )
  }
  skipped_rules = {
    for name, v in local.active_variant :
    name => "no application selector in export (needs one of application/customApp/appCategory/customCategory/sanctionedAppsCategory/applicationType) -- creating it would silently broaden scope"
    if !local.rule_app_named[name]
  }
  deployable_rules_by_name = {
    for name, rw in local.rules_by_name : name => rw
    if !contains(keys(local.skipped_rules), name)
  }

  # Country "Any" is a CMA pseudo-entity meaning "no country filter" -- the API
  # rejects it as a real entity ref (ruleHasInvalidEntity). An empty/omitted
  # country list is the equivalent selection, so filter it out.
  source_countries = {
    for name, v in local.active_variant :
    name => [for x in try(v.source.country, []) : x if try(x.name, "") != "Any"]
  }

  # ─── typed-rule body translation (API camelCase -> provider snake_case) ──
  # Entity refs are name-or-id; API single-object refs (application block) are
  # wrapped into terraform sets. Optional selector sets are included only when
  # non-empty (the provider enforces SizeAtLeast(1)).
  typed_rule_bodies = {
    for name, v in local.active_variant : name => merge(
      {
        action   = v.action
        severity = v.severity
      },
      # source: include only populated selectors; omit the block when empty
      length(merge(
        length(local.source_countries[name]) > 0 ? { country = [for x in local.source_countries[name] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(length(v.source.ip), 0) > 0 ? { ip = v.source.ip } : {},
        try(length(v.source.host), 0) > 0 ? { host = [for x in v.source.host : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(length(v.source.site), 0) > 0 ? { site = [for x in v.source.site : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(length(v.source.subnet), 0) > 0 ? { subnet = v.source.subnet } : {},
        try(length(v.source.ipRange), 0) > 0 ? { ip_range = [for r in v.source.ipRange : { from = r.from, to = r.to }] } : {},
        try(length(v.source.globalIpRange), 0) > 0 ? { global_ip_range = [for x in v.source.globalIpRange : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(length(v.source.networkInterface), 0) > 0 ? { network_interface = [for x in v.source.networkInterface : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(length(v.source.siteNetworkSubnet), 0) > 0 ? { site_network_subnet = [for x in v.source.siteNetworkSubnet : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(length(v.source.floatingSubnet), 0) > 0 ? { floating_subnet = [for x in v.source.floatingSubnet : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(length(v.source.user), 0) > 0 ? { user = [for x in v.source.user : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(length(v.source.usersGroup), 0) > 0 ? { users_group = [for x in v.source.usersGroup : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(length(v.source.group), 0) > 0 ? { group = [for x in v.source.group : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(length(v.source.systemGroup), 0) > 0 ? { system_group = [for x in v.source.systemGroup : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
        )) > 0 ? {
        source = merge(
          length(local.source_countries[name]) > 0 ? { country = [for x in local.source_countries[name] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(v.source.ip), 0) > 0 ? { ip = v.source.ip } : {},
          try(length(v.source.host), 0) > 0 ? { host = [for x in v.source.host : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(v.source.site), 0) > 0 ? { site = [for x in v.source.site : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(v.source.subnet), 0) > 0 ? { subnet = v.source.subnet } : {},
          try(length(v.source.ipRange), 0) > 0 ? { ip_range = [for r in v.source.ipRange : { from = r.from, to = r.to }] } : {},
          try(length(v.source.globalIpRange), 0) > 0 ? { global_ip_range = [for x in v.source.globalIpRange : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(v.source.networkInterface), 0) > 0 ? { network_interface = [for x in v.source.networkInterface : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(v.source.siteNetworkSubnet), 0) > 0 ? { site_network_subnet = [for x in v.source.siteNetworkSubnet : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(v.source.floatingSubnet), 0) > 0 ? { floating_subnet = [for x in v.source.floatingSubnet : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(v.source.user), 0) > 0 ? { user = [for x in v.source.user : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(v.source.usersGroup), 0) > 0 ? { users_group = [for x in v.source.usersGroup : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(v.source.group), 0) > 0 ? { group = [for x in v.source.group : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(v.source.systemGroup), 0) > 0 ? { system_group = [for x in v.source.systemGroup : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
        )
      } : {},
      # tracking (defaults match the provider's)
      {
        tracking = {
          event = { enabled = try(v.tracking.event.enabled, false) }
          alert = merge(
            {
              enabled   = try(v.tracking.alert.enabled, false)
              frequency = try(v.tracking.alert.frequency, "HOURLY")
            },
            try(length(v.tracking.alert.subscriptionGroup), 0) > 0 ? { subscription_group = [for x in v.tracking.alert.subscriptionGroup : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
            try(length(v.tracking.alert.webhook), 0) > 0 ? { webhook = [for x in v.tracking.alert.webhook : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
            try(length(v.tracking.alert.mailingList), 0) > 0 ? { mailing_list = [for x in v.tracking.alert.mailingList : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
          )
        }
      },
      try(v.schedule, null) != null ? {
        schedule = merge(
          { active_on = try(v.schedule.activeOn, "ALWAYS") },
          try(v.schedule.customTimeframe, null) != null ? {
            custom_timeframe = { from = v.schedule.customTimeframe.from, to = v.schedule.customTimeframe.to }
          } : {},
          try(v.schedule.customRecurring, null) != null ? {
            custom_recurring = { days = v.schedule.customRecurring.days, from = v.schedule.customRecurring.from, to = v.schedule.customRecurring.to }
          } : {}
        )
      } : {},
      try(length(v.device), 0) > 0 ? {
        device = [for x in v.device : can(x.name) ? { name = x.name } : { id = x.id }]
      } : {},
      try(length(v.accessMethod), 0) > 0 ? {
        access_method = [for am in v.accessMethod : merge(
          { access_method = am.accessMethod, operator = am.operator },
          try(am.value, null) != null ? { value = am.value } : (
            try(am.valueSet, null) != null ? { value = try(am.valueSet.id, am.valueSet.name) } : {}
          )
        )]
      } : {},
      # application block: API returns SINGLE refs; terraform takes sets.
      length(merge(
        try(v.application.application, null) != null ? { application = [for x in [v.application.application] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(v.application.customApp, null) != null ? { custom_app = [for x in [v.application.customApp] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(v.application.appCategory, null) != null ? { app_category = [for x in [v.application.appCategory] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(v.application.customCategory, null) != null ? { custom_category = [for x in [v.application.customCategory] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        try(v.application.sanctionedAppsCategory, null) != null ? { sanctioned_apps_category = [for x in [v.application.sanctionedAppsCategory] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
        length(try(v.application.applicationType, [])) > 0 ? { application_type = v.application.applicationType } : {}
        )) > 0 ? {
        application = merge(
          try(v.application.application, null) != null ? { application = [for x in [v.application.application] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(v.application.customApp, null) != null ? { custom_app = [for x in [v.application.customApp] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(v.application.appCategory, null) != null ? { app_category = [for x in [v.application.appCategory] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(v.application.customCategory, null) != null ? { custom_category = [for x in [v.application.customCategory] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(v.application.sanctionedAppsCategory, null) != null ? { sanctioned_apps_category = [for x in [v.application.sanctionedAppsCategory] : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          length(try(v.application.applicationType, [])) > 0 ? { application_type = v.application.applicationType } : {}
        )
      } : {},
      try(length(v.applicationActivity), 0) > 0 ? {
        # Activities are the one EXCEPTION to the name-first convention: their
        # ids are CATALOG-GLOBAL (identical across tenants, e.g.
        # openai_login_third_party), and the addRule API resolves activities
        # reliably only BY ID -- by-NAME fails server-side with
        # "activity: <app>-<name> does not exist". The exporter keeps both
        # fields on activity refs for exactly this reason.
        application_activity = [for a in v.applicationActivity : merge(
          {
            activity = can(a.activity.id) ? { id = a.activity.id } : { name = a.activity.name }
          },
          # granular conditions -- some activities (e.g. Full Path URL) REQUIRE
          # a field/operator/value; the API rejects a bare activity ref.
          try(a.field, null) != null ? { field = can(a.field.id) ? { id = a.field.id } : { name = a.field.name } } : {},
          try(a.operator, null) != null ? { operator = a.operator } : {},
          try(a.value, null) != null ? { value = tostring(a.value) } : {},
          try(a.valueSet, null) != null ? { value_set = can(a.valueSet.id) ? { id = a.valueSet.id } : { name = a.valueSet.name } } : {}
        )]
      } : {},
      try(v.applicationActivitySatisfy, null) != null ? {
        application_activity_satisfy = v.applicationActivitySatisfy
      } : {},
      # application_criteria: rule-level in BOTH export and provider. "ANY"
      # attribute values mean "no constraint" -- the provider requires them
      # omitted, so only non-ANY entries are passed through. Risk scores are
      # numbers in exports, strings in the provider schema.
      !local.rule_criteria_trivial[name] ? {
        application_criteria = merge(
          length({ for k, val in try(v.applicationCriteria.attributes.complianceAttributes, {}) : k => val if val != "ANY" }) > 0 ? {
            compliance_attributes = { for k, val in v.applicationCriteria.attributes.complianceAttributes : k => val if val != "ANY" }
          } : {},
          length({ for k, val in try(v.applicationCriteria.attributes.securityAttributes, {}) : k => val if val != "ANY" }) > 0 ? {
            security_attributes = { for k, val in v.applicationCriteria.attributes.securityAttributes : k => val if val != "ANY" }
          } : {},
          length(try(v.applicationCriteria.originCountry, [])) > 0 ? {
            origin_country = [for x in v.applicationCriteria.originCountry : can(x.name) ? { name = x.name } : { id = x.id }]
          } : {},
          length(try(v.applicationCriteria.risk, [])) > 0 ? {
            risk = [for r in v.applicationCriteria.risk : { risk = tostring(r.risk), risk_operator = r.riskOperator }]
          } : {},
          length(try(v.applicationCriteria.aiRisk, [])) > 0 ? {
            ai_risk = [for a in v.applicationCriteria.aiRisk : a]
          } : {}
        )
      } : {},
      !local.rule_criteria_trivial[name] ? {
        application_criteria_satisfy = try(v.applicationCriteriaSatisfy, "ALL")
      } : {},
      try(length(v.actionConfig.userNotification), 0) > 0 ? {
        action_config = {
          user_notification = [for x in v.actionConfig.userNotification : can(x.name) ? { name = x.name } : { id = x.id }]
        }
      } : {},
      try(length(v.fileAttribute), 0) > 0 ? {
        file_attribute = [for fa in v.fileAttribute : merge(
          { file_attribute = fa.fileAttribute, operator = fa.operator },
          # CONTENT_TYPE rows must NOT carry value -- they select via the
          # content-type ref sets below.
          try(fa.value, null) != null ? { value = tostring(fa.value) } : {},
          try(length(fa.contentTypeValues), 0) > 0 ? { content_type_values = [for x in fa.contentTypeValues : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(fa.contentTypeGroupValues), 0) > 0 ? { content_type_group_values = [for x in fa.contentTypeGroupValues : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
        )]
      } : {},
      try(v.fileAttributeSatisfy, null) != null ? {
        file_attribute_satisfy = v.fileAttributeSatisfy
      } : {},
      # dlp_profile: required for DATA rules (>=1 content or edm profile)
      length(merge(
        try(length(v.dlpProfile.contentProfile), 0) > 0 ? { x = 1 } : {},
        try(length(v.dlpProfile.edmProfile), 0) > 0 ? { y = 1 } : {}
        )) > 0 ? {
        dlp_profile = merge(
          try(length(v.dlpProfile.contentProfile), 0) > 0 ? { content_profile = [for x in v.dlpProfile.contentProfile : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(v.dlpProfile.edmProfile), 0) > 0 ? { edm_profile = [for x in v.dlpProfile.edmProfile : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
        )
      } : {}
    )
  }
}

# Safety guard: evaluated even with 0 rule for_each instances (a precondition
# on the rule resource itself would never run if local.rules_data_raw is
# empty). Fails plan unless var.allow_empty_policy is explicitly set.
resource "terraform_data" "guard_empty_policy" {
  lifecycle {
    precondition {
      condition     = var.allow_empty_policy || length(local.rules_data_raw) > 0
      error_message = "Policy JSON contains 0 rules. If intentional (greenfield/teardown), set allow_empty_policy = true. A truncated or wrong-tenant export would otherwise destroy the entire live policy."
    }
  }
}

# Optional account-level policy toggle. null leaves the toggle unmanaged (count 0);
# true/false manages the account-wide Application Control enable/disable state. The
# provider requires data_control_enabled alongside enabled, so the optional
# policy_data_control_enabled variable (default false) supplies it.
resource "cato_application_control_policy" "policy" {
  count                = var.policy_enabled == null ? 0 : 1
  enabled              = var.policy_enabled
  data_control_enabled = var.policy_data_control_enabled
}

resource "cato_application_control_section" "sections" {
  for_each = local.sections_data
  at = {
    position = "LAST_IN_POLICY"
  }
  section = {
    name = each.value.section_name
  }
}

resource "cato_application_control_rule" "rules" {
  depends_on = [cato_application_control_section.sections]
  for_each   = local.deployable_rules_by_name

  at = contains(keys(local.sections_data), each.value.rule.section.name) ? {
    position = "LAST_IN_SECTION"
    ref      = cato_application_control_section.sections[each.value.rule.section.name].id
    } : {
    position = "LAST_IN_POLICY"
  }

  rule = merge(
    {
      name      = each.key
      enabled   = try(each.value.rule.enabled, true)
      rule_type = each.value.rule.ruleType
    },
    try(each.value.rule.description, "") != "" ? { description = each.value.rule.description } : {},
    each.value.rule.ruleType == "APPLICATION" ? { application_rule = local.typed_rule_bodies[each.key] } : {},
    each.value.rule.ruleType == "DATA" ? { data_rule = local.typed_rule_bodies[each.key] } : {},
    each.value.rule.ruleType == "FILE" ? { file_rule = local.typed_rule_bodies[each.key] } : {}
  )

  # `at` is a create-time positioning directive; actual ordering is owned by
  # cato_bulk_apc_move_rule. On brownfield import the provider hydrates `at` as
  # LAST_IN_POLICY (it can't recover the original directive), so a rule placed in
  # a named section (LAST_IN_SECTION) shows a phantom diff on every import.
  # Ignore post-create `at` changes -- ordering is reconciled by the move resource.
  lifecycle {
    ignore_changes = [at]
  }
}

# Ordering + republish on changes.
resource "cato_bulk_apc_move_rule" "all_apc_rules" {
  depends_on = [cato_application_control_section.sections, cato_application_control_rule.rules]

  section_data = local.move_section_data
  rule_data    = local.move_rule_data
}
