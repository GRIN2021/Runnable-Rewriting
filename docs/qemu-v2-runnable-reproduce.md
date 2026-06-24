# QEMU V2 Runnable Reproduction Guide

本文档用于让另一位合作者在自己的机器上复现当前 QEMU v2 迁移分支里的新版
`runnable-lift` 构建和最小运行验证。

当前验证分支：

```bash
git clone git@github.com:GRIN2021/Runnable-Rewriting.git
cd Runnable-Rewriting
git checkout codex/qemu-upgrade-v2
```

## 目标

最小复现成功需要做到：

1. 能构建 QEMU v2 runtime Docker 镜像。
2. 能构建当前分支的 `runnable-lift`。
3. 能在同一个 runtime 环境里运行 `runnable-lift --help`。
4. 能 lift 一个 tiny static ELF，并生成非空 `.ll`。

完整 libcrypto canonical evaluation 还需要额外的 `GroudTruth` 资产和 bionic
runtime 镜像，不属于最小复现路径。

## 机器前置条件

合作者机器需要：

- Linux x86_64。
- Docker 可用，并且当前用户能运行 `docker run`。
- 仓库 checkout 位于本机可写目录。
- 仓库内有 classic Runnable/LLVM 依赖目录 `root/`。

确认 Docker：

```bash
docker version
```

确认 `root/` 依赖：

```bash
test -x root/bin/llvm-config
test -f root/lib/cmake/llvm/LLVMConfig.cmake || \
test -f root/share/llvm/cmake/LLVMConfig.cmake
```

`root/` 是本地构建/预置依赖目录，不在 Git 里。如果新机器没有 `root/`，使用
下面任意一种方式准备：

- 复用实验环境里已经验证过的 `root/` 预置包，放到仓库根目录。
- 在 Ubuntu 18.04/bionic 环境按旧流程构建依赖：

```bash
sudo support/install-dependencies.sh
make install-runnable
```

新版脚本会自动识别 `root/lib/cmake/llvm` 和 `root/share/llvm/cmake`。如果 LLVM
CMake 目录在别处，可以显式指定：

```bash
runnable/scripts/build_runnable_lift_v2.sh \
  --llvm-dir /path/to/dir-containing-LLVMConfig.cmake \
  --verify
```

## 构建 QEMU V2 Runtime 镜像

从仓库根目录运行：

```bash
docker build -t rr_qemu_v2_runtime:latest docker/qemu-v2-runtime
```

或者直接用 wrapper，让它自动构建镜像并运行短 smoke：

```bash
docker/qemu-v2-runtime/run-smoke.sh --download-qemu
```

这个 smoke 会下载/准备 QEMU 10.2.3，并检查 AVX-512 probe 和当前 PTC shim
loadability 路径。它不要求跑完整 libcrypto。

## 构建新版 Runnable-Lift

推荐入口：

```bash
runnable/scripts/build_runnable_lift_v2.sh --verify
```

这个脚本在 host 模式下会：

1. 构建或复用 `rr_qemu_v2_runtime:latest`。
2. 把仓库挂载到 `/workspace/Runnable-Rewriting`。
3. 在容器内配置 CMake。
4. 构建 build-tree 里的 `runnable-lift`。
5. 运行 `ldd` 和 `--help` smoke。

成功后会输出类似：

```text
BUILD_OK=1
RUNNABLE_LIFT=/workspace/Runnable-Rewriting/build-codex-dynamic-current/tools/runnable-lift/runnable-lift
LD_LIBRARY_PATH=/workspace/Runnable-Rewriting/build-codex-dynamic-current/lib/StackAnalysis:...
```

host 上对应的二进制位置是：

```bash
build-codex-dynamic-current/tools/runnable-lift/runnable-lift
```

如果已经在 `rr_qemu_v2_runtime:latest` 容器里，可以跳过 Docker handoff：

```bash
bash runnable/scripts/build_runnable_lift_v2.sh --no-docker --verify
```

## Tiny ELF Lift Smoke

构建完成后，用同一个 runtime 镜像运行一个最小 lift：

```bash
docker/qemu-v2-runtime/run-validation.sh --download-qemu -- bash -lc '
set -euo pipefail

cat >/tmp/rr-v2-smoke.S <<\EOF
.global _start
.text
_start:
  mov $60, %rax
  xor %rdi, %rdi
  syscall
EOF

gcc -nostdlib -static -Wl,-e,_start /tmp/rr-v2-smoke.S -o /tmp/rr-v2-smoke

export LD_LIBRARY_PATH="$PWD/build-codex-dynamic-current/lib/StackAnalysis:$PWD/build-codex-dynamic-current/lib/BasicAnalyses:$PWD/build-codex-dynamic-current/lib/Support:$PWD/root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

./build-codex-dynamic-current/tools/runnable-lift/runnable-lift \
  /tmp/rr-v2-smoke \
  /tmp/rr-v2-smoke.ll \
  -no-link \
  >/tmp/rr-v2-smoke.stdout \
  2>/tmp/rr-v2-smoke.stderr

test -s /tmp/rr-v2-smoke.ll
grep -q "Rewrite Successful" /tmp/rr-v2-smoke.stdout
echo "TINY_ELF_LIFT_SMOKE=pass"
'
```

看到下面输出即表示新版 `runnable-lift` 在合作者机器上可以运行：

```text
TINY_ELF_LIFT_SMOKE=pass
```

## 可选：运行 QEMU V2 Validation Shell

需要手动调试时，可以进入同一个容器环境：

```bash
docker/qemu-v2-runtime/run-validation.sh --download-qemu -- bash
```

容器内仓库路径固定为：

```bash
/workspace/Runnable-Rewriting
```

手动运行 build-tree binary 前需要设置：

```bash
export LD_LIBRARY_PATH="$PWD/build-codex-dynamic-current/lib/StackAnalysis:$PWD/build-codex-dynamic-current/lib/BasicAnalyses:$PWD/build-codex-dynamic-current/lib/Support:$PWD/root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

## 可选：Libcrypto Canonical Subset

只有在合作者机器同时具备以下资产时再跑：

- sibling checkout 或挂载目录 `GroudTruth/`，包含 canonical `libcrypto.so.3`、
  `libcrypto.gtBlock.pb` 和 `protobuf_def/blocks_pb2.py`。
- bionic runtime 镜像 `rr_bionic_exportfs:2026-04-14`，用于兼容旧 libcrypto
  pipeline。
- 已生成的 QEMU v2 `libtinycode-x86_64.so`、`libtinycode-helpers-x86_64.ll` 和
  `early-linked-x86_64.ll`。

建议先只跑 subset：

```bash
runnable/scripts/qemu_v2_ptc_libcrypto_canonical_subset.sh \
  --scratch-root /tmp/rr-qemu-v2-libcrypto-canonical-subset \
  --runnable-lift build-codex-dynamic-current/tools/runnable-lift/runnable-lift \
  --libtinycode build-codex-dynamic-current/tools/runnable-lift/libtinycode-x86_64.so \
  --helpers build-codex-dynamic-current/tools/runnable-lift/libtinycode-helpers-x86_64.ll \
  --early-linked build-codex-dynamic-current/tools/runnable-lift/early-linked-x86_64.ll
```

结果摘要会写到：

```text
/tmp/rr-qemu-v2-libcrypto-canonical-subset/sha1/qemu_v2_ptc_libcrypto_canonical_subset.summary.json
```

## 常见问题

### 找不到 LLVMConfig.cmake

错误类似：

```text
LLVM CMake directory not found
```

先检查：

```bash
find root -path '*LLVMConfig.cmake' -print
```

如果文件在非默认位置，重新运行：

```bash
runnable/scripts/build_runnable_lift_v2.sh \
  --llvm-dir /exact/path/to/cmake/dir \
  --verify
```

### runnable-lift 启动时报 libstdc++ 或 glibc 版本错误

不要直接拿 host 上其他 build dir 里的二进制放进 runtime。重新用：

```bash
runnable/scripts/build_runnable_lift_v2.sh --verify
```

然后使用：

```bash
build-codex-dynamic-current/tools/runnable-lift/runnable-lift
```

### tiny smoke 里找不到分析库

确认 `LD_LIBRARY_PATH` 包含：

```text
build-codex-dynamic-current/lib/StackAnalysis
build-codex-dynamic-current/lib/BasicAnalyses
build-codex-dynamic-current/lib/Support
root/lib
```

### libcrypto subset 找不到 ground truth

设置或挂载 canonical assets：

```bash
export RUNNABLE_LIBCRYPTO_BENCH_ROOT=/path/to/libcrypto-artifacts
export RUNNABLE_LIBCRYPTO_GROUND_TRUTH=/path/to/libcrypto.so.3
export RUNNABLE_LIBCRYPTO_GROUND_TRUTH_PB=/path/to/libcrypto.gtBlock.pb
```

并确认：

```bash
python3 runnable/scripts/libcrypto_bench_paths.py binary --must-exist
python3 runnable/scripts/libcrypto_bench_paths.py groundtruth-pb --must-exist
python3 runnable/scripts/libcrypto_bench_paths.py blocks-pb2 --must-exist
```
