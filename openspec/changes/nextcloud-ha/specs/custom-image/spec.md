## OUT OF SCOPE

The `custom-image` capability was removed from this change set.

**Reason**: Cinder multi-attach shares the `/var/www/html` volume across all replica pods. This eliminates the need for an emptyDir-per-pod approach and therefore eliminates the need to bake apps into a custom Docker image. The existing hook-based app-enable mechanism continues to work: on first pod start the hook runs `occ app:enable`; the state file on the shared PVC prevents re-runs on subsequent pods.

**Future consideration**: A custom image would reduce cold-start time (no app download at startup) and make the deployment fully offline-capable. This is worth revisiting if startup latency becomes a concern or if Conduction apps are released to a private registry. It can be implemented independently of the HA storage change.
