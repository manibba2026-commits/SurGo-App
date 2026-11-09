# SurGo Final Presentation Documentation

This folder is a documentation-only package prepared for the SurGo thesis defense and live demonstration. It describes the repository as it exists at the time of writing; it does not change application code, database schema, data, or configuration.

## Read in this order

| File | Purpose |
| --- | --- |
| [SYSTEM_OVERVIEW.md](SYSTEM_OVERVIEW.md) | What SurGo is, who it serves, what is real vs. simulated, and the honest scope of the prototype. |
| [SYSTEM_ARCHITECTURE.md](SYSTEM_ARCHITECTURE.md) | Flutter app layers, auth, repository/data modes, Supabase, and the Next.js admin dashboard. |
| [DATABASE_OVERVIEW.md](DATABASE_OVERVIEW.md) | Tables, enums, RLS, RPCs, migrations, hosted-vs-local differences, and demo data. |
| [USER_WORKFLOWS.md](USER_WORKFLOWS.md) | End-to-end workflows for auth, rides, rider/helper, rentals, Pasuyo, wallet, verification, and admin. |
| [FEATURE_AUDIT.md](FEATURE_AUDIT.md) | Feature-by-feature status with evidence and demo guidance. |
| [PRESENTATION_TEST_CHECKLIST.md](PRESENTATION_TEST_CHECKLIST.md) | Pre-defense verification steps and pass/fail criteria. |
| [THESIS_PRESENTATION_OUTLINE.md](THESIS_PRESENTATION_OUTLINE.md) | Fifteen-slide deck outline with visuals and speaker notes. |
| [LIVE_DEMO_SCRIPT.md](LIVE_DEMO_SCRIPT.md) | An 8–12 minute demo sequence with exact actions and recovery paths. |
| [PANEL_QA.md](PANEL_QA.md) | Twenty-five-plus anticipated panel questions with technically accurate answers. |
| [FINAL_READINESS_REPORT.md](FINAL_READINESS_REPORT.md) | Readiness summary, blockers, Qoder dependencies, and preparation order. |

## Status vocabulary

These labels are used consistently across the package:

| Label | Meaning |
| --- | --- |
| **Implemented and demonstrable** | The flow exists, is reachable from the running app or admin dashboard, and has been exercised or is directly supported by the code path. |
| **Implemented but needs verification** | Code exists, but a live end-to-end check (browser, device, hosted data, or network path) has not been completed or is environment-dependent. |
| **Simulated/demo data** | The user-facing behaviour is intentionally faked in the prototype (timers, seeded lists, in-memory mutations). It is not a real backend transaction. |
| **Partially implemented** | Some layers are real and some are stubbed; the boundary is stated explicitly. |
| **Not implemented** | No working code path exists. |
| **Provisional** | A claim that could not be confirmed from the repository or the hosted project at the time of writing. |

## Source-of-truth rule

Repository code is treated as the source of truth. `README.md`, `supabase/README.md`, and `surgo_special_readme.md` contain stale statements (for example, the old 10% ride commission and "no screen reads the database"). Where they conflict with code, the code wins and the conflict is called out.
