# 2026-06-23 Serial vs Parallel Lift on libcrypto.so.3 — Precision & Recall

## 背景

本次实验目的：对比 serial lift（单入口、无 worker）和 parallel lift（多 seed、`-dynamic-parallel`）在 `libcrypto.so.3` 上的指令级 precision 和 recall，评估 dynamic-parallel 模式的实际收益。

评估口径遵循既有 canonical contract（见
`docs/exp/2026-05-10-libcrypto-canonical-eval-contract.md`）：
- Binary: `GroudTruth/groundtruth-gap-analysis-skill/results/libcrypto-artifacts/libcrypto.so.3`
- Ground truth: 同目录 `libcrypto.gtBlock.pb`（via objdump `.text`）
- Eval script: `runnable/scripts/run_cmp_eval.py`
- `--text-start 0xcef80 --runnable-base 0x50000000`
- GT 总指令数：**679,506**

---

## 关键发现 1：host-native 构建的 runnable-lift 在容器内不可用

### 问题

`build-codex-dynamic-current/runnable-lift`（在 host 上直接 cmake 构建）在
`rr_bionic_exportfs:2026-04-14` 容器内启动立即失败：

```
runnable-lift: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.34' not found
runnable-lift: /usr/lib/x86_64-linux-gnu/libstdc++.so.6: version `GLIBCXX_3.4.32' not found
```

表现为 binary 存在、大小正常（~8MB），但无法执行。这是历次 "看起来已构建但
实际未生效" 的根本原因。

### 原因

Host（Ubuntu 22.04+）编译链接了新版 glibc/libstdc++。容器运行环境是
Ubuntu 18.04（bionic），无法满足符号版本要求。

### 修复方法

**必须在容器内编译**。预构建的 LLVM 7 / QEMU / Boost 依赖位于容器内的
`/root/Runnable-Rewriting/root`，不需要重新构建。

```bash
# 从 Runnable-Rewriting/ 目录下一键构建
runnable/scripts/build_runnable_lift.sh        # 产物: build-bionic/runnable-lift
```

核心 cmake 调用（cmake 3.10 需在 `--` 后面传 `-j`）：

```bash
docker run --rm -v "$WORKSPACE_ROOT":/workspace rr_bionic_exportfs:2026-04-14 bash -lc '
  BUILD=/workspace/Runnable-Rewriting/build-bionic
  DEPS=/root/Runnable-Rewriting/root
  mkdir -p "$BUILD" && cd "$BUILD"
  cmake /workspace/Runnable-Rewriting/runnable \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_INSTALL_PREFIX="$BUILD/install" \
    -DQEMU_INSTALL_PATH="$DEPS" \
    -DLLVM_DIR="$DEPS/lib/cmake/llvm" \
    -DBOOST_ROOT="$DEPS" -DBoost_NO_SYSTEM_PATHS=On \
    -DCMAKE_CXX_LINK_FLAGS="-static-libgcc -static-libstdc++" \
    -DCMAKE_C_LINK_FLAGS="-static-libgcc"
  cmake --build . -- -j"$(nproc)"    # ~90 个 TU，128 核约 1.5 分钟
'
```

验证（确认 `-dynamic-parallel` 出现，无 GLIBC 报错）：

```bash
B=/workspace/Runnable-Rewriting/build-bionic
LDP="$B/lib/Support:$B/lib/BasicAnalyses:$B/lib/Dump:$B/lib/FunctionIsolation:$B/lib/StackAnalysis:/root/Runnable-Rewriting/root/lib"
docker run --rm -v "$PWD/..":/workspace -e LD_LIBRARY_PATH="$LDP" \
  rr_bionic_exportfs:2026-04-14 bash -lc \
  './build-bionic/runnable-lift --help 2>&1 | grep -E "dynamic-parallel|addr-range"'
```

注意：`cmake --install` 不安装 `runnable-lift` target；可用二进制在
build tree：`build-bionic/runnable-lift`（这也是 `probe_build_tree_runnable_lift` 所查找的路径）。

---

## 关键发现 2：Serial lift 在 precision 和 recall 上均优于 Parallel lift

### 配置

| 项 | Serial lift | Parallel lift (all-symbols) |
|---|---|---|
| 入口数量 | 1（`.text` 起始地址 `0x500cef80`） | 5324（全部 symtab 符号） |
| `-dynamic-parallel` | 否 | 是，`-parallel-workers=5` |
| addr-range 约束 | 无（自由跟随调用链） | 每个 seed 限制在自身函数范围内 |
| 并行度 | 单线程 | 6 个并发 coordinator，各 5 个 worker |
| 运行时长 | ~2.5 小时 | ~47 分钟 |
| 产物 `.ll` | 39M 行 | 无（merge 后约等量） |
| 使用的 binary | May 14 bionic build（`~30.8MB`） | 同 |
| 运行日期 | 2026-05-14 | 2026-05-14（`full-32g-30c-20260514-214906`），2026-06-22 复验（`prune-full-20260622`） |

### 结果

| 模式 | Precision | Recall | TP (hit) | FP | FN | .ll 指令数 |
|------|-----------|--------|----------|----|----|-----------|
| **Serial** | **0.9107** | **0.7799** | 529,936 | 51,961 | 149,570 | 581,897 |
| **Parallel (all-symbols)** | 0.7104 | 0.6714 | 456,189 | 185,986 | 223,317 | 642,175 |

两次 parallel 运行（May 14 和 Jun 22）结果一致（精度差 <0.002%），数据可信。

### 分析

**Precision 差距（0.91 vs 0.71）**：Parallel 模式每个 coordinator 在函数范围内
开启 5 个 worker 探索分支，产生大量 speculative 假正例（FP=185,986 vs 51,961）。
`-addr-range-min/-addr-range-max` 限制的是范围外的跳出，但函数内的分支仍被大量探索。

**Recall 差距（0.78 vs 0.67）**：Serial lift 从单一入口自由跟随调用链，遍历
libcrypto 中大部分可达函数。Parallel 的 per-function 范围约束阻止了跨函数控制流，
5324 个孤立 fragment merge 后仍遗漏了 223K 个 GT 中存在的指令块。
**Parallel lift 产出的 .ll 更大（642K vs 582K 条），却匹配到更少的真实指令（456K vs 530K）。**

### 与 SPEC2006 的一致性

此结论与之前 SPEC2006 binary 的测试（见 memory/spec2006-parallel-lift-eval.md）一致：
dynamic-parallel 在单 binary 全量分析时 recall 不升反降，precision 也显著下降。

---

## 关键发现 3：Dynsym/worklist 模式（`.text` 范围约束）目前无法完成运行

### 设计意图

Worklist 模式（`--dynsym-only`，默认开启）使用约 2050 个 exported symbol 作为
seed，并将 coordinator 的 addr-range 设为整个 `.text` section，从而允许跨函数探索，
理论上兼顾 recall 和精度。

### 当前状态

测试 3 个 AES 函数（`AES_encrypt / AES_decrypt / AES_set_decrypt_key`）时，
每个 seed 均超过 30 分钟超时（`rc=124`）：

```
done fn_00000000000cf4b0 status=failed rc=124 workers=1 elapsed=1801.3
done fn_00000000000cfa40 status=failed rc=124 workers=3 elapsed=1801.5
done fn_00000000000cfdc0 status=failed rc=124 workers=3 elapsed=1801.4
```

原因：在 `.text` 范围内，AES 函数的分支树极大（含大量 lookup-table 驱动的
条件跳转），coordinator 持续探索新分支直至超时。

### 注意

worklist 模式的 shard manifest 中 `coordinator_flags` 字段看起来为空（`[]`），
**这是误导性的**：`write_shard_manifests` 函数本身不写 coordinator_flags，
该字段来自 python3 取了默认值。实际 `.text` bounds 是通过 `--coordinator-flag`
参数传给 shard runner 的，并会出现在最终的 runnable-lift 调用中。可通过
`detect_text_bounds()` 在 `libcrypto_bench_paths.py` 中验证。

### 待解决方向

1. 提高 per-seed 超时（`--lift-timeout-sec`），或按 symbol 大小分级超时
2. 增加 branch-depth limit，避免 coordinator 对同一地址反复探索
3. 先排除 AES 等已知超时函数，评估其余 dynsym seed 的 precision/recall

---

## 产物位置

| 内容 | 路径 |
|---|---|
| Serial lift `.ll` | `/hdd/runnable-libcrypto-serial-lift-20260514-132835/output/libcrypto.so.3.entry_0x500cf000.ll` |
| Serial eval JSON | `/hdd/runnable-libcrypto-serial-lift-20260514-132835/canonical_cmp/cmp.json` |
| Parallel lift `.ll` | `/hdd/runnable-libcrypto-dynamic-parallel-optimized/runs/full-32g-30c-20260514-214906/libcrypto.dynamic.parallel.ll` |
| Parallel eval JSON | `/hdd/runnable-libcrypto-dynamic-parallel-optimized/runs/full-32g-30c-20260514-214906/eval/cmp-eval.json` |
| Bionic build script | `Runnable-Rewriting/runnable/scripts/build_runnable_lift.sh` |
| Bionic build output | `Runnable-Rewriting/build-bionic/runnable-lift` |
| Build/eval skill | `Runnable-Rewriting/.codex/skills/runnable-build/SKILL.md` |

---

## 下一步

1. **Worklist 超时问题**：针对 AES 函数确认根因（branch 循环 or 分支数过多），
   再决定是调整超时还是加 depth limit。
2. **Parallel 精度优化**：探索是否可在 per-function 模式下减少 worker 数量，
   以降低 FP，同时接受轻微 recall 损失。
3. **Serial recall 提升**：考虑从多个 dynsym entry point 分别做 serial lift
   再 merge，测试 recall 能否接近 GT 上限。
