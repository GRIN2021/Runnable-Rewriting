# Experiment Topics

This page groups experiment-related documents by topic so that new runs can be found without knowing the exact date-based filename.

## libcrypto

Use this group for `libcrypto.so.3` lift, agent/classifier, and policy experiments.

- [2026-04-22 libcrypto boundary audit](2026-04-22-libcrypto-boundary-audit.md)
  - normalizes current illegal-entry candidates and emits deterministic boundary actions
- [2026-04-22 libcrypto old classifier validation](2026-04-22-libcrypto-old-classifier-validation.md)
  - validates old `raw` and old `agent` classifiers on current `libcrypto.so.3`
  - includes wrong-proxy failure and fixed-proxy rerun
- [2026-05-10 libcrypto canonical eval contract](2026-05-10-libcrypto-canonical-eval-contract.md)
  - fixes the SYM-20 evaluation contract and separates canonical GT compare from historical sidecar-union metrics
- [../design/libcrypto/README.md](../design/libcrypto/README.md)
  - method/design navigation for the `libcrypto` track
- [../reference/RUNNABLE_CORE_AND_METRICS.md](../reference/RUNNABLE_CORE_AND_METRICS.md)
  - background on how `--llm-policy` fits into Runnable

## Rewrite Validation

Use this group for serial vs parallel rewrite checks and behavior-validation summaries.

- [../results/2026-04-22-coreutils-serial-parallel-validation.md](../results/2026-04-22-coreutils-serial-parallel-validation.md)
  - serial/parallel behavior comparison on `coreutils`

## GT / Embedded Data

Use this group for ground-truth methodology and embedded-data interpretation.

- [../reference/README-embedata.md](../reference/README-embedata.md)
  - concrete embedded-data examples
- [../design/2026-04-02-evaluation-wrapup-design.md](../design/2026-04-02-evaluation-wrapup-design.md)
  - GT repair and stripped-OpenSSL design context

## Notes

- A single experiment can appear under multiple topics.
- Date-based experiment files should stay under `docs/exp/`.
- Broader validation summaries that are more like stable result notes can remain under `docs/results/` and still be linked here.
