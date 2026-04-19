variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "discord_webhook_url" {
  description = "Discord Webhook URL"
  type        = string
  sensitive   = true
}

variable "api_users" {
  description = "APIキーを発行するユーザー名リスト"
  type        = list(string)
}
