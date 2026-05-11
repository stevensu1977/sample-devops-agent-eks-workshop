# CloudFront distribution in front of ALB
# Security requirement: ALB does not expose port 80/443 publicly.
# ALB listens on port 8999, restricted to CloudFront via managed prefix list.

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb_cloudfront" {
  name        = "${local.cluster_name}-alb-cloudfront"
  description = "ALB security group - only allows CloudFront on port 8999"
  vpc_id      = module.vpc.inner.vpc_id

  ingress {
    description     = "Allow CloudFront origin-facing IPs on port 8999"
    from_port       = 8999
    to_port         = 8999
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    description = "Allow all egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(module.tags.result, {
    Name = "${local.cluster_name}-alb-cloudfront"
  })
}

resource "random_password" "cloudfront_secret" {
  length  = 32
  special = false
}

resource "aws_cloudfront_distribution" "ui" {
  enabled         = true
  comment         = "${local.cluster_name} - Retail Store UI"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true

  origin {
    domain_name = try(
      data.kubernetes_ingress_v1.ui_ingress.status[0].load_balancer[0].ingress[0].hostname,
      "placeholder.elb.amazonaws.com"
    )
    origin_id = "alb-ui"

    custom_origin_config {
      http_port              = 8999
      https_port             = 8999
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-CloudFront-Secret"
      value = random_password.cloudfront_secret.result
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-ui"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["Host", "Origin", "Accept", "Accept-Language"]

      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = merge(module.tags.result, {
    Name = "${local.cluster_name}-ui-cloudfront"
  })
}

output "cloudfront_url" {
  description = "CloudFront URL for the retail store application"
  value       = "https://${aws_cloudfront_distribution.ui.domain_name}"
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.ui.id
}

output "alb_security_group_id" {
  description = "ALB security group ID (CloudFront-only access on port 8999)"
  value       = aws_security_group.alb_cloudfront.id
}
