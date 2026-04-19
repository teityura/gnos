output "gateway_url" {
  description = "gnos-gateway の API Gateway URL"
  value       = aws_apigatewayv2_stage.gateway.invoke_url
}

output "site_url" {
  description = "gnos-site の公開URL"
  value       = "https://gnos.teityura.com"
}

output "api_keys" {
  description = "ユーザーごとの API キー"
  value       = { for user, pwd in random_password.api_key : user => pwd.result }
  sensitive   = true
}
