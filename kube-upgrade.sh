#!/usr/bin/env bash
#
# kube-upgrade.sh — automate a single-node kubeadm upgrade from a deploy host.
#
# Usage:
#   ./kube-upgrade.sh --node <node-name> [--version <major.minor>] \
#       [--containerd-upgrade true|false] [--containerd-version <pkg-version>] \
#       [--role auto|primary-control|secondary-control|worker] \
#       [--ssh-user <user>] [--dry-run] [--yes]
#
# --version may be omitted if you only want to upgrade containerd (see below).
# At least one of --version / --containerd-upgrade true must be given.
#
# Examples:
#   # kubernetes + containerd upgrade
#   ./kube-upgrade.sh --node k1-control01 --version 1.34 \
#       --containerd-upgrade true --containerd-version 2.2.6-1~ubuntu.24.04~noble
#
#   # containerd-only upgrade (kubernetes untouched)
#   ./kube-upgrade.sh --node k1-control01 \
#       --containerd-upgrade true --containerd-version 2.2.6-1~ubuntu.24.04~noble
#
# Assumes:
#   - passwordless SSH from this (deploy) host to the target node
#   - passwordless sudo on the target node
#   - kubectl on this deploy host is already configured against the cluster

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------
NODE=""
K8S_VERSION=""
CONTAINERD_UPGRADE="false"
CONTAINERD_VERSION=""
CONTAINERD_PACKAGE="auto"
ROLE="auto"
SSH_USER=""
DRY_RUN="false"
ASSUME_YES="false"
IGNORE_PREFLIGHT_ERRORS="CreateJob"

usage() {
    cat <<EOF
Usage: $0 --node <node-name> [--version <major.minor>] [options]

Required:
  --node <name>                Target node hostname (as reachable over SSH)

At least one of the following must be given:
  --version <major.minor>      Target Kubernetes minor version, e.g. 1.34
                                (omit this to skip the kubernetes upgrade entirely
                                and only upgrade containerd)
  --containerd-upgrade true    Together with --containerd-version, upgrades containerd

Options:
  --containerd-upgrade <bool>  Also upgrade containerd (default: false)
  --containerd-version <ver>   containerd package version (required if --containerd-upgrade true)
  --containerd-package <auto|containerd|containerd.io>
                                containerd package name (default: auto, detected from the
                                package currently installed on the node — Ubuntu's own repo
                                uses "containerd", Docker's repo uses "containerd.io")
  --role <auto|primary-control|secondary-control|worker>
                                Override node-role detection (default: auto, inferred from node name)
  --ssh-user <user>             SSH user to connect as (default: current user / ssh config)
  --ignore-preflight-errors <list>
                                Comma-separated list passed to kubeadm's --ignore-preflight-errors
                                on 'upgrade plan/apply/node' (default: CreateJob — kubeadm's
                                pre-upgrade health-check Job commonly times out even on healthy
                                clusters; pass "" to disable and let kubeadm fail fatally instead)
  --dry-run                     Print remote/kubectl commands without executing them
  --yes                         Skip the confirmation prompt
  -h, --help                    Show this help

Examples:
  # kubernetes + containerd upgrade
  $0 --node k1-control01 --version 1.34 \\
      --containerd-upgrade true --containerd-version 2.2.6-1~ubuntu.24.04~noble

  # containerd-only upgrade (kubernetes untouched)
  $0 --node k1-control01 \\
      --containerd-upgrade true --containerd-version 2.2.6-1~ubuntu.24.04~noble

  # kubernetes-only upgrade
  $0 --node k1-node01 --version 1.34
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node) NODE="$2"; shift 2 ;;
        --version) K8S_VERSION="$2"; shift 2 ;;
        --containerd-upgrade) CONTAINERD_UPGRADE="$2"; shift 2 ;;
        --containerd-version) CONTAINERD_VERSION="$2"; shift 2 ;;
        --containerd-package) CONTAINERD_PACKAGE="$2"; shift 2 ;;
        --role) ROLE="$2"; shift 2 ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --ignore-preflight-errors) IGNORE_PREFLIGHT_ERRORS="$2"; shift 2 ;;
        --dry-run) DRY_RUN="true"; shift ;;
        --yes) ASSUME_YES="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ -z "$NODE" ]]; then
    echo "ERROR: --node is required." >&2
    usage
    exit 1
fi

if [[ -n "$K8S_VERSION" && ! "$K8S_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: --version must be in major.minor form, e.g. 1.34 (got: $K8S_VERSION)" >&2
    exit 1
fi

CONTAINERD_UPGRADE="$(tr '[:upper:]' '[:lower:]' <<<"$CONTAINERD_UPGRADE")"
if [[ "$CONTAINERD_UPGRADE" != "true" && "$CONTAINERD_UPGRADE" != "false" ]]; then
    echo "ERROR: --containerd-upgrade must be 'true' or 'false' (got: $CONTAINERD_UPGRADE)" >&2
    exit 1
fi

if [[ "$CONTAINERD_UPGRADE" == "true" && -z "$CONTAINERD_VERSION" ]]; then
    echo "ERROR: --containerd-version is required when --containerd-upgrade true" >&2
    exit 1
fi

if [[ "$CONTAINERD_PACKAGE" != "auto" && "$CONTAINERD_PACKAGE" != "containerd" && "$CONTAINERD_PACKAGE" != "containerd.io" ]]; then
    echo "ERROR: --containerd-package must be one of auto|containerd|containerd.io" >&2
    exit 1
fi

if [[ -z "$K8S_VERSION" && "$CONTAINERD_UPGRADE" != "true" ]]; then
    echo "ERROR: nothing to do. Specify --version to upgrade kubernetes and/or --containerd-upgrade true (with --containerd-version) to upgrade containerd." >&2
    usage
    exit 1
fi

if [[ "$ROLE" != "auto" && "$ROLE" != "primary-control" && "$ROLE" != "secondary-control" && "$ROLE" != "worker" ]]; then
    echo "ERROR: --role must be one of auto|primary-control|secondary-control|worker" >&2
    exit 1
fi

SSH_TARGET="$NODE"
[[ -n "$SSH_USER" ]] && SSH_TARGET="${SSH_USER}@${NODE}"

IGNORE_PREFLIGHT_FLAG=""
[[ -n "$IGNORE_PREFLIGHT_ERRORS" ]] && IGNORE_PREFLIGHT_FLAG=" --ignore-preflight-errors=${IGNORE_PREFLIGHT_ERRORS}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo -e "\033[1;32m[kube-upgrade]\033[0m $*"; }
warn() { echo -e "\033[1;33m[kube-upgrade]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[kube-upgrade]\033[0m $*" >&2; exit 1; }

# run a command on the target node over ssh
run_remote() {
    local cmd="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run][ssh $SSH_TARGET] $cmd"
        return 0
    fi
    ssh -o BatchMode=yes "$SSH_TARGET" "$cmd"
}

# run a command on the target node over ssh, capturing stdout
run_remote_capture() {
    local cmd="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run][ssh $SSH_TARGET] $cmd" >&2
        echo ""
        return 0
    fi
    ssh -o BatchMode=yes "$SSH_TARGET" "$cmd"
}

# run kubectl locally on the deploy node
run_kubectl() {
    local cmd="kubectl $*"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run][local] $cmd"
        return 0
    fi
    kubectl "$@"
}

# apt-get install on the target node, with needrestart's automatic service
# restarts suppressed — otherwise it can silently bounce containerd (and every
# container it runs, including etcd/kube-apiserver) during an unrelated
# package install, which is a common cause of "connection refused" mid-upgrade.
apt_install() {
    run_remote "sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y $1"
}

# poll the target node's kube-apiserver until it responds again (any HTTP
# status counts — we only care that something is listening on :6443), or
# give up after max_wait seconds.
wait_for_apiserver() {
    local max_wait=180
    local interval=5
    local waited=0

    log "Waiting for kube-apiserver on $NODE to come back up (timeout: ${max_wait}s)..."
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run][ssh $SSH_TARGET] wait for https://127.0.0.1:6443/livez to respond (timeout: ${max_wait}s)"
        return 0
    fi

    while (( waited < max_wait )); do
        if ssh -o BatchMode=yes "$SSH_TARGET" "curl -sk -o /dev/null -m 3 https://127.0.0.1:6443/livez"; then
            log "kube-apiserver is responding again (after ${waited}s)."
            return 0
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done

    die "kube-apiserver on $NODE did not come back up within ${max_wait}s. Aborting."
}

# ---------------------------------------------------------------------------
# Role detection
# ---------------------------------------------------------------------------
detect_role() {
    if [[ "$ROLE" != "auto" ]]; then
        echo "$ROLE"
        return
    fi
    if [[ "$NODE" =~ control0*([0-9]+)$ ]]; then
        if [[ "${BASH_REMATCH[1]}" == "1" ]]; then
            echo "primary-control"
        else
            echo "secondary-control"
        fi
    else
        echo "worker"
    fi
}

NODE_ROLE="$(detect_role)"
IS_CONTROL="false"
[[ "$NODE_ROLE" == "primary-control" || "$NODE_ROLE" == "secondary-control" ]] && IS_CONTROL="true"

log "Node:      $NODE"
log "Role:      $NODE_ROLE"
if [[ -n "$K8S_VERSION" ]]; then
    log "Target K8s minor version: $K8S_VERSION"
else
    log "Kubernetes upgrade: skipped (no --version given)"
fi
if [[ "$CONTAINERD_UPGRADE" == "true" ]]; then
    log "containerd upgrade: true (version: $CONTAINERD_VERSION)"
else
    log "containerd upgrade: false"
fi
[[ "$DRY_RUN" == "true" ]] && log "DRY-RUN mode: no remote/kubectl commands will actually run"

CONFIRM_MSG="Proceed with upgrade of '$NODE' ($NODE_ROLE)"
[[ -n "$K8S_VERSION" ]] && CONFIRM_MSG="$CONFIRM_MSG to v${K8S_VERSION}.x"
[[ "$CONTAINERD_UPGRADE" == "true" ]] && CONFIRM_MSG="$CONFIRM_MSG (containerd -> $CONTAINERD_VERSION)"
if [[ "$ASSUME_YES" != "true" ]]; then
    read -r -p "${CONFIRM_MSG}? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user."
fi

if [[ -n "$K8S_VERSION" ]]; then
    # -----------------------------------------------------------------------
    # 1. Point the node at the target Kubernetes apt repo and refresh package lists
    # -----------------------------------------------------------------------
    log "Configuring apt repo for v${K8S_VERSION} and refreshing package lists..."
    run_remote "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null"
    run_remote "sudo apt-get update -qq"

    # -----------------------------------------------------------------------
    # 2. Resolve full package versions (kubeadm/kubelet/kubectl share one version)
    # -----------------------------------------------------------------------
    log "Resolving latest kubeadm package version for v${K8S_VERSION}..."
    FULL_PKG_VERSION="$(run_remote_capture "apt-cache madison kubeadm | awk '{print \$3}' | grep -E '^${K8S_VERSION}\.' | sort -V | tail -1")"

    if [[ "$DRY_RUN" != "true" && -z "$FULL_PKG_VERSION" ]]; then
        die "Could not find a kubeadm package matching ${K8S_VERSION}.x in apt-cache madison output."
    fi
    [[ "$DRY_RUN" == "true" ]] && FULL_PKG_VERSION="${K8S_VERSION}.0-1.1"

    KUBE_SEMVER="${FULL_PKG_VERSION%%-*}"   # e.g. 1.35.6 (strip debian revision)
    log "Resolved package version: $FULL_PKG_VERSION (kube semver: v${KUBE_SEMVER})"

    # -----------------------------------------------------------------------
    # 3. Upgrade kubeadm
    # -----------------------------------------------------------------------
    log "Upgrading kubeadm to $FULL_PKG_VERSION..."
    run_remote "sudo apt-mark unhold kubeadm"
    apt_install "kubeadm=${FULL_PKG_VERSION}"
    run_remote "sudo apt-mark hold kubeadm"

    # -----------------------------------------------------------------------
    # 4. Show upgrade plan (control-plane nodes only, informational)
    # -----------------------------------------------------------------------
    if [[ "$IS_CONTROL" == "true" ]]; then
        log "Running 'kubeadm upgrade plan' (informational)..."
        run_remote "sudo kubeadm upgrade plan${IGNORE_PREFLIGHT_FLAG}" || warn "kubeadm upgrade plan returned non-zero; continuing."
    fi

    # -----------------------------------------------------------------------
    # 5. Apply the control-plane / node upgrade
    # -----------------------------------------------------------------------
    case "$NODE_ROLE" in
        primary-control)
            log "Stopping kube-apiserver for in-place upgrade..."
            run_remote "sudo killall -s SIGTERM kube-apiserver" || true
            wait_for_apiserver
            log "Running 'kubeadm upgrade apply v${KUBE_SEMVER} --certificate-renewal=false'..."
            run_remote "sudo kubeadm upgrade apply v${KUBE_SEMVER} --certificate-renewal=false -y${IGNORE_PREFLIGHT_FLAG}"
            ;;
        secondary-control)
            log "Stopping kube-apiserver for in-place upgrade..."
            run_remote "sudo killall -s SIGTERM kube-apiserver" || true
            wait_for_apiserver
            log "Running 'kubeadm upgrade node --certificate-renewal=false'..."
            run_remote "sudo kubeadm upgrade node --certificate-renewal=false${IGNORE_PREFLIGHT_FLAG}"
            ;;
        worker)
            log "Running 'kubeadm upgrade node --certificate-renewal=false'..."
            run_remote "sudo kubeadm upgrade node --certificate-renewal=false${IGNORE_PREFLIGHT_FLAG}"
            ;;
    esac
else
    log "Skipping kubernetes package upgrade (no --version given)."
fi

# ---------------------------------------------------------------------------
# 6. Drain the node
# ---------------------------------------------------------------------------
log "Draining node $NODE (timeout: 5m)..."
if ! run_kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=5m; then
    die "Drain of node $NODE did not complete within 5 minutes. Aborting."
fi

# ---------------------------------------------------------------------------
# 7. Upgrade kubelet (+ kubectl on control-plane nodes)
# ---------------------------------------------------------------------------
if [[ -n "$K8S_VERSION" ]]; then
    if [[ "$IS_CONTROL" == "true" ]]; then
        log "Upgrading kubelet and kubectl to $FULL_PKG_VERSION..."
        run_remote "sudo apt-mark unhold kubelet kubectl"
        apt_install "kubelet=${FULL_PKG_VERSION} kubectl=${FULL_PKG_VERSION}"
        run_remote "sudo apt-mark hold kubelet kubectl"
    else
        log "Upgrading kubelet to $FULL_PKG_VERSION..."
        run_remote "sudo apt-mark unhold kubelet"
        apt_install "kubelet=${FULL_PKG_VERSION}"
        run_remote "sudo apt-mark hold kubelet"
    fi

    run_remote "sudo systemctl daemon-reload"
    run_remote "sudo systemctl restart kubelet"
fi

# ---------------------------------------------------------------------------
# 8. Optional containerd upgrade
# ---------------------------------------------------------------------------
if [[ "$CONTAINERD_UPGRADE" == "true" ]]; then
    if [[ "$CONTAINERD_PACKAGE" == "auto" ]]; then
        log "Detecting installed containerd package name..."
        RESOLVED_CONTAINERD_PKG="$(run_remote_capture "if dpkg -s containerd.io >/dev/null 2>&1; then echo containerd.io; elif dpkg -s containerd >/dev/null 2>&1; then echo containerd; fi")"
        if [[ "$DRY_RUN" != "true" && -z "$RESOLVED_CONTAINERD_PKG" ]]; then
            die "Could not detect an installed containerd/containerd.io package on $NODE. Re-run with --containerd-package <containerd|containerd.io> to specify it explicitly."
        fi
        [[ "$DRY_RUN" == "true" ]] && RESOLVED_CONTAINERD_PKG="containerd.io"
    else
        RESOLVED_CONTAINERD_PKG="$CONTAINERD_PACKAGE"
    fi
    log "Upgrading $RESOLVED_CONTAINERD_PKG to $CONTAINERD_VERSION..."
    run_remote "sudo apt-get update -qq"
    apt_install "${RESOLVED_CONTAINERD_PKG}=${CONTAINERD_VERSION}"
    run_remote "sudo systemctl daemon-reload"
    run_remote "sudo systemctl restart containerd"
    run_remote "containerd --version"
    run_remote "sudo systemctl restart kubelet"
fi

# ---------------------------------------------------------------------------
# 9. Uncordon the node
# ---------------------------------------------------------------------------
log "Uncordoning node $NODE..."
run_kubectl uncordon "$NODE"

if [[ -n "$K8S_VERSION" ]]; then
    log "Upgrade of $NODE ($NODE_ROLE) to v${KUBE_SEMVER} complete."
else
    log "containerd upgrade of $NODE ($NODE_ROLE) complete."
fi
