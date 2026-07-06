---
last_reviewed: 2026-07-06
owner: mark
---

# Noodprocedures

Incident-runbooks. Namespace = de kale tenant-naam. Voor rustige
inspectie zie [DEBUGGING.md](DEBUGGING.md).

## Pod crasht continu

```bash
TENANT=canary
NS=$TENANT

# 1. Check events
kubectl describe pod -n $NS -l app.kubernetes.io/name=nextcloud

# 2. Check logs van crashed pod
kubectl logs -n $NS -l app.kubernetes.io/name=nextcloud --previous

# 3. Tijdelijk maintenance mode via env var
kubectl set env deployment/nextcloud -n $NS NEXTCLOUD_MAINTENANCE=1

# 4. Start debug pod met de image die de draaiende deployment gebruikt
IMAGE=$(kubectl get deploy nextcloud -n $NS -o jsonpath='{.spec.template.spec.containers[0].image}')
kubectl run debug -n $NS --rm -it --image="$IMAGE" -- bash
```

## Argo CD sync faalt

```bash
TENANT=canary

# 1. Check Application status
argocd app get nc-$TENANT

# 2. Bekijk sync errors
argocd app sync nc-$TENANT --dry-run

# 3. Force refresh
argocd app refresh nc-$TENANT --hard-refresh

# 4. Handmatige sync met prune
argocd app sync nc-$TENANT --prune --force
```

## Storage vol

```bash
TENANT=canary
NS=$TENANT

# 1. Check PVC usage
kubectl exec -n $NS deploy/nextcloud -- df -h

# 2. Vind grote bestanden
kubectl exec -n $NS deploy/nextcloud -- du -sh /var/www/html/* | sort -hr | head -20

# 3. Cleanup logs
kubectl exec -n $NS deploy/nextcloud -- rm -rf /var/www/html/data/nextcloud.log.*

# 4. Cleanup trashbin (per user)
kubectl exec -n $NS deploy/nextcloud -- php occ trashbin:cleanup --all-users
```

## Alle tenants uitschakelen (noodgeval)

```bash
# Suspend alle Argo CD syncs
kubectl patch applicationset nextcloud-tenants -n argocd \
  --type=merge \
  -p '{"spec":{"template":{"spec":{"syncPolicy":{"automated":null}}}}}'

# Re-enable na incident
kubectl patch applicationset nextcloud-tenants -n argocd \
  --type=merge \
  -p '{"spec":{"template":{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}}}'
```
