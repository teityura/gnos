terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

resource "aws_dynamodb_table" "games" {
  name         = "${var.project_name}-games"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "app_id"

  attribute {
    name = "app_id"
    type = "S"
  }
}

resource "aws_dynamodb_table" "prices" {
  name         = "${var.project_name}-prices"
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

resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

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
  name = "${var.project_name}-lambda-policy"
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
          "dynamodb:UpdateItem",
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

data "archive_file" "observer" {
  type        = "zip"
  source_file = "${path.module}/../src/observer.py"
  output_path = "${path.module}/.build/observer.zip"
}

resource "aws_lambda_function" "observer" {
  function_name    = local.functions.observer
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

data "archive_file" "api" {
  type        = "zip"
  source_file = "${path.module}/../src/api.py"
  output_path = "${path.module}/.build/api.zip"
}

resource "aws_lambda_function" "api" {
  function_name    = local.functions.api
  role             = aws_iam_role.lambda_role.arn
  handler          = "api.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256

  environment {
    variables = {
      DISCORD_WEBHOOK = var.discord_webhook_url
      API_KEYS        = jsonencode(var.api_keys)
    }
  }
}

resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "DELETE"]
    # 許可しないとプリフライトが落ちて POST/DELETE が通らない
    allow_headers = ["content-type", "x-api-key"]
  }
}

# 公開には許可が2つ要る。2024年以降のアカウントは Function URL の公開が
# 既定でブロックされており、InvokeFunctionUrl だけだと 403 になる。
resource "aws_lambda_permission" "api_url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# 公開ブロックを解除するのはこちら。
# function_url_auth_type は InvokeFunctionUrl 専用なので指定できない
resource "aws_lambda_permission" "api_invoke" {
  statement_id  = "AllowPublicInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "*"
}

# 宣言しないと Lambda が暗黙に作り、destroy してもログだけ残る。
# Lambda リソースを参照しないのは、for_each のキーが apply 時まで
# 未確定になり import できなくなるため。
resource "aws_cloudwatch_log_group" "lambda" {
  for_each = toset(values(local.functions))

  name              = "/aws/lambda/${each.value}"
  retention_in_days = 30
}

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "${var.project_name}-schedule"
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

resource "aws_s3_bucket" "site" {
  bucket = "${var.project_name}-site"
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
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.site.arn}/*"
      },
      {
        # [NOTE] S3 はタグ条件非対応なので中央のガードレールが効かない
        # ポリシー自体の変更・削除も拒否し、剥がしてから消す2段削除を防ぐ
        Sid       = "DenyDelete"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "s3:DeleteBucket",
          "s3:DeleteBucketPolicy",
          "s3:DeleteObject",
          "s3:PutBucketPolicy",
        ]
        Resource = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"]
        Condition = {
          ArnNotLike = { "aws:PrincipalArn" = local.deploy_principal_arn }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.site]
}

# templatefile ではなく replace なのは、HTML内の ${...} を展開しないため
locals {
  site_files = {
    "index.html"   = "${path.module}/../site/index.html"
    "history.html" = "${path.module}/../site/history.html"
  }
}

resource "aws_s3_object" "site" {
  for_each = local.site_files

  bucket = aws_s3_bucket.site.id
  key    = each.key
  # Function URL は末尾に / が付く。JS が API_URL + "/games" と
  # 連結するので、剥がさないと //games になり一致しない
  content      = replace(file(each.value), "__API_URL__", trimsuffix(aws_lambda_function_url.api.function_url, "/"))
  content_type = "text/html"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  functions = {
    observer = "${var.project_name}-observer"
    api      = "${var.project_name}-api"
  }

  deploy_principal_arn = data.aws_caller_identity.current.arn
}
