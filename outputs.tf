# outputs.tf — apply 후 kubectl / helm 단계에서 필요한 값들을 화면에 출력

output "vpc_id" {
  value = aws_vpc.main.id
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "lbc_role_arn" {
  value = aws_iam_role.lbc.arn
}
