# Documentation Index (English)

This directory holds the design, verification and operational records for HermesPaw,
the HarmonyOS NEXT client for the [Hermes Agent](https://hermes-agent.nousresearch.com/docs) gateway.

> **Language note.** The body of these documents is written in Simplified Chinese — they are
> engineering working records kept alongside the code, and translating every revision would
> double the maintenance cost. This page is the English entry point: it tells you **what each
> document answers, who it is for, and whether it is still authoritative**, so you can decide
> whether to read the original (with a translation tool) or only the parts that matter.
> The user-facing documentation — [`README.md`](../README.md) and
> [`README.en.md`](../README.en.md) — is fully bilingual.

## Read in this order

| # | Document | Answers | Audience | Status |
|---|---|---|---|---|
| 1 | [`refactor-design.md`](refactor-design.md) | **Why the client is built this way**: transport strategy (getRun polling as the baseline, SSE only as an enhancement), run lifecycle and give-up rules, session/title contract, approval flow, size and dependency red lines. The signed-off design baseline (v1.6). | Anyone reviewing architecture decisions | 📌 Authoritative design baseline |
| 2 | [`impl-status.md`](impl-status.md) | **What was actually built and how it was proven**: every step (S1…S11) with the evidence that accepted it — build times, gate results, on-device logs, and the conclusions that were later *disproved*. | Contributors, reviewers, future maintainers | 🔄 Living record, updated per step |
| 3 | [`server-setup.md`](server-setup.md) | **How to prepare the gateway side by hand**: profile, long-lived key, LAN binding, firewall, and the pairing QR code that `tools/hermes-paw-qr` prints. Complements step-by-step instructions in the main README. | Whoever runs the gateway | ✅ Operational, verified on real hardware |
| 4 | [`slash-command-support.md`](slash-command-support.md) | **Which Hermes CLI slash commands the app supports**, measured on a real device: 5 commands mapped locally, 7 explicitly rejected, the rest forwarded to the model as plain text (the gateway does not dispatch slash commands over REST). | Users filing "command X does nothing" reports; contributors | ✅ Measured matrix |
| 5 | [`user-auth-and-settings-design.md`](user-auth-and-settings-design.md) | **The email-code login design and why it is switched off**: gateway-side P1 was reverted, client-side P2 is dormant (probe returns 404 → legacy mode), only the small P3 scope shipped. Contains the re-enable path. | Reviewers of auth-related changes | ⏸️ Feature dormant by decision (D6) |
| 6 | [`third-party-references.md`](third-party-references.md) | **Licensing boundary**: MIT for this repository, zero third-party runtime dependencies, and how referenced projects (iHermes, Conduit, segno) may and may not be used. | Distributors, downstream packagers, legal review | ✅ Binding |
| 7 | [`test-target-s1.md`](test-target-s1.md) · [`-s2`](test-target-s2.md) · [`-s3`](test-target-s3.md) | **Machine-checkable acceptance targets** per stage, written before implementation so that "done" is not a matter of opinion. Useful as a template if you extend the app. | Test authors | 🗄️ Historical, still valid as examples |
| 8 | [`s3-c-token-recheck.md`](s3-c-token-recheck.md) | **Token storage re-check**: static verification that credentials only live in secure storage, with zero code change required. | Security reviewers | 🗄️ Historical evidence |
| 9 | [`dsh-smoke-arkts.md`](dsh-smoke-arkts.md) | **ArkTS smoke test**: whether a headless model-driven workflow can produce a compilable HarmonyOS NEXT component with an accurate API surface. Background on how parts of this codebase were produced. | Curious contributors | 🗄️ Historical |

## Conventions used in these documents

- **Evidence over adjectives.** Statements carry a measurable artefact: a build duration,
  a gate count, a log line with a timestamp, a device layout dump. If a claim has no artefact,
  it is marked as a hypothesis.
- **Disproved conclusions are kept, not deleted.** When a change was implemented and then
  measured to have no effect, it was reverted *and* recorded (see the SQLite `PRAGMA` finding
  in `impl-status.md`). Deleting the record would invite the same mistake twice.
- **Design documents do not contain code**, implementation records do not change design.
  When the two disagree, the design document wins and the implementation record is corrected.
- **No internal identifiers.** Hostnames, LAN addresses, tokens and personal data are stripped
  from anything that ships; gates enforce this on every commit.

## Where the code-level facts live

| Question | Look at |
|---|---|
| How do I build, sign and install it? | [`README.en.md`](../README.en.md) |
| What runs on the phone? | `entry/src/main/ets/` — `viewmodel/` (state machine, polling policy), `net/` (gateway API, SSE), `pages/` (UI) |
| How is behaviour verified without a device? | `tools/*-selftest.py` and `make test` |
| How is it verified on a device? | `entry/src/ohosTest/` (Hypium, `make test-device`) |
| What stops regressions in specs? | `tools/arkts-lint.py`, `tools/i18n-selftest.py`, `tools/s3-selftest.py` — all wired into `make test` |
