# LLM FP Filter v1 — 设计文档

## 目标

用 DeepSeek LLM 对 serial lift 输出中的假正例（FP）做 post-process 分类，识别
`.text` 内 inline data（主要是 jump table）并从评估指令集中剔除，从而提升 precision。

不修改 `.ll` 本体，仅在评估阶段过滤，使改动范围最小、可快速验证。

---

## 设计原则

- **Post-process only**：lift 阶段不介入，避免错误剪枝带来的级联 recall 损失
- **不使用 GT 做候选筛选**：候选识别基于二进制启发式，GT 仅用于事后度量
- **结果可复现**：所有 LLM 调用结果写入 JSON，支持 replay 不重复调用 API

---

## 新增文件

```
runnable/scripts/llm_data_classifier.py   # 主脚本，产出 data-filter.json
```

评估集成方式：在 `run_cmp_eval.py` 增加 `--data-filter` 参数，加载 JSON 后
从 `ll_instructions` 中剔除被标注为 data 的地址，再做 compare。

---

## Pipeline

```
binary (.so)  ──┐
lifted .ll    ──┤── [1] 候选提取  ──► clusters.json
                │
                └── [2] objdump 上下文提取
                         │
                         ▼
                    [3] DeepSeek 分类  ──► data-filter.json
                         │
                         ▼
                    [4] 过滤评估
                    run_cmp_eval.py --data-filter data-filter.json
                         │
                         ▼
                    filtered-cmp.json  (新 precision/recall)
```

---

## 阶段 1：候选地址提取

### 原理

FP 候选 = 出现在 `.ll` 但不在 objdump 的地址（即 `ll_only` 集合）。
这些地址复用 `_compare_runnable_text_lib` 已有逻辑直接算出，不依赖 GT 边界。

### 聚类

将 FP 地址按连续性分组：若相邻两个地址的差 ≤ `--cluster-gap`（默认 64 字节），
归入同一 cluster。每个 cluster 作为一次 LLM 调用的分析单元。

```python
def cluster_fp_addrs(fp_addrs: list[int], gap: int = 64) -> list[list[int]]:
    if not fp_addrs:
        return []
    sorted_addrs = sorted(fp_addrs)
    clusters, cur = [], [sorted_addrs[0]]
    for a in sorted_addrs[1:]:
        if a - cur[-1] <= gap:
            cur.append(a)
        else:
            clusters.append(cur)
            cur = [a]
    clusters.append(cur)
    return clusters
```

**过滤小 cluster**：单个孤立 FP 地址（cluster 大小 = 1）概率上更可能是
mnemonic mismatch 或 QEMU 探索死分支，而非 jump table。默认跳过 size < 3 的
cluster，直接标记为 `unknown`，不消耗 API 配额。

---

## 阶段 2：objdump 上下文提取

每个 cluster 取以下上下文，拼成字符串传给 LLM：

| 部分 | 内容 | 大小 |
|---|---|---|
| 前导指令 | cluster 起始地址前 `--ctx-before`（默认 32）字节的 objdump 行 | ~5-8 行 |
| 可疑区域 | cluster 覆盖的地址范围的 objdump 行（标记 `>>>`） | cluster 大小 |
| 后缀指令 | cluster 结束地址后 `--ctx-after`（默认 16）字节的 objdump 行 | ~2-4 行 |
| 指针解读 | 将可疑区域字节按 8 字节对齐读取，判断是否为合法 `.text` 地址 | cluster/8 行 |

"指针解读"由脚本计算，不依赖 LLM：

```python
def as_text_pointers(binary_bytes: bytes, offset: int,
                     text_start: int, text_end: int) -> list[str]:
    lines = []
    for i in range(0, len(binary_bytes) - 7, 8):
        val = int.from_bytes(binary_bytes[offset+i:offset+i+8], "little")
        in_text = text_start <= val < text_end
        lines.append(f"  +{i:#04x}: {val:#018x}  {'→ .text ✓' if in_text else '(out of .text)'}")
    return lines
```

若 cluster 内 ≥ 50% 的 8-byte 值落在 `.text` 范围内，在 prompt 里注明
`[pointer-pattern: LIKELY JUMP TABLE]`，给 LLM 更强的提示。

---

## 阶段 3：LLM 分类

### API 配置

```python
from openai import OpenAI

client = OpenAI(
    api_key=os.environ["DEEPSEEK_API_KEY"],
    base_url="https://api.deepseek.com",
)
MODEL = "deepseek-chat"   # v3，够用且便宜
```

### Prompt 模板

```
System:
You are a binary analysis expert specializing in x86-64 machine code.
Your task: decide whether a highlighted region in a disassembly is inline data
(e.g., a switch jump table) or actual executable code.
Reply with a JSON object only — no prose.
{"classification": "data"|"code", "confidence": 0.0-1.0, "reason": "<one sentence>"}

User:
Binary: libcrypto.so.3 (stripped, x86-64)
.text range: [0xcef80, 0x3b1ff0)

Disassembly context (objdump -d):
<前导指令，原样粘贴>

>>> [SUSPECTED REGION - {cluster_size} bytes at {hex(cluster_start)}]
<可疑区域 objdump 行，每行前缀 ">>>">
>>> [END SUSPECTED REGION]

<后缀指令>

Bytes in suspected region interpreted as 8-byte little-endian values:
<指针解读行>
{pointer_pattern_hint}

Does the suspected region contain inline data or actual code?
```

### 调用参数

```python
response = client.chat.completions.create(
    model=MODEL,
    messages=[{"role": "system", "content": SYSTEM}, {"role": "user", "content": user_msg}],
    temperature=0.0,      # 确定性输出
    max_tokens=128,
    response_format={"type": "json_object"},
)
```

### 错误处理

- JSON 解析失败 → 标记 `unknown`，confidence=0
- API 超时 → 重试最多 3 次，指数退避
- `unknown` 地址在过滤阶段保留（不剔除），保守处理

---

## 阶段 4：过滤评估集成

### data-filter.json 格式

```json
{
  "version": 1,
  "binary": "/path/to/libcrypto.so.3",
  "ll": "/path/to/libcrypto.ll",
  "text_start": "0xcef80",
  "text_end": "0x3b1ff0",
  "clusters": [
    {
      "addrs": ["0xcf1a9", "0xcf1b1", "0xcf1b9"],
      "classification": "data",
      "confidence": 0.95,
      "reason": "8-byte values all point into .text; follows indirect jmp dispatch",
      "pointer_pattern": true
    }
  ],
  "data_addrs": ["0xcf1a9", "0xcf1b1", "0xcf1b9"],
  "stats": {
    "total_fp_candidates": 51961,
    "clusters_analyzed": 312,
    "clusters_classified_data": 178,
    "addrs_classified_data": 31400,
    "addrs_unknown": 820
  }
}
```

### run_cmp_eval.py 改动

在 `main()` 里加一个 `--data-filter` 参数：

```python
ap.add_argument("--data-filter", help="JSON from llm_data_classifier.py; removes data addrs from ll set")
```

在 `normalize_ll_addresses` 之后、`compare()` 之前：

```python
if args.data_filter:
    data_filter = json.loads(Path(args.data_filter).read_text())
    exclude = {int(a, 16) for a in data_filter.get("data_addrs", [])}
    ll_instructions = {a: v for a, v in ll_instructions.items() if a not in exclude}
```

这样不改原有逻辑，新旧两次评估结果完全可对比。

---

## CLI 接口

```bash
python3 runnable/scripts/llm_data_classifier.py \
  --binary  GroudTruth/.../libcrypto.so.3 \
  --ll      /hdd/.../libcrypto.so.3.entry_0x500cef80.ll \
  --text-start 0xcef80 \
  --runnable-base 0x50000000 \
  --out     /tmp/data-filter.json \
  [--cluster-gap 64]       \   # 聚类间距阈值（字节）
  [--min-cluster-size 3]   \   # 小于此值的 cluster 跳过
  [--ctx-before 32]        \   # 前导上下文字节数
  [--ctx-after 16]         \   # 后缀上下文字节数
  [--dry-run]              \   # 只提取候选，不调 LLM
  [--replay /tmp/old.json]     # 复用已有 LLM 结果，不重复调用 API

# 过滤评估
python3 runnable/scripts/run_cmp_eval.py \
  --binary  GroudTruth/.../libcrypto.so.3 \
  --ll      /hdd/.../libcrypto.so.3.entry_0x500cef80.ll \
  --text-start 0xcef80 \
  --runnable-base 0x50000000 \
  --data-filter /tmp/data-filter.json \
  --json-out /tmp/filtered-cmp.json
```

---

## 预期度量

基准（serial lift，无过滤）：

| 指标 | 值 |
|---|---|
| Precision | 0.9107 |
| Recall | 0.7799 |
| FP (ll_only) | 51,961 |

目标（LLM 过滤后）：

- Precision ≥ 0.95（理想情况：jump table 是主因，过滤掉 ~30K FP）
- Recall 变化 < 0.5%（LLM 误判 code 为 data 带来的召回损失）
- `clusters_classified_data / clusters_analyzed` 反映 jump table 密度

---

## 依赖

```
openai>=1.0          # DeepSeek 兼容 OpenAI SDK
DEEPSEEK_API_KEY     # 环境变量
objdump              # 系统工具，已有
```

---

## 风险与限制

| 风险 | 缓解 |
|---|---|
| LLM 将 code 误判为 data → recall 下降 | `unknown` 默认保留；confidence < 0.7 的不过滤 |
| jump table 不是 FP 主因 → 过滤效果差 | `--dry-run` 先看 pointer_pattern 覆盖率再决定是否调 API |
| API 成本 | 先 `--dry-run` 统计 cluster 数；预估约 312 次调用，成本 < $0.5 |
| 大 cluster（长 jump table）token 超限 | cluster 超过 512 字节时拆分为子 cluster |
