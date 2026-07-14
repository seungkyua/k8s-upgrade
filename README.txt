kube-upgrade.sh
================

deploy 노드에서 실행하여 대상 kubernetes 노드 하나를 kubeadm 방식으로 업그레이드하는
스크립트입니다.

사전 조건
---------
- deploy 노드에서 대상 노드로 비밀번호 없이 ssh 접속이 가능해야 합니다.
- 대상 노드에서 비밀번호 없이 sudo 실행이 가능해야 합니다.
- deploy 노드에 kubectl 이 설치되어 있고 클러스터에 접근 가능한 kubeconfig 가
  설정되어 있어야 합니다. (drain / uncordon 은 deploy 노드에서 로컬로 실행됩니다)


사용법
------
  ./kube-upgrade.sh --node <node-name> [--version <major.minor>] [옵션]

필수 옵션
  --node <name>              대상 노드 이름 (ssh 로 접속 가능한 호스트명)

다음 중 최소 하나는 반드시 지정해야 합니다
  --version <major.minor>    업그레이드할 kubernetes 마이너 버전 (예: 1.34)
                              (생략하면 kubernetes 업그레이드는 건너뛰고 containerd 만 업그레이드)
  --containerd-upgrade true  --containerd-version 과 함께 지정하면 containerd 업그레이드

선택 옵션
  --containerd-upgrade <bool>  containerd 도 함께 업그레이드 (기본값: false)
  --containerd-version <ver>   containerd 패키지 버전
                                (--containerd-upgrade true 일 때만 사용됨)
  --containerd-package <auto|containerd|containerd.io>
                                containerd 패키지 이름 (기본값: auto)
                                auto 인 경우 대상 노드에 현재 설치되어 있는 패키지가
                                containerd.io 인지 containerd 인지 자동 감지합니다.
                                (Ubuntu 기본 저장소는 "containerd", Docker 저장소는
                                "containerd.io" 라는 이름을 사용합니다)
  --role <auto|primary-control|secondary-control|worker>
                                노드 역할 자동 판별을 무시하고 강제 지정 (기본값: auto)
  --ssh-user <user>            ssh 접속 계정 (기본값: 현재 사용자 / ssh config)
  --dry-run                    실제 명령을 실행하지 않고 어떤 명령이 실행될지만 출력
  --yes                        실행 전 확인 프롬프트를 건너뜀
  -h, --help                   도움말 출력

* --version 과 --containerd-upgrade true 를 모두 생략하면 수행할 작업이 없어 에러로 종료됩니다.


노드 역할 자동 판별
-------------------
--role 을 지정하지 않으면 --node 이름 끝의 "controlNN" 패턴으로 역할을 판별합니다.

  *control01                 -> primary-control   (kubeadm upgrade apply 사용, 최초 1대만)
  *control02, *control03 ... -> secondary-control  (kubeadm upgrade node 사용)
  그 외 (worker 노드)          -> worker            (kubeadm upgrade node 사용, kubectl 미설치)

이름 규칙이 다른 노드는 --role 로 직접 지정하세요.


예제
----

1) 첫 번째 컨트롤 플레인 노드 업그레이드 (containerd 도 함께 업그레이드)

  ./kube-upgrade.sh --node k1-control01 --version 1.34 \
      --containerd-upgrade true --containerd-version 2.2.6-1~ubuntu.24.04~noble

2) 두 번째/세 번째 컨트롤 플레인 노드 업그레이드 (containerd 업그레이드 없이)

  ./kube-upgrade.sh --node k1-control02 --version 1.34
  ./kube-upgrade.sh --node k1-control03 --version 1.34

3) 워커 노드 업그레이드

  ./kube-upgrade.sh --node k1-node01 --version 1.34

4) containerd 만 업그레이드 (kubernetes 버전은 그대로 유지, --version 생략)
   패키지 이름(containerd / containerd.io)은 노드에 설치된 것을 자동으로 감지합니다.

  ./kube-upgrade.sh --node k1-control01 \
      --containerd-upgrade true --containerd-version 2.2.6-1~ubuntu.24.04~noble

  # Docker 공식 저장소(containerd.io) 대신 Ubuntu 기본 저장소(containerd)를 쓰는 경우 예시
  ./kube-upgrade.sh --node k1-control01 \
      --containerd-upgrade true --containerd-version 2.2.1-0ubuntu1~24.04.3

5) 실행 전 어떤 명령이 수행될지 미리 확인 (dry-run)

  ./kube-upgrade.sh --node k1-control01 --version 1.34 --dry-run

6) 확인 프롬프트 없이 바로 실행 (자동화 파이프라인용)

  ./kube-upgrade.sh --node k1-node01 --version 1.34 --yes

7) 노드 이름 규칙이 맞지 않아 역할을 직접 지정하는 경우

  ./kube-upgrade.sh --node control-a --version 1.34 --role primary-control

8) ssh 계정을 별도로 지정하는 경우

  ./kube-upgrade.sh --node k1-node01 --version 1.34 --ssh-user ubuntu


처리 순서 (요약)
----------------
(--version 이 지정된 경우에만 1~5, 7 단계를 수행합니다. --version 을 생략하면
 kubernetes 관련 단계는 모두 건너뛰고 drain -> containerd 업그레이드 -> uncordon 만 수행합니다.)

1. 대상 노드의 kubernetes apt 저장소를 --version 에 맞게 갱신하고 apt update
2. apt-cache madison 으로 --version 에 해당하는 최신 패치 버전(kubeadm) 자동 탐색
3. kubeadm 패키지 unhold -> 설치 -> hold
4. (컨트롤 플레인 노드만) kubeadm upgrade plan 출력
5. 역할별 업그레이드 적용
   - primary-control  : kube-apiserver 종료 후 kubeadm upgrade apply v<ver> --certificate-renewal=false
   - secondary-control: kube-apiserver 종료 후 kubeadm upgrade node --certificate-renewal=false
   - worker           : kubeadm upgrade node --certificate-renewal=false
6. kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=5m
   (5분 안에 drain 이 끝나지 않으면 스크립트를 종료합니다)
7. kubelet (+ 컨트롤 플레인 노드는 kubectl 도) unhold -> 설치 -> hold, kubelet 재시작
8. (--containerd-upgrade true 인 경우) 설치된 containerd 패키지 이름 자동 감지 후 업그레이드 및 재시작
9. kubectl uncordon <node>


주의 사항
---------
- 클러스터의 첫 번째 컨트롤 플레인 노드(primary-control)만 kubeadm upgrade apply 를
  수행해야 합니다. 여러 컨트롤 플레인 노드에 동시에 --role primary-control 로 실행하지
  마세요.
- 컨트롤 플레인 노드는 반드시 control01 -> control02 -> control03 순서로,
  워커 노드는 그 이후 순서로 한 번에 하나씩 실행하세요.
- 처음 실행하는 환경이라면 --dry-run 으로 먼저 명령어를 확인한 후 실행하는 것을
  권장합니다.
- containerd 패키지 자동 감지는 노드에 containerd 또는 containerd.io 중 하나가 이미
  dpkg 로 설치되어 있어야 동작합니다. 감지에 실패하면 --containerd-package 로 직접
  지정하세요.
