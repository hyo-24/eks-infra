variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS 클러스터 이름"
  type        = string
  default     = "login-service-cluster"
}

variable "node_instance_type" {
  description = "워커 노드 EC2 인스턴스 타입"
  type        = string
  default     = "t3.small"
}

variable "db_password" {
  description = "RDS 마스터 비밀번호 (TF_VAR_db_password 환경변수로 주입)"
  type        = string
  sensitive   = true
}
