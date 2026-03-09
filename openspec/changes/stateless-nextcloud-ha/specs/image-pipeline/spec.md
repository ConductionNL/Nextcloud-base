## ADDED Requirements

### Requirement: Custom image includes Nextcloud and Conduction apps
The custom image SHALL be based on the official `nextcloud:{version}-fpm` image with opencatalogi, openconnector, and openregister pre-installed at pinned versions.

#### Scenario: Image contains expected apps
- **WHEN** a container is started from `conduction/nextcloud:{nc-version}-apps-{apps-version}`
- **THEN** `php occ app:list` SHALL show opencatalogi, openconnector, and openregister as installed
- **THEN** each app SHALL be at the pinned version declared in the image build manifest

#### Scenario: Image does not contain secrets or credentials
- **WHEN** the image is built and scanned
- **THEN** no secrets, API keys, or credentials SHALL be present in any image layer
- **THEN** gitleaks and truffleHog scans SHALL report zero findings

### Requirement: PHP extensions are declaratively configurable in the image build manifest
The image build manifest SHALL support a list of additional PHP extensions to compile and enable. Operators SHALL be able to add extensions (e.g., `pdo_pgsql`, `soap`, `intl`, `gd`) without modifying the Dockerfile directly — only the manifest changes.

#### Scenario: PostgreSQL extension enabled
- **WHEN** `pdo_pgsql` is listed in the extensions manifest
- **THEN** the built image SHALL have `pdo_pgsql` loaded (`php -m | grep pdo_pgsql` returns a match)
- **THEN** Nextcloud SHALL be able to connect to a PostgreSQL database using this extension

#### Scenario: SOAP extension enabled
- **WHEN** `soap` is listed in the extensions manifest
- **THEN** the built image SHALL have the SOAP extension loaded (`php -m | grep soap` returns a match)

#### Scenario: Extension addition triggers rebuild and version bump
- **WHEN** a PR to the `nextcloud-image` repo adds or removes an extension from the manifest
- **THEN** CI SHALL build a new image
- **THEN** the `apps-semver` SHALL be bumped (extensions are part of the image bundle, not versioned separately)

#### Scenario: No extension listed — minimal surface
- **WHEN** an extension is NOT listed in the manifest
- **THEN** it SHALL NOT be compiled into the image (no silent extras from base image overrides)

### Requirement: Image tag encodes Nextcloud version and apps bundle version
Image tags SHALL follow the scheme `{nc-version}-apps-{apps-semver}` (e.g., `32.0.5-apps-1.2.3`). The `latest` tag SHALL NOT be used in production.

#### Scenario: Tag is deterministic and immutable
- **WHEN** an image is built with a given Nextcloud version and apps semver
- **THEN** the resulting tag SHALL always refer to the same image digest
- **THEN** pushing the same tag again SHALL be blocked (immutable tags enforced at registry level)

### Requirement: Image rebuild triggers are limited to meaningful version changes
The image build pipeline SHALL trigger ONLY when the Nextcloud base image version changes or when a Conduction app version pin changes. Platform repo pushes (values, config, tenant files) SHALL NOT trigger image rebuilds.

#### Scenario: App version bump triggers rebuild
- **WHEN** a PR to the `nextcloud-image` repo changes an app version pin
- **THEN** CI SHALL build a new image with the updated app version
- **THEN** CI SHALL push the image to GHCR with a new `apps-semver` tag

#### Scenario: Platform repo push does not trigger rebuild
- **WHEN** a commit is pushed to `nextcloud-platform` that changes only values files
- **THEN** no image build SHALL be triggered

### Requirement: Image vulnerability scanning is mandatory before publication
Every built image SHALL be scanned for vulnerabilities before being published to the registry. Images with Critical CVEs SHALL NOT be published without explicit override and documented justification.

#### Scenario: Clean image published
- **WHEN** an image build completes with no Critical CVEs
- **THEN** the image SHALL be pushed to GHCR and the tag made available for use

#### Scenario: Critical CVE blocks publication
- **WHEN** an image build completes and the scanner finds a Critical CVE
- **THEN** the image SHALL NOT be pushed to the registry
- **THEN** CI SHALL fail and report the CVE details
- **THEN** a human MUST review and either fix the base image/app version or document an explicit acceptance before overriding

### Requirement: Platform repo references custom image by explicit tag
`values/common.yaml` SHALL reference the custom image by its full tag (`conduction/nextcloud:{nc-version}-apps-{apps-version}`). The upstream `nextcloud:{version}-fpm` image SHALL NOT be referenced in production values after Phase 2 completes.

#### Scenario: Image tag update is a GitOps commit
- **WHEN** a new image is validated on canary-prod and ready for prod rollout
- **THEN** the image tag in `values/common.yaml` SHALL be updated via a git commit to `nextcloud-platform`
- **THEN** Argo CD SHALL detect the change and trigger a rolling update across tenants per wave
