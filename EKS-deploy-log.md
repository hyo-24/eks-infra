# EKS 배포 기록 — kubeconfig 연결부터 정리까지

2026-10-26, EKS 클러스터에 로그인 서비스(auth-service, member-service)를 배포하고
동작을 검증한 뒤 비용 때문에 같은 날 전부 정리했다.
terraform apply 직후인 kubeconfig 연결 단계부터, 실제 실행한 명령어와 출력,
겪은 에러를 순서대로 남긴다.

---

## 3단계 — kubeconfig 연결

terraform apply가 끝나면 클러스터는 AWS에 존재하지만 kubectl은 그 존재를 모른다.
접속 정보를 로컬에 심어주는 단계다.

```
aws eks update-kubeconfig --name login-service-cluster --region us-east-1
```

이 명령이 `~/.kube/config`에 클러스터 주소와 인증 정보를 기록한다. 출력:

```
Added new context arn:aws:eks:us-east-1:<ACCOUNT_ID>:cluster/login-service-cluster to /Users/leehyoju/.kube/config
```

이어서 노드 상태를 확인했다.

```
kubectl get nodes

NAME                         STATUS   ROLES    AGE   VERSION
ip-10-0-1-14.ec2.internal    Ready    <none>   20m   v1.37.1-eks-39aca56
ip-10-0-2-116.ec2.internal   Ready    <none>   20m   v1.37.1-eks-39aca56
```

노드 2대가 각각 다른 가용영역(us-east-1a, us-east-1b)에 뜨고 둘 다 Ready면 정상이다.
이 노드가 바로 EC2 인스턴스이고, 이름의 `.ec2.internal`이 그 증거다.
EKS가 관리하는 건 제어 플레인이고, 노드는 내 계정의 EC2로 떠 있다.

### 겪은 에러

두 명령어를 한 번에 붙여넣자 줄바꿈이 사라져 하나로 합쳐졌다.

```
aws: [ERROR]: An error occurred (ParamValidation): Unknown options: kubectl,get,nodes
```

`kubectl get nodes`가 aws 명령의 옵션으로 들어간 것이다.
여러 줄을 한꺼번에 붙여넣으면 줄바꿈이 간혹 씹히므로,
백슬래시로 이어지지 않은 명령어는 한 줄씩 실행한다.

---

## 4단계 — Load Balancer Controller 설치

Ingress를 적용해도 ALB를 만들어줄 프로그램이 없으면 아무 일도 일어나지 않는다.
그 프로그램을 Helm으로 설치했다.
lbc.tf가 만든 건 IAM 권한뿐이고, 컨트롤러 자체는 여기서 깔린다.

```
helm repo add eks https://aws.github.io/eks-charts
helm repo update
```

```
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=login-service-cluster \
  --set region=us-east-1 \
  --set vpcId=vpc-0cc1db55e45f3109b \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKSLoadBalancerControllerRole"
```

| 옵션 | 역할 |
| --- | --- |
| clusterName | 어느 클러스터의 ALB를 관리할지 |
| region, vpcId | 어느 VPC에 ALB를 만들지 |
| serviceAccount.annotations ... role-arn | lbc.tf가 만든 IAM 역할을 서비스 계정에 연결 (IRSA) |

마지막 줄이 핵심이다. 이게 없으면 컨트롤러 Pod는 떠도 AWS 권한이 없어 ALB를 못 만든다.
어노테이션 키의 백슬래시는 Helm이 점을 계층 구분자로 해석하지 않게 막는 이스케이프라
지우면 안 된다.

설치된 버전은 차트 3.6.2 / 앱 v3.6.2였고,
이는 eks-infra 폴더의 iam_policy.json을 내려받은 버전과 맞춰야 한다.

```
kubectl get pods -n kube-system | grep aws-load-balancer

aws-load-balancer-controller-85f75fdb96-mxrjd   1/1   Running
aws-load-balancer-controller-85f75fdb96-v2887   1/1   Running
```

Pod가 2개인 건 고가용성 때문이고, 리더 선출로 한쪽만 실제로 일하고 나머지는 대기한다.
처음 10~30초는 `0/1`로 보이는데 준비 상태 검사를 통과하는 중이라 정상이다.

### 겪은 에러

helm이 설치돼 있지 않았다.
`zsh: command not found: helm` → `brew install helm`으로 해결.

---

## 5단계 — app-secret 생성

member.yaml과 auth.yaml은 `DB_PASSWORD`와 `JWT_SECRET`을
`app-secret`이라는 Secret에서 가지고 온다.
이 Secret이 없으면 Pod가 `CreateContainerConfigError`로 뜨지 못하니,
매니페스트를 적용하기 전에 먼저 만들어야 한다.

```
echo -n "DB 비밀번호: "; read -s PW;  echo
echo -n "JWT_SECRET: ";  read -s JWT; echo

kubectl create secret generic app-secret \
  --from-literal=DB_PASSWORD="$PW" \
  --from-literal=JWT_SECRET="$JWT"

unset PW JWT
```

값을 `--from-literal`에 직접 적으면 **명령줄 전체가 셸 히스토리에 남는다.**
Terraform 비밀번호는 `read -s`로 받으면서 이쪽은 평문으로 쳤던 것이 당시의 실수였고,
기록을 바로잡아 둔다. 히스토리에는 변수 이름만 남는다.

`JWT_SECRET`이 32자 이상이어야 하는 것은 취향이 아니라 제약이다.
토큰 생성 코드가 `Keys.hmacShaKeyFor(secret.getBytes(UTF_8))`로 HS256 키를 만들기 때문에,
256비트(= 32바이트) 미만이면 앱이 예외를 던지고 실패한다.

값이 제대로 들어갔는지는 키 이름만 확인하면 된다.

```
kubectl get secret app-secret -o jsonpath='{.data}' | tr ',' '\n'
```

주의할 점이 하나 있다. Kubernetes Secret은 암호화가 아니고 base64 인코딩만 한 것이다.
`kubectl get secret -o yaml`에 그대로 나오니, 생성 명령어를 그대로 캡처해서
어디에도 올리면 안 된다.
살아있는 클러스터라면 Secrets Manager나 External Secrets Operator로 바꾸는 게 원칙인데,
GitHub Actions 쪽에서는 이미 Secrets Manager를 쓰고 있었다
(`--secret-id login-service/db-password`).
면접에서 물으면 "이번 EKS 실습은 시간이 짧아 kubectl Secret으로 덮었고,
원래 CI 파이프라인은 Secrets Manager를 쓴다"가 정확한 답이다.

---

## 6단계 — 매니페스트 적용

### RDS 주소 채우기

member.yaml의 `SPRING_DATASOURCE_URL`은 `<RDS_ENDPOINT>`라는 플레이스홀더 상태여서,
terraform이 만들기 전엔 알 수 없는 주소를 여기서 주입해야 한다.
이게 outputs.tf를 만들어둔 이유다.

```
terraform output -raw rds_endpoint

login-service-db.c6lgkimcmm92.us-east-1.rds.amazonaws.com
```

이 값을 member.yaml에 바꿔 넣었다.
포트 `:3306`은 URL에 이미 적혀 있어서 호스트만 갈아끼우면 된다.

```
sed -i '' 's|<RDS_ENDPOINT>|login-service-db.c6lgkimcmm92.us-east-1.rds.amazonaws.com|' member.yaml
```

매번 사람이 고쳐 넣는 게 이 구조의 유일한 수작업이다.
다시 하면 `terraform output` → `sed` → `kubectl apply`를 deploy.sh 한 장으로 묶는 게 맞다.

### 적용

```
kubectl apply -f member.yaml
kubectl apply -f auth.yaml
kubectl apply -f ingress.yaml
```

Ingress를 마지막에 적용한 건 우연이 아니다.
Ingress를 먼저 올리면 컨트롤러가 ALB를 만들면서 연결할 Service를 못 찾아
타겟 그룹이 한동안 비어 있거나 재시도를 반복한다.
Service를 먼저 올려두면 컨트롤러가 한 번에 제대로 만든다.

### 확인

```
kubectl get pods

NAME                              READY   STATUS    RESTARTS   AGE
auth-service-xxxxxxxxx-xxxxx      1/1     Running   0          2m
auth-service-xxxxxxxxx-xxxxx      1/1     Running   0          2m
member-service-xxxxxxxxx-xxxxx    1/1     Running   0          2m
member-service-xxxxxxxxx-xxxxx    1/1     Running   0          2m
```

이미지는 Docker Hub에서 바로 가지고 온다.
GitHub Actions가 `leehyoju24/login-service:latest`와
`leehyoju24/member-service:latest`로 푸시해놨고, 각 노드의 kubelet이 그걸 pull한다.
클러스터가 GitHub을 보는 게 아니라 Docker Hub를 보는 게 핵심이다.

Ingress에 ALB 주소가 붙는 데는 2~3분 걸렸다. 처음엔 ADDRESS 칸이 비어 있다.

```
kubectl get ingress

NAME            CLASS   ADDRESS                                                                  PORTS
login-service   alb     k8s-default-loginser-d9af0f8a41-2068962518.us-east-1.elb.amazonaws.com   80
```

---

## 7단계 — 동작 검증

### 타겟 그룹 상태

ALB 주소가 나왔다고 끝이 아니다.
ALB가 실제로 Pod를 잡았는지, 헬스체크가 통하는지를 봤다.

```
aws elbv2 describe-target-health --target-group-arn <ARN>
```

| 타겟 그룹 | 타겟 | 상태 |
| --- | --- | --- |
| auth (8080) | 10.0.1.27, 10.0.2.229 | healthy |
| member (8081) | 10.0.2.124, 10.0.1.243 | healthy |

여기서 한 가지가 한눈에 보인다. 타겟이 노드 IP가 아니고 **Pod IP**다.
ingress.yaml에 `alb.ingress.kubernetes.io/target-type: ip`를 적어뒀기 때문이고,
그래서 ALB가 NodePort를 거치지 않고 Pod에 바로 꽂는다.

헬스체크 경로는 Service에 어노테이션으로 붙여놨다.
auth는 `/actuator/health`, member는 `/`다.
member에는 actuator가 없어서 `/`로 둔 건데,
이건 나중에 고쳐야 할 부분으로 마지막 섹션에 적어뒀다.

### API 호출 테스트 4가지

| 구분 | 요청 | 결과 |
| --- | --- | --- |
| A | `POST /members/join` | 200 — 통과 |
| B | `POST /auth/login` | 200, JWT 토큰 발급 |
| C | `GET /members/info` + Bearer 토큰 | 403 (앱이 내린 JSON) |
| D | `GET /internal` | 403 (ALB가 내린 응답) |

A→B가 통한 건 경로 분기와 DB 연결이 동시에 돌아감을 말한다.
`/`는 member-service로, `/auth`는 auth-service로 갔고,
member-service는 RDS에 행을 써넣었고,
auth-service는 member-service를 `http://member-service:8081`로 내부 호출해 자격을 확인했다.
클러스터 DNS가 그 이름을 ClusterIP로 해석해주는 것도 여기서 같이 증명된다.

C와 D는 둘 다 403인데 **전혀 다른 403**이다.
이 차이를 구분하는 게 이 검증의 핵심이다.

- **C**는 요청이 ALB를 통과해 member-service Pod까지 도달한 뒤,
  `LoginCheckInterceptor`가 토큰은 정상인데 role이 `ROLE_ADMIN`이 아니라서 리턴한 403이다.
  앱 JSON 바디가 나왔으니 애플리케이션이 살아있고 토큰 검사까지 돌았다는 증거다.
- **D**는 요청이 Pod에 닿지도 않았다.
  응답 헤더가 `Server: awselb/2.0`이고 바디가 `Forbidden`인 건
  ingress.yaml의 `actions.deny-internal` 고정 응답이 ALB 단에서 막았다는 뜻이다.
  앱까지 오기 전에 엣지에서 막는 구조를 일부러 넣은 것이고,
  그게 일하고 있다는 걸 헤더로 증명한 셈이다.

중간에 `/members/join`이 500을 낸 적이 있다.
알고 보니 첫 번째 가입이 이미 성공해서 중복 가입이었다.
버그는 아니지만 중복에 500을 내는 건 설계 허점이다. 409 Conflict가 맞다.

### 기록 저장

캡처를 한 장도 안 남기고 터미널로만 진행해서,
마지막에 `capture.sh`를 만들어 모든 상태를 한 번에 파일로 뽑았다.
노드 / Pod / Service / Ingress / describe ingress / LBC Pod와 helm list /
Secret 키 이름 / terraform output / 타겟 그룹 헬스 / 앱 로그 / API 테스트 4개가 들어간다.
JWT는 `sed`로 마스킹 처리해서 토큰 전문은 파일에 남지 않는다.

```
./capture.sh

저장 완료: /Users/leehyoju/Portfolio/eks-infra/eks-verification.txt
153 eks-verification.txt
```

클러스터를 지우고 나면 다시 얻을 수 없는 증거니, 포폴에는 이 파일을 그대로 쓰면 된다.
다만 10번 섹션은 grep 범위가 짧아서 RDS 연결 로그 대신 스택 트레이스가 찍혔다.

### EKS 콘솔이 Unauthorized로 나왔던 이유

콘솔에서 클러스터 리소스를 보려고 하니 Unauthorized가 나왔다.
CLI는 멀쩡하게 돌아가는데 콘솔은 안 되는 건,
둘이 서로 다른 IAM 주체로 접속하고 있어서다.
클러스터를 만든 주체(terraform-admin)만 Kubernetes 권한을 갖고,
콘솔에 로그인한 주체는 EKS API는 봐도 클러스터 내부는 못 본다.
access entry를 추가하면 해결되지만 비용을 줄이려고 건너뛰었다.

---

## 8단계 — 정리

이 단계가 생각보다 중요하다.
삭제 순서를 틀리면 돈이 계속 나가고 terraform도 정상 삭제를 못 한다.

이유는 ALB가 **terraform의 장부에 없는 리소스**라는 점이다.
ALB는 terraform이 아니라 Load Balancer Controller가 Ingress를 보고 만든 것이라,
terraform의 state에는 그 기록이 없다.
그렇다고 ALB를 남긴 상태로 `terraform destroy`를 하면 두 가지가 동시에 터진다.
하나는 ALB가 고아 리소스로 남아 계속 과금되고,
다른 하나는 그 ALB가 쓰는 서브넷·보안그룹 때문에
VPC 삭제가 `DependencyViolation`으로 실패한다.

그래서 순서는 이렇게 갔다.

### 1. Ingress 삭제

```
kubectl delete -f ingress.yaml
```

컨트롤러가 이걸 감지해서 ALB와 타겟 그룹을 지운다.
컨트롤러가 아직 살아있어야 하니,
절대 이것보다 컨트롤러나 클러스터를 먼저 지우면 안 된다.

### 2. ALB가 정말 없어졌는지 확인

```
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
```

아무것도 안 나오면 성공이다. 이걸 넘기고 다음으로 가면 위에서 말한 고아 ALB가 생긴다.

### 3. 나머지 매니페스트 삭제

```
kubectl delete -f auth.yaml -f member.yaml
kubectl delete secret app-secret
```

### 4. terraform destroy

```
terraform destroy

Destroy complete! Resources: 22 destroyed.
```

VPC, 서브넷 2개, IGW, 라우트 테이블, IAM 역할 3개, OIDC provider,
EKS 클러스터, 노드그룹, RDS까지 한 번에 삭제됐다.
이게 IaC의 가장 피부에 닿는 이점이다.
콘솔에서 지우면 무엇을 만들었는지 기억해서 하나하나 찾아야 하고,
빼고 남길 게 반드시 생긴다.

### 5. 남은 게 없는지 확인

```
aws eks list-clusters
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier"
aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].VpcId"
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
```

전부 빈 배열로 나왔다.
이전 연습에서 생긴 타겟 그룹 일부가 남아 있는데,
타겟 그룹은 ALB에 붙지 않으면 과금이 없어서 그냥 뒀다.

이번에 추가로 나간 비용은 전체 **약 $0.30** 정도다.
비용이 가장 빠르게 붙는 게 ALB와 EKS 제어 플레인이니,
다음에도 "만들기 → 검증 → 기록 → 지우기"를 한 번에 끝내는 진행이 맞다.

---

## 다시 올린다면 고칠 것

면접에서 "아직 부족한 게 어디냐"는 질문에 그대로 쓸 수 있는 목록이다.
모두 지우기 전에 스스로 표시해뒀던 것들이다.

### 앱 쪽

| 문제 | 지금 상태 | 고칠 방향 |
| --- | --- | --- |
| member-service에 actuator 없음 | 헬스체크를 `/`로 대체 | actuator 추가 후 `/actuator/health`로 통일 |
| probe 없음 | Pod가 뜨면 바로 트래픽 받음 | readiness / liveness probe 추가 |
| `/members/info`가 ROLE_ADMIN 요구 | 본인 정보 조회에 403 | 본인 조회는 일반 사용자 허용, 관리 조회는 경로 분리 |
| 중복 가입에 500 | 응답만 보고는 원인 특정 불가 | 409 Conflict + 에러 코드 |

### 인프라 쪽

- **사설 서브넷이 없다.** 지금은 노드와 RDS가 모두 퍼블릭 서브넷에 있고,
  RDS는 `publicly_accessible = false` + 보안그룹으로만 막혀 있다.
  사설 서브넷으로 나누는 게 교과서적이지만 NAT 게이트웨이 요금이 붙어서 일부러 안 했다.
  이건 "못 한" 게 아니라 "돈 때문에 안 한" 걸로 답하는 게 정확하다.
- **RDS가 단일 AZ, 스냅샷 없이 삭제.** `multi_az` 미지정 + `skip_final_snapshot = true`다.
  실습에선 맞지만 운영에선 둘 다 반대로 가야 한다.
  주석으로 운영용 설정을 같이 적어두면 의도적으로 끈 거라는 게 보인다.
- **`db_password` 변수가 rds.tf에 선언돼 있다.** variables.tf로 옮기는 게 맞다.
- **RDS 주소 주입이 수작업이다.** `terraform output` → `sed` → `kubectl apply`를
  deploy.sh로 묶으면 사람 손이 들어갈 자리가 없어진다.
- **Secret을 kubectl로 직접 만들었다.** GitHub Actions 쪽은 이미 Secrets Manager를 쓰고 있으니,
  클러스터도 External Secrets Operator로 맞추는 게 다음 단계다.

### 포폴 쪽

- eks-infra 폴더가 아직 git 저장소가 아니다.
  인프라 코드가 포트폴리오에 없으면 "IaC로 했다"는 말을 보여줄 것이 없다.
  밀어 올리는 게 가장 빠른 전진이다.
- README와 아키텍처 그림, 그리고 `eks-verification.txt`를 같이 두면
  클러스터가 없어도 동작했다는 것이 남는다.

---

## 이후 조치

기록은 실습 당일(2026-10-26) 상태 그대로 두고, 이후 고친 내용만 여기에 날짜별로 덧붙인다.

### 2026-11-14 — Secret 생성 명령에서 평문 입력 제거

5단계의 `kubectl create secret` 명령이 `--from-literal`에 값을 직접 적는 방식이었다.
명령줄 전체가 셸 히스토리에 남기 때문에, Terraform 비밀번호를 `read -s`로 받은 것과
기준이 어긋나 있었다. 같은 기준을 적용해 변수로 받아 넘기도록 기록을 수정했다.

보안 설정은 한 곳만 지켜서는 의미가 없다.
같은 값이 지나가는 모든 경로에 같은 기준을 적용해야 한다.

### 2026-11-06 — member-service 헬스체크를 actuator로 통일

실습 당시 member-service에는 actuator가 없어 헬스체크를 `/`로 뒀다.
`/`는 웹서버가 떠 있는지만 알려주기 때문에, DB 연결이 끊겨도 200이 나와
ALB가 그 Pod를 계속 healthy로 보고 트래픽을 보내는 문제가 있다.
요청은 전부 500이 나는데 로드밸런서는 이상을 모르는 상태가 된다.

actuator의 health는 DataSource 연결까지 점검해서 DOWN을 반환하므로
ALB가 해당 Pod를 타겟에서 빼준다. 그래서 auth-service와 같은 방식으로 맞췄다.

- `member-service/build.gradle` — `spring-boot-starter-actuator` 의존성 추가
- `eks-infra/member.yaml` — `healthcheck-path`를 `/` → `/actuator/health`로 변경

아직 남은 것: 운영 환경이라면 actuator를 `management.server.port`로 별도 포트에 분리해
외부 노출을 막고, ALB 쪽에는 `healthcheck-port` 어노테이션으로 그 포트를 지정하는 게 정석이다.
현재는 auth-service와 동일하게 서비스 포트로 노출돼 있다.
