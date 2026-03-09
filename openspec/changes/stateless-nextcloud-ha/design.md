## Context

Today, every Nextcloud pod mounts a shared Cinder block volume (`cinder-rwx`, ext4) for `/var/www/html`. ext4 is not a cluster filesystem. Two pods writing concurrently to the same block device corrupt each other's inodes — confirmed on canary-prod 2026-03-09 (1880 multiply-claimed blocks). This forces RS=1 across all tenants, eliminating any meaningful pod-level HA.

The rest of the stack is already stateless-ready: S3 handles all user data, Redis handles sessions and locking, MariaDB/PostgreSQL handle structured data. The only remaining shared state is the application code and installed apps in `/var/www/html`.

**Three-phase migration:**
1. **PoC (now)**: `emptyDir` per pod for `/var/www/html`, apps installed at startup via hook — proves stateless model, unlocks RS=2 on canary immediately
2. **Medium-term**: Custom image with apps pre-installed (`conduction/nextcloud:{nc-version}-{apps-version}`) — removes startup install overhead, produces immutable artefacts
3. **Long-term**: Blue-green rollout via Argo Rollouts — zero-downtime image upgrades across all tenants, canary-first

## Goals / Non-Goals

**Goals:**
- Eliminate shared PVC as the blocker for RS=2+
- Establish canary-prod as the mandatory validation gate for every phase
- Produce a custom image that is versioned, scannable, and reproducible
- Enable blue-green deployments for zero-downtime Nextcloud upgrades
- Keep the existing S3/Redis/PostgreSQL stack unchanged

**Non-Goals:**
- Replacing S3 as the data layer
- Changing database engines or connection pooling
- Migrating existing tenant data (this is purely an application layer change)
- Building a cluster filesystem (GFS2/OCFS2) — rejected as unnecessary complexity

## Decisions

### D1: emptyDir for PoC, not a second PVC

**Decision**: Use `emptyDir` (ephemeral, per-pod) for `/var/www/html` in the PoC phase, not a ReadWriteOnce PVC per pod.

**Rationale**: A per-pod RWO PVC would survive pod restarts (good) but complicates RS scaling (Kubernetes must provision a new PVC per replica, StatefulSet semantics). `emptyDir` is simpler, proves the concept immediately, and is discarded once the custom image lands. App install time on startup is acceptable for a PoC.

**Alternative rejected**: Keeping the cinder-rwx PVC with a cluster filesystem (GFS2/OCFS2). Adds significant node-level complexity, requires DaemonSet config, hard to operate.

### D2: Separate image repo, not a subdirectory of the platform repo

**Decision**: Build the custom image in a dedicated repo (`nextcloud-image` or similar), not inside `nextcloud-platform`.

**Rationale**: Image builds have different triggers (Nextcloud release, app version bump), different tooling (Docker, GHCR), and a different review cadence than platform config changes. Coupling them creates noise in both directions. The platform repo references the image tag — that's the only coupling needed.

**Alternative rejected**: Monorepo with a `build/` subdirectory. Works initially but pollutes platform CI with image build steps and makes the separation of concerns less clear.

**Note on per-tenant image variants**: The tenant values file can override the image tag, so per-tenant variants are technically possible. This should be avoided in practice. Extensions compiled into the image add negligible overhead and are not active unless used — having `soap` available does not expose it. The right model is one well-curated platform image with all extensions the platform will ever need. Per-tenant variants are only justified for something truly heavyweight, proprietary, or license-incompatible with the base image. Proliferating variants multiplies build, scan, and maintenance surface with no meaningful benefit for standard PHP extensions.

### D3: Canary-prod as mandatory gate — not advisory

**Decision**: No phase graduates to prod tenants until canary-prod has run it for a minimum validation period with explicit sign-off. This is a hard process gate, not a recommendation.

**Rationale**: Canary exists precisely for this. ext4 corruption was caught because canary ran first. The value of the canary pattern is only realised if graduation requires evidence, not just intent.

**Graduation criteria per phase:**
- PoC (emptyDir + RS=2): 1 week clean operation, zero CrashLoopBackOff, startup time ≤ 3 min, `/status.php` green
- Custom image: 2 weeks on canary, image scan clean (no critical CVEs), app versions confirmed correct, rollback tested
- Blue-green: 1 full upgrade cycle on canary (old→new→rollback→new), zero downtime confirmed via probe logs

### D4: Blue-green via Argo Rollouts, not manual Ingress switching

**Decision**: Use Argo Rollouts `BlueGreen` strategy rather than maintaining two Deployments manually.

**Rationale**: Manual blue-green is error-prone at scale (12+ tenants). Argo Rollouts integrates with Argo CD, supports automated analysis (AnalysisRun), and handles the Ingress/Service switching atomically. The controller overhead is minimal.

**Alternative rejected**: Kubernetes native RollingUpdate. Works fine for stateless pods but doesn't give pre-promotion validation. Acceptable for day-to-day restarts but insufficient for image upgrades.

### D5: Image tag scheme `{nc-version}-{apps-semver}`

**Decision**: Tag images as `conduction/nextcloud:32.0.5-apps-1.2.3` where `apps-1.2.3` is a semver that increments when any Conduction app version changes.

**Rationale**: Makes it immediately obvious what Nextcloud version and app bundle version are in use. Avoids ambiguity of a single incrementing build number.

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| emptyDir: pod restart = full app reinstall (startup latency) | Acceptable for PoC only; custom image eliminates this |
| emptyDir: app state lost on pod crash | Apps are re-installed idempotently; DB and S3 data are unaffected |
| Image build pipeline becomes a new dependency | Pin base image digest; fail-open (old image stays in production) on build failure |
| Blue-green doubles resource usage during upgrade | Short-lived; Argo Rollouts cleans up old ReplicaSet after promotion. Acceptable for a platform at this scale. |
| Canary gate adds delay to prod rollouts | Intentional — this is the trade-off for safety. Graduation criteria are defined upfront so there is no ambiguity about when to promote. |

## Migration Plan

### Phase 1 — PoC: emptyDir + RS=2 on canary-prod

1. Update `canary-overrides.yaml`: set `persistence.enabled: false`, configure `emptyDir` volumes for `/var/www/html` subtrees
2. Set `replicaCount: 2` in `tenant-canary-prod.yaml`
3. Sync canary-prod, validate startup, confirm RS=2 runs clean for ≥1 week
4. **Gate**: sign-off required before Phase 2

### Phase 2 — Custom image pipeline

1. Create `nextcloud-image` repo with Dockerfile, app version pins, GitHub Actions pipeline
2. Publish first image to GHCR: `conduction/nextcloud:32.0.5-apps-1.0.0`
3. Update `canary-overrides.yaml` to reference custom image
4. Run on canary-prod for ≥2 weeks, validate image scan, confirm app install
5. Update `values/common.yaml` to reference custom image for all tenants
6. **Gate**: image scan clean + 2-week canary validation before prod rollout

### Phase 3 — Blue-green via Argo Rollouts (long-term)

1. Install Argo Rollouts controller in cluster
2. Add `Rollout` resource to platform chart, configure BlueGreen strategy
3. Test on canary-prod: full upgrade cycle + rollback
4. Graduate to prod tenants wave by wave (wave 0 → 1 → 2 → 3)
5. **Gate**: full canary upgrade cycle with zero downtime before any prod tenant

**Rollback**: At every phase, the previous image tag / configuration remains tagged and can be re-applied by reverting the platform repo commit and syncing Argo CD.

## Open Questions

- **Image registry**: GHCR (free, integrated with GitHub Actions) vs Docker Hub vs self-hosted. Recommendation: GHCR for now.
- **App version coordination**: Who decides when to bump the `apps-semver`? Suggested: PR to `nextcloud-image` repo with updated version pins, reviewed by mwest2020.
- **Argo Rollouts analysis**: Use HTTP probe to `/status.php` as the success metric for automated promotion? Or manual promotion only? Start with manual, add automated analysis later.
- **emptyDir size limit**: Should we set `sizeLimit` on the emptyDir to prevent runaway app installs? Suggest `2Gi` initially.
