variable "apc_rules_json_file_path" {
  description = "Path to the Application Control JSON export produced by `catocli export apc_rules` (data.policy.applicationControl.policy root)."
  type        = string
}

variable "policy_enabled" {
  description = "Manage the account-level Application Control policy toggle. null leaves the toggle unmanaged; true/false manages it via cato_application_control_policy."
  type        = bool
  default     = null
}

variable "policy_data_control_enabled" {
  description = "Data Control sub-toggle for the account-level Application Control policy. Only used when policy_enabled is non-null (the cato_application_control_policy resource requires both enabled and data_control_enabled). Defaults to false."
  type        = bool
  default     = false
}

variable "allow_empty_policy" {
  type        = bool
  default     = false
  description = "Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown."
}
