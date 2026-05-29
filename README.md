> [!IMPORTANT]
> ## 🚚 This repository has moved to Codeberg
>
> Active development now happens at **https://codeberg.org/Conduction/Nextcloud-base**.
> This GitHub mirror is read-only — issues, pull requests, and new commits should go to Codeberg.
> Update your remote with: `git remote set-url origin https://codeberg.org/Conduction/Nextcloud-base`# Nextcloud Multi-Tenant GitOps Platform

<div align="center">

![Nextcloud](https://img.shields.io/badge/Nextcloud-0082C9?style=for-the-badge&logo=nextcloud&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)
![ArgoCD](https://img.shields.io/badge/Argo%20CD-EF7B4D?style=for-the-badge&logo=argo&logoColor=white)
![Helm](https://img.shields.io/badge/Helm-0F1689?style=for-the-badge&logo=helm&logoColor=white)

**Een production-ready GitOps platform voor het draaien van meerdere Nextcloud instances op Kubernetes**

[Quick Start](#-quick-start) •
[Architectuur](#-architectuur) •
[Documentatie](#-documentatie) •
[Bijdragen](#-bijdragen)

</div>

---

## ✨ Kenmerken

- 🚀 **Multi-tenant architectuur** — Elke tenant draait in eigen namespace met volledige isolatie
- 🔄 **GitOps-first** — Alle configuratie in Git, automatische sync via Argo CD
- 📦 **S3 Primary Storage** — Geen NFS-afhankelijkheden, resilient tijdens node upgrades
- 🔐 **Secrets Management** — Ondersteuning voor External Secrets Operator of fallback generator
- 📊 **Observability** — Prometheus metrics, ServiceMonitors, en alerting ready
- 🎯 **Canary Deployments** — Wave-based rollouts met canary-first strategie
- ⚡ **Connection Pooling** — Shared Redis en PgBouncer voor efficiënt resource gebruik

## 🏗️ Architectuur

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Kubernetes Cluster                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         Platform Components                              ││
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────────────────────────┐ ││
│  │  │   Redis     │  │  PgBouncer  │  │  External Secrets Operator       │ ││
│  │  │  (shared)   │  │  (shared)   │  │  (secrets from Vault/cloud)      │ ││
│  │  └─────────────┘  └─────────────┘  └──────────────────────────────────┘ ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐          │
│  │ ns: nc-canary    │  │ ns: nc-tenant-a  │  │ ns: nc-tenant-b  │   ...    │
│  │  ┌────────────┐  │  │  ┌────────────┐  │  │  ┌────────────┐  │          │
│  │  │ Nextcloud  │  │  │  │ Nextcloud  │  │  │  │ Nextcloud  │  │          │
│  │  │   Pod(s)   │  │  │  │   Pod(s)   │  │  │  │   Pod(s)   │  │          │
│  │  └────────────┘  │  │  └────────────┘  │  │  └────────────┘  │          │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘          │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           External Services                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────────┐  │
│  │   Ceph RGW S3   │  │   PostgreSQL    │  │        CephFS               │  │
│  │  (user files)   │  │   (database)    │  │   (minimal appdata)         │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Waarom S3 Primary Storage?

Tijdens Kubernetes node upgrades kan de provider toegang tot de OpenStack API blokkeren, waardoor:
- CSI attach/mount operaties falen
- In-cluster NFS provisioner onbeschikbaar wordt
- Services uitvallen voor de duur van de upgrade

**Onze oplossing:** User files in S3 (Ceph RGW) zijn altijd toegankelijk, onafhankelijk van cluster-status.

| Component | Traditioneel | Dit Platform |
|-----------|-------------|--------------|
| User files | NFS/block storage | **S3 Object Storage** |
| Config | RWX NFS volume | **ConfigMaps + Secrets** |
| Sessions | Local/NFS | **Redis** (shared) |
| Locking | File-based | **Redis** (distributed) |

## 📁 Repository Structuur

```
nextcloud-platform/
├── argo/                           # Argo CD configuratie
│   ├── applicationsets/            # ApplicationSet voor tenants
│   └── projects/                   # Argo CD project definitie
├── platform/                       # Shared platform components
│   ├── redis/                      # Shared Redis deployment
│   ├── pgbouncer/                  # Connection pooler
│   ├── externalsecrets/            # ESO ClusterSecretStore
│   └── policies/                   # NetworkPolicies, PDBs
├── values/                         # Helm values
│   ├── common.yaml                 # Gedeelde configuratie
│   ├── env/                        # Environment overrides
│   │   ├── accept.yaml
│   │   └── prod.yaml
│   └── tenants/                    # Tenant configuraties
│       └── tenant-canary.yaml
├── scripts/                        # Utility scripts
│   ├── create-tenant-secret.sh
│   ├── validate-values.sh
│   └── smoke-checks.sh
└── docs/                           # Documentatie
    ├── ADDING-TENANT.md
    ├── DATABASE.md
    ├── SECRETS.md
    └── UPGRADE.md
```

## 🚀 Quick Start

### Prerequisites

- Kubernetes 1.28+
- Argo CD geïnstalleerd
- cert-manager met `letsencrypt-prod` ClusterIssuer
- S3-compatible storage (Ceph RGW, MinIO, AWS S3)
- DNS geconfigureerd voor tenants

### 1. Clone de repository

```bash
git clone https://github.com/your-org/nextcloud-platform.git
cd nextcloud-platform
```

### 2. Configureer de eerste tenant

Maak een secret aan voor de canary tenant:

```bash
kubectl create namespace nc-canary

kubectl create secret generic nextcloud-secrets \
  --namespace=nc-canary \
  --from-literal=nextcloud-username=admin \
  --from-literal=nextcloud-password='$(openssl rand -base64 24)' \
  --from-literal=s3-access-key='YOUR_S3_ACCESS_KEY' \
  --from-literal=s3-secret-key='YOUR_S3_SECRET_KEY' \
  --from-literal=db-password='YOUR_DB_PASSWORD' \
  --from-literal=redis-password='' \
  --from-literal=nextcloud-secret="$(openssl rand -base64 48)"
```

### 3. Deploy met Argo CD

```bash
# Apply Argo CD project
kubectl apply -f nextcloud-platform/argo/projects/nextcloud-platform.yaml

# Apply ApplicationSet
kubectl apply -f nextcloud-platform/argo/applicationsets/nextcloud-tenants.yaml
```

### 4. Monitor de deployment

```bash
kubectl get applications -n argocd -w
kubectl get pods -n nc-canary -w
```

### 5. Toegang tot Nextcloud

Open je browser en ga naar `https://nextcloud-canary.commonground.nu` (of je geconfigureerde hostname).

## 📚 Documentatie

| Document | Beschrijving |
|----------|--------------|
| [SETUP.md](nextcloud-platform/SETUP.md) | Volledige setup guide voor eerste deployment |
| [ADDING-TENANT.md](nextcloud-platform/docs/ADDING-TENANT.md) | Stap-voor-stap guide voor nieuwe tenants |
| [DATABASE.md](nextcloud-platform/docs/DATABASE.md) | Database opties (MariaDB, PostgreSQL, External) |
| [SECRETS.md](nextcloud-platform/docs/SECRETS.md) | Secrets management met ESO of fallback |
| [UPGRADE.md](nextcloud-platform/docs/UPGRADE.md) | Upgrade procedures en rollback |

## 🔧 Tenant Toevoegen

Maak een nieuw bestand `values/tenants/tenant-<naam>.yaml`:

```yaml
tenant:
  name: mijn-tenant
  environment: prod
  wave: "1"
  hostname: mijn-tenant.nextcloud.example.com
  
  s3:
    bucket: nextcloud-mijn-tenant

nextcloud:
  host: mijn-tenant.nextcloud.example.com
  trustedDomains:
    - mijn-tenant.nextcloud.example.com

ingress:
  tls:
    - secretName: nextcloud-mijn-tenant-tls
      hosts:
        - mijn-tenant.nextcloud.example.com
  hosts:
    - host: mijn-tenant.nextcloud.example.com
      paths:
        - path: /
          pathType: Prefix
```

Commit en push — Argo CD maakt automatisch de Application aan.

## 📊 Monitoring & Alerting

Het platform is voorbereid op Prometheus monitoring:

- ServiceMonitors voor Nextcloud, Redis, PgBouncer
- Pod annotations voor metrics scraping
- Aanbevolen alert rules in de documentatie

## 🔄 Upgrade Strategie

1. **Update chart version** in `values/common.yaml`
2. **Canary rollout** — Wave 0 (canary) wordt eerst geupgrade
3. **Validatie** — Health checks op canary
4. **Wave rollout** — Overige tenants per wave

```bash
# Controleer status
argocd app get nc-canary

# Valideer na upgrade
kubectl exec -it -n nc-canary deploy/nextcloud -- php occ status
```

## 🤝 Bijdragen

1. Fork de repository
2. Maak een feature branch (`git checkout -b feature/mijn-feature`)
3. Valideer je wijzigingen:
   ```bash
   ./scripts/validate-values.sh
   ./scripts/smoke-checks.sh
   ```
4. Commit je changes (`git commit -m 'feat: beschrijving'`)
5. Push naar de branch (`git push origin feature/mijn-feature`)
6. Open een Pull Request

## 📝 License

Dit project is gelicenseerd onder de MIT License - zie het [LICENSE](nextcloud-platform/LICENSE) bestand voor details.

---

<div align="center">
  <sub>Built with ❤️ for the CommonGround community</sub>
</div>