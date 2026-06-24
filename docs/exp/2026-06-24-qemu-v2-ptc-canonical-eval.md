# 2026-06-24 QEMU V2 PTC Canonical Eval Expansion

Date: 2026-06-24

## Goal

在已经确认 `codex-bionic-rebuild` 单 seed `SHA1` canonical compare 可通过后，
继续扩大 canonical 覆盖，确认 QEMU V2 PTC 并非只通过 `SHA1`。

本次工作只做三件事：

- 审计并最小扩展 `runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh`
  的入口配置能力；
- 新增批量 wrapper `runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh`，
  把单 symbol canonical verify 整理成 sweep；
- 选取额外可直接比较的 canonical `libcrypto.so.3` 导出函数，复用同一条
  bionic rebuild + canonical compare 路径做增量验证。

这不是“整个迁移完成”的声明；这里只证明当前路径已覆盖多于一个 canonical
seed/function。

## Script Audit

审计前，`runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh` 只支持：

- `--entry`
- 自动从 binary 探测 `.text` 边界
- 默认 seed 为 `SHA1@@OPENSSL_3.0.0`

它不支持直接按 symbol 选入口，也不支持显式覆盖 `--text-start` /
`--text-end`。

本次做了最小扩展：

- 新增 `--symbol NAME`
- 新增 `--text-start HEX`
- 新增 `--text-end HEX`
- 默认行为保持不变，仍然对应
  `SHA1@@OPENSSL_3.0.0` / `0x50304f30`

实现方式：

- 若提供 `--symbol`，脚本从 canonical `libcrypto.so.3` 的 `readelf -Ws`
  导出符号表解析入口地址，并覆盖 `--entry`
- 若未显式传入 `--text-start` / `--text-end`，继续沿用原来的自动探测逻辑
- summary JSON 新增 `symbol` 字段

## Sweep Wrapper

新增 `runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh`，职责只做外层调度，
不改动单项 subset 执行语义。

支持：

- `--symbol NAME` 直接追加单个 symbol
- `--symbol-spec LABEL=SYMBOL` 显式指定 label suffix
- `--symbol-file PATH` 从文件读取 symbol list
- `--profile next-family` 直接加载本轮同族候选
- `--profile broad-family` 加载更广的 EVP/PKCS/BN/RSA/BIO 混合候选
- `--` 之后透传给
  `qemu_v2_ptc_libcrypto_canonical_subset.sh` 的其余参数

行为：

- 对每个 symbol 单独调用 `qemu_v2_ptc_libcrypto_canonical_subset.sh`
- 单项失败时继续后续 symbol，不中断整个 sweep
- 单项 stdout/stderr 落到
  `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/<label-prefix>/items/<item-label>/`
- 聚合输出：
  - summary JSON:
    `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/<label-prefix>/qemu_v2_ptc_libcrypto_canonical_sweep.summary.json`
  - markdown table:
    `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/<label-prefix>/qemu_v2_ptc_libcrypto_canonical_sweep.table.md`
- summary JSON 现会额外聚合：
  - `cmp_rc_counts`
  - `cmp_verdict_counts`
  - `failure_class_counts`
  - `blocker_code_counts`
  - `lift_rc_counts`
  - `cmp_metric_summary`
    （当前整理 `precision/recall/hit/ll_count/obj_count/false_positive/false_negative/mismatch`）

判定口径更新：

- `lift_rc=0` 只表示 lift execution 成功，不等于整体 PASS
- 只有 `lift_rc=0` 且 `cmp_verdict=true` 且 `precision/recall` 达标且 `ll_count>0`
  才算 PASS
- `cmp_verdict=false`、`precision/recall` 低于阈值或 `ll_count=0` 都必须记为 FAIL，
  并给出机器可读 blocker

## Canonical Seeds

候选函数来自 canonical binary 本身的已导出函数，避免盲选不可比较入口。

本次确认的导出符号：

- `SHA1@@OPENSSL_3.0.0` at `0x304f30`
- `SHA256@@OPENSSL_3.0.0` at `0x304fd0`
- `MD5@@OPENSSL_3.0.0` at `0x20b870`
- `AES_encrypt@@OPENSSL_3.0.0` at `0xcf4b0`
- `SHA384@@OPENSSL_3.0.0` at `0x305020`
- `SHA512@@OPENSSL_3.0.0` at `0x305070`
- `AES_decrypt@@OPENSSL_3.0.0` at `0xcfa40`
- `HMAC@@OPENSSL_3.0.0` at `0x1e7c10`
- `HMAC_Init_ex@@OPENSSL_3.0.0` at `0x1e7680`
- `BN_mod_exp@@OPENSSL_3.0.0` at `0x113ab0`
- `HMAC_Update@@OPENSSL_3.0.0` at `0x1e7990`
- `HMAC_Final@@OPENSSL_3.0.0` at `0x1e79b0`
- `BN_exp@@OPENSSL_3.0.0` at `0x111e80`
- `BN_mod_mul@@OPENSSL_3.0.0` at `0x119bc0`
- `PKCS5_PBKDF2_HMAC@@OPENSSL_3.0.0` at `0x1d87c0`
- `EVP_Digest@@OPENSSL_3.0.0` at `0x1b7020`
- `EVP_EncryptUpdate@@OPENSSL_3.0.0` at `0x1c7930`
- `EVP_DigestInit_ex@@OPENSSL_3.0.0` at `0x1b7010`
- `EVP_DigestInit@@OPENSSL_3.0.0` at `0x1b6fe0`
- `EVP_EncryptInit_ex2@@OPENSSL_3.0.0` at `0x1ca6f0`
- `EVP_MD_CTX_copy_ex@@OPENSSL_3.0.0` at `0x1b70d0`
- `PKCS7_sign@@OPENSSL_3.0.0` at `0x2d7af0`
- `PKCS7_set_type@@OPENSSL_3.0.0` at `0x2d5fb0`
- `PKCS12_init_ex@@OPENSSL_3.0.0` at `0x2cea00`
- `BN_mod_sqr@@OPENSSL_3.0.0` at `0x119c70`
- `BN_div@@OPENSSL_3.0.0` at `0x111610`
- `RSA_size@@OPENSSL_3.0.0` at `0x2e9870`
- `RSA_bits@@OPENSSL_3.0.0` at `0x2e9860`
- `BIO_read@@OPENSSL_3.0.0` at `0x101850`
- `BIO_write_ex@@OPENSSL_3.0.0` at `0x1018d0`

统一运行条件：

- binary:
  `/home/iskindar/Project/runnable-rewriting-project/GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.so.3`
- runnable base:
  `0x50000000`
- `.text`:
  `[0xcef80, 0x3b1fee)` relative,
  `[0x500cef80, 0x503b1fee)` absolute
- mode:
  `-dynamic-parallel -parallel-workers=2 -use-debug-symbols -no-link`
- runtime:
  `rr_bionic_exportfs:2026-04-14`
- libtinycode path:
  in-container rebuilt live-sidecar `real_translation=true`

## Commands

默认 `SHA1` PASS 复用已有结果：

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label codex-bionic-rebuild
```

新增 expanded subset：

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label codex-bionic-rebuild-sha256 \
  --symbol 'SHA256@@OPENSSL_3.0.0'
```

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label codex-bionic-rebuild-md5 \
  --symbol 'MD5@@OPENSSL_3.0.0'
```

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label codex-bionic-rebuild-aesenc \
  --symbol 'AES_encrypt@@OPENSSL_3.0.0'
```

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label codex-bionic-rebuild-sha384 \
  --symbol 'SHA384@@OPENSSL_3.0.0'
```

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label codex-bionic-rebuild-sha512 \
  --symbol 'SHA512@@OPENSSL_3.0.0'
```

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label codex-bionic-rebuild-aesdec \
  --symbol 'AES_decrypt@@OPENSSL_3.0.0'
```

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label codex-bionic-rebuild-hmac \
  --symbol 'HMAC@@OPENSSL_3.0.0'
```

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label codex-bionic-rebuild-hmac-init \
  --symbol 'HMAC_Init_ex@@OPENSSL_3.0.0'
```

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --label codex-bionic-rebuild-bn-mod-exp \
  --symbol 'BN_mod_exp@@OPENSSL_3.0.0'
```

下一批同族函数改用 sweep wrapper：

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh \
  --label-prefix codex-bionic-rebuild-next-family \
  --profile next-family
```

```bash
bash runnable/scripts/qemu_v2_ptc_libcrypto_canonical_sweep.sh \
  --label-prefix codex-bionic-rebuild-broad-family \
  --profile broad-family
```

## Result Matrix

| Label | Symbol | Entry | lift_rc | cmp_rc | failure_class | blocker_code | Result |
| --- | --- | --- | ---: | ---: | --- | --- | --- |
| `codex-bionic-rebuild` | `SHA1@@OPENSSL_3.0.0` | `0x50304f30` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-sha256` | `SHA256@@OPENSSL_3.0.0` | `0x304fd0` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-md5` | `MD5@@OPENSSL_3.0.0` | `0x20b870` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-aesenc` | `AES_encrypt@@OPENSSL_3.0.0` | `0xcf4b0` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-sha384` | `SHA384@@OPENSSL_3.0.0` | `0x305020` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-sha512` | `SHA512@@OPENSSL_3.0.0` | `0x305070` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-aesdec` | `AES_decrypt@@OPENSSL_3.0.0` | `0xcfa40` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-hmac` | `HMAC@@OPENSSL_3.0.0` | `0x1e7c10` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-hmac-init` | `HMAC_Init_ex@@OPENSSL_3.0.0` | `0x1e7680` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-bn-mod-exp` | `BN_mod_exp@@OPENSSL_3.0.0` | `0x113ab0` | 0 | 0 | `none` | `null` | PASS |

对应 summary JSON：

- `/tmp/rr-qemu-v2-libcrypto-canonical-subset/codex-bionic-rebuild/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-subset/codex-bionic-rebuild-sha256/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-subset/codex-bionic-rebuild-md5/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-subset/codex-bionic-rebuild-aesenc/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-subset/codex-bionic-rebuild-sha384/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-subset/codex-bionic-rebuild-sha512/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-subset/codex-bionic-rebuild-aesdec/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-subset/codex-bionic-rebuild-hmac/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-subset/codex-bionic-rebuild-hmac-init/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-subset/codex-bionic-rebuild-bn-mod-exp/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`

## Next-Family Sweep Result Matrix

| Label | Symbol | Entry | lift_rc | cmp_rc | failure_class | blocker_code | Result |
| --- | --- | --- | ---: | ---: | --- | --- | --- |
| `codex-bionic-rebuild-next-family-hmac-update` | `HMAC_Update@@OPENSSL_3.0.0` | `0x1e7990` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-next-family-hmac-final` | `HMAC_Final@@OPENSSL_3.0.0` | `0x1e79b0` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-next-family-bn-exp` | `BN_exp@@OPENSSL_3.0.0` | `0x111e80` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-next-family-bn-mod-mul` | `BN_mod_mul@@OPENSSL_3.0.0` | `0x119bc0` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-next-family-pkcs5-pbkdf2-hmac` | `PKCS5_PBKDF2_HMAC@@OPENSSL_3.0.0` | `0x1d87c0` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-next-family-evp-digest` | `EVP_Digest@@OPENSSL_3.0.0` | `0x1b7020` | 0 | 0 | `none` | `null` | PASS |
| `codex-bionic-rebuild-next-family-evp-encrypt-update` | `EVP_EncryptUpdate@@OPENSSL_3.0.0` | `0x1c7930` | 0 | 0 | `none` | `null` | PASS |

批量 summary：

- `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/codex-bionic-rebuild-next-family/qemu_v2_ptc_libcrypto_canonical_sweep.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/codex-bionic-rebuild-next-family/qemu_v2_ptc_libcrypto_canonical_sweep.table.md`

单项 summary：

- `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/codex-bionic-rebuild-next-family/subset-runs/codex-bionic-rebuild-next-family-hmac-update/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/codex-bionic-rebuild-next-family/subset-runs/codex-bionic-rebuild-next-family-hmac-final/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/codex-bionic-rebuild-next-family/subset-runs/codex-bionic-rebuild-next-family-bn-exp/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/codex-bionic-rebuild-next-family/subset-runs/codex-bionic-rebuild-next-family-bn-mod-mul/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/codex-bionic-rebuild-next-family/subset-runs/codex-bionic-rebuild-next-family-pkcs5-pbkdf2-hmac/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/codex-bionic-rebuild-next-family/subset-runs/codex-bionic-rebuild-next-family-evp-digest/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/codex-bionic-rebuild-next-family/subset-runs/codex-bionic-rebuild-next-family-evp-encrypt-update/qemu_v2_ptc_libcrypto_canonical_subset.summary.json`

失败项：

- 本轮 `next-family` sweep 无失败项，`7/7` 为 `PASS`

## Broad-Family Sweep Result Matrix (Historical, Superseded)

This matrix preserves an earlier `codex-bionic-rebuild-broad-family` run for audit
history only. It is not the current repo status.

Current authoritative status for the same 13-symbol broad-family scope is the
passing `validation23-broad-family-scoped` sweep recorded in
`docs/exp/2026-06-24-qemu-v2-evidence-manifest.md` and in
`/tmp/rr-qemu-v2-libcrypto-canonical-sweep/validation23-broad-family-scoped/qemu_v2_ptc_libcrypto_canonical_sweep.summary.json`.

`broad-family` 选了 13 个真实导出符号，刻意覆盖更多
`EVP_* / PKCS* / BN_* / RSA_* / BIO_*`：

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

| Label | Symbol | Entry | lift_rc | cmp_rc | cmp_verdict | precision | recall | failure_class | blocker_code | Result |
| --- | --- | --- | ---: | ---: | --- | ---: | ---: | --- | --- | --- |
| `codex-bionic-rebuild-broad-family-evp-digest-init-ex` | `EVP_DigestInit_ex@@OPENSSL_3.0.0` | `0x1b7010` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-evp-digest-init` | `EVP_DigestInit@@OPENSSL_3.0.0` | `0x1b6fe0` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-evp-encrypt-init-ex2` | `EVP_EncryptInit_ex2@@OPENSSL_3.0.0` | `0x1ca6f0` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-evp-md-ctx-copy-ex` | `EVP_MD_CTX_copy_ex@@OPENSSL_3.0.0` | `0x1b70d0` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-pkcs7-sign` | `PKCS7_sign@@OPENSSL_3.0.0` | `0x2d7af0` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-pkcs7-set-type` | `PKCS7_set_type@@OPENSSL_3.0.0` | `0x2d5fb0` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-pkcs12-init-ex` | `PKCS12_init_ex@@OPENSSL_3.0.0` | `0x2cea00` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-bn-mod-sqr` | `BN_mod_sqr@@OPENSSL_3.0.0` | `0x119c70` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-bn-div` | `BN_div@@OPENSSL_3.0.0` | `0x111610` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-rsa-size` | `RSA_size@@OPENSSL_3.0.0` | `0x2e9870` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-rsa-bits` | `RSA_bits@@OPENSSL_3.0.0` | `0x2e9860` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-bio-read` | `BIO_read@@OPENSSL_3.0.0` | `0x101850` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |
| `codex-bionic-rebuild-broad-family-bio-write-ex` | `BIO_write_ex@@OPENSSL_3.0.0` | `0x1018d0` | 0 | 0 | `false` | 0.000000 | 0.000000 | `cmp-failed` | `blocked:lift-empty-ll` | FAIL |

批量 summary：

- `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/codex-bionic-rebuild-broad-family/qemu_v2_ptc_libcrypto_canonical_sweep.summary.json`
- `/tmp/rr-qemu-v2-libcrypto-canonical-sweep/codex-bionic-rebuild-broad-family/qemu_v2_ptc_libcrypto_canonical_sweep.table.md`

跨 symbol 聚合指标：

- `pass_count=13`, `fail_count=0`
- `lift_rc_counts={"0": 13}`
- `cmp_rc_counts={"0": 13}`
- `failure_class_counts={"none": 13}`
- `blocker_code_counts={"null": 13}`
- `cmp_verdict_counts={"false": 13}`
- `cmp_metric_summary.cmp_json_count=13`
- `cmp_metric_summary.precision_avg=0.0`, `precision_min=0.0`, `precision_max=0.0`
- `cmp_metric_summary.recall_avg=0.0`, `recall_min=0.0`, `recall_max=0.0`
- `cmp_metric_summary.hit_sum=0`
- `cmp_metric_summary.ll_count_sum=0`
- `cmp_metric_summary.obj_count_sum=8833578`
- `cmp_metric_summary.false_positive_sum=0`
- `cmp_metric_summary.false_negative_sum=8833578`
- `cmp_metric_summary.mismatch_sum=0`

失败项：

- 这份历史 run 当时记录为 `13/13 FAIL`，现已被 `validation23-broad-family-scoped`
  的 `13/13 PASS` 当前证据明确 superseded
- 这些项的 lift execution 都是 `lift_rc=0`
- 但 compare verdict 层面 `13/13` 都是 `ok: false`
- 典型 verdict 原因一致：
  `precision 0.000000 < 0.800000`、
  `recall 0.000000 < 0.800000`、
  `metrics are catastrophically low; the .ll likely comes from a different binary build`

## Interpretation

这次 expanded subset 给出的证据是：

- QEMU V2 PTC canonical path 已不再局限于单一 `SHA1` seed；
- 至少 10 个 canonical `libcrypto.so.3` 导出函数已经完成
  `lift_rc=0` 且 `cmp_rc=0`；
- 覆盖了两个摘要族入口（`SHA1`、`SHA256`）、一个历史摘要入口（`MD5`）、
  两个 SHA-2 近邻入口（`SHA384`、`SHA512`）、两个对称密码入口
  （`AES_encrypt`、`AES_decrypt`）、以及一个 HMAC 族入口和一个大整数模幂入口
  （`HMAC`、`HMAC_Init_ex`、`BN_mod_exp`）。
- 同时补上了 7 个同族入口的批量 sweep，覆盖 HMAC update/final、
  BN exp/mod mul、PBKDF2-HMAC、EVP digest/encrypt-update。

因此，这份历史 run 当时给出的结论是：

- QEMU V2 PTC 已经在 canonical libcrypto compare 路径上通过多 seed/function
  的 lift execution 验证；
- 当前已覆盖 `17 + 13 = 30` 个 canonical 导出函数的 subset；
- 但新 sweep 聚合显示，`cmp_rc=0` 不等于 compare verdict 通过：
  `broad-family` 的 `cmp_verdict_counts={"false": 13}`，且 `precision/recall`
  全为 `0.0`；
- 因此仍不足以声称整个 libcrypto canonical workload 或整个迁移已经完成。

这已经不是当前状态。当前 authoritative status 以 `validation22`/`validation23`
artifact 为准，其中 `broad-mini 3/3 PASS`、`next-family 7/7 PASS`、
`broad-family 13/13 PASS`。

## Historical Coverage Snapshot

Below is the symbol coverage discussed by the earlier draft around the historical
failing broad-family run. For current repo status, use the evidence manifest.

当前确认 lift execution PASS 的 canonical subset：

- `SHA1@@OPENSSL_3.0.0`
- `SHA256@@OPENSSL_3.0.0`
- `MD5@@OPENSSL_3.0.0`
- `AES_encrypt@@OPENSSL_3.0.0`
- `SHA384@@OPENSSL_3.0.0`
- `SHA512@@OPENSSL_3.0.0`
- `AES_decrypt@@OPENSSL_3.0.0`
- `HMAC@@OPENSSL_3.0.0`
- `HMAC_Init_ex@@OPENSSL_3.0.0`
- `HMAC_Update@@OPENSSL_3.0.0`
- `HMAC_Final@@OPENSSL_3.0.0`
- `BN_exp@@OPENSSL_3.0.0`
- `BN_mod_exp@@OPENSSL_3.0.0`
- `BN_mod_mul@@OPENSSL_3.0.0`
- `PKCS5_PBKDF2_HMAC@@OPENSSL_3.0.0`
- `EVP_Digest@@OPENSSL_3.0.0`
- `EVP_EncryptUpdate@@OPENSSL_3.0.0`
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

尚未做的事：

- 把新的 `cmp_verdict` / `cmp_metric_summary` 继续推广到更多 profile
- 继续解释为什么 `cmp_verdict` 在这些项上稳定为 `false`
- 判断是 compare 输入 build 不匹配、`-no-link` 产物为空，还是当前
  canonical compare 语义本身需要收紧

## Historical Next Blocker

当前 blocker 已不再是 “QEMU V2 只能过 SHA1”。

对当时那份历史 run 来说，更现实的下一步是 coverage blocker：

- coverage 已从 17-symbol subset 扩到 30-symbol subset，但仍然只是 subset；
- 真正新的 blocker 是 compare 语义 blocker：
  `cmp_rc` 现在全是 0，但 `cmp_verdict` 在 `broad-family` 上 `13/13 false`；
- 下一个应该优先追的点是 `validate_libcrypto_ground_truth.py cmp`
  为什么在 `ll_count=0`、`precision=0.0`、`recall=0.0` 时仍返回 `cmp_rc=0`。

## Validation3 Audit

本轮接手时，`validation3` 产物已经落在 `/tmp/rr-qemu-v2-libcrypto-canonical-subset/`。
我对 `SHA1` 和 `EVP_DigestInit_ex` 两个样本做了最小核对，结论一致：

- `lift_rc=0`
- `cmp_rc=0`
- `cmp_verdict=false`
- `ll_count=0`
- `precision=0.000000`
- `recall=0.000000`
- `blocker_code=blocked:lift-empty-ll`

`eval-manual` 也没有把结果拉起来，仍然是同一组 `ll_count=0 / precision=0 / recall=0`。
这说明当前 `.ll` 里没有可供 compare 读取的地址语义标记，至少不是当前 parser 认识的
`;\ 0x...:` 或 `bb.0x...:` 形式。于是这轮最小收口不是继续追 compare 算法，而是把
blocker 明确固化为 `blocked:lift-empty-ll`，并把根因限定为“lift 产物缺少地址语义”。
