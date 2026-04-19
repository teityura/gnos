terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ============================================================
# API キー（ユーザーごとに1本）
# ============================================================

resource "random_password" "api_key" {
  for_each = toset(var.api_users)
  length   = 16
  special  = false
}

locals {
  api_keys = jsonencode({
    for user, pwd in random_password.api_key : pwd.result => user
  })
}

provider "aws" {
  region = var.aws_region
}

# ============================================================
# DynamoDB
# ============================================================

resource "aws_dynamodb_table" "games" {
  name         = "gnos-games"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "app_id"

  attribute {
    name = "app_id"
    type = "S"
  }
}

resource "aws_dynamodb_table" "prices" {
  name         = "gnos-prices"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "app_id"
  range_key    = "checked_at"

  attribute {
    name = "app_id"
    type = "S"
  }
  attribute {
    name = "checked_at"
    type = "S"
  }
}

# ============================================================
# IAM
# ============================================================

resource "aws_iam_role" "lambda_role" {
  name = "gnos-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "gnos-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Scan",
          "dynamodb:Query",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:BatchWriteItem",
        ]
        Resource = [
          aws_dynamodb_table.games.arn,
          aws_dynamodb_table.prices.arn,
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ============================================================
# Lambda: gnos-observer
# ============================================================

data "archive_file" "observer" {
  type        = "zip"
  source_file = "${path.module}/../src/observer.py"
  output_path = "${path.module}/.build/observer.zip"
}

resource "aws_lambda_function" "observer" {
  function_name    = "gnos-observer"
  role             = aws_iam_role.lambda_role.arn
  handler          = "observer.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.observer.output_path
  source_code_hash = data.archive_file.observer.output_base64sha256

  environment {
    variables = {
      DISCORD_WEBHOOK = var.discord_webhook_url
    }
  }
}

# ============================================================
# Lambda: gnos-gateway
# ============================================================

data "archive_file" "gateway" {
  type        = "zip"
  source_file = "${path.module}/../src/gateway.py"
  output_path = "${path.module}/.build/gateway.zip"
}

resource "aws_lambda_function" "gateway" {
  function_name    = "gnos-gateway"
  role             = aws_iam_role.lambda_role.arn
  handler          = "gateway.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.gateway.output_path
  source_code_hash = data.archive_file.gateway.output_base64sha256

  environment {
    variables = {
      DISCORD_WEBHOOK = var.discord_webhook_url
      API_KEYS        = local.api_keys
    }
  }
}

# ============================================================
# API Gateway HTTP API: gnos-gateway
# ============================================================

resource "aws_apigatewayv2_api" "gateway" {
  name          = "gnos-gateway"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "DELETE"]
    allow_headers = ["Content-Type", "x-api-key"]
  }
}

resource "aws_apigatewayv2_integration" "gateway" {
  api_id                 = aws_apigatewayv2_api.gateway.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.gateway.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "add" {
  api_id    = aws_apigatewayv2_api.gateway.id
  route_key = "POST /add"
  target    = "integrations/${aws_apigatewayv2_integration.gateway.id}"
}

resource "aws_apigatewayv2_route" "games" {
  api_id    = aws_apigatewayv2_api.gateway.id
  route_key = "GET /games"
  target    = "integrations/${aws_apigatewayv2_integration.gateway.id}"
}

resource "aws_apigatewayv2_route" "history" {
  api_id    = aws_apigatewayv2_api.gateway.id
  route_key = "GET /history"
  target    = "integrations/${aws_apigatewayv2_integration.gateway.id}"
}

resource "aws_apigatewayv2_route" "search" {
  api_id    = aws_apigatewayv2_api.gateway.id
  route_key = "GET /search"
  target    = "integrations/${aws_apigatewayv2_integration.gateway.id}"
}

resource "aws_apigatewayv2_route" "delete_game" {
  api_id    = aws_apigatewayv2_api.gateway.id
  route_key = "DELETE /games"
  target    = "integrations/${aws_apigatewayv2_integration.gateway.id}"
}

resource "aws_apigatewayv2_stage" "gateway" {
  api_id      = aws_apigatewayv2_api.gateway.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.gateway.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.gateway.execution_arn}/*/*"
}

# ============================================================
# EventBridge: gnos-schedule
# ============================================================

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "gnos-schedule"
  schedule_expression = "rate(3 hours)"
}

resource "aws_cloudwatch_event_target" "observer" {
  rule = aws_cloudwatch_event_rule.schedule.name
  arn  = aws_lambda_function.observer.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.observer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}

# ============================================================
# S3: gnos-site
# ============================================================

resource "aws_s3_bucket" "site" {
  bucket = "gnos-site"
}

resource "aws_s3_bucket_website_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.site]
}

locals {
  gateway_url  = trimsuffix(aws_apigatewayv2_stage.gateway.invoke_url, "/")
  index_html   = templatefile("${path.module}/../site/index.html", { api_url = local.gateway_url })
  history_html = templatefile("${path.module}/../site/history.html", { api_url = local.gateway_url })
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.site.id
  key          = "index.html"
  content      = local.index_html
  content_type = "text/html"
  etag         = md5(local.index_html)
}

resource "aws_s3_object" "history" {
  bucket       = aws_s3_bucket.site.id
  key          = "history.html"
  content      = local.history_html
  content_type = "text/html"
  etag         = md5(local.history_html)
}
