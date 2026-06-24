#!/usr/bin/env bash
#
# Throwaway QEMU 10.2.3 EVEX vpclmulhqlqdq smoke patch experiment.
#
# All QEMU source/build/probe outputs stay under /tmp.  The patch is an
# exact-byte experiment for the aggregate AVX-512 boundary through:
#   62 73 55 48 44 c4 01          vpclmulhqlqdq zmm8,zmm5,zmm4
#
# Previous aggregate EVEX bytes are carried forward as exact-byte smoke
# semantics so this script can verify the next aggregate boundary.
set -euo pipefail

QEMU_VERSION="10.2.3"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
QEMU_URL="https://download.qemu.org/${QEMU_TARBALL}"
QEMU_SHA256="2aa0e420e4ea89ea34a833f4c4eced96a35b51a9ee8568b232692729b60b064d"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGGREGATE_SRC="$REPO_ROOT/test/qemu-v2-probes/avx512-evex.S"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_EVEX_VPCLMUL_HQLQ_SMOKE_ROOT:-/tmp/rr-qemu-v2-evex-vpclmul-hqlq-smoke}"
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
FRESH=0
SKIP_DOWNLOAD=0
SKIP_AGGREGATE=0
QEMU_TARBALL_PATH=""

DOWNLOAD_DIR=""
BASE_SRC=""
PATCHED_SRC=""
BUILD_DIR=""
INSTALL_DIR=""
PATCH_FILE=""
OUT_DIR=""
PROBE_DIR=""
VENV_DIR=""
AGGREGATE_DIR=""
AGGREGATE_BIN=""

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_evex_vpclmul_hqlq_smoke_patch.sh [options]

Options:
  --scratch-root DIR     Scratch root under /tmp.
                         Default: /tmp/rr-qemu-v2-evex-vpclmul-hqlq-smoke
  --qemu-tarball FILE    Reuse an existing qemu-10.2.3.tar.xz.
  --jobs N, -j N         Parallel ninja jobs. Default: 3
  --fresh                Remove the scratch root before starting.
  --skip-download        Reuse an existing tarball/source tree; do not curl.
  --skip-aggregate       Do not run the aggregate boundary check.
  -h, --help             Show this help.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

refresh_paths() {
  DOWNLOAD_DIR="$SCRATCH_ROOT/download"
  BASE_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}"
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vpclmul-hqlq-smoke-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-evex-vpclmul-hqlq-smoke"
  INSTALL_DIR="$SCRATCH_ROOT/install-${QEMU_VERSION}-evex-vpclmul-hqlq-smoke"
  PATCH_FILE="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-evex-vpclmul-hqlq-smoke.patch"
  OUT_DIR="$SCRATCH_ROOT/out"
  PROBE_DIR="$SCRATCH_ROOT/probes"
  VENV_DIR="$SCRATCH_ROOT/venv"
  AGGREGATE_DIR="$SCRATCH_ROOT/aggregate"
  AGGREGATE_BIN="$AGGREGATE_DIR/avx512-evex"
}

write_patch_file() {
  mkdir -p "$SCRATCH_ROOT"
  cat >"$PATCH_FILE" <<'PATCH'
diff --git a/target/i386/tcg/decode-new.c.inc b/target/i386/tcg/decode-new.c.inc
--- a/target/i386/tcg/decode-new.c.inc
+++ b/target/i386/tcg/decode-new.c.inc
@@ -2533,6 +2533,341 @@
  * Convert one instruction. s->base.is_jmp is set if the translation must
  * be stopped.
  */
+static bool rr_evex_exact_bytes(DisasContext *s, CPUX86State *env,
+                                target_ulong pc, const uint8_t *insn,
+                                int len)
+{
+#ifdef TARGET_X86_64
+    int i;
+
+    if (!CODE64(s)) {
+        return false;
+    }
+    for (i = 0; i < len; i++) {
+        if (translator_ldub(env, &s->base, pc + i) != insn[i]) {
+            return false;
+        }
+    }
+    return true;
+#else
+    return false;
+#endif
+}
+
+static target_ulong rr_evex_rip_rel_addr(DisasContext *s, CPUX86State *env,
+                                         target_ulong pc, int insn_len)
+{
+#ifdef TARGET_X86_64
+    uint32_t disp = 0;
+    int i;
+
+    for (i = 0; i < 4; i++) {
+        disp |= (uint32_t)translator_ldub(env, &s->base,
+                                          pc + insn_len - 4 + i) << (8 * i);
+    }
+
+    return (target_ulong)((int64_t)(pc + insn_len) + (int32_t)disp);
+#else
+    return 0;
+#endif
+}
+
+static void rr_evex_store_zmm1_512(DisasContext *s, target_ulong guest_addr)
+{
+    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
+    TCGv_i128 t = tcg_temp_new_i128();
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 0);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(0)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 16);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(1)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 32);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(2)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 48);
+    tcg_gen_ld_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[1].ZMM_X(3)));
+    tcg_gen_qemu_st_i128(t, s->A0, s->mem_index, mop);
+}
+
+static void rr_evex_load_zmm2_512(DisasContext *s, target_ulong guest_addr)
+{
+    MemOp mop = MO_128 | MO_LE | MO_ATOM_IFALIGN_PAIR;
+    TCGv_i128 t = tcg_temp_new_i128();
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 0);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(0)));
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 16);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(1)));
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 32);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(2)));
+
+    tcg_gen_movi_tl(s->A0, guest_addr + 48);
+    tcg_gen_qemu_ld_i128(t, s->A0, s->mem_index, mop);
+    tcg_gen_st_i128(t, tcg_env, offsetof(CPUX86State, xmm_regs[2].ZMM_X(3)));
+}
+
+static void rr_evex_pshufb_xmm_lane(intptr_t dofs, intptr_t vofs,
+                                    intptr_t sofs)
+{
+    TCGv_ptr d = tcg_temp_new_ptr();
+    TCGv_ptr v = tcg_temp_new_ptr();
+    TCGv_ptr mask = tcg_temp_new_ptr();
+
+    tcg_gen_addi_ptr(d, tcg_env, dofs);
+    tcg_gen_addi_ptr(v, tcg_env, vofs);
+    tcg_gen_addi_ptr(mask, tcg_env, sofs);
+    gen_helper_pshufb_xmm(tcg_env, d, v, mask);
+}
+
+static void rr_evex_pclmul_xmm_lane(intptr_t dofs, intptr_t vofs,
+                                    intptr_t sofs, uint32_t ctrl)
+{
+    TCGv_ptr d = tcg_temp_new_ptr();
+    TCGv_ptr v = tcg_temp_new_ptr();
+    TCGv_ptr src = tcg_temp_new_ptr();
+
+    tcg_gen_addi_ptr(d, tcg_env, dofs);
+    tcg_gen_addi_ptr(v, tcg_env, vofs);
+    tcg_gen_addi_ptr(src, tcg_env, sofs);
+    gen_helper_pclmulqdq_xmm(tcg_env, d, v, src, tcg_constant_i32(ctrl));
+}
+
+static void rr_evex_add_zmm4_zmm3_zmm2_512(void)
+{
+    tcg_gen_gvec_add(MO_32,
+                     offsetof(CPUX86State, xmm_regs[4]),
+                     offsetof(CPUX86State, xmm_regs[3]),
+                     offsetof(CPUX86State, xmm_regs[2]),
+                     64, 64);
+}
+
+static void rr_evex_xor_zmm5_zmm5_zmm4_zmm3_512(void)
+{
+    tcg_gen_gvec_xor(MO_64,
+                     offsetof(CPUX86State, xmm_regs[5]),
+                     offsetof(CPUX86State, xmm_regs[5]),
+                     offsetof(CPUX86State, xmm_regs[4]),
+                     64, 64);
+    tcg_gen_gvec_xor(MO_64,
+                     offsetof(CPUX86State, xmm_regs[5]),
+                     offsetof(CPUX86State, xmm_regs[5]),
+                     offsetof(CPUX86State, xmm_regs[3]),
+                     64, 64);
+}
+
+static void rr_evex_pshufb_zmm3_zmm2_zmm2_512(void)
+{
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(0)));
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(1)));
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(2)));
+    rr_evex_pshufb_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[3].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[2].ZMM_X(3)));
+}
+
+static void rr_evex_pclmul_zmm6_zmm5_zmm4_lqlq_512(void)
+{
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[6].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(0)), 0x00);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[6].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(1)), 0x00);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[6].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(2)), 0x00);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[6].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x00);
+}
+
+static void rr_evex_pclmul_zmm7_zmm5_zmm4_lqhq_512(void)
+{
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(0)), 0x10);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(1)), 0x10);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(2)), 0x10);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[7].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x10);
+}
+
+static void rr_evex_pclmul_zmm8_zmm5_zmm4_hqlq_512(void)
+{
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(0)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(0)), 0x01);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(1)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(1)), 0x01);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(2)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(2)), 0x01);
+    rr_evex_pclmul_xmm_lane(
+        offsetof(CPUX86State, xmm_regs[8].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[5].ZMM_X(3)),
+        offsetof(CPUX86State, xmm_regs[4].ZMM_X(3)), 0x01);
+}
+
+static bool rr_try_evex_vpclmul_hqlq_smoke(DisasContext *s, CPUX86State *env)
+{
+#ifdef TARGET_X86_64
+    static const uint8_t vpxorq_zmm0_zmm0_zmm0[] = {
+        0x62, 0xf1, 0xfd, 0x48, 0xef, 0xc0
+    };
+    static const uint8_t vmovdqa64_zmm1_zmm0[] = {
+        0x62, 0xf1, 0xfd, 0x48, 0x6f, 0xc8
+    };
+    static const uint8_t vmovdqu64_store_single[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x7f, 0x0d, 0xf6, 0x0f, 0x00, 0x00
+    };
+    static const uint8_t vmovdqu64_load_single[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x6f, 0x15, 0xf6, 0x0f, 0x00, 0x00
+    };
+    static const uint8_t vmovdqu64_store_chain[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x7f, 0x0d, 0xea, 0x0f, 0x00, 0x00
+    };
+    static const uint8_t vmovdqu64_load_chain[] = {
+        0x62, 0xf1, 0xfe, 0x48, 0x6f, 0x15, 0xe0, 0x0f, 0x00, 0x00
+    };
+    static const uint8_t vpshufb_zmm3_zmm2_zmm2[] = {
+        0x62, 0xf2, 0x6d, 0x48, 0x00, 0xda
+    };
+    static const uint8_t vpaddd_zmm4_zmm3_zmm2[] = {
+        0x62, 0xf1, 0x65, 0x48, 0xfe, 0xe2
+    };
+    static const uint8_t vpternlogq_zmm5_zmm4_zmm3_0x96[] = {
+        0x62, 0xf3, 0xdd, 0x48, 0x25, 0xeb, 0x96
+    };
+    static const uint8_t vpclmullqlqdq_zmm6_zmm5_zmm4[] = {
+        0x62, 0xf3, 0x55, 0x48, 0x44, 0xf4, 0x00
+    };
+    static const uint8_t vpclmullqhqdq_zmm7_zmm5_zmm4[] = {
+        0x62, 0xf3, 0x55, 0x48, 0x44, 0xfc, 0x10
+    };
+    static const uint8_t vpclmulhqlqdq_zmm8_zmm5_zmm4[] = {
+        0x62, 0x73, 0x55, 0x48, 0x44, 0xc4, 0x01
+    };
+    target_ulong pc = s->pc;
+    target_ulong guest_addr;
+
+    if (rr_evex_exact_bytes(s, env, pc, vpxorq_zmm0_zmm0_zmm0,
+                            sizeof(vpxorq_zmm0_zmm0_zmm0))) {
+        tcg_gen_gvec_dup_imm(MO_64, offsetof(CPUX86State, xmm_regs[0]),
+                             64, 64, 0);
+        s->pc = pc + sizeof(vpxorq_zmm0_zmm0_zmm0);
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vmovdqa64_zmm1_zmm0,
+                            sizeof(vmovdqa64_zmm1_zmm0))) {
+        tcg_gen_gvec_mov(MO_64, offsetof(CPUX86State, xmm_regs[1]),
+                         offsetof(CPUX86State, xmm_regs[0]), 64, 64);
+        s->pc = pc + sizeof(vmovdqa64_zmm1_zmm0);
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vmovdqu64_store_single,
+                            sizeof(vmovdqu64_store_single)) ||
+        rr_evex_exact_bytes(s, env, pc, vmovdqu64_store_chain,
+                            sizeof(vmovdqu64_store_chain))) {
+        guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
+        rr_evex_store_zmm1_512(s, guest_addr);
+        s->pc = pc + 10;
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vmovdqu64_load_single,
+                            sizeof(vmovdqu64_load_single)) ||
+        rr_evex_exact_bytes(s, env, pc, vmovdqu64_load_chain,
+                            sizeof(vmovdqu64_load_chain))) {
+        guest_addr = rr_evex_rip_rel_addr(s, env, pc, 10);
+        rr_evex_load_zmm2_512(s, guest_addr);
+        s->pc = pc + 10;
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vpshufb_zmm3_zmm2_zmm2,
+                            sizeof(vpshufb_zmm3_zmm2_zmm2))) {
+        rr_evex_pshufb_zmm3_zmm2_zmm2_512();
+        s->pc = pc + sizeof(vpshufb_zmm3_zmm2_zmm2);
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vpaddd_zmm4_zmm3_zmm2,
+                            sizeof(vpaddd_zmm4_zmm3_zmm2))) {
+        rr_evex_add_zmm4_zmm3_zmm2_512();
+        s->pc = pc + sizeof(vpaddd_zmm4_zmm3_zmm2);
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vpternlogq_zmm5_zmm4_zmm3_0x96,
+                            sizeof(vpternlogq_zmm5_zmm4_zmm3_0x96))) {
+        rr_evex_xor_zmm5_zmm5_zmm4_zmm3_512();
+        s->pc = pc + sizeof(vpternlogq_zmm5_zmm4_zmm3_0x96);
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vpclmullqlqdq_zmm6_zmm5_zmm4,
+                            sizeof(vpclmullqlqdq_zmm6_zmm5_zmm4))) {
+        rr_evex_pclmul_zmm6_zmm5_zmm4_lqlq_512();
+        s->pc = pc + sizeof(vpclmullqlqdq_zmm6_zmm5_zmm4);
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vpclmullqhqdq_zmm7_zmm5_zmm4,
+                            sizeof(vpclmullqhqdq_zmm7_zmm5_zmm4))) {
+        rr_evex_pclmul_zmm7_zmm5_zmm4_lqhq_512();
+        s->pc = pc + sizeof(vpclmullqhqdq_zmm7_zmm5_zmm4);
+        return true;
+    }
+
+    if (rr_evex_exact_bytes(s, env, pc, vpclmulhqlqdq_zmm8_zmm5_zmm4,
+                            sizeof(vpclmulhqlqdq_zmm8_zmm5_zmm4))) {
+        rr_evex_pclmul_zmm8_zmm5_zmm4_hqlq_512();
+        s->pc = pc + sizeof(vpclmulhqlqdq_zmm8_zmm5_zmm4);
+        return true;
+    }
+#endif
+    return false;
+}
+
 static void disas_insn(DisasContext *s, CPUState *cpu)
 {
     CPUX86State *env = cpu_env(cpu);
@@ -2556,6 +2891,10 @@
     s->has_modrm = false;
     s->prefix = 0;

+    if (rr_try_evex_vpclmul_hqlq_smoke(s, env)) {
+        return;
+    }
+
  next_byte:;
 #ifdef TARGET_X86_64
     /* clear any REX prefix followed by other prefixes.  */
PATCH
}

ensure_build_tools() {
  require_tool python3
  if command -v meson >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1; then
    log "Using Meson/Ninja from PATH"
    return
  fi

  if [[ ! -x "$VENV_DIR/bin/meson" || ! -x "$VENV_DIR/bin/ninja" ]]; then
    log "Preparing Meson/Ninja venv under $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip meson ninja
  fi
  export PATH="$VENV_DIR/bin:$PATH"
}

download_or_extract_qemu() {
  mkdir -p "$DOWNLOAD_DIR"
  if [[ -d "$BASE_SRC" ]]; then
    log "Using existing source tree $BASE_SRC"
    return
  fi

  local tarball="$DOWNLOAD_DIR/$QEMU_TARBALL"
  if [[ -n "$QEMU_TARBALL_PATH" ]]; then
    [[ -f "$QEMU_TARBALL_PATH" ]] || die "missing --qemu-tarball file: $QEMU_TARBALL_PATH"
    log "Copying $QEMU_TARBALL_PATH"
    cp "$QEMU_TARBALL_PATH" "$tarball"
  elif [[ ! -f "$tarball" ]]; then
    [[ "$SKIP_DOWNLOAD" -eq 0 ]] || die "missing tarball $tarball and --skip-download was requested"
    require_tool curl
    log "Downloading $QEMU_TARBALL"
    curl -L --fail --retry 3 -o "$tarball" "$QEMU_URL"
  fi

  require_tool sha256sum
  (cd "$DOWNLOAD_DIR" && printf '%s  %s\n' "$QEMU_SHA256" "$QEMU_TARBALL" | sha256sum -c -)

  log "Extracting $QEMU_TARBALL"
  tar -C "$SCRATCH_ROOT" -xf "$tarball"
  [[ -x "$BASE_SRC/configure" ]] || die "expected configure script at $BASE_SRC/configure"
}

prepare_patched_tree() {
  if [[ -d "$PATCHED_SRC" ]]; then
    if [[ -f "$PATCHED_SRC/.rr-evex-vpclmul-hqlq-smoke-patched" ]]; then
      log "Using existing patched source tree $PATCHED_SRC"
      return
    fi
    die "patched tree exists without stamp: $PATCHED_SRC"
  fi

  log "Copying throwaway source tree"
  cp -a "$BASE_SRC" "$PATCHED_SRC"

  require_tool patch
  log "Applying EVEX vpclmul hqlq smoke patch"
  (cd "$PATCHED_SRC" && patch -p1 <"$PATCH_FILE")
  touch "$PATCHED_SRC/.rr-evex-vpclmul-hqlq-smoke-patched"
}

configure_qemu() {
  if [[ -f "$BUILD_DIR/build.ninja" && -x "$BUILD_DIR/qemu-x86_64" ]]; then
    log "Reusing existing build directory $BUILD_DIR"
    return
  fi

  mkdir -p "$BUILD_DIR" "$INSTALL_DIR"
  log "Configuring QEMU $QEMU_VERSION"
  (
    cd "$BUILD_DIR"
    "$PATCHED_SRC/configure" \
      --target-list=x86_64-linux-user \
      --disable-system \
      --disable-tools \
      --disable-docs \
      --disable-gtk \
      --disable-sdl \
      --disable-vnc \
      --disable-curses \
      --disable-slirp \
      --disable-capstone \
      --disable-werror \
      --prefix="$INSTALL_DIR"
  )
}

build_qemu() {
  log "Building qemu-x86_64"
  ninja -C "$BUILD_DIR" -j "$JOBS" qemu-x86_64
  [[ -x "$BUILD_DIR/qemu-x86_64" ]] || die "missing built binary: $BUILD_DIR/qemu-x86_64"
}

write_probe_sources() {
  mkdir -p "$PROBE_DIR" "$OUT_DIR"

  cat >"$PROBE_DIR/vpclmul-hqlq-single.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    vpclmulhqlqdq zmm8, zmm5, zmm4
    mov eax, 60
    xor edi, edi
    syscall
EOF

  cat >"$PROBE_DIR/vpclmul-hqlq-chain.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
EOF

  cat >"$PROBE_DIR/vpclmul-hqlq-semantic.S" <<'EOF'
.intel_syntax noprefix
.section .text
.global _start
.type _start, @function
_start:
    movdqu xmm5, xmmword ptr [rip + src_a]
    movdqu xmm4, xmmword ptr [rip + src_b]
    .byte 0x62, 0x73, 0x55, 0x48, 0x44, 0xc4, 0x01
    movdqu xmmword ptr [rip + out], xmm8

    mov rax, qword ptr [rip + out]
    xor rax, qword ptr [rip + expected]
    mov rdx, qword ptr [rip + out + 8]
    xor rdx, qword ptr [rip + expected + 8]
    or rax, rdx
    setne dil
    movzx edi, dil
    mov eax, 60
    syscall

.section .data
.align 16
src_a:
    .quad 0x123456789abcdef0, 0xfeedfacecafebeef
src_b:
    .quad 0x0fedcba987654321, 0x0123456789abcdef
expected:
    .quad 0x708b0f331722920f, 0x05544a6551cee46a
out:
    .zero 16
EOF
}

build_probe() {
  local name="$1"
  local src="$PROBE_DIR/$name.S"
  local bin="$PROBE_DIR/$name"
  local objdump_file="$OUT_DIR/$name.objdump.txt"

  require_tool gcc
  require_tool objdump

  log "Building probe $name"
  gcc -nostdlib -no-pie -Wl,--build-id=none -o "$bin" "$src"
  objdump -d -Mintel "$bin" >"$objdump_file"

  grep -F "62 73 55 48 44 c4 01" "$objdump_file" >/dev/null \
    || die "$name objdump is missing exact vpclmulhqlqdq bytes"
  grep -F "vpclmulhqlqdq zmm8,zmm5,zmm4" "$objdump_file" >/dev/null \
    || die "$name objdump is missing expected vpclmulhqlqdq mnemonic"

  if [[ "$name" == "vpclmul-hqlq-chain" ]]; then
    grep -F "62 f3 55 48 44 f4 00" "$objdump_file" >/dev/null \
      || die "$name objdump is missing prior vpclmullqlqdq bytes"
    grep -F "62 f3 55 48 44 fc 10" "$objdump_file" >/dev/null \
      || die "$name objdump is missing prior vpclmullqhqdq bytes"
  fi
}

run_one_probe() {
  local name="$1"
  local bin="$PROBE_DIR/$name"
  local stdout_file="$OUT_DIR/$name.qemu.stdout"
  local stderr_file="$OUT_DIR/$name.qemu.stderr"
  local qemu_log="$OUT_DIR/$name.qemu.log"
  local run_rc=0
  local exception_hits=0
  local vpclmul_hqlq_hits=0
  local pclmul_helper_hits=0
  local result="FAIL"

  log "Running probe $name under patched qemu-x86_64"
  set +e
  QEMU_LOG_FILENAME="$qemu_log" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    "$bin" \
    >"$stdout_file" 2>"$stderr_file"
  run_rc=$?
  set -e

  if [[ -f "$qemu_log" ]]; then
    exception_hits="$({ grep -Ehi 'raise_exception|Illegal instruction|EXCP06|check_exception' "$qemu_log" "$stderr_file" || true; } | wc -l)"
    vpclmul_hqlq_hits="$({ grep -Ehi 'vpclmulhqlqdq zmm8,zmm5,zmm4' "$qemu_log" || true; } | wc -l)"
    pclmul_helper_hits="$({ grep -Ehi 'pclmulqdq_xmm' "$qemu_log" || true; } | wc -l)"
  fi

  if [[ "$run_rc" -eq 0 && "$exception_hits" -eq 0 && "$pclmul_helper_hits" -ge 4 ]]; then
    result="PASS"
  fi

  cat <<EOF
probe:                 $name
result:                $result
run_rc:                $run_rc
exception_hits:        $exception_hits
vpclmul_hqlq_hits:     $vpclmul_hqlq_hits
pclmul_helper_hits:    $pclmul_helper_hits
probe_bin:             $bin
qemu_log:              $qemu_log
EOF

  if [[ "$result" != "PASS" ]]; then
    echo "---- $name stderr ----"
    sed -n '1,120p' "$stderr_file" || true
    echo "---- $name qemu log head ----"
    sed -n '1,220p' "$qemu_log" || true
    return 1
  fi

  echo "---- $name qemu EVEX/helper ops ----"
  grep -En 'vpclmul|pclmul|raise_exception|check_exception|rip,\$0x[0-9a-f]+' "$qemu_log" | head -120 || true
  return 0
}

build_aggregate_probe() {
  require_tool gcc
  require_tool objdump

  [[ -f "$AGGREGATE_SRC" ]] || die "missing aggregate probe source: $AGGREGATE_SRC"
  mkdir -p "$AGGREGATE_DIR"

  log "Building aggregate probe"
  gcc -nostdlib -no-pie -Wl,--build-id=none -o "$AGGREGATE_BIN" "$AGGREGATE_SRC"
  objdump -d -Mintel "$AGGREGATE_BIN" >"$OUT_DIR/aggregate.objdump.txt"

  grep -F "62 f3 55 48 44 fc 10" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vpclmullqhqdq bytes"
  grep -F "62 73 55 48 44 c4 01" "$OUT_DIR/aggregate.objdump.txt" >/dev/null \
    || die "aggregate objdump is missing expected vpclmulhqlqdq bytes"
}

run_aggregate_probe() {
  local stdout_file="$OUT_DIR/aggregate.qemu.stdout"
  local stderr_file="$OUT_DIR/aggregate.qemu.stderr"
  local qemu_log="$OUT_DIR/aggregate.qemu.log"
  local run_rc=0
  local exception_hits=0
  local vpclmul_hqlq_hits=0
  local pclmul_helper_hits=0
  local failure_pc_hex=""
  local result="FAIL_BEFORE_OR_AT_VPCLMUL_HQLQ"
  local next_line

  build_aggregate_probe
  next_line="unknown"

  log "Running aggregate probe under patched qemu-x86_64"
  set +e
  QEMU_LOG_FILENAME="$qemu_log" \
    "$BUILD_DIR/qemu-x86_64" \
    -d in_asm,op,int \
    "$AGGREGATE_BIN" \
    >"$stdout_file" 2>"$stderr_file"
  run_rc=$?
  set -e

  if [[ -f "$qemu_log" ]]; then
    exception_hits="$({ grep -Ehi 'raise_exception|Illegal instruction|EXCP06|check_exception' "$qemu_log" "$stderr_file" || true; } | wc -l)"
    vpclmul_hqlq_hits="$({ grep -Ehi 'vpclmulhqlqdq zmm8,zmm5,zmm4' "$qemu_log" || true; } | wc -l)"
    pclmul_helper_hits="$({ grep -Ehi 'pclmulqdq_xmm' "$qemu_log" || true; } | wc -l)"
    failure_pc_hex="$(
      grep -Eoi 'rip,\$0x[0-9a-f]+' "$qemu_log" \
        | tail -1 \
        | sed 's/.*\$0x//' \
        | tr '[:upper:]' '[:lower:]' \
        || true
    )"
    if [[ -n "$failure_pc_hex" ]]; then
      next_line="$(
        grep -E -i -m1 "^ *${failure_pc_hex}:" "$OUT_DIR/aggregate.objdump.txt" \
          | sed 's/[[:space:]][[:space:]]*/ /g' \
          || true
      )"
    fi
  fi

  if [[ "$run_rc" -eq 0 ]]; then
    result="PASS_ALL"
  elif [[ "$failure_pc_hex" =~ ^[0-9a-f]+$ ]] &&
       (( 16#$failure_pc_hex > 16#401041 )) &&
       [[ "$pclmul_helper_hits" -ge 4 ]]; then
    result="EXPECTED_FAIL_AFTER_VPCLMUL_HQLQ"
  fi

  cat <<EOF
aggregate_result:             $result
aggregate_run_rc:             $run_rc
aggregate_exception_hits:     $exception_hits
aggregate_vpclmul_hqlq_hits:  $vpclmul_hqlq_hits
aggregate_pclmul_helper_hits: $pclmul_helper_hits
aggregate_fail_pc:            ${failure_pc_hex:-unknown}
aggregate_next:               ${next_line:-unknown}
aggregate_bin:                $AGGREGATE_BIN
aggregate_qemu_log:           $qemu_log
EOF

  echo "---- aggregate boundary ops ----"
  grep -En 'vpclmul|pclmul|raise_exception|check_exception|rip,\$0x[0-9a-f]+' "$qemu_log" | head -160 || true

  case "$result" in
    PASS_ALL|EXPECTED_FAIL_AFTER_VPCLMUL_HQLQ)
      return 0
      ;;
    *)
      echo "---- aggregate stderr ----"
      sed -n '1,120p' "$stderr_file" || true
      echo "---- aggregate qemu log head ----"
      sed -n '1,260p' "$qemu_log" || true
      return 1
      ;;
  esac
}

run_probes() {
  local failures=0
  local name

  write_probe_sources

  for name in vpclmul-hqlq-single vpclmul-hqlq-chain vpclmul-hqlq-semantic; do
    build_probe "$name"
    if ! run_one_probe "$name"; then
      failures=$((failures + 1))
    fi
  done

  if [[ "$SKIP_AGGREGATE" -eq 0 ]]; then
    if ! run_aggregate_probe; then
      failures=$((failures + 1))
    fi
  else
    echo "aggregate_result: SKIPPED"
  fi

  cat <<EOF
scratch_root: $SCRATCH_ROOT
patch_file:   $PATCH_FILE
source_touch: target/i386/tcg/decode-new.c.inc
build_bin:    $BUILD_DIR/qemu-x86_64
probe_dir:    $PROBE_DIR
failures:     $failures
EOF

  [[ "$failures" -eq 0 ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-root)
      SCRATCH_ROOT="${2:?missing value for --scratch-root}"
      shift 2
      ;;
    --qemu-tarball)
      QEMU_TARBALL_PATH="${2:?missing value for --qemu-tarball}"
      shift 2
      ;;
    --jobs|-j)
      JOBS="${2:?missing value for --jobs}"
      shift 2
      ;;
    --fresh)
      FRESH=1
      shift
      ;;
    --skip-download)
      SKIP_DOWNLOAD=1
      shift
      ;;
    --skip-aggregate)
      SKIP_AGGREGATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
  die "--jobs must be a positive integer: $JOBS"
fi

case "$SCRATCH_ROOT" in
  /tmp/*) ;;
  *) die "--scratch-root must be under /tmp: $SCRATCH_ROOT" ;;
esac

refresh_paths

if [[ "$FRESH" -eq 1 ]]; then
  log "Removing scratch root $SCRATCH_ROOT"
  rm -rf "$SCRATCH_ROOT"
fi

mkdir -p "$SCRATCH_ROOT"
write_patch_file
ensure_build_tools
download_or_extract_qemu
prepare_patched_tree
configure_qemu
build_qemu
run_probes
