# Design: tenant-isolation-and-pdb

## The measurement this rests on

Everything below assumes the state measured on 2026-08-17. Re-measure before starting; a
default-deny built on a stale inventory is exactly how this goes wrong.

| Question | Answer, 2026-08-17 |
|---|---|
| PDBs selecting `app.kubernetes.io/name: nextcloud` | 0 across the fleet |
| NetworkPolicies selecting the Nextcloud pod | 0 |
| Policies present in a tenant namespace | 1 from `postgresql` subchart, 3 from the React frontend |
| Namespace label for platform services | `app.kubernetes.io/part-of: nextcloud-platform`, applied via `managedNamespaceMetadata` |
| Platform-side protection | `redis` and `pgbouncer` in `nextcloud-platform` admit only namespaces with that label |
| CNI | Calico — NetworkPolicy is enforced |

## Why the allowlist has to be observed, not designed

The deleted chart is the argument. Someone sat down and reasoned out what Nextcloud needs —
Redis, PgBouncer, S3, SMTP, LDAP — and produced a policy with egress to `0.0.0.0/0` on eight
ports and an ingress rule that admitted the whole cluster. That is what happens when the
allowlist comes from imagination: the uncertain cases get widened until the policy is no longer a
control.

Nextcloud is a plugin platform. `opencatalogi`, `openconnector` and `openregister` make outbound
calls that no one has inventoried, and `openconnector` exists specifically to talk to arbitrary
third-party endpoints. The set of destinations is not derivable from this repo.

So: measure first. Calico can log flows; a period of observation on one tenant produces the real
destination set. Anything still unknown after that gets an explicit, dated, commented rule rather
than a silent `0.0.0.0/0`.

## Ingress before egress

Two reasons to split them.

Ingress is knowable and small: the ingress controller, the Gateway dataplane, kubelet probes, and
Prometheus. It is also where the tenant-to-tenant exposure lives, so ingress-only already closes
the gap that matters most.

Egress is the part that breaks things quietly. A blocked outbound call from a background job
surfaces as a failed sync hours later, not as a 502 someone notices. Shipping it separately means
that when something breaks, the cause is unambiguous.

## Ingress must know about two front doors

For the duration of `add-gateway-api-bootstrap` a tenant may be served by ingress-nginx, by Envoy
Gateway, or by both during coexistence. The policy admits both namespaces. Dropping the
`ingress-nginx` rule is part of decommissioning ingress-nginx, not part of this change.

Note the trap in the deleted chart: it allowed ingress from `ingress-nginx` and then added a
second rule from `0.0.0.0/0` for kubelet. Probe traffic comes from the node, not from a pod, and
in Calico it is not subject to pod-selector ingress rules in the way that rule assumed. Verify
probe behaviour on the canary before generalising; do not pre-emptively widen to `0.0.0.0/0`.

## Delivery: a separate ApplicationSet, again

Same reasoning as `nextcloud-tenant-routes`, and the same conclusion:

- a fourth source on `nextcloud-tenants` changes the spec of all 84 tenant Applications for a
  control that starts on one tenant;
- `templatePatch` cannot help — it is a merge patch and merge patches replace lists, so the whole
  `sources` list would have to be duplicated;
- a post-selector on an opt-in flag generates nothing for tenants that have not opted in.

Flag: `tenant.networkPolicy.enabled`. Kept separate from `tenant.gateway.*` because the two
migrations are independent — a tenant may get its policy long before or long after its route.

## The PDB: a decision not to act

A `PodDisruptionBudget` over a single-replica Deployment is not a safety net, it is a lock. With
`minAvailable: 1` and one replica, `kubectl drain` never completes; with `maxUnavailable: 1` the
budget permits everything and asserts nothing. Neither is worth having, and the first is actively
harmful on a cluster that gets node upgrades.

The honest position is therefore: no PDB while `replicaCount` is 1. That is not a gap to be
apologised for, it is the correct configuration for the current topology — but it has to be
*written down with its trigger*, otherwise the next reviewer finds a missing control and the
cycle repeats. The trigger is RS>1 becoming possible, which is what `nextcloud-ha` and
`stateless-nextcloud-ha` are for.

This is why the change carries a `tenant-availability` capability that adds a documented decision
rather than a manifest. A spec that records "deliberately absent, here is when that changes" is a
control in the audit sense; an unexplained absence is not.

## What would make this change wrong

Worth stating so it can be checked rather than assumed:

- If the observation window is run on a quiet accept tenant, it will miss destinations that only
  a busy tenant reaches. Observe on a tenant with real traffic, or accept that the first wave
  will surface more.
- If `openconnector` targets are configured per tenant, there may be no fleet-wide egress
  allowlist at all, and egress policy has to become per-tenant data. That possibility should be
  settled during observation, before the egress phase is designed.
