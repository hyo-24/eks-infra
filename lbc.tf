# lbc.tf — AWS Load Balancer Controller가 쓸 IAM 권한 (IRSA 방식)
#
# 흐름: EKS 클러스터의 "신분증 발급소(OIDC)"를 IAM에 등록하고,
#       kube-system 네임스페이스의 aws-load-balancer-controller 서비스 계정만
#       이 IAM 역할을 빌려 쓸 수 있게 허용한다.

locals {
  # 예: oidc.eks.us-east-1.amazonaws.com/id/ABCDEF...  (https:// 를 뗀 주소)
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# 1) OIDC 발급소의 인증서 지문 읽어오기
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# 2) IAM에 "이 클러스터가 발급한 신분증을 믿겠다"고 등록
resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# 3) 컨트롤러가 ALB를 만들고 지울 수 있는 권한 (AWS 공식 정책 파일)
#    같은 폴더에 iam_policy.json 을 먼저 내려받아 두어야 함
resource "aws_iam_policy" "lbc" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/iam_policy.json")
}

# 4) 위 권한을 담은 역할 — 정해진 서비스 계정 하나만 쓸 수 있음
resource "aws_iam_role" "lbc" {
  name = "AmazonEKSLoadBalancerControllerRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}
