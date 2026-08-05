# changelog.d — één bestand per wijziging

Leg de changelog-entry van je PR hier neer als los bestand in plaats van hem in
`CHANGELOG.md` te schrijven.

## Waarom

Elke PR schreef zijn entry direct onder `## [Unreleased]` in `CHANGELOG.md`, op
precies dezelfde regel. Daardoor brak élke merge naar main alle andere openstaande
PR's: het conflict zat niet in de inhoud, maar in de invoegpositie.

Dat maakte de wachtrij van `scheduled-merge.yaml` onbruikbaar. Op 2026-08-05
gebeurde dat drie keer op één avond: na iedere merge stonden de resterende PR's op
`CONFLICTING` en moesten ze met de hand worden bijgewerkt. Een rij die na elke stap
handwerk vraagt, loopt niet leeg.

Met één bestand per wijziging bestaat die gedeelde regel niet meer. Twee PR's
kunnen niet conflicteren, want ze raken verschillende bestanden.

## Hoe

Maak een bestand `changelog.d/<pr-nummer>-<korte-slug>.md`:

```markdown
### Gewijzigd — 2026-08-05 (korte titel)

Wat er is gewijzigd en waarom. Zelfde toon en detailniveau als voorheen in
CHANGELOG.md — dit is nog steeds het audit-spoor, alleen op een andere plek.
```

Het PR-nummer voorin houdt de bestandsnamen uniek en de sortering chronologisch.
Ken je het nummer nog niet, gebruik dan de branchnaam en hernoem later.

## Samenvoegen

Bij een release voegt `nextcloud-platform/scripts/collect-changelog.sh` alle
fragmenten samen onder `## [Unreleased]` in `CHANGELOG.md` en verwijdert ze hier.
Dat is één commit door één persoon, dus daar kan niets meer conflicteren.

`CHANGELOG.md` blijft de canonieke, doorzoekbare historie. Deze map is alleen de
wachtruimte.

## Openstaand

De kop van `CHANGELOG.md` zegt nog "update it in the same commit as the change".
Dat klopt niet meer letterlijk — het is nu "leg een fragment neer in dezelfde
commit". Die regel is hier bewust niet aangepast: `CHANGELOG.md` wijzigen zou
precies het conflict veroorzaken dat deze map oplost, bij de PR's die op dit moment
in de wachtrij staan. Werk hem bij in de eerste `collect-changelog.sh`-commit, want
dan raakt het bestand toch al.
