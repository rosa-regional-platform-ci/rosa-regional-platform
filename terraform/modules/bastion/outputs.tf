output "ecs_cluster_name" {
  description = "Name of the ECS cluster for bastion tasks"
  value       = aws_ecs_cluster.bastion.name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster for bastion tasks"
  value       = aws_ecs_cluster.bastion.arn
}

output "task_definition_arn" {
  description = "ARN of the bastion task definition"
  value       = aws_ecs_task_definition.bastion.arn
}

output "task_definition_family" {
  description = "Family name of the bastion task definition"
  value       = aws_ecs_task_definition.bastion.family
}

output "security_group_id" {
  description = "Security group ID for bastion tasks"
  value       = aws_security_group.bastion.id
}

output "task_role_arn" {
  description = "ARN of the IAM role used by the bastion container"
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "ARN of the IAM execution role for ECS"
  value       = aws_iam_role.execution.arn
}

output "log_group_name" {
  description = "CloudWatch log group name for bastion logs"
  value       = aws_cloudwatch_log_group.bastion.name
}

output "container_name" {
  description = "Name of the container in the task definition"
  value       = local.container_name
}

output "log_collector_task_family" {
  description = "Family name of the log-collector task definition"
  value       = aws_ecs_task_definition.log_collector.family
}

output "logs_transfer_bucket" {
  description = "S3 bucket name for log transfer"
  value       = aws_s3_bucket.logs_transfer.id
}

output "run_task_command" {
  description = "AWS CLI command to start a bastion task"
  value       = <<-EOT
    AWS_PAGER="" aws ecs run-task \
      --cluster ${aws_ecs_cluster.bastion.name} \
      --task-definition ${aws_ecs_task_definition.bastion.family} \
      --launch-type FARGATE \
      --enable-execute-command \
      --network-configuration 'awsvpcConfiguration={subnets=[${join(",", var.private_subnet_ids)}],securityGroups=[${aws_security_group.bastion.id}],assignPublicIp=DISABLED}'
  EOT
}

output "exec_command_template" {
  description = "AWS CLI command template to connect to a running bastion (replace <TASK_ID>)"
  value       = <<-EOT
    aws ecs execute-command \
      --cluster ${aws_ecs_cluster.bastion.name} \
      --task <TASK_ID> \
      --container ${local.container_name} \
      --interactive \
      --command '/bin/bash'
  EOT
}

output "get_runtime_id_command" {
  description = "AWS CLI command to get the runtimeId for SSM port forwarding (replace <TASK_ID>)"
  value       = <<-EOT
    aws ecs describe-tasks \
      --cluster ${aws_ecs_cluster.bastion.name} \
      --tasks <TASK_ID> \
      --query 'tasks[0].containers[?name==`${local.container_name}`].runtimeId | [0]' \
      --output text
  EOT
}

output "ssm_port_forward_template" {
  description = "AWS CLI command template for SSM port forwarding (replace <TASK_ID> and <RUNTIME_ID>)"
  value       = <<-EOT
    aws ssm start-session \
      --target ecs:${aws_ecs_cluster.bastion.name}_<TASK_ID>_<RUNTIME_ID> \
      --document-name AWS-StartPortForwardingSession \
      --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'
  EOT
}
