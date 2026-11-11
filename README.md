# eks-infra — 로그인 서비스 EKS 인프라 (Terraform)

JWT 기반 MSA 로그인 서비스(auth-service, member-service)를 AWS EKS에 배포하기 위한
인프라 코드입니다. VPC부터 EKS 클러스터, 노드그룹, RDS, IAM까지 **22개 리소스를
Terraform으로 한 번에 생성하고 한 번에 삭제**합니다.

- 애플리케이션 코드: [hyo-24/loginservice_aws](https://github.com/hyo-24/loginservice_aws)
- 배포 전 과정 기록: [`EKS-deploy-log.md`](./EKS-deploy-log.md)
- 실제 동작 검증 결과: [`eks-verification.txt`](./eks-verification.txt)

> 비용 때문에 실습 후 전부 `terraform destroy`한 상태입니다.
> 클러스터가 살아있을 때의 검증 기록을 위 두 파일로 남겨두었습니다.

---

## 아키텍처

```
                            인터넷
                               │
                      ┌────────▼────────┐
                      │       ALB       │  internet-facing
                      │ (LBC가 생성)    │  /internal → 403 차단
                      └────────┬────────┘  /auth → auth, / → member
                               │ target-type: ip (Pod에 직접 연결)
      ┌────────────────────────┴────────────────────────┐
      │          EKS 클러스터  (VPC 10.0.0.0/16)        │
      │                                                 │
      │   ┌──────────────┐        ┌──────────────┐      │
      │   │ auth-service │───────▶│member-service│      │
      │   │   Pod × 2    │  내부  │   Pod × 2    │      │
      │   │    :8080     │  호출  │    :8081     │      │
      │   └──────────────┘        └───────┬──────┘      │
      │                                   │             │
      │   노드 × 2 (t3.small, us-east-1a / 1b)          │
      └───────────────────────────────────┼─────────────┘
                                          │ 3306
                                 ┌────────▼────────┐
                                 │   RDS (MySQL)   │  db.t4g.micro
                                 │ publicly_       │  외부 접근 차단
                                 │ accessible=false│
                                 └─────────────────┘
```

**요청 흐름** — ALB가 경로를 보고 서비스를 가릅니다. 로그인(`/auth/login`)이 들어오면
auth-service가 member-service를 `http://member-service:8081`로 내부 호출해 자격을
확인하고, 통과하면 JWT를 발급합니다. 서비스 이름은 클러스터 DNS가 ClusterIP로 해석합니다.

---

## 어떻게 여기까지 왔나

한 번에 EKS로 간 것이 아니라, 각 단계에서 불편했던 점을 다음 단계로 해결해왔습니다.

| 단계 | 그때 불편했던 것 | 그래서 도입한 것 |
| --- | --- | --- |
| 로컬 실행 | 내 컴퓨터에서만 돌아감 | **Docker** — 환경을 이미지로 고정 |
| 로컬 Docker | 남이 접속할 수 없음 | **EC2 배포** — Docker Hub에 올려 서버에서 pull |
| EC2 수동 배포 | 배포마다 SSH로 들어가 `docker pull` + `run` 반복 | **GitHub Actions** — push하면 자동 빌드·배포 |
| CI/CD 구축 | DB 비밀번호가 명령 히스토리와 GitHub Secrets에 평문으로 남음 | **AWS Secrets Manager** — 배포 시점에 조회 |
| 인프라는 여전히 수동 | 콘솔에서 클릭해 만들고, 지울 때 무엇을 만들었는지 기억해야 함 | **Terraform** — 코드로 만들고 한 번에 삭제 |
| EC2 + Terraform | 컨테이너가 죽으면 SSH로 들어가 직접 다시 띄워야 함 | **EKS** — 선언한 개수를 알아서 유지 |

Terraform 자체도 세 단계로 나눠 익혔습니다.

```
terraform-practice    보안 그룹 1개          — 문법 연습, nginx로 Service 타입 테스트
        ↓
loginservice-infra    11개 리소스            — VPC·IGW·EC2·RDS, EC2에 docker run 방식
        ↓
eks-infra             22개 리소스 (이 저장소) — EKS·노드그룹·IAM 3개·OIDC·S3 원격 state
```

두 번째에서 세 번째로 넘어갈 때 **로컬 state를 S3 원격 백엔드로 옮겼습니다.**
로컬 state는 장비가 바뀌거나 파일이 날아가면 이미 만든 인프라를 Terraform이
알아보지 못해, 지울 수도 고칠 수도 없게 됩니다.

---
## 파일 구성

| 파일 | 역할 |
| --- | --- |
| `main.tf` | S3 원격 state 설정, VPC·서브넷·IGW·라우트, EKS 클러스터, 노드그룹, IAM 역할 2개 |
| `rds.tf` | DB 서브넷 그룹, RDS 보안 그룹, MySQL 인스턴스 |
| `lbc.tf` | OIDC provider, AWS Load Balancer Controller용 IAM 역할 (IRSA) |
| `variables.tf` | 리전, 클러스터 이름, 노드 타입, DB 비밀번호 변수 |
| `outputs.tf` | `vpc_id`, `rds_endpoint`, `lbc_role_arn` — 생성 후에야 알 수 있는 값 |
| `iam_policy.json` | AWS 공식 Load Balancer Controller 권한 정책 (78개 액션) |
| `member.yaml` / `auth.yaml` | Deployment(replicas 2) + Service(ClusterIP) |
| `ingress.yaml` | ALB 경로 분기 규칙과 `/internal` 차단 |
| `capture.sh` | 클러스터 상태·API 테스트 결과를 한 번에 파일로 수집 (JWT는 마스킹) |

---

## 리소스 목록 (22개)

| 구분 | 리소스 | 개수 |
| --- | --- | --- |
| 네트워크 | VPC, 퍼블릭 서브넷 ×2, IGW, 라우트 테이블, 라우트 연결 ×2 | 7 |
| 클러스터 | IAM 역할, 정책 연결, EKS 클러스터 | 3 |
| 노드 | IAM 역할, 정책 연결 ×3, 노드그룹 | 5 |
| 데이터베이스 | DB 서브넷 그룹, 보안 그룹, RDS 인스턴스 | 3 |
| LBC 권한 | OIDC provider, IAM 정책, IAM 역할, 정책 연결 | 4 |

---

## 사전 준비

```bash
# 1) state 저장용 S3 버킷 (최초 1회)
aws s3 mb s3://hyoju-terraform-state-loginservice --region us-east-1

# 2) AWS 공식 LBC 권한 정책 내려받기
curl -o iam_policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.2/docs/install/iam_policy.json

# 3) DB 비밀번호는 파일에 쓰지 않고 환경변수로 주입
echo -n "DB 비밀번호 입력: "; read -s TF_VAR_db_password; echo
export TF_VAR_db_password
```

`iam_policy.json`의 버전은 나중에 설치할 Helm 차트 버전과 맞춰야 합니다.

---

## 배포 순서

```bash
# 1. 인프라 생성 (약 15분)
terraform init
terraform apply

# 2. kubectl 연결
aws eks update-kubeconfig --name login-service-cluster --region us-east-1
kubectl get nodes          # 노드 2대가 Ready면 정상

# 3. AWS Load Balancer Controller 설치 (IRSA 연결)
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=login-service-cluster \
  --set region=us-east-1 \
  --set vpcId=$(terraform output -raw vpc_id) \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$(terraform output -raw lbc_role_arn)"

# 4. 앱이 쓸 비밀 생성 (JWT_SECRET은 HS256 때문에 32자 이상 필수)
kubectl create secret generic app-secret \
  --from-literal=DB_PASSWORD='<비밀번호>' \
  --from-literal=JWT_SECRET='<32자 이상>'

# 5. RDS 주소를 매니페스트에 주입
#    member.yaml의 <RDS_ENDPOINT>는 생성 전에는 알 수 없는 값이라 여기서 채운다
sed -i '' "s|<RDS_ENDPOINT>|$(terraform output -raw rds_endpoint)|" member.yaml

# 6. 적용 — Service를 먼저, Ingress를 마지막에
kubectl apply -f member.yaml
kubectl apply -f auth.yaml
kubectl apply -f ingress.yaml

kubectl get ingress        # ADDRESS에 ALB 주소가 붙는 데 2~3분
```

**6번 순서가 중요합니다.** Ingress를 먼저 올리면 컨트롤러가 ALB를 만들면서 연결할
Service를 찾지 못해 타겟 그룹이 비어 있거나 재시도를 반복합니다.

---

## 정리 순서 (반드시 이 순서로)

ALB는 Terraform이 만든 것이 아니라 **Load Balancer Controller가 Ingress를 보고 만든
AWS 리소스**입니다. Terraform의 state에 기록이 없으므로, 남겨둔 채 `destroy`하면
① ALB가 고아 리소스로 남아 계속 과금되고
② 그 ALB가 쓰는 서브넷·보안 그룹 때문에 VPC 삭제가 `DependencyViolation`으로 실패합니다.

```bash
# 1) Ingress 먼저 삭제 — 컨트롤러가 살아있어야 ALB를 지울 수 있다
kubectl delete -f ingress.yaml

# 2) ALB가 정말 사라졌는지 확인 (빈 결과여야 함)
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"

# 3) 나머지 매니페스트
kubectl delete -f auth.yaml -f member.yaml
kubectl delete secret app-secret

# 4) 인프라
terraform destroy
```

---

## 설계에서 의도한 선택

| 선택 | 이유 |
| --- | --- |
| **Ingress + ALB 1개** (서비스별 LoadBalancer 대신) | 서비스마다 LoadBalancer를 두면 ALB가 2개 필요합니다. 경로 분기로 하나만 쓰면 비용이 절반이 됩니다. |
| **`target-type: ip`** | ALB가 NodePort를 거치지 않고 Pod IP에 직접 연결합니다. 홉이 하나 줄고, 헬스체크가 노드가 아니라 **Pod 단위**로 정확해집니다. EKS의 VPC CNI가 Pod에 실제 VPC IP를 주기 때문에 가능합니다. |
| **ClusterIP + Ingress** (NodePort 대신) | 두 서비스를 외부에 직접 노출하지 않고, 외부 입구를 ALB 하나로 모아 차단·분기를 한 곳에서 관리합니다. |
| **`/internal` ALB 단 차단** | `/internal/members/verify`는 auth-service가 토큰 없이 호출하는 내부 전용 경로입니다. 외부에 열리면 비밀번호를 무한정 시도할 수 있어, 앱에 닿기 전 엣지에서 고정 응답 403으로 막았습니다. |
| **S3 원격 state** | 로컬 state는 장비가 바뀌면 인프라를 잃습니다. 원격으로 옮겨 어디서든 같은 state를 보게 했습니다. |
| **IRSA** (액세스 키 대신) | 컨트롤러에 AWS 키를 심지 않고, 서비스 계정이 IAM 역할을 빌려 쓰게 했습니다. 키를 보관·교체할 일이 없어집니다. |
| **퍼블릭 서브넷만 사용** | 사설 서브넷으로 나누는 것이 정석이지만 NAT 게이트웨이 요금이 붙습니다. RDS는 `publicly_accessible = false` + 보안 그룹으로 차단해 두고, 비용을 이유로 의도적으로 생략했습니다. |
| **RDS 보안 그룹이 클러스터 SG를 참조** | IP를 하드코딩하지 않고 `cluster_security_group_id`를 참조해, 노드가 교체돼도 규칙을 고칠 필요가 없습니다. |

---

## 검증 결과 요약

`eks-verification.txt`에 전체 출력이 있습니다.

| 확인 항목 | 결과 |
| --- | --- |
| 노드 | 2대 Ready (us-east-1a / 1b) |
| Pod | 4개 Running, 재시작 0 |
| 타겟 그룹 | 전부 healthy, 타겟이 **Pod IP**(노드 2대보다 많은 4개) |
| `POST /members/join` | 200 — 경로 분기 + RDS 쓰기 동시 확인 |
| `POST /auth/login` | 200, JWT 발급 — 서비스 간 통신 + 클러스터 DNS + RDS 읽기 확인 |
| `GET /members/info` | 403, **앱 JSON** — 요청이 Pod까지 도달해 인가가 작동함 |
| `GET /internal` | 403, **`Server: awselb/2.0`** — ALB 단에서 차단됨 |

마지막 두 줄이 핵심입니다. 같은 403이지만 **응답을 만든 주체가 서로 달라야** 통과입니다.
`/members/info`는 앱이 막아야 인가가 동작한다는 뜻이고, `/internal`은 ALB가 막아야
차단 규칙이 동작한다는 뜻입니다. 차단 설정은 걸려 있지 않아도 서비스에 아무 증상이
없으므로, 일부러 호출해 확인했습니다.

---

## 개선 과제

### 인프라

- **사설 서브넷 분리** — 현재 노드와 RDS가 모두 퍼블릭 서브넷에 있습니다. NAT 게이트웨이
  비용 때문에 보류했습니다.
- **RDS 운영 설정** — `multi_az` 미지정, `skip_final_snapshot = true`입니다. 실습 기준이며
  운영이라면 둘 다 반대로 가야 합니다.
- **비밀 관리 단일화** — 같은 DB 비밀번호가 Terraform 변수 / AWS Secrets Manager /
  쿠버네티스 Secret 세 곳에 사본으로 존재합니다. CI 파이프라인은 이미 Secrets Manager에서
  조회하고 있으므로, External Secrets Operator를 도입해 Secrets Manager를 단일 원본으로
  삼는 것이 다음 단계입니다.
- **`deploy.sh` 자동화** — `terraform output` → `sed` → `kubectl apply`가 유일한 수작업입니다.
  스크립트로 묶으면 사람이 기억할 것이 없어집니다. 이때 `member.yaml`을 템플릿으로 두고
  채운 결과를 별도 파일로 뽑아야 재실행이 가능합니다.
- **차단을 허용 목록 방식으로** — 지금은 `/`로 전부 통과시키고 `/internal`만 차단합니다.
  내부 경로가 늘어나면 차단 규칙을 계속 추가해야 하므로, 필요한 경로만 허용하거나 내부
  엔드포인트를 별도 포트로 분리하는 편이 안전합니다.

### 애플리케이션

- **probe 추가** — readiness / liveness probe가 없어 Pod가 뜨는 즉시 트래픽을 받습니다.
- **actuator 포트 분리** — 운영이라면 `management.server.port`로 빼고 ALB 쪽에
  `healthcheck-port`를 지정해 외부 노출을 막는 것이 정석입니다.
- **중복 가입 응답** — 현재 500입니다. 409 Conflict가 맞습니다.

---

## 비용

실습 전체(생성 → 검증 → 삭제)에 추가로 발생한 비용은 **약 $0.30**입니다.
시간당 비용이 가장 큰 것은 ALB와 EKS 제어 플레인이므로,
"생성 → 검증 → 기록 → 삭제"를 한 번에 끝내는 방식으로 진행했습니다.
