# Changelog

## 1.0 (31) — 2026-09-22

- Refine profile, history, exercise-library and training-entry presentation.
- Add a guided InBody empty state with scan and manual-entry actions.
- Accept Weight/Weights headers and reconstruct cross-sheet training dates in week order.
- Record unchanged actual values when confirming the picker.


## Unreleased — 2026-09-17

- Exercise name display in Today reverts to the pre-refresh inline "中文（English）" layout; heart rate screen gains a session trend chart and a Z1-Z5 zone band; InBody trend chart gets a proper date axis and tighter Y-axis scaling; body-composition bar renders as one continuous proportional bar; history list gains a training-intensity heatmap.
- Today's "add from history" now copies any past day's full block/round/set detail, not just a simplified last-session template; any historical day can also be saved as a reusable session template.
- Exercise library expanded from 240 to about 300 bilingual entries, sourced from real coach programming patterns.
- Templates split into three non-overlapping libraries: session templates, superset templates, and a new WOD template library seeded with well-known public CrossFit benchmark WODs (Fran, Grace, Helen, Diane, Cindy, Annie, Karen, Isabel, Elizabeth, Nancy, Angie, Murph, DT, Jackie).
- Adding a superset or WOD in Today now defaults to picking from the matching template library, falling back to manual entry when nothing fits.

## 1.0 source distribution — 2026-09-14

- Initial clean source publication, based on application build 21.
- Strength sessions, supersets, WODs, profiles, history, local imports and exports.
- Local activity-energy estimates and optional structured DeepSeek reviews.
- New plans and added rounds keep actual results unrecorded until entered.
- Configurable self-hosted relay; no author service, credentials or signing team.
- Synthetic fixtures and templates; no private datasets or legacy Git history.
- Build, privacy, security, contribution and CI documentation.

Historical private development logs and device release receipts are intentionally excluded. This source publication is not an App Store or TestFlight release.
