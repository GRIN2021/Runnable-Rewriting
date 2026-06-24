# AVX-512 Lift 支持计划

## 背景

Serial lift 在 libcrypto.so.3 上的实测 recall 为 0.78。分析发现：

- 149K FN 中约 103K（70%）集中在 `ossl_aes_gcm_encrypt_avx512` 和
  `ossl_aes_gcm_decrypt_avx512` 两个函数
- 主导 mnemonic：`vpxorq`、`vaesenc`、`vbroadcastf64x2`、`vpternlogq`、
  `vpclmullqlqdq` 等，全为 AVX-512（EVEX 前缀）指令
- 排除 AVX-512 函数后 recall 升至 **0.927**；排除所有 SIMD-heavy 函数后升至 **0.971**
- 评估噪音（`cs`/`(bad)` 对齐填充）仅贡献约 6K FN，可忽略

## 根因分析

### QEMU 版本

容器内 QEMU：**2.4.50**（2015 年），用于 runnable-lift 动态执行的是其中的
`libtinycode-x86_64.so`（patched TCG）。

### 现有 EVEX 处理逻辑

`qemu/target-i386/translate.c` 中有两处定制改动：

**1. EVEX 前缀解码（line 4645）**

```c
case 0x62: /* EVEX or bound */
    if (CODE64(s) && !s->vm86) {
        // 解析 p0/p1/p2，提取 rex_r/rex_x/rex_b/rex_w/vex_v/vex_l
        // 设置 PREFIX_VEX，推进 s->pc += 3，读取 opcode | 0x200
    }
```

EVEX 前缀本身已被正确解析，opcode 进入 `0x200–0x2ff` 区间。

**2. `ptc_evex_tail_bytes`（line 189）**

```c
static int ptc_evex_tail_bytes(CPUX86State *env, target_ulong pc,
                               TCGMemOp aflag, int p0, int p1, int opcode)
{
    int map = p0 & 0x3;
    int pp  = p1 & 0x3;
    int length = ptc_modrm_bytes(env, pc, aflag);  // ModRM + SIB + disp 字节数

    switch (map) {
    case 1: // 0F
        if (pp==1 && opcode==0xef)               return length;      // vpxorq
        if ((opcode==0x6f||opcode==0x7f) && ...) return length;      // vmovdqu*
    case 2: // 0F 38
        if (pp==1 && (opcode==0x00||0x1a||0xdc)) return length;      // vbroadcast/vaesenc
    case 3: // 0F 3A
        if (pp==1 && (opcode==0x25||0x39||0x44)) return length + 1;  // vpternlogq/vpclmul*
    default:
        return -1;  // → goto illegal_op → SIGILL
    }
}
```

**关键问题**：`case 0x200...0x2ff` 的处理逻辑是：

```c
case 0x200 ... 0x2ff: {
    int tail_bytes = ptc_evex_tail_bytes(...);
    if (tail_bytes < 0) { goto illegal_op; }
    s->pc += tail_bytes;   // 只推进 PC，跳过字节
    break;                 // 不发射任何 TCG op
}
```

即：**EVEX 指令字节被消费，但完全没有生成 TCG IR**。结果：
- `ptc_translate` 产出的 `PTCInstructionList` 不含 EVEX 指令
- LLVM IR 里没有对应的地址注释 `; 0xADDR: vpxorq ...`
- 动态执行（`ptc_exec`）跳过这些指令，ZMM 寄存器无更新
- AVX-512 函数执行结果完全错误，大概率引发后续内存访问错误
- 整块 AVX-512 代码在 .ll 里消失 → FN

`ptc_evex_tail_bytes` 目前只覆盖了约 7 个 opcode，
`vpxorq`/`vaesenc`/`vbroadcastf64x2`/`vpternlogq`/`vpclmul*` 恰好都在其中，
**所以是"被跳过"而非"SIGILL"**（SIGILL 仅发生在 `ptc_evex_tail_bytes` 返回 -1
的 opcode 上）。

## 解决方案对比

| 方案 | 难度 | recall 改善 | IR 正确性 | 说明 |
|---|---|---|---|---|
| A. 升级 QEMU 到 5.x/6.x | 极高 | 完整 | 完整 | 需要移植 1800 行 PTC 接口 + ptc_evex 扩展到新 API |
| B. EVEX 发射 tombstone marker | 中 | 高（+0.15） | 地址正确，语义为 NOP | 改动限于 translate.c，最小代价恢复 recall |
| C. Capstone 静态 fallback | 中 | 高 | 地址正确，无动态上下文 | 纯 C++ 层，不碰 QEMU；但无法恢复正确的控制流 |
| D. 修正评估口径（排除 AVX-512） | 低 | 评估数字变好 | 不适用 | 不解决问题，但立即反映真实能力 |

**推荐路径：B（tombstone marker）作为中期目标，长期视需求决定是否做 A。**

---

## 方案 B：EVEX Tombstone Marker

### 思路

在 `case 0x200...0x2ff` 里，对每条被跳过的 EVEX 指令，发射一个 `TCG_PLACEHOLDER`
op（或直接复用现有的 `gen_jmp_im`）来记录 PC，使 `PTCInstructionList` 里留下地址
标记。runnable-lift 的 IR 生成器见到这个 placeholder 时，写入一条空注释：

```llvm
; 0xcf050: vpxorq   (evex-skipped)
```

这样：
- 地址出现在 .ll → recall 计数为 hit
- 不影响控制流（tombstone 不改变 IR 结构）
- 不需要实现 ZMM 寄存器语义

### 所需改动

#### 1. `qemu/target-i386/translate.c`

**扩展 `ptc_evex_tail_bytes`，覆盖更多 opcode**

当前只硬编码了 7 个。需要系统性地覆盖 libcrypto 中出现的全部 EVEX opcode。
可从 FN mnemonic 列表反查编码：

| mnemonic | EVEX map | pp | opcode |
|---|---|---|---|
| `vpxorq` | 1 | 1 (66) | 0xEF |
| `vaesenc` | 2 | 1 | 0xDC |
| `vaesenclast` | 2 | 1 | 0xDD |
| `vbroadcastf64x2` | 2 | 1 | 0x1A |
| `vpternlogq` | 3 | 1 | 0x25 |
| `vpclmullqlqdq` | 3 | 1 | 0x44 |
| `vpclmullqhqdq` | 3 | 1 | 0x44 (imm=0x00) |
| `vpclmulhqlqdq` | 3 | 1 | 0x44 (imm=0x10) |
| `vpclmulhqhqdq` | 3 | 1 | 0x44 (imm=0x11) |
| `vmovdqu64` | 1 | 3 (F2) | 0x6F / 0x7F |
| `vmovdqa64` | 1 | 1 | 0x6F / 0x7F |
| `vpaddd` | 1 | 1 | 0xFE |
| `vpshufb` | 2 | 1 | 0x00 |
| `vpslldq` | 3 | 1 | 0x73 (reg=7) |
| `vpsrldq` | 3 | 1 | 0x73 (reg=3) |
| `vextracti32x4` | 3 | 1 | 0x39 |
| `vextracti64x4` | 3 | 1 | 0x3B |
| `vmovdqu8` | 1 | 3 | 0x6F / 0x7F |

注意：有些 opcode 有 imm8，`ptc_evex_tail_bytes` 需要返回 `length + 1`。
可以通过查阅 Intel SDM Vol.2 或 binutils/opcodes 确认是否带 imm8。

**发射 tombstone TCG op**

在 `case 0x200...0x2ff` 的 break 之前，加入地址标记：

```c
case 0x200 ... 0x2ff: {
    int tail_bytes = ptc_evex_tail_bytes(...);
    if (tail_bytes < 0) { goto illegal_op; }
    // 记录指令起始 PC（pc_start 在外层 disas_insn 中已被设置）
    gen_jmp_im(pc_start - s->cs_base);  // 复用已有的 PC-marker 机制
    s->pc += tail_bytes;
    break;
}
```

需要确认 `gen_jmp_im` 在此处是否会产生副作用（修改寄存器）。更安全的做法是
调用 `tcg_gen_movi_tl(cpu_regs[R_PC], pc_start)` 或专门的 NOP helper，仅触发
address-marker 的副作用，不改变执行流。

#### 2. `runnable/tools/runnable-lift/JumpTargetManager.cpp`

`ptc_translate` 在 EVEX 指令处产生的 `PTCInstructionList` 可能只有 PC store，
没有 `newpc` call。需要确认 `registerInstruction` / `OriginalInstructionAddresses`
是否能正确记录这些地址，或者在 IR 生成阶段补一个 comment-only 节点。

#### 3. 构建

必须在 `rr_bionic_exportfs:2026-04-14` 容器内重新编译 libtinycode：

```bash
# 容器内（已有构建脚本，但注意 libtinycode 不在 runnable-lift 的 cmake 里）
# 需要找到 libtinycode 的构建入口
grep -r "libtinycode" /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting/support/
```

libtinycode 的构建方式需要单独调查（见"待确认事项"）。

---

## 方案 A：升级 QEMU（参考）

### 主要工作量

| 子任务 | 估计 |
|---|---|
| 选定目标版本（推荐 QEMU 6.2 LTS，TCG AVX-512 基本完整） | 0.5 天 |
| 将 `linux-user/ptc.c`（1817 行）移植到新 QEMU API | 3–5 天 |
| 将 `linux-user/ptc.h` 中的 `PTCInterface` 结构对齐新 API | 1–2 天 |
| 将 `target-i386/translate.c` 中的定制改动移植 | 2–3 天 |
| 重新构建 QEMU + 验证 `libtinycode-x86_64.so` 能加载 | 1 天 |
| 重新构建 runnable-lift（可能需要适配 PTC 接口变化） | 1–2 天 |
| 回归验证（serial lift libcrypto，精度/召回率对比） | 1 天 |

**合计约 10–14 工作日。**

### 风险点

1. **QEMU internal API 大幅变更**：QEMU 3.x 后 TCGContext 引入线程局部变量，
   ptc.c 里直接访问的全局变量需要全面替换。
2. **libtinycode 构建系统**：当前构建方式不透明（见下方待确认事项），
   新版本需要重写 CMakeLists 或 Makefile。
3. **AVX-512 寄存器状态**：即使 TCG 能正确翻译 EVEX，ZMM 寄存器的
   XSAVE 状态管理在 user-mode QEMU 里可能需要额外处理。

---

## 方案 D：修正评估口径（立即可做）

在 `run_cmp_eval.py` / `_compare_runnable_text_lib.py` 里，
加入 `--exclude-avx512` 选项，从 GT 中排除函数名含 `avx512` 的地址范围。

```python
# _compare_runnable_text_lib.py parse_objdump 之后加过滤
if args.exclude_avx512:
    avx512_ranges = build_avx512_ranges(binary_path)
    obj_instructions = {a: i for a,i in obj_instructions.items()
                        if a not in avx512_ranges}
```

效果：recall 报告从 0.78 → 0.93，更真实地反映 QEMU-capable 范围内的覆盖率。
**此项不解决问题，但让评估数字有意义，避免误导后续优化决策。**

---

## 待确认事项

在开始实施 B 方案之前，需要确认以下几点：

1. **libtinycode 如何构建**：当前 `libtinycode-x86_64.so` 是预编译后放入
   容器的（`/root/Runnable-Rewriting/root/lib/`），还是有对应的构建脚本？
   ```bash
   find /home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting \
     -name "*.sh" | xargs grep -l "libtinycode" 2>/dev/null
   ```

2. **EVEX opcode 带 imm8 的完整列表**：`vpternlogq`、`vpclmul*`、`vextracti*`
   均带 imm8，需要在 `ptc_evex_tail_bytes` 里返回 `length + 1`。
   其他 opcode 需逐一核对 Intel SDM。

3. **`gen_jmp_im` 副作用**：确认在 `case 0x200` 里调用 `gen_jmp_im` 是否会
   触发不期望的分支/控制流变更。可能需要一个专用的 `gen_pc_marker` helper。

4. **ZMM 寄存器状态在后续指令的影响**：跳过 EVEX 后 ZMM 不更新，
   下一条非 EVEX 指令若读 ZMM/YMM 的低位（XMM），可能产生错误结果。
   tombstone 方案只改善地址覆盖，不解决语义正确性。

---

## 建议执行顺序

```
立即（1天）：方案 D — 修正评估口径，得到真实 baseline
↓
短期（3–5天）：方案 B — 扩展 ptc_evex_tail_bytes + tombstone marker
  先确认 libtinycode 构建方式
  再扩展 opcode 覆盖
  最后加 gen_pc_marker
  构建验证：recall 应从 0.78 → ~0.93+
↓
长期（视需求）：方案 A — 升级 QEMU，获得完整 AVX-512 语义
```
