#!/bin/sh

# 테스트 계정은 환경변수로 주입한다 (저장소에 비밀번호를 남기지 않기 위해)
#   사용 예: TEST_ID=eks-test TEST_PW=... ./capture.sh
TEST_ID="${TEST_ID:?TEST_ID 환경변수가 필요합니다}"
TEST_PW="${TEST_PW:?TEST_PW 환경변수가 필요합니다}"
# EKS 배포 검증 증거 수집 스크립트
ALB=$(kubectl get ingress login-service-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
OUT=eks-verification.txt

{
echo "=========================================="
echo " EKS 배포 검증 기록"
echo " 수집 시각: $(date)"
echo " ALB 주소: $ALB"
echo "=========================================="

echo; echo "### 1. 노드 상태"
kubectl get nodes -o wide

echo; echo "### 2. Pod 상태"
kubectl get pods -o wide

echo; echo "### 3. 서비스 (ClusterIP)"
kubectl get svc

echo; echo "### 4. Ingress"
kubectl get ingress

echo; echo "### 5. Ingress 상세 (ALB 경로 분기 규칙)"
kubectl describe ingress login-service-ingress

echo; echo "### 6. Load Balancer Controller"
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
helm list -n kube-system

echo; echo "### 7. Secret (값은 안 보임)"
kubectl get secret app-secret

echo; echo "### 8. Terraform 출력값"
terraform output

echo; echo "### 9. ALB 대상 그룹 상태"
for tg in $(aws elbv2 describe-target-groups --region us-east-1 --query 'TargetGroups[].TargetGroupArn' --output text); do
  echo "--- $tg"
  aws elbv2 describe-target-health --target-group-arn "$tg" --region us-east-1 \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State}' --output table
done

echo; echo "### 10. member-service 로그 (RDS 연결 확인)"
kubectl logs -l app=member-service --tail=40 | grep -iE "Database|Started|Tomcat|Hikari" | head -20

echo; echo "### 11. auth-service 로그"
kubectl logs -l app=auth-service --tail=20 | grep -iE "Started|Tomcat" | head -10

echo; echo "=========================================="
echo " API 동작 검증"
echo "=========================================="

echo; echo "### A. GET /  (member-service 분기)"
curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://$ALB/"

echo; echo "### B. POST /auth/login  (Pod 간 통신 + JWT 발급)"
LOGIN=$(curl -s -X POST "http://$ALB/auth/login" -H 'Content-Type: application/json' \
  -d "{\"loginId\":\"$TEST_ID\",\"password\":\"$TEST_PW\"}")
echo "$LOGIN" | sed 's/\(eyJ[A-Za-z0-9_-]\{20\}\)[A-Za-z0-9._-]*/\1...(생략)/g'

TOKEN=$(echo "$LOGIN" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')

echo; echo "### C. GET /members/info  (JWT 서명 검증 통과 — 403은 role 체크 단계)"
curl -s -i "http://$ALB/members/info" -H "Authorization: Bearer $TOKEN" | head -8

echo; echo "### D. POST /internal/...  (ALB가 외부 접근 차단)"
curl -s -i -X POST "http://$ALB/internal/members/verify" -H 'Content-Type: application/json' \
  -d "{\"loginId\":\"$TEST_ID\",\"password\":\"$TEST_PW\"}" | head -8

echo; echo "=========================================="
echo " 수집 완료"
echo "=========================================="
} > "$OUT" 2>&1

echo "저장 완료: $(pwd)/$OUT"
wc -l "$OUT"
