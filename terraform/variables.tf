variable "project_name" {
  description = "リソース名の接頭辞。全リソースが {project_name}-* になり、ガードレールもこの接頭辞で守る"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
}

variable "api_keys" {
  description = "API の認証キー。{ キー = ユーザー名 }"
  type        = map(string)
  sensitive   = true
}

variable "discord_webhook_url" {
  description = "Discord Webhook URL"
  type        = string
  sensitive   = true
}
