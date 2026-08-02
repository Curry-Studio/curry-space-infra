variable "name" {
  description = "e.g. cs-beta-use1-api. Used for the service, task definition, and log group names."
  type        = string
}

variable "cluster_arn" { type = string }
variable "image" { type = string }
variable "command" { type = list(string) }
variable "container_port" {
  description = "null for worker/scheduler, which don't listen on a port."
  type        = number
  default     = null
}

variable "cpu" { type = number }
variable "memory" { type = number }
variable "min_count" { type = number }
variable "max_count" { type = number }

variable "subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }
variable "task_role_arn" { type = string }
variable "execution_role_arn" { type = string }

variable "target_group_arn" {
  description = "null for services not behind the ALB (worker, scheduler)."
  type        = string
  default     = null
}

variable "capacity_provider_strategy" {
  type = list(object({
    capacity_provider = string
    weight            = number
    base              = optional(number)
  }))
}

variable "deployment_minimum_healthy_percent" {
  type    = number
  default = 100
}

variable "deployment_maximum_percent" {
  type    = number
  default = 200
}

variable "environment_vars" {
  type    = list(object({ name = string, value = string }))
  default = []
}

variable "secrets" {
  type    = list(object({ name = string, valueFrom = string }))
  default = []
}

variable "region" { type = string }
variable "log_retention_days" {
  type    = number
  default = 14
}
