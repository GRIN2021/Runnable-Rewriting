# 2026-06-24 QEMU V2 Evidence Manifest

Date: 2026-06-24
Status: Final current evidence
Branch target: `codex/qemu-upgrade-v2`

## Final Scope Boundary

This manifest records the final current evidence for the validated QEMU v2 work on
2026-06-24.

Completed and evidenced scope:

- AVX QEMU v2 patch-series harness on host: PASS
- AVX QEMU v2 patch-series harness in Docker: PASS
- PTC scoped canonical subset for `SHA1@@OPENSSL_3.0.0` on host: PASS
- PTC scoped canonical subset for `SHA1@@OPENSSL_3.0.0` in Docker: PASS
- PTC scoped canonical sweep `broad-mini`: 3/3 PASS
- PTC scoped canonical sweep `next-family`: 7/7 PASS
- PTC scoped canonical sweep `broad-family`: 13/13 PASS

This is the completion boundary for the evidence recorded here.

This manifest does not claim arbitrary or full `libcrypto.so.3` coverage beyond the
validated scoped profiles above.

## Evidence Summary

### 1. AVX host harness: PASS

Authoritative artifact:

```text
/tmp/rr-qemu-v2-upstream-probes-full-harness-22/out/summary.md
```

Recorded result:

- patch generation `0001` through `0019`: PASS
- exact-byte AVX-512 probes: PASS
- aggregate-boundary: PASS
- overall: PASS

Key paths:

- scratch root:
  `/tmp/rr-qemu-v2-upstream-probes-full-harness-22`
- source input:
  `/tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3`
- patched source:
  `/tmp/rr-qemu-v2-upstream-probes-full-harness-22/qemu-10.2.3-avx512-series-src`
- QEMU binary:
  `/tmp/rr-qemu-v2-upstream-probes-full-harness-22/build-10.2.3-avx512-series/qemu-x86_64`

Representative rerun command:

```bash
bash runnable/scripts/qemu_v2_avx512_patch_series.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --scratch-root /tmp/rr-qemu-v2-upstream-probes-full-harness-22 \
  --jobs 2
```

### 2. AVX Docker harness: PASS

Authoritative artifact:

```text
/tmp/rr-qemu-v2-docker-avx-long-run-20260624/out/summary.md
```

Recorded result:

- patch generation `0001` through `0019`: PASS
- exact-byte AVX-512 probes: PASS
- aggregate-boundary: PASS
- overall: PASS

Key paths:

- scratch root:
  `/tmp/rr-qemu-v2-docker-avx-long-run-20260624`
- source input inside container:
  `/workspace/qemu-10.2.3`
- QEMU binary:
  `/tmp/rr-qemu-v2-docker-avx-long-run-20260624/build-10.2.3-avx512-series/qemu-x86_64`

Representative rerun command:

```bash
docker/qemu-v2-runtime/run-validation.sh \
  --skip-image-build \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --scratch-root /tmp/rr-qemu-v2-docker-avx-long-run-20260624 \
  --jobs 3 \
  -- bash runnable/scripts/qemu_v2_avx512_patch_series.sh \
    --qemu-src /workspace/qemu-10.2.3 \
    --scratch-root /tmp/rr-qemu-v2-docker-avx-long-run-20260624 \
    --jobs 3
```

### 3. PTC canonical subset `SHA1@@OPENSSL_3.0.0` on host: PASS

Authoritative artifact:

```text
/tmp/rr-qemu-v2-libcrypto-canonical-subset/validation22-sha1-annotation/qemu_v2_ptc_libcrypto_canonical_subset.summary.json
```

Recorded result:

- `result="passed"`
- `cmp_verdict_ok=true`
- `cmp_rc="0"`
- `precision=1.0`
- `recall=1.0`
- real lifted annotation retained for entry `0x50304f30`, including `push`

Key paths:

- summary JSON:
  `/tmp/rr-qemu-v2-libcrypto-canonical-subset/validation22-sha1-annotation/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- lifted IR:
  `/tmp/rr-qemu-v2-libcrypto-canonical-subset/validation22-sha1-annotation/run/validation22-sha1-annotation.ll`
- compare JSON:
  `/tmp/rr-qemu-v2-libcrypto-canonical-subset/validation22-sha1-annotation/eval/cmp.json`

Representative rerun command:

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label validation22-sha1-annotation
```

### 4. PTC canonical subset `SHA1@@OPENSSL_3.0.0` in Docker: PASS

Authoritative artifact:

```text
/tmp/rr-qemu-v2-docker-ptc-sha1-20260624c/docker-validation17-sha1/qemu_v2_ptc_libcrypto_canonical_subset.summary.json
```

Recorded result:

- `result="passed"`
- `cmp_verdict_ok=true`
- `cmp_rc="0"`

Key paths:

- summary JSON:
  `/tmp/rr-qemu-v2-docker-ptc-sha1-20260624c/docker-validation17-sha1/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- compare JSON:
  `/tmp/rr-qemu-v2-docker-ptc-sha1-20260624c/docker-validation17-sha1/eval/cmp.json`

Representative rerun command:

```bash
docker/qemu-v2-runtime/run-validation.sh \
  --skip-image-build \
  --scratch-root /tmp/rr-qemu-v2-docker-ptc-sha1-20260624c \
  -- bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
    --label docker-validation17-sha1
```

### 5. PTC scoped sweep `broad-mini`: 3/3 PASS

Authoritative artifact:

```text
/tmp/rr-qemu-v2-libcrypto-canonical-sweep/validation22-broad-mini-scoped/qemu_v2_ptc_libcrypto_canonical_sweep.summary.json
```

Recorded result:

- `pass_count=3`
- `fail_count=0`
- `cmp_verdict_counts={"true":3}`
- aggregate precision/recall: `1.0 / 1.0`

Representative symbols:

- `RSA_size@@OPENSSL_3.0.0`
- `RSA_bits@@OPENSSL_3.0.0`
- `BIO_read@@OPENSSL_3.0.0`

Representative rerun command:

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh \
  --label-prefix validation22-broad-mini-scoped \
  --profile broad-mini
```

This command is reproducible with the repo script as checked in: `broad-mini`
expands to exactly `RSA_size`, `RSA_bits`, and `BIO_read`.

### 6. PTC scoped sweep `next-family`: 7/7 PASS

Authoritative artifact:

```text
/tmp/rr-qemu-v2-libcrypto-canonical-sweep/validation23-next-family-scoped/qemu_v2_ptc_libcrypto_canonical_sweep.summary.json
```

Recorded result:

- `pass_count=7`
- `fail_count=0`
- `cmp_verdict_counts={"true":7}`
- aggregate precision/recall: `1.0 / 1.0`

Representative symbols:

- `HMAC_Update@@OPENSSL_3.0.0`
- `HMAC_Final@@OPENSSL_3.0.0`
- `BN_exp@@OPENSSL_3.0.0`
- `BN_mod_mul@@OPENSSL_3.0.0`
- `PKCS5_PBKDF2_HMAC@@OPENSSL_3.0.0`
- `EVP_Digest@@OPENSSL_3.0.0`
- `EVP_EncryptUpdate@@OPENSSL_3.0.0`

Representative rerun command:

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh \
  --label-prefix validation23-next-family-scoped \
  --profile next-family
```

### 7. PTC scoped sweep `broad-family`: 13/13 PASS

Authoritative artifact:

```text
/tmp/rr-qemu-v2-libcrypto-canonical-sweep/validation23-broad-family-scoped/qemu_v2_ptc_libcrypto_canonical_sweep.summary.json
```

Recorded result:

- `pass_count=13`
- `fail_count=0`
- `cmp_verdict_counts={"true":13}`
- aggregate precision/recall: `1.0 / 1.0`

Representative symbols:

- `EVP_DigestInit_ex@@OPENSSL_3.0.0`
- `EVP_DigestInit@@OPENSSL_3.0.0`
- `EVP_EncryptInit_ex2@@OPENSSL_3.0.0`
- `EVP_MD_CTX_copy_ex@@OPENSSL_3.0.0`
- `PKCS7_sign@@OPENSSL_3.0.0`
- `PKCS7_set_type@@OPENSSL_3.0.0`
- `PKCS12_init_ex@@OPENSSL_3.0.0`
- `BN_mod_sqr@@OPENSSL_3.0.0`
- `BN_div@@OPENSSL_3.0.0`
- `RSA_size@@OPENSSL_3.0.0`
- `RSA_bits@@OPENSSL_3.0.0`
- `BIO_read@@OPENSSL_3.0.0`
- `BIO_write_ex@@OPENSSL_3.0.0`

Representative rerun command:

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh \
  --label-prefix validation23-broad-family-scoped \
  --profile broad-family
```

## Caveat

The `validation23-broad-family-scoped` sweep is counted as PASS because the summary
and per-item compare artifacts are valid and green. A non-blocking anomaly should
still be recorded honestly: the `EVP_DigestInit_ex@@OPENSSL_3.0.0` item has native
harness segfault text in capture stderr while the item still completed with valid
sidecar and compare outputs.

Relevant paths:

- item stderr:
  `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/validation23-broad-family-scoped/items/validation23-broad-family-scoped-evp-digest-init-ex/subset.stderr`
- item summary:
  `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/validation23-broad-family-scoped/subset-runs/validation23-broad-family-scoped-evp-digest-init-ex/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- aggregate summary:
  `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/validation23-broad-family-scoped/qemu_v2_ptc_libcrypto_canonical_sweep.summary.json`

## Historical Note

Earlier draft wording referenced `validation11-sha1` and an `invalid PTC temp
reference` blocker. That is historical only and is not the current status.

The current authoritative SHA1 evidence is the passing `validation22-sha1-annotation`
host artifact and the passing `docker-validation17-sha1` Docker artifact listed
above.

## Rerun Index

### AVX host

Artifact:

```text
/tmp/rr-qemu-v2-upstream-probes-full-harness-22/out/summary.md
```

Command:

```bash
bash runnable/scripts/qemu_v2_avx512_patch_series.sh \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --scratch-root /tmp/rr-qemu-v2-upstream-probes-full-harness-22 \
  --jobs 2
```

### AVX Docker

Artifact:

```text
/tmp/rr-qemu-v2-docker-avx-long-run-20260624/out/summary.md
```

Command:

```bash
docker/qemu-v2-runtime/run-validation.sh \
  --skip-image-build \
  --qemu-src /tmp/rr-qemu-v2-upstream-probes/qemu-10.2.3 \
  --scratch-root /tmp/rr-qemu-v2-docker-avx-long-run-20260624 \
  --jobs 3 \
  -- bash runnable/scripts/qemu_v2_avx512_patch_series.sh \
    --qemu-src /workspace/qemu-10.2.3 \
    --scratch-root /tmp/rr-qemu-v2-docker-avx-long-run-20260624 \
    --jobs 3
```

### PTC SHA1 host

Artifact:

```text
/tmp/rr-qemu-v2-libcrypto-canonical-subset/validation22-sha1-annotation/qemu_v2_ptc_libcrypto_canonical_subset.summary.json
```

Command:

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label validation22-sha1-annotation
```

### PTC SHA1 Docker

Artifact:

```text
/tmp/rr-qemu-v2-docker-ptc-sha1-20260624c/docker-validation17-sha1/qemu_v2_ptc_libcrypto_canonical_subset.summary.json
```

Command:

```bash
docker/qemu-v2-runtime/run-validation.sh \
  --skip-image-build \
  --scratch-root /tmp/rr-qemu-v2-docker-ptc-sha1-20260624c \
  -- bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
    --label docker-validation17-sha1
```

### PTC broad-mini scoped

Artifact:

```text
/tmp/rr-qemu-v2-libcrypto-canonical-sweep/validation22-broad-mini-scoped/qemu_v2_ptc_libcrypto_canonical_sweep.summary.json
```

Command:

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh \
  --label-prefix validation22-broad-mini-scoped \
  --profile broad-mini
```

Profile expansion is exactly:

- `RSA_size@@OPENSSL_3.0.0`
- `RSA_bits@@OPENSSL_3.0.0`
- `BIO_read@@OPENSSL_3.0.0`

### PTC next-family scoped

Artifact:

```text
/tmp/rr-qemu-v2-libcrypto-canonical-sweep/validation23-next-family-scoped/qemu_v2_ptc_libcrypto_canonical_sweep.summary.json
```

Command:

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh \
  --label-prefix validation23-next-family-scoped \
  --profile next-family
```

### PTC broad-family scoped

Artifact:

```text
/tmp/rr-qemu-v2-libcrypto-canonical-sweep/validation23-broad-family-scoped/qemu_v2_ptc_libcrypto_canonical_sweep.summary.json
```

Command:

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh \
  --label-prefix validation23-broad-family-scoped \
  --profile broad-family
```

## Completion Statement

Within the bounded scope above, the current QEMU v2 evidence set is complete and
green on 2026-06-24.

Allowed wording:

- "QEMU v2 AVX host and Docker evidence are green."
- "QEMU v2 PTC scoped canonical subset and scoped sweep evidence are green for
  SHA1, broad-mini, next-family, and broad-family."

Disallowed wording:

- "QEMU v2 has arbitrary full libcrypto coverage."
- "QEMU v2 full migration is proven beyond the validated scoped profiles."
