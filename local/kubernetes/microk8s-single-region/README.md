# Camunda 8 on MicroK8s (local development)

This reference deploys Camunda 8 Self-Managed to an **existing local MicroK8s
cluster** on Ubuntu. It follows the same local-development architecture as the
Kind reference, but it does not create or delete the Kubernetes cluster.

The recommended full setup is:

```bash
SECONDARY_STORAGE=elasticsearch make domain.init
```

This installs the full Camunda platform including Optimize, using:

- MicroK8s
- `microk8s-hostpath` persistent storage
- Contour/Envoy on host ports 80 and 443
- `https://camunda.example.com`
- mkcert TLS
- ECK-managed single-node Elasticsearch
- CloudNativePG
- the Keycloak Operator

RDBMS secondary storage and no-domain mode are also supported:

```bash
SECONDARY_STORAGE=postgres make domain.init
SECONDARY_STORAGE=elasticsearch make no-domain.init
SECONDARY_STORAGE=postgres make no-domain.init
```

## Prerequisites

The machine must already have a working MicroK8s installation. The scripts also
expect `kubectl`, Helm, `curl`, `envsubst`, `yq`, and (for domain mode) `mkcert`.

The deployment creates its own kubeconfig, kubectl discovery cache, and Helm
cache/config/data under `.state/`; it never modifies `~/.kube/config`,
`~/.kube/cache`, or your normal Helm configuration. The entire `.state/`
directory is removed by a successful purge.

The full Elasticsearch deployment is resource-intensive. Camunda's local guide
recommends at least 12 GB available for the Elasticsearch profile.

## Why this directory reuses the Kind Helm values

The Camunda Helm values in `../kind-single-region/helm-values` are not
Kind-specific in practice: they describe the local domain/no-domain topology,
Contour ingress, mkcert trust, local resource limits, and secondary-storage
overlays. This MicroK8s reference deliberately reuses those values and shared
helpers, while keeping Kubernetes-distribution-specific behavior here:

- cluster preparation
- MicroK8s addons/storage
- single-node Elasticsearch
- Contour scheduling
- CoreDNS mutation
- installation ownership tracking
- cleanup

This keeps the Camunda-specific configuration in one place and avoids two local
references silently drifting apart.

## Installation

```bash
cd local/kubernetes/microk8s-single-region

SECONDARY_STORAGE=elasticsearch make domain.init
```

After deployment:

```text
https://camunda.example.com
```

Useful commands:

```bash
make status
make get-password
make get-keycloak-password
```

## Cleanup / uninstall

This reference treats cleanup as a first-class workflow because the MicroK8s
cluster itself is not disposable.

```bash
make purge
make verify-clean
```

`make domain.clean` and `make no-domain.clean` are aliases for the same purge.

Purge removes resources created by this reference, including:

- the Camunda release and `camunda` namespace
- Elasticsearch, PostgreSQL, Keycloak resources and their PVC/PVs
- ECK, CloudNativePG, and Keycloak CRDs/operators if this reference installed them
- Contour/Envoy and Contour CRDs
- container images pulled for these workloads, unless they existed before install or are still used elsewhere
- the Camunda CoreDNS rewrite block
- `/etc/hosts` lines marked by this reference
- generated TLS files and the temporary Helm chart checkout
- MicroK8s `dns` / `hostpath-storage` addons **only if this reference enabled them**

The installer refuses to adopt an existing Camunda namespace, Contour
installation, ECK installation, CloudNativePG installation, or Keycloak CRDs.
That is intentional: it makes the ownership boundary clear enough for purge to
be safe.

Do not delete `.state/` before running purge. It is the ownership record used to
distinguish resources created by this reference from resources that existed
beforehand. If the state is lost, purge refuses destructive cleanup. An explicit
`FORCE_PURGE=1 make purge` escape hatch exists for recovery, but it should not be
needed during the normal install/uninstall flow.

### mkcert

If this reference created the mkcert CA, `make purge` uninstalls it and removes
its newly-created CA directory.

If mkcert already existed before installation, purge leaves that pre-existing CA
alone. To explicitly uninstall it too:

```bash
PURGE_MKCERT_CA=1 make purge
```

That option affects other local projects using the same mkcert CA, so use it
only when you really want the machine-wide CA removed.

### Persistent data

Before deleting the `camunda` namespace, purge records exactly which PVs and
hostpath directories belong to it. It waits for the PVs to be deleted and, if
the MicroK8s hostpath provisioner leaves a stale backing directory, removes only
a directory whose recorded path belongs to the `camunda` namespace. It never
sweeps `/var/snap/microk8s/common/default-storage`.

Before installation, the reference records the current MicroK8s/containerd image
list. During purge it captures the images actually referenced by Camunda and its
owned infrastructure, then removes only matching image references that were not
present in that baseline and are not used by any remaining pod.

MicroK8s itself is never uninstalled or reset.
