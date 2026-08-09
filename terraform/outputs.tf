output "api_url" {
  description = "API の Lambda Function URL"
  value       = aws_lambda_function_url.api.function_url
}

output "site_url" {
  description = "静的サイトの S3 エンドポイント"
  value       = aws_s3_bucket_website_configuration.site.website_endpoint
}

output "project_name" {
  description = "リソース名の接頭辞。backup.sh が対象テーブルの絞り込みに使う"
  value       = var.project_name
}
