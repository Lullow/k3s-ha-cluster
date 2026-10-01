# Plan: a k3s cluster with three control-plane nodes and three workers

## Goal

A k3s cluster with three control-plane nodes and three worker nodes, created and torn down by scripts, with a hello-world pod reachable from the browser. Then the chatbot from homework 7 running on the same cluster. `kubectl` is used only to verify.

## Constraints

- **Windows 11 Home, so no Hyper-V.** Virtual machines through Hyper-V or Multipass are out. Docker Desktop with the WSL 2 backend is installed and was used in homework 7.
- **One laptop, 16 GB of RAM** shared between WSL, Docker Desktop and Ollama. Six nodes have to be cheap.
- **Reproducible.** The same commands must give the same cluster on another day, so every version is pinned.
- **The chatbot image already exists** as `ghcr.io/lullow/docker-chatbot:v1` (homework 7). This repository should only point at it, not rebuild it.

## Options considered

| Option | The nodes are | Verdict |
|---|---|---|
| **k3d** (k3s in Docker) | Docker containers, each running the real k3s binary | **Chosen.** Real k3s, multi-node, one config file, about 2.5 GB of RAM for six nodes, created in about a minute |
| k3s on VMs (VirtualBox, Multipass) | Virtual machines | Closest to a production setup, but six VMs need well over 6 GB, VirtualBox is the only hypervisor left on Windows Home, and provisioning six VMs from a script is a project in itself |
| kind | Docker containers running kubeadm | Also multi-node in containers, but it is not k3s |
| Docker Desktop's built-in Kubernetes | One node | Cannot do 3 + 3. It was the platform for homework 7 |

The important trade-off is that k3d nodes share the host kernel and the Docker network. That is fine for learning how a multi-node cluster schedules, routes and survives the loss of a server. It is not a substitute for real machines when it comes to isolation.

## Design

**Nodes.** k3d calls control-plane nodes *servers* and workers *agents*.

| Node | Role | Taint | Runs |
|---|---|---|---|
| `k3d-hw8-server-0`, `-1`, `-2` | control-plane, etcd | `node-role.kubernetes.io/control-plane:NoSchedule` | API server, scheduler, controller manager, embedded etcd, and the k3s add-ons that tolerate the taint |
| `k3d-hw8-agent-0`, `-1`, `-2` | worker | none | Traefik, hello world, the chatbot |
| `k3d-hw8-serverlb` | not a node | | nginx in front of the cluster, the only container with published ports |

Three servers because the embedded etcd needs a majority to accept writes: with three members one can be lost. k3s does not taint its servers by default, so the taint is passed as a k3s argument in `cluster.yaml`. That way no node has two roles and the pod list shows it.

**Versions.** k3d v5.9.0 (binary from the GitHub release, checksum verified, installed to `~/.local/bin` without sudo) and `rancher/k3s:v1.36.5-k3s1`, the same minor as the kubectl client on the machine.

**Ports.** Docker Desktop's own Kubernetes already uses 6443 and 8000 on the host, so the k3d API is published on `127.0.0.1:6550` and the web on `127.0.0.1:8080`. Docker Desktop makes a port bound to 127.0.0.1 inside its VM reachable from `localhost` on Windows.

**The path from the browser into a pod.**

```
localhost:8080  →  k3d-hw8-serverlb (nginx)  →  port 80 on any of the six nodes
  →  svclb-traefik (k3s ServiceLB, a DaemonSet on every node)  →  Traefik on a worker
  →  Ingress rule  →  Service  →  Pod
```

Two Ingress rules: hello world has no host and is the default site on `http://localhost:8080`; the chatbot answers on `http://chat.localhost:8080`. Browsers resolve `*.localhost` to 127.0.0.1 themselves, so no hosts-file entry is needed.

**Workloads.**
- Hello world: `nginxdemos/hello:0.4`, three replicas with a topology spread constraint so that each worker gets one. The page prints the pod name, so a refresh shows which pod answered.
- Chatbot: the homework 7 image, two replicas. The server is stateless (the browser sends the whole conversation), so either pod can answer. `LLM_BASE_URL=http://host.k3d.internal:11434/v1`: k3d injects `host.k3d.internal` into CoreDNS with the address of the Docker host, and Ollama listens there.

## Steps, all scripted

`./up.sh`
1. Check that `docker` and `kubectl` exist and that the daemon answers.
2. Install k3d v5.9.0 if it is missing or another version, after verifying the SHA-256 checksum.
3. `k3d cluster create --config cluster.yaml`, or `k3d cluster start` if the cluster already exists. Re-running the script is safe.
4. Wait until six nodes are Ready and Traefik has rolled out.
5. `kubectl apply -f k8s/` and wait for both deployments.
6. Print the nodes with roles and taints, and the pods with the node they run on.

`./down.sh`
1. `k3d cluster delete hw8`, which removes the six nodes, the load balancer and the tools container.
2. Switch kubectl back to the Docker Desktop context if there is one.
3. List remaining `k3d-` containers, which should be none.

## Verification

- `kubectl get nodes` shows three `control-plane,etcd` nodes and three workers, all Ready, all `v1.36.5+k3s1`.
- Only the servers carry the taint.
- `kubectl get pods -o wide` places every hello and chatbot pod on an agent.
- `http://localhost:8080` shows the hello page with a pod name; `http://chat.localhost:8080` shows the chatbot, which answers a question through Ollama.
- Stopping one server container: `kubectl` and the pages keep answering.
- After `./down.sh`, `docker ps -a` shows no `k3d-` containers.

## Risks identified before building

| Risk | Plan | Outcome |
|---|---|---|
| A pod cannot reach Ollama on the host | Try `host.k3d.internal`, fall back to `host.docker.internal` or the host IP | `host.k3d.internal` resolved to `192.168.65.254` and the chatbot answered on the first try |
| Port clashes with Docker Desktop's Kubernetes | Use 6550 and 8080 | No clash |
| k3s servers schedule workloads | Taint them in `cluster.yaml` | Every workload pod landed on a worker |
| The load balancer only forwards to servers, which are tainted | Check its config | k3d forwards port 80 to all six nodes, and ServiceLB runs on every node, so any node accepts the request |
| Six nodes are too heavy for the laptop | Measure | About 2.4 GB in total: 460 to 760 MB per server, about 220 MB per agent |

## Outcome (2026-09-30)

Built and verified as planned. The one thing that came up was the checksum file in the k3d release, which lists the binaries as `_dist/<name>`; the install step in `up.sh` accounts for it.
