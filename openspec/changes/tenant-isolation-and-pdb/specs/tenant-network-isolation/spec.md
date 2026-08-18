## ADDED Requirements

### Requirement: A tenant namespace denies ingress by default
Every tenant namespace SHALL carry a default-deny ingress `NetworkPolicy`, with an explicit
allowlist for the traffic the tenant actually needs. A tenant that has not opted in SHALL be
unaffected, and enabling the policy for one tenant SHALL NOT change the rendered output of any
other tenant.

#### Scenario: A neighbouring tenant is refused
- **GIVEN** tenants A and B both run in the fleet and A has the policy enabled
- **WHEN** a pod in namespace B opens a connection to the Nextcloud pod in namespace A
- **THEN** the connection is refused
- **AND** the same request through the ingress controller or the Gateway still succeeds

#### Scenario: Opting one tenant in leaves the rest untouched
- **WHEN** a single tenant file sets the opt-in flag
- **THEN** only that tenant gains a NetworkPolicy Application
- **AND** the specs of the other tenant Applications are byte-identical to before

### Requirement: Ingress admits every front door in use
The ingress allowlist SHALL admit both the ingress-nginx namespace and the Envoy Gateway
namespace for as long as both serve tenant traffic. Removing either SHALL be a deliberate step
tied to decommissioning that ingress path, not a side effect of another change.

#### Scenario: A tenant is migrated to Gateway API
- **GIVEN** a tenant with the NetworkPolicy enabled and an `HTTPRoute` on the shared Gateway
- **WHEN** its DNS record is moved to the Gateway
- **THEN** the tenant keeps serving, because the policy already admitted the Gateway namespace

### Requirement: The allowlist is derived from observed traffic
Egress rules SHALL be based on a recorded observation of real traffic from a tenant with
representative load, not on a design-time list of expected destinations. A rule that cannot be
justified from that observation SHALL either be omitted or carry a dated comment naming what
requires it. A blanket `0.0.0.0/0` egress rule SHALL NOT be introduced without such a
justification.

#### Scenario: An unknown destination appears
- **WHEN** a destination is found during observation that no one can attribute to a component
- **THEN** it is investigated and either allowed with a named justification or left denied
- **AND** it is not folded into a wildcard rule to make the policy pass

### Requirement: Isolation is verified from both sides
Validating the policy SHALL include a check that traffic which should now be refused is in fact
refused. Confirming only that the tenant still serves SHALL NOT be accepted as proof, because a
policy that admits everything also passes that check.

#### Scenario: Validation after enabling a tenant
- **WHEN** the policy is enabled for a tenant
- **THEN** validation records both that the tenant still answers through its front door
- **AND** that a connection attempt from another tenant namespace fails

### Requirement: Rollout is staged and reversible
The policy SHALL be introduced ingress-first, then egress, and per tenant before any wave, with a
recorded observation window between stages. Each stage SHALL be revertible by removing the
tenant's opt-in flag.

#### Scenario: A wave surfaces a broken background job
- **WHEN** a tenant in a wave reports a failing sync after the egress stage
- **THEN** removing that tenant's flag restores the previous behaviour without touching any other
  tenant
