#!/usr/bin/env bash
# Delete the cluster and every container that belongs to it.
set -euo pipefail

CLUSTER="hw8"
export PATH="${HOME}/.local/bin:${PATH}"

k3d cluster delete "${CLUSTER}"

# k3d removes its context from the kubeconfig. Fall back to Docker Desktop's context if there is one.
if kubectl config get-contexts docker-desktop >/dev/null 2>&1; then
  kubectl config use-context docker-desktop >/dev/null
fi

echo
echo "Containers left with a k3d- prefix (should be none):"
docker ps -a --filter "name=k3d-" --format '{{.Names}}'
