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

# [NOTE] オンデマンドは無料枠の対象外。プロビジョンドの 25 WCU / 25 RCU はリージョン内の全テーブルの合計なので、2テーブルで 5 ずつ使う
# [NOTE] crawler の書き込みは毎時の数秒に集中するが、使わなかった容量が最大5分ぶん貯まるバースト容量で吸収できる
resource "aws_dynamodb_table" "games" {
  name           = "${var.project_name}-games"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "app_id"

  attribute {
    name = "app_id"
    type = "S"
  }
}

resource "aws_dynamodb_table" "prices" {
  name           = "${var.project_name}-prices"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "app_id"
  range_key      = "checked_at"

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

data "archive_file" "crawler" {
  type        = "zip"
  source_file = "${path.module}/../src/crawler.py"
  output_path = "${path.module}/.build/crawler.zip"
}

# [NOTE] crawler は見に行って記録するだけなので、Discord の設定は渡さない
resource "aws_lambda_function" "crawler" {
  function_name    = local.functions.crawler
  role             = aws_iam_role.lambda_role.arn
  handler          = "crawler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.crawler.output_path
  source_code_hash = data.archive_file.crawler.output_base64sha256
}

data "archive_file" "notifier" {
  type        = "zip"
  source_file = "${path.module}/../src/notifier.py"
  output_path = "${path.module}/.build/notifier.zip"
}

resource "aws_lambda_function" "notifier" {
  function_name    = local.functions.notifier
  role             = aws_iam_role.lambda_role.arn
  handler          = "notifier.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.notifier.output_path
  source_code_hash = data.archive_file.notifier.output_base64sha256

  environment {
    variables = {
      DISCORD_WEBHOOK  = var.discord_webhook_url
      DISCORD_USER_IDS = jsonencode(local.discord_user_ids)
      SITE_URL         = var.site_url
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
      API_KEYS        = jsonencode(local.api_keys)
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

# [NOTE] EventBridge Scheduler は Lambda 側の許可ではなく、このロールを借りて Lambda を呼ぶ
resource "aws_iam_role" "scheduler_role" {
  name = "${var.project_name}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      # [NOTE] 他のアカウントの Scheduler にこのロールを使わせない
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_policy" {
  name = "${var.project_name}-scheduler-policy"
  role = aws_iam_role.scheduler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [aws_lambda_function.crawler.arn, aws_lambda_function.notifier.arn]
    }]
  })
}

resource "aws_scheduler_schedule" "crawl" {
  name                = "${var.project_name}-crawl"
  schedule_expression = "rate(1 hour)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.crawler.arn
    role_arn = aws_iam_role.scheduler_role.arn
  }
}

# [NOTE] Scheduler はタイムゾーンを指定できるので、11時を UTC に直さずそのまま書ける
resource "aws_scheduler_schedule" "notify" {
  name                         = "${var.project_name}-notify"
  schedule_expression          = "cron(0 11 * * ? *)"
  schedule_expression_timezone = "Asia/Tokyo"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.notifier.arn
    role_arn = aws_iam_role.scheduler_role.arn
  }
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

module "s3_guardrail" {
  source               = "github.com/teityura/terraform-modules//s3-guardrail"
  bucket_arn           = aws_s3_bucket.site.arn
  allow_principal_arns = [local.deploy_principal_arn]
}

data "aws_iam_policy_document" "site" {
  source_policy_documents = [module.s3_guardrail.json]

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json

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
    crawler  = "${var.project_name}-crawler"
    notifier = "${var.project_name}-notifier"
    api      = "${var.project_name}-api"
  }

  deploy_principal_arn = data.aws_caller_identity.current.arn

  # [NOTE] Lambda には今までと同じ形で渡すので、Lambda のコードは users の形を知らなくてよい
  # [NOTE] 同じ api_key を2人に書くと、キーが重複して plan が Duplicate object key で止まる
  api_keys         = { for name, u in var.users : u.api_key => name }
  discord_user_ids = { for name, u in var.users : name => u.discord_id if u.discord_id != null }
}
