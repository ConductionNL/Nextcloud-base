---
last_reviewed: 2026-07-06
owner: info@conduction.nl
---

# Storage-operaties: PVC resizen en S3-databeheer

Namespace = de kale tenant-naam (de Argo Application heet `nc-<tenant>`,
de namespace niet).

## PVC Resizen

**Let op:** Niet alle storage classes ondersteunen volume expansion!

### Check of resizing mogelijk is

```bash
kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}: {.allowVolumeExpansion}{"\n"}{end}'
```

### PVC vergroten (indien ondersteund)

```bash
TENANT=canary
NS=$TENANT
NEW_SIZE=50Gi

# 1. Patch de PVC
kubectl patch pvc nextcloud -n $NS \
  -p '{"spec":{"resources":{"requests":{"storage":"'$NEW_SIZE'"}}}}'

# 2. Verifieer
kubectl get pvc -n $NS
```

### PVC vergroten (indien NIET ondersteund)

```bash
TENANT=canary
NS=$TENANT

# 1. Maak backup van data
kubectl exec -n $NS deploy/nextcloud -- tar czf /tmp/backup.tar.gz /var/www/html

# 2. Kopieer backup naar lokaal
kubectl cp $NS/$(kubectl get pod -n $NS -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}'):/tmp/backup.tar.gz ./backup.tar.gz

# 3. Scale down
kubectl scale deployment nextcloud -n $NS --replicas=0

# 4. Verwijder oude PVC
kubectl delete pvc nextcloud -n $NS

# 5. Update PVC size in values en sync (Argo leest Codeberg, niet GitHub)
# Edit tenant yaml: persistence.size: 50Gi
git commit -am "chore: increase PVC size for $TENANT"
git push codeberg

# 6. Wacht op nieuwe PVC en pod
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nextcloud -n $NS --timeout=300s

# 7. Restore backup
kubectl cp ./backup.tar.gz $NS/$(kubectl get pod -n $NS -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}'):/tmp/backup.tar.gz
kubectl exec -n $NS deploy/nextcloud -- tar xzf /tmp/backup.tar.gz -C /
```

## S3 Data Beheer

### S3 data bekijken

```bash
TENANT=canary
BUCKET=nextcloud

# List objects
aws --endpoint-url https://core.fuga.cloud:8080 s3 ls s3://$BUCKET/$TENANT/ --recursive

# Totale grootte
aws --endpoint-url https://core.fuga.cloud:8080 s3 ls s3://$BUCKET/$TENANT/ --recursive --summarize
```

### S3 data verwijderen

```bash
TENANT=canary
BUCKET=nextcloud

# ⚠️ WAARSCHUWING: Dit verwijdert ALLE user data permanent!

# Dry-run eerst
aws --endpoint-url https://core.fuga.cloud:8080 s3 rm s3://$BUCKET/$TENANT/ --recursive --dryrun

# Daadwerkelijk verwijderen
aws --endpoint-url https://core.fuga.cloud:8080 s3 rm s3://$BUCKET/$TENANT/ --recursive
```

### S3 data migreren naar andere bucket/prefix

```bash
OLD_PREFIX=canary
NEW_PREFIX=canary-v2
BUCKET=nextcloud

aws --endpoint-url https://core.fuga.cloud:8080 s3 sync \
  s3://$BUCKET/$OLD_PREFIX/ \
  s3://$BUCKET/$NEW_PREFIX/
```
