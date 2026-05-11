output "configure_kubectl" {
  description = "Command to update kubeconfig for this cluster"
  value       = module.retail_app_eks.configure_kubectl
}

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = local.cluster_name
}

output "region" {
  description = "AWS region where the cluster is deployed"
  value       = var.region
}

output "retail_app_url" {
  description = "URL to access the retail store application via CloudFront"
  value       = "https://${aws_cloudfront_distribution.ui.domain_name}"
}

output "alb_internal_url" {
  description = "ALB internal URL (port 8999, CloudFront-only access)"
  value = try(
    "http://${data.kubernetes_ingress_v1.ui_ingress.status[0].load_balancer[0].ingress[0].hostname}:8999",
    "ALB provisioning - run: kubectl get ingress -n ui ui"
  )
}

output "alb_logs_bucket" {
  description = "S3 bucket for ALB access logs"
  value       = aws_s3_bucket.alb_logs.id
}
