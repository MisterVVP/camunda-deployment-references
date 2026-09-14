# Camunda 8 on MicroK8s (local development)

This reference deploys Camunda 8 Self-Managed to local MicroK8s. The supported
golden path is **native Ubuntu/Debian Linux**. It follows the same local-development
architecture as the Kind reference, but does not require users to manually
assemble the prerequisite toolchain.

The default installation is the full Camunda platform including Optimize:

```bash
./install.sh
```

The script checks the machine, shows any host packages it needs to install, asks
for confirmation, bootstraps missing prerequisites, and then runs the deployment
with TLS + mkcert and Elasticsearch.

For unattended/local automation, explicitly accept prerequisite installation:

```bash
./install.sh --yes
```

The deployment uses:

- MicroK8s
- `microk8s-hostpath` persistent storage
- Contour/Envoy on host ports 80 and 443
- `https://camunda.example.com`
- mkcert TLS
- ECK-managed single-node Elasticsearch
- CloudNativePG
- the Keycloak Operator

RDBMS secondary storage and no-domain mode remain supported:

```bash
./install.sh --secondary-storage postgres
./install.sh --mode no-domain
./install.sh --mode no-domain --secondary-storage postgres
```

## Prerequisites and bootstrap

Users should not need to work out how to install the prerequisite tools by hand.
The golden-path `install.sh` calls `procedure/install-prerequisites.sh` first.
On native Ubuntu/Debian Linux the bootstrap can install missing host packages
and MicroK8s (after confirmation), then provides the remaining tools locally in
this directory.

The bootstrap intentionally minimizes machine-wide changes:

- `kubectl` is a repo-local wrapper around MicroK8s' bundled kubectl.
- Helm is downloaded to `.tools/bin` at a pinned Helm 3 version.
- mkcert is downloaded to `.tools/bin` at a pinned version.
- `envsubst` is provided by a small bundled helper because this reference only
  uses ordinary environment-variable substitution.
- `yq` is no longer required: the MicroK8s PostgreSQL path uses the unfiltered
  shared manifests and explicitly adds `pg-camunda` in RDBMS mode.
- Only base host utilities that cannot sensibly be bundled (`curl`, `git`,
  `make`, `openssl`, CA/TLS utilities, archive tools, and Linux NSS tooling) are
  installed through apt when missing.

You can install prerequisites without deploying:

```bash
make prerequisites
```

Or only check them:

```bash
./procedure/install-prerequisites.sh --check
```

The deployment creates its kubeconfig, kubectl discovery cache, and Helm
cache/config/data under `.state/`; it never modifies `~/.kube/config`,
`~/.kube/cache`, or your normal Helm configuration. Bootstrap binaries live in
`.tools/`. Both directories are ignored by Git.

### macOS and Windows

The prerequisite bootstrap detects macOS and can best-effort install the
Canonical MicroK8s launcher and local tooling there. Native Windows is detected
and rejected with guidance rather than silently installing an incomplete stack.

The **deployment golden path remains native Linux today**. Canonical runs
MicroK8s inside a VM on macOS and Windows, while this reference currently relies
on Linux-host `hostNetwork`, `/etc/hosts`, and hostpath cleanup semantics. We do
not claim those platforms are supported until ingress addressing and zero-leftover
cleanup are VM-aware as well.

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
- prerequisite bootstrap
- cleanup

This keeps the Camunda-specific configuration in one place and avoids two local
references silently drifting apart.

## Installation

```bash
cd local/kubernetes/microk8s-single-region
./install.sh
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

The old Makefile entry points remain available for development/debugging. They
now run a prerequisite check before touching the cluster:

```bash
SECONDARY_STORAGE=elasticsearch make domain.init
SECONDARY_STORAGE=postgres make domain.init
SECONDARY_STORAGE=elasticsearch make no-domain.init
SECONDARY_STORAGE=postgres make no-domain.init
```

## Cleanup / uninstall

This reference treats cleanup as a first-class workflow because a pre-existing
MicroK8s cluster must not be damaged.

```bash
make purge
make verify-clean
```

`make domain.clean` and `make no-domain.clean` are aliases for the same purge.
A successful `make purge` also removes the repo-local `.tools/` bootstrap
binaries.

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
- repo-local Helm, mkcert, kubectl wrapper and bootstrap metadata

The installer refuses to adopt an existing Camunda namespace, Contour
installation, ECK installation, CloudNativePG installation, or Keycloak CRDs.
That is intentional: it makes the ownership boundary clear enough for purge to
be safe.

Do not delete `.state/` before running purge. It is the ownership record used to
distinguish resources created by this reference from resources that existed
beforehand. If the state is lost, purge refuses destructive cleanup. An explicit
`FORCE_PURGE=1 make purge` escape hatch exists for recovery, but it should not be
needed during the normal install/uninstall flow.

### Undo bootstrap-installed host prerequisites

Normal purge does not uninstall generic host packages such as `git` or `curl`,
because removing developer/system packages automatically is more dangerous than
leaving them installed. If the bootstrap installed host prerequisites and you
explicitly want to return the machine closer to its pre-bootstrap state, run:

```bash
PURGE_PREREQUISITES=1 make purge
```

In this mode the cleanup script removes exactly the apt/Homebrew packages that
were absent before bootstrap and removes MicroK8s itself **only if the bootstrap
installed MicroK8s**. It never removes a MicroK8s installation that existed
before `./install.sh`.

Do not run `make purge` once and then try to request strict prerequisite cleanup
later: successful purge deletes `.tools/bootstrap-state`, because keeping an
ownership record after cleanup would itself be a leftover. Choose
`PURGE_PREREQUISITES=1` on the purge invocation where you want that cleanup.

### mkcert

If this reference created the mkcert CA, `make purge` uninstalls it and removes
its newly-created CA directory.

If the CA already existed before installation, purge leaves that pre-existing CA
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

A MicroK8s installation that existed before bootstrap is never uninstalled or
reset.
