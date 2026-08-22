# Alcove UI Spec for Tyland

Visual/interaction tokens reverse-engineered from Alcove v1.7 (Softpedia screenshots, live site,
release notes) and mapped onto Tyland's architecture. Reference captures live in
`/var/folders/66/kk0psrmd69g4rphqdcc33tsh0000gn/T/opencode/alcove-ref/`.

## Tokens

| Token | Value | Source |
|---|---|---|
| Card background | near-black `#0A0A0A`, no shadow at rest | shots 1, 3 |
| Expanded corners | top ~14pt, bottom ~28pt, continuous curve | shot 1 vs current 13/24 |
| Accent (calendar/dates) | coral red `rgb(255, 90, 110)` | shot 3 |
| Title type | SF Pro semibold 14pt white | shot 1 |
| Secondary type | SF Pro regular 11pt white 55% | shot 1 |
| Scrubber row | `elapsed — bar — -remaining` on ONE line, mono digits 10pt | shot 1 |
| Transport | shuffle · back · big pause · forward, spread to bar edges | shot 1 |
| HUD pill | `[icon] Label …slider…` wide pill, label after icon | shot 5 |
| Idle ambient | next calendar event title beside notch, dimmed small text | tryalcove.com hero |
| Mini-card pop | scale 0.92→1 + fade on activity change | release notes ("fluid transitions") |
| Motion | expand spring ≈ response 0.42 / damping 0.82; collapse faster, drier 0.32/0.9 | video review feel |

## Slices

A. **Motion & geometry** — IslandView springs asymmetric; expanded radii 14/28; compact
   activities pop in with scale+fade.
B. **Ambient idle** — when no activity and calendar has an upcoming event, show its title left
   of the notch (dimmed 10pt). Only widens when an event exists (keeps self-test invariant).
C. **Now Playing** — move elapsed/remaining onto the scrubber row; title 13→14pt.
D. **Month calendar** — replace agenda-only panel with Alcove layout: left column weekday caps +
   big day number + next-event line; right month grid M–S with accent circle on today; agenda
   rows stay underneath when events exist.
E. **HUD restyle** — add labels ("Sound", "Brightness", "Keyboard") between icon and level bar;
   level bar becomes continuous capsule fill instead of segments.

## Non-goals this pass
Shuffle/repeat (MediaCommand lacks them — backend work), weather idle chip (no service),
file shelf, lock-screen widgets (separate LockScreenController already exists).
