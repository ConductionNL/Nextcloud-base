### Gewijzigd — 2026-08-05 (de merge-wachtrij kan nu echt leeglopen)

Twee dingen hielden `scheduled-merge.yaml` tegen om meer dan één PR per run te
verwerken. Beide zijn op 2026-08-05 in echte runs waargenomen, niet uit theorie.

**Mergeability werd één keer uitgevraagd.** GitHub berekent die waarde lazy: direct
na een merge staat hij voor de volgende PR's op `UNKNOWN`, wat "nog niet berekend"
betekent en niet "niet mergebaar". De workflow las één keer en sloeg de PR dan over.
In run `31026343726` ging #10 er volledig door, waarna #22 en #21 beide werden
overgeslagen met `niet mergebaar (UNKNOWN/UNKNOWN)`. De wachtrij kon daardoor per
run nooit verder komen dan de eerste PR, wat de hele wijziging van #28 ongedaan
maakte. Nu wordt er tot twaalf keer met vijf seconden ertussen uitgevraagd; het
uitvragen zelf triggert de berekening.

**Elke PR schreef op dezelfde regel van `CHANGELOG.md`.** Alle entries gingen
direct onder `## [Unreleased]`, dus iedere merge naar main zette alle andere
openstaande PR's op `CONFLICTING` — het conflict zat in de invoegpositie, niet in de
inhoud. Dat gebeurde die avond drie keer, en elke keer moest de rest van de rij met
de hand worden bijgewerkt. Een wachtrij die na iedere stap handwerk vraagt, loopt
niet leeg.

Daarom `changelog.d/`: één bestand per wijziging, `<pr-nummer>-<slug>.md`. Twee PR's
raken dan verschillende bestanden en kunnen niet meer conflicteren. Deze entry is
zelf zo'n fragment, dus deze PR wijzigt `CHANGELOG.md` niet en botst niet met de
PR's die nog in de rij staan.

`nextcloud-platform/scripts/collect-changelog.sh` voegt de fragmenten bij een
release samen onder `## [Unreleased]` en verwijdert ze. Dat is één commit door één
persoon, dus daar valt niets te conflicteren. `CHANGELOG.md` blijft de canonieke
historie; `changelog.d/` is alleen de wachtruimte.
