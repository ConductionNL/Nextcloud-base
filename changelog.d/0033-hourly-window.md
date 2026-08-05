### Gewijzigd — 2026-08-05 (scheduled-merge vuurt uurlijks, venster filtert)

De workflow had twee crons, 15:05 en 16:05 UTC, waarvan de venstercheck er per
seizoen één doorliet. Effectief dus één kans per avond. Een PR die om 21:00 groen
wordt, wacht dan tot de volgende dag — dezelfde flessenhals als één-wave-per-avond,
alleen op de tijd-as. En vandaag bleek het scherper: beide slots waren al gepasseerd
toen de wachtrij klaarstond, dus er gebeurde die avond niets meer.

Nu één cron, `5 * * * *`, en de check op `TZ=Europe/Amsterdam` bepaalt of er iets
gebeurt. Dat geeft 14 kansen per werkavond (7 tussen 17:00 en 23:00, 7 in de nacht
tot 07:00) en 56 per week. Een gemiste kans kost een uur in plaats van een dag.

Bijkomend: dit is zomertijd-proof zonder trucs. De twee crons bestonden alleen omdat
GitHub alleen UTC kent en 17:05 lokaal per seizoen verschuift. Nu doet de
venstercheck al het werk en is de cron onverschillig voor de klok.

Kosten zijn verwaarloosbaar: buiten het venster stopt de run in de eerste stap, in
enkele seconden. Overlap is afgedekt door de bestaande concurrency-groep
`release-pointer`; een uurlijkse trigger tijdens een lopende run wacht en vindt daarna
een lege wachtrij.

Het venster zelf is niet gewijzigd — ma–do vanaf 17:00 plus de nacht tot 07:00,
vrijdagavond en weekend niet. De waarheidstabel van twaalf gevallen is opnieuw
gedraaid en klopt.
