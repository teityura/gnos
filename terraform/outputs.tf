output "api_url" {
  description = "API の Lambda Function URL"
  value       = aws_lambda_function_url.api.function_url
}

output "project_name" {
  description = "リソース名の接頭辞。backup.sh が対象テーブルの絞り込みに使う"
  value       = var.project_name
}

output "cloudfront_domain" {
  description = "CloudFront が持つ既定のドメイン。DNS を切り替える前に、ここを開いて動きを確かめる"
  value       = aws_cloudfront_distribution.site.domain_name
}
