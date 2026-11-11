# rds.tf — EKS와 같은 VPC 안에 member-service용 MySQL

resource "aws_db_subnet_group" "main" {
  name       = "login-service-db-subnet"
  subnet_ids = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

# DB 출입 명단: EKS 클러스터 보안 그룹(노드와 Pod)에서 오는 3306만 허용
resource "aws_security_group" "rds" {
  name   = "login-service-rds-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }
}

resource "aws_db_instance" "main" {
  identifier             = "login-service-db"
  engine                 = "mysql"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  db_name                = "logindockerdb" # member-service application.yml 과 동일
  username               = "admin"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible = false # 공인 IP 없음 → IPv4 요금 없음, 외부 접근 차단
  skip_final_snapshot = true  # 삭제 시 최종 스냅샷을 남기지 않음 (실습용)
}
