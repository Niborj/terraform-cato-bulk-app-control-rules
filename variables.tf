variable "apc_rules_json_file_path" {
  description = "Path to the Application Control JSON export produced by `catocli export apc_rules` (data.policy.applicationControl.policy root)."
  type        = string
}

variable "allow_empty_policy" {
  type        = bool
  default     = false
  description = "Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown."
}
