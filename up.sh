#!/usr/bin/env bash
# Create the cluster and deploy the workloads. Everything is scripted;
# kubectl is only used to wait for and show the result.
set -euo pipefail
cd "$(dirname "$0")"

K3D_VERSION="v5.9.0"
CLUSTER="hw8"
BIN_DIR="${HOME}/.local/bin"
export PATH="${BIN_DIR}:${PATH}"

log() { printf '\n==> %s\n' "$*"; }

# 1. Prerequisites: Docker (Docker Desktop with the WSL integration) and kubectl.
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "the Docker daemon is not running" >&2; exit 1; }

# 2. k3d in a pinned version. Installed to ~/.local/bin, no sudo needed.
if ! command -v k3d >/dev/null || ! k3d version | grep -q "k3d version ${K3D_VERSION}$"; then
  log "Installing k3d ${K3D_VERSION} to ${BIN_DIR}"
  mkdir -p "${BIN_DIR}"
  release="https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}"
  tmp="$(mktemp -d)"
  curl -fsSL "${release}/k3d-linux-amd64" -o "${tmp}/k3d-linux-amd64"
  curl -fsSL "${release}/checksums.txt" -o "${tmp}/checksums.txt"
  # The checksum file lists the binaries as _dist/<name>.
  expected="$(awk '$2 == "_dist/k3d-linux-amd64" {print $1}' "${tmp}/checksums.txt")"
  (cd "${tmp}" && echo "${expected}  k3d-linux-amd64" | sha256sum -c -)
  install -m 0755 "${tmp}/k3d-linux-amd64" "${BIN_DIR}/k3d"
  rm -rf "${tmp}"
fi
k3d version

# 3. The cluster: 3 servers + 3 agents from cluster.yaml. Re-running the script is safe.
if k3d cluster list "${CLUSTER}" >/dev/null 2>&1; then
  if kubectl --context "k3d-${CLUSTER}" get --raw /readyz >/dev/null 2>&1; then
    log "Cluster ${CLUSTER} is already running"
  else
    # Stop before start. Docker Desktop restarts the containers in an arbitrary order, and
    # an agent can then take a server's static IP, so the servers never come up. k3d starts
    # the servers first, but only if nothing else holds their addresses.
    log "Cluster ${CLUSTER} exists but does not answer, restarting it in the right order"
    k3d cluster stop "${CLUSTER}"
    k3d cluster start "${CLUSTER}"
  fi
else
  log "Creating cluster ${CLUSTER} (3 servers + 3 agents)"
  k3d cluster create --config cluster.yaml
fi

log "Waiting for all six nodes to register and become Ready"
until [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -eq 6 ]; do sleep 2; done
kubectl wait --for=condition=Ready node --all --timeout=300s

log "Waiting for Traefik, the ingress controller that ships with k3s"
until kubectl -n kube-system get deploy traefik >/dev/null 2>&1; do sleep 3; done
kubectl -n kube-system rollout status deploy/traefik --timeout=300s

# 4. The workloads: hello world and the chatbot image from homework 7 (GHCR).
log "Deploying hello world and the chatbot"
kubectl apply -f k8s/
kubectl rollout status deploy/hello --timeout=300s
kubectl rollout status deploy/chatbot --timeout=300s

# 5. Show the result.
log "Nodes and their roles"
kubectl get nodes
log "Taints (only the control plane should have one)"
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key'
log "Pods and the node each one runs on"
kubectl get pods -o wide
log "Done. Open http://localhost:8080 (hello world) and http://chat.localhost:8080 (chatbot)."
