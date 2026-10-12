# [NOTE] ゾーンは作らず、すでにあるものを読むだけ。destroy しても、他のレコードを巻き込まない
data "cloudflare_zones" "this" {
  name = var.zone_name
}

locals {
  zone_id = data.cloudflare_zones.this.result[0].id
}

resource "aws_acm_certificate" "site" {
  provider = aws.us_east_1

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# [NOTE] 「このドメインの持ち主です」と証明するためのレコード。証明書の自動更新もこれを見るので、消すと1年後に更新が失敗する
resource "cloudflare_dns_record" "acm" {
  for_each = {
    for o in aws_acm_certificate.site.domain_validation_options : o.domain_name => o
  }

  zone_id = local.zone_id
  name    = trimsuffix(each.value.resource_record_name, ".")
  type    = each.value.resource_record_type
  content = trimsuffix(each.value.resource_record_value, ".")
  ttl     = 60
  proxied = false
}

resource "aws_acm_certificate_validation" "site" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in cloudflare_dns_record.acm : r.name]
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

# [NOTE] 見る人のヘッダと URL のパラメータを Lambda に渡す。Host だけは渡さない（渡すと Lambda の URL と合わず、断られる）
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

locals {
  # [NOTE] Function URL は https://xxxx.lambda-url.…/ の形。CloudFront にはドメインの部分だけを渡す
  api_domain = trimsuffix(trimprefix(aws_lambda_function_url.api.function_url, "https://"), "/")
}

resource "aws_cloudfront_distribution" "site" {
  enabled = true
  comment = var.project_name
  aliases = [var.domain_name]

  # [NOTE] PriceClass_100 だと日本のエッジが入らない
  price_class = "PriceClass_200"

  origin {
    domain_name = local.api_domain
    origin_id   = "api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "api"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # [NOTE] 証明書そのものではなく「検証が済んだこと」を参照して、発行が終わるのを待つ
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# [NOTE] proxied = false にして、Cloudflare は名前を引くだけにする。true のままだと、Cloudflare と CloudFront で CDN が二重になる
resource "cloudflare_dns_record" "site" {
  zone_id = local.zone_id
  name    = var.domain_name
  type    = "CNAME"
  content = aws_cloudfront_distribution.site.domain_name
  # [NOTE] Cloudflare では、ttl = 1 が「自動」を表す
  ttl     = 1
  proxied = false
}
