#!/usr/bin/env bash
# =============================================================================
# Install and set up Docker, kubectl and kind on an Ubuntu EC2 instance
# Tested layout: Ubuntu 20.04 / 22.04 / 24.04 (x86_64 and ARM64/Graviton)
#
# Usage:
#   chmod +x setup-docker-kind-kubectl.sh
#   ./setup-docker-kind-kubectl.sh                 # install everything
#   CREATE_CLUSTER=true ./setup-docker-kind-kubectl.sh   # also create a kind cluster
#   KIND_VERSION=v0.30.0 ./setup-docker-kind-kubectl.sh  # pin a kind version
# =============================================================================
set -euo pipefail

CREATE_CLUSTER="${CREATE_CLUSTER:-false}"
CLUSTER_NAME="${CLUSTER_NAME:-kind}"
KIND_VERSION="${KIND_VERSION:-}"          # empty = latest release
TARGET_USER="${SUDO_USER:-$USER}"         # user who will be added to docker group

log()  { echo -e "\n\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[ -r /etc/os-release ] || die "Cannot detect OS."
. /etc/os-release
[ "${ID}" = "ubuntu" ] || die "This script supports Ubuntu only (found: ${ID})."

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required when not running as root."
  SUDO="sudo"
fi

case "$(uname -m)" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac
log "Detected Ubuntu ${VERSION_ID} (${UBUNTU_CODENAME:-$VERSION_CODENAME}) on ${ARCH}"

# ---------------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------------
log "Updating apt and installing prerequisites"
$SUDO apt-get update -y
$SUDO apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https

# ---------------------------------------------------------------------------
# 2. Docker Engine (official Docker apt repository)
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  warn "Docker already installed: $(docker --version) - skipping install"
else
  log "Installing Docker Engine"

  # Remove conflicting/unofficial packages if present
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    $SUDO apt-get remove -y "$pkg" >/dev/null 2>&1 || true
  done

  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

  $SUDO apt-get update -y
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi

log "Enabling and starting Docker"
$SUDO systemctl enable --now docker

# Allow the non-root user to run docker without sudo
if ! id -nG "$TARGET_USER" | grep -qw docker; then
  log "Adding '${TARGET_USER}' to the docker group"
  $SUDO usermod -aG docker "$TARGET_USER"
  NEED_RELOGIN=true
else
  NEED_RELOGIN=false
fi

# ---------------------------------------------------------------------------
# 3. kubectl (official binary from dl.k8s.io, checksum verified)
# ---------------------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1; then
  warn "kubectl already installed: $(kubectl version --client 2>/dev/null | head -n1) - skipping install"
else
  log "Installing kubectl"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o "${TMP_DIR}/kubectl" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  curl -fsSL -o "${TMP_DIR}/kubectl.sha256" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256"

  echo "$(cat "${TMP_DIR}/kubectl.sha256")  ${TMP_DIR}/kubectl" | sha256sum --check
  $SUDO install -o root -g root -m 0755 "${TMP_DIR}/kubectl" /usr/local/bin/kubectl
fi

# Bash completion + alias for kubectl (idempotent)
$SUDO sh -c 'kubectl completion bash > /etc/bash_completion.d/kubectl' || true
BASHRC="$(getent passwd "$TARGET_USER" | cut -d: -f6)/.bashrc"
if [ -f "$BASHRC" ] && ! grep -q "alias k=kubectl" "$BASHRC"; then
  {
    echo ""
    echo "# kubectl alias + completion"
    echo "alias k=kubectl"
    echo "complete -o default -F __start_kubectl k"
  } >> "$BASHRC"
fi

# ---------------------------------------------------------------------------
# 4. kind (Kubernetes IN Docker)
# ---------------------------------------------------------------------------
if command -v kind >/dev/null 2>&1; then
  warn "kind already installed: $(kind version) - skipping install"
else
  log "Installing kind"
  if [ -z "$KIND_VERSION" ]; then
    KIND_VERSION="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
      | grep '"tag_name"' | head -n1 | cut -d '"' -f4 || true)"
    [ -n "$KIND_VERSION" ] || { KIND_VERSION="v0.30.0"; warn "Could not detect latest kind, using ${KIND_VERSION}"; }
  fi

  curl -fsSL -o /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  $SUDO install -o root -g root -m 0755 /tmp/kind /usr/local/bin/kind
  rm -f /tmp/kind
fi

# ---------------------------------------------------------------------------
# 5. Kernel tuning recommended for kind (multi-node / many pods)
# ---------------------------------------------------------------------------
log "Applying inotify limits recommended for kind"
$SUDO tee /etc/sysctl.d/99-kind.conf >/dev/null <<'EOF'
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 512
EOF
$SUDO sysctl --system >/dev/null

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
log "Installed versions"
$SUDO docker --version
kubectl version --client
kind version

# ---------------------------------------------------------------------------
# 7. Optional: create a kind cluster
# ---------------------------------------------------------------------------
if [ "$CREATE_CLUSTER" = "true" ]; then
  log "Creating kind cluster '${CLUSTER_NAME}'"
  if $SUDO -u "$TARGET_USER" -H sg docker -c "kind get clusters" 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    warn "Cluster '${CLUSTER_NAME}' already exists - skipping"
  else
    $SUDO -u "$TARGET_USER" -H sg docker -c "kind create cluster --name ${CLUSTER_NAME}"
  fi
  $SUDO -u "$TARGET_USER" -H kubectl cluster-info --context "kind-${CLUSTER_NAME}" || true
  $SUDO -u "$TARGET_USER" -H kubectl get nodes || true
fi

# --------------------------------------------------------------------------
# 8. Docker Final Check
# --------------------------------------------------------------------------
sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu
newgrp docker

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "Setup complete"
if [ "$NEED_RELOGIN" = "true" ]; then
  warn "Log out and back in (or run: newgrp docker) so '${TARGET_USER}' can use docker without sudo."
fi
echo "Next steps:"
echo "  kind create cluster --name demo"
echo "  kubectl get nodes"
