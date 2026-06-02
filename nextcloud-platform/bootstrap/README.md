# Platform bootstrap (app-of-apps)

`nextcloud-platform-bootstrap.yaml` is the **root Argo CD Application** that makes
everything under [`../argo/`](../argo/) GitOps-managed: the AppProjects
(`nextcloud-platform`, `nextcloud-platform-core`), the `nextcloud-platform-components`
ApplicationSet, and the bundled `nextcloud-platform` Application.

## Why

Historically these objects were applied to the cluster by hand, so Git and the
cluster drifted (e.g. the GitHub→Codeberg cutover missed the component apps; the
tenant project's `*-demo` destination was in Git but never live). With this root
app, the loop is: **commit to Codeberg `main` → Argo reconciles**. No more live
`kubectl patch`/`apply` to keep projects/appsets aligned.

## One-time bootstrap

Applied once, by hand (this is the standard chicken-and-egg bootstrap step):

```bash
kubectl apply -f nextcloud-platform/bootstrap/nextcloud-platform-bootstrap.yaml
```

After that, the root app appears in the Argo UI with the projects/appsets as
children. Start it on **manual sync** (review the diff, then Sync). Switch to
`automated: {selfHeal, prune}` later once trusted.

> **Order matters:** merge the platform-components/core-project change to `main`
> *before* applying this, otherwise the root app syncs the old `argo/` and would
> revert the bundled app's project back to `nextcloud-platform`.

## Deliberate exclusion

`../argo/applicationsets/nextcloud-tenants.yaml` is **not** managed here. It uses
a Git generator with raw Go-template control flow (`{{- if eq ... }}`) in
`valueFiles`, which is not valid standalone YAML for a directory-type source, and
it carries gated canary/stateless drift. It stays hand-maintained until that
workstream lands and its template is made directory-safe.
