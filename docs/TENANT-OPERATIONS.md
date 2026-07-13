---
last_reviewed: 2026-07-06
owner: info@conduction.nl
---

# Tenant-operaties: reset, verwijderen, opnieuw opzetten

Runbooks voor de tenant-levenscyclus. Namespace = de kale tenant-naam
(de Argo Application heet `nc-<tenant>`, de namespace niet).

## Tenant Reset (Data wissen)

Reset een tenant naar een schone staat **zonder** de configuratie te verwijderen.

### Alleen PVCs resetten (snelste methode)

```bash
TENANT=canary
NS=$TENANT

# 1. Scale down de deployment
kubectl scale deployment nextcloud -n $NS --replicas=0
kubectl scale deployment nextcloud-mariadb -n $NS --replicas=0  # indien MariaDB

# 2. Wacht tot pods weg zijn
kubectl wait --for=delete pod -l app.kubernetes.io/name=nextcloud -n $NS --timeout=60s

# 3. Verwijder alle PVCs
kubectl delete pvc --all -n $NS

# 4. Scale up (nieuwe lege PVCs worden aangemaakt)
kubectl scale deployment nextcloud-mariadb -n $NS --replicas=1  # indien MariaDB
kubectl scale deployment nextcloud -n $NS --replicas=1

# 5. Wacht op nieuwe pods
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nextcloud -n $NS --timeout=300s
```

### Volledige reset inclusief secrets

```bash
TENANT=canary
NS=$TENANT

# 1. Scale down
kubectl scale deployment nextcloud -n $NS --replicas=0
kubectl scale deployment nextcloud-mariadb -n $NS --replicas=0

# 2. Verwijder PVCs en secrets
kubectl delete pvc --all -n $NS
kubectl delete secret nextcloud-secrets -n $NS

# 3. Maak nieuwe secrets aan
kubectl create secret generic nextcloud-secrets \
  --namespace=$NS \
  --from-literal=nextcloud-username=admin \
  --from-literal=nextcloud-password="$(openssl rand -base64 24)" \
  --from-literal=s3-access-key='<YOUR_S3_ACCESS_KEY>' \
  --from-literal=s3-secret-key='<YOUR_S3_SECRET_KEY>' \
  --from-literal=mariadb-root-password="$(openssl rand -base64 24)" \
  --from-literal=mariadb-password="$(openssl rand -base64 24)" \
  --from-literal=redis-password='' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"

# 4. Scale up
kubectl scale deployment nextcloud-mariadb -n $NS --replicas=1
kubectl scale deployment nextcloud -n $NS --replicas=1

# 5. Noteer het nieuwe admin wachtwoord!
kubectl get secret nextcloud-secrets -n $NS -o jsonpath='{.data.nextcloud-password}' | base64 -d
```

## Tenant Volledig Verwijderen

### Via GitOps (aanbevolen)

```bash
TENANT=canary
NS=$TENANT

# 1. Verwijder tenant bestand uit Git
git rm nextcloud-platform/values/tenants/tenant-$TENANT.yaml
git commit -m "chore: remove tenant $TENANT"
# Argo leest Codeberg, niet GitHub — push naar de codeberg remote
git push codeberg

# 2. Argo CD verwijdert de Application (nc-$TENANT), MAAR de ApplicationSet
#    heeft preserveResourcesOnDeletion: true. De namespace en alle resources
#    (PVCs, secrets, deployments) blijven dus staan — dit is een opzettelijke
#    safety feature. Handmatige cleanup is vereist (zie hieronder).

# 3. Verifieer dat de Application weg is
kubectl get application nc-$TENANT -n argocd  # Should return "not found"

# 4. De namespace bestaat NOG — ruim handmatig op indien gewenst
kubectl get ns $NS              # bestaat nog
kubectl delete namespace $NS    # handmatige cleanup (cascade delete)
```

> Zie ook [REMOVING-TENANT.md](REMOVING-TENANT.md) voor de volledige
> verwijderprocedure en de achtergrond bij `preserveResourcesOnDeletion`.

### Handmatig (sneller, maar niet GitOps)

```bash
TENANT=canary
NS=$TENANT

# 1. Verwijder Argo CD Application
kubectl delete application nc-$TENANT -n argocd

# 2. Verwijder namespace (cascade delete)
kubectl delete namespace $NS

# 3. Verifieer
kubectl get ns $NS
```

**Let op:** Dit verwijdert NIET:
- S3 data (zie [STORAGE-OPERATIONS.md](STORAGE-OPERATIONS.md))
- Database in externe PostgreSQL (indien gebruikt)
- DNS records

## Tenant Opnieuw Opzetten

### Na handmatige verwijdering

```bash
TENANT=canary

# Canonieke refresh: zet de Argo refresh-annotatie op de ApplicationSet.
# Argo pikt de gewijzigde annotatie op en re-evalueert de generator.
kubectl annotate applicationset nextcloud-tenants -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Dezelfde annotatie kan op de gegenereerde Application worden gezet:
kubectl annotate application nc-$TENANT -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# (CLI-alternatief — vereist de argocd CLI met server-toegang)
argocd app get nc-$TENANT --refresh
```

### Na GitOps verwijdering

```bash
TENANT=canary
NS=$TENANT

# 1. Herstel of maak nieuw tenant bestand
cp nextcloud-platform/values/templates/tenant-template.yaml \
   nextcloud-platform/values/tenants/tenant-$TENANT.yaml

# 2. Pas configuratie aan
# Edit nextcloud-platform/values/tenants/tenant-$TENANT.yaml

# 3. Maak secret aan VOORDAT je commit
kubectl create namespace $NS
kubectl create secret generic nextcloud-secrets \
  --namespace=$NS \
  --from-literal=nextcloud-username=admin \
  --from-literal=nextcloud-password="$(openssl rand -base64 24)" \
  --from-literal=s3-access-key='<YOUR_S3_ACCESS_KEY>' \
  --from-literal=s3-secret-key='<YOUR_S3_SECRET_KEY>' \
  --from-literal=mariadb-root-password="$(openssl rand -base64 24)" \
  --from-literal=mariadb-password="$(openssl rand -base64 24)" \
  --from-literal=redis-password='' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"

# 4. Commit en push (Argo leest Codeberg, niet GitHub)
git add nextcloud-platform/values/tenants/tenant-$TENANT.yaml
git commit -m "feat: add tenant $TENANT"
git push codeberg

# 5. Noteer admin wachtwoord
kubectl get secret nextcloud-secrets -n $NS -o jsonpath='{.data.nextcloud-password}' | base64 -d
```
