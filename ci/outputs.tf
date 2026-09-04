output "ci_role_arn" {
  description = "Role the GitHub Actions workflow assumes. Goes in the workflow's role-to-assume."
  value       = aws_iam_role.ci_plan.arn
}

output "oidc_provider_arn" {
  description = "The GitHub OIDC identity provider registered in this account."
  value       = aws_iam_openid_connect_provider.github.arn
}
