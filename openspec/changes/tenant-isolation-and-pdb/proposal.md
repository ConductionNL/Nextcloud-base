## Why

`docs/HAVEN-COMPLIANCE.md` claimed two tenant-level controls that do not exist. The document was
corrected on 2026-08-17 (found by `add-gateway-api-bootstrap` in techbook while deleting the
never-deployed `platform/tenant-resources` chart). The controls themselves were deliberately left
open, because closing them over a live fleet of ~50 municipality tenants is not a documentation
fix.

Measured against the cluster on 2026-08-17:

- **Zero** `PodDisruptionBudget` objects in the fleet select `app.kubernetes.io/name: nextcloud`.
  The only PDB in a tenant namespace comes from the `postgresql` subchart and protects the
  database.
- The Nextcloud pod has **no `NetworkPolicy` at all**. What exists in a tenant namespace is one
  policy from the `postgresql` subchart and three (`default-deny`, `allow-ingress`,
  `allow-egress`) from the React frontend chart. None of them selects the Nextcloud pod.

The consequence is east-west: with no default-deny in a tenant namespace, a pod in tenant A can
reach a pod in tenant B directly. For a platform whose selling point is separation between
municipalities, that is the gap worth naming plainly.

**What is not broken.** The platform side is protected. `nextcloud-platform` carries
NetworkPolicies for `redis` and `pgbouncer` that only admit namespaces labelled
`app.kubernetes.io/part-of: nextcloud-platform`, and the tenant ApplicationSet stamps that label
via `managedNamespaceMetadata`. The shared cache and DB proxy are therefore not open to the
cluster — they are open to every tenant, which is what a shared service means. The labelling
mechanism a tenant policy would key on already works; only the policy is absent.

**Restoring the deleted chart is not the fix.** Its `networkpolicy.yaml` had three defects,
consistent with never having been deployed or tested:

- an ingress rule `from: [ipBlock: 0.0.0.0/0]` on ports 80 and 8080, commented "allow health
  checks from kubelet". NetworkPolicy rules are OR'd, so that rule alone admitted the entire
  cluster and negated the ingress-nginx restriction directly above it.
- egress to `0.0.0.0/0` on 80, 443, 8080, 25, 465, 587, 389 and 636 — effectively unrestricted.
- `metadata.namespace` defaulting to `nc-<tenant>`, which is the Argo *Application* name prefix,
  not the namespace convention (`<tenant>`). It would have rendered into a namespace that does
  not exist.

## What Changes

- Add a per-tenant `NetworkPolicy` set: namespace default-deny plus an explicit allowlist derived
  from **observed traffic**, not from the assumptions in the deleted chart.
- Ingress must admit **both** `ingress-nginx` and `envoy-gateway-system` for as long as the
  Gateway API migration runs (`add-gateway-api-bootstrap`). A policy that only knows about
  ingress-nginx takes every migrated tenant offline.
- Roll out opt-in per tenant, then in waves, mirroring the Gateway route migration. Use a
  separate ApplicationSet with a post-selector: adding a source to `nextcloud-tenants` changes the
  spec of all 84 tenant Applications at once, and `templatePatch` cannot avoid that because a
  merge patch replaces lists. Settled precedent in this repo: `nextcloud-tenant-routes`.
- **Recommend NOT adding a `PodDisruptionBudget` yet, and recording that as a decision.** With
  `replicaCount: 1` and HPA disabled fleet-wide (compliance doc §6, RWO Cinder constraint), a PDB
  with `minAvailable: 1` does not protect availability — it blocks node drains outright, turning
  every cluster upgrade into manual intervention across ~50 namespaces. The PDB belongs with the
  work that makes RS>1 possible (`nextcloud-ha`, `stateless-nextcloud-ha`), not before it. What
  this change adds is the written decision and the trigger that reopens it.

## Impact

- New chart `charts/tenant-networkpolicy` plus an ApplicationSet `nextcloud-tenant-netpol` with a
  post-selector on an opt-in flag.
- `docs/HAVEN-COMPLIANCE.md` §5 and §9 updated again once the controls land, replacing the "open
  gap" text with the implementation.
- No change to `values/`, the upstream chart, or any existing tenant Application until a tenant
  opts in.
- CNI is Calico, which enforces NetworkPolicy — this is a real control, not advisory.
- Risk: **high if wrong.** A default-deny that is too tight takes a municipality's live Nextcloud
  offline, and the failure mode is partial and delayed — a background job talking to an endpoint
  nobody inventoried. Mitigated by deriving rules from observed flows, shipping ingress-only
  before egress, and one canary tenant with a full observation window before any wave.

## Capabilities

### New Capabilities

- `tenant-network-isolation`: default-deny per tenant namespace with an explicit, observed
  allowlist, so a new tenant is isolated from its neighbours without a manual policy update.
- `tenant-availability`: an explicit, recorded position on PodDisruptionBudgets tied to the
  replica count, so the absence of a PDB is a decision with a trigger rather than an oversight.

## Out of scope

- Changing what the shared `redis` and `pgbouncer` admit. They are reachable from every tenant
  namespace by design; narrowing that to per-tenant identity is a separate question.
- The React frontend's policies. They exist already and are not part of this gap.
- Anything that makes RS>1 possible. Tracked in `nextcloud-ha` and `stateless-nextcloud-ha`.
