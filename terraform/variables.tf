variable "project_name" {
  description = "リソース名の接頭辞 = Project タグの値。全リソースが {project_name}-* になる"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
}

# [NOTE] 認証キーとメンション先を1人1行にまとめる。名前を2か所に書くと綴りがずれてもエラーにならず、メンションが黙って飛ばなくなる
variable "users" {
  description = "{ ユーザー名 = { api_key, discord_id } }。ユーザー名は登録者として DB に残るので変えない。discord_id を省くとメンションしない"
  type = map(object({
    api_key    = string
    discord_id = optional(string)
  }))
  sensitive = true
}

variable "discord_webhook_url" {
  description = "Discord Webhook URL"
  type        = string
  sensitive   = true
}

variable "site_url" {
  description = "通知に載せる履歴ページの URL の頭。ドメインは terraform の管理外"
  type        = string
}
