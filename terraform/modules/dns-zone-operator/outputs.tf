output "role_arn" {
  description = "IAM role ARN for DNS zone operator (external-dns, cert-manager cross-account access)"
  value       = aws_iam_role.dns_zone_operator.arn
}
