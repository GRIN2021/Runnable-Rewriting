#!/usr/bin/env bash
#
# Throwaway QEMU 10.2.3 C-side TCGOp/TCGTemp walker probe for the Runnable
# QEMU V2 PTC port. QEMU source/build/output stay under /tmp by default; this
# script only writes an experimental patch into the scratch directory and never
# patches the repository qemu/ tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

QEMU_VERSION="10.2.3"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
QEMU_URL="https://download.qemu.org/${QEMU_TARBALL}"
QEMU_SHA256="2aa0e420e4ea89ea34a833f4c4eced96a35b51a9ee8568b232692729b60b064d"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_PTC_OP_WALK_ROOT:-/tmp/rr-qemu-v2-ptc-tcg-op-walker}"
DOWNLOAD_DIR=""
BASE_SRC=""
PATCHED_SRC=""
BUILD_DIR=""
PROBE_BUILD_DIR=""
OUT_DIR=""
VENV_DIR=""
BUILD_PYTHON=""
JOBS="${RUNNABLE_QEMU_V2_JOBS:-3}"
QEMU_CPU_MODEL="${RUNNABLE_QEMU_V2_PTC_OP_WALK_CPU:-max}"
FRESH=0
SKIP_DOWNLOAD=0
APPLY_PATCH_ONLY=0
BUILD_ONLY=0
RUN_ONLY=0
SHOW_INSTRUCTIONS=0
EXTERNAL_BINARY=""
EXTERNAL_ENTRY_PC=""
EXTERNAL_LABEL=""
EXTERNAL_RUN_DIR=""
QEMU_GUEST_BASE=""

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_tcg_op_walker_probe.sh [options]

Options:
  --scratch-root DIR      Scratch root for QEMU source/build/output.
                          Default: /tmp/rr-qemu-v2-ptc-tcg-op-walker
  --qemu-src DIR          Existing unpatched QEMU 10.2.3 source tree to copy.
                          Default: download/extract under scratch root.
  --jobs N, -j N          Parallel ninja jobs. Default: 3 or RUNNABLE_QEMU_V2_JOBS.
  --cpu MODEL             QEMU linux-user CPU model. Default: max.
  --fresh                 Remove the patched source, build dir, probe build dir,
                          and output dir before running.
  --skip-download         Require an existing tarball/source tree; do not curl.
  --apply-patch-only      Prepare patched source and patch file, then stop.
  --build-only            Prepare patch and build qemu-x86_64, then stop.
  --run-only              Reuse an existing patched build and only run probes.
  --show-instructions     Print exact manual commands and create the patch file,
                          but do not patch/build/run.
  --external-binary PATH  Run a caller-supplied executable instead of the built-in
                          AVX probes.
  --external-entry HEX    Capture PC to match when using --external-binary.
  --external-label NAME   Output label to use with --external-binary.
  --external-run-dir DIR  Working directory for the external executable.
                          Default: directory containing --external-binary.
  --guest-base HEX        Pass qemu-x86_64 -B HEX when launching guest code.
  -h, --help              Show this help.

Outputs:
  $SCRATCH_ROOT/qemu-10.2.3-ptc-tcg-op-walker.patch
  $SCRATCH_ROOT/qemu-10.2.3-ptc-tcg-op-walker-src/
  $SCRATCH_ROOT/build-10.2.3-ptc-tcg-op-walker/qemu-x86_64
  $SCRATCH_ROOT/probes-build/{avx2-vex,avx512-evex}
  $SCRATCH_ROOT/dumps/{avx2-vex,avx512-evex}.tcg-op-walk.jsonl

The patched QEMU walker is disabled unless RR_PTC_OP_WALK_DUMP is set.
RR_PTC_OP_WALK_PC optionally filters by translation-block start PC.
JSONL records carry record/event tags for tb, temp, and op records; op records
retain their original event and raw args fields for compatibility.
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

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$PWD" "$input"
  fi
}

refresh_paths() {
  DOWNLOAD_DIR="$SCRATCH_ROOT/download"
  BASE_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}"
  PATCHED_SRC="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-ptc-tcg-op-walker-src"
  BUILD_DIR="$SCRATCH_ROOT/build-${QEMU_VERSION}-ptc-tcg-op-walker"
  PROBE_BUILD_DIR="$SCRATCH_ROOT/probes-build"
  OUT_DIR="$SCRATCH_ROOT/dumps"
  VENV_DIR="$SCRATCH_ROOT/venv"
}

write_patch() {
  mkdir -p "$SCRATCH_ROOT"
  local patch_file="$SCRATCH_ROOT/qemu-${QEMU_VERSION}-ptc-tcg-op-walker.patch"
  cat >"$patch_file" <<'PATCH'
diff --git a/accel/tcg/translate-all.c b/accel/tcg/translate-all.c
--- a/accel/tcg/translate-all.c
+++ b/accel/tcg/translate-all.c
@@ -22,6 +22,7 @@
 #include "trace.h"
 #include "disas/disas.h"
 #include "tcg/tcg.h"
+#include "tcg/helper-info.h"
 #include "exec/mmap-lock.h"
 #include "tb-internal.h"
 #include "exec/tb-flush.h"
@@ -232,6 +232,353 @@ static uint8_t *encode_search(TranslationBlock *tb, uint8_t *block)
     return p;
 }

+#define RR_PTC_OP_WALK_MAX_ARGS 32
+
+static FILE *rr_ptc_op_walk_stream(void)
+{
+    static bool rr_ptc_op_walk_checked;
+    static FILE *rr_ptc_op_walk_file;
+    const char *path;
+
+    if (likely(rr_ptc_op_walk_checked)) {
+        return rr_ptc_op_walk_file;
+    }
+
+    rr_ptc_op_walk_checked = true;
+    path = getenv("RR_PTC_OP_WALK_DUMP");
+    if (path && path[0]) {
+        rr_ptc_op_walk_file = fopen(path, "w");
+        if (!rr_ptc_op_walk_file) {
+            fprintf(stderr, "RR_PTC_OP_WALK_DUMP: could not open %s\n", path);
+        }
+    }
+    return rr_ptc_op_walk_file;
+}
+
+static bool rr_ptc_op_walk_pc_matches(vaddr pc)
+{
+    const char *filter = getenv("RR_PTC_OP_WALK_PC");
+    unsigned long long wanted;
+
+    if (!filter || !filter[0]) {
+        return true;
+    }
+    if (sscanf(filter, "%llx", &wanted) != 1) {
+        return false;
+    }
+    return pc == (vaddr)wanted;
+}
+
+static const char *rr_ptc_op_walk_type_name(TCGType type)
+{
+    switch (type) {
+    case TCG_TYPE_I32:
+        return "TCG_TYPE_I32";
+    case TCG_TYPE_I64:
+        return "TCG_TYPE_I64";
+    case TCG_TYPE_I128:
+        return "TCG_TYPE_I128";
+    case TCG_TYPE_V64:
+        return "TCG_TYPE_V64";
+    case TCG_TYPE_V128:
+        return "TCG_TYPE_V128";
+    case TCG_TYPE_V256:
+        return "TCG_TYPE_V256";
+    default:
+        return "TCG_TYPE_UNKNOWN";
+    }
+}
+
+static const char *rr_ptc_op_walk_temp_kind_name(TCGTempKind kind)
+{
+    switch (kind) {
+    case TEMP_EBB:
+        return "TEMP_EBB";
+    case TEMP_TB:
+        return "TEMP_TB";
+    case TEMP_GLOBAL:
+        return "TEMP_GLOBAL";
+    case TEMP_FIXED:
+        return "TEMP_FIXED";
+    case TEMP_CONST:
+        return "TEMP_CONST";
+    default:
+        return "TEMP_KIND_UNKNOWN";
+    }
+}
+
+static const char *rr_ptc_op_walk_temp_val_name(TCGTempVal val_type)
+{
+    switch (val_type) {
+    case TEMP_VAL_DEAD:
+        return "TEMP_VAL_DEAD";
+    case TEMP_VAL_REG:
+        return "TEMP_VAL_REG";
+    case TEMP_VAL_MEM:
+        return "TEMP_VAL_MEM";
+    case TEMP_VAL_CONST:
+        return "TEMP_VAL_CONST";
+    default:
+        return "TEMP_VAL_UNKNOWN";
+    }
+}
+
+static bool rr_ptc_op_walk_temp_index(TCGContext *ctx, TCGTemp *ts,
+                                      unsigned *index)
+{
+    uintptr_t base = (uintptr_t)&ctx->temps[0];
+    uintptr_t end = (uintptr_t)&ctx->temps[ctx->nb_temps];
+    uintptr_t value = (uintptr_t)ts;
+
+    if (value < base || value >= end) {
+        return false;
+    }
+    if ((value - base) % sizeof(ctx->temps[0]) != 0) {
+        return false;
+    }
+    *index = (unsigned)((value - base) / sizeof(ctx->temps[0]));
+    return true;
+}
+
+static bool rr_ptc_op_walk_arg_temp_id(TCGContext *ctx, TCGArg arg,
+                                       unsigned *index)
+{
+    return rr_ptc_op_walk_temp_index(ctx, arg_temp(arg), index);
+}
+
+static void rr_ptc_op_walk_dump_json_string(FILE *f, const char *s)
+{
+    const unsigned char *p = (const unsigned char *)s;
+
+    fputc('"', f);
+    if (p) {
+        for (; *p; p++) {
+            switch (*p) {
+            case '"':
+                fputs("\\\"", f);
+                break;
+            case '\\':
+                fputs("\\\\", f);
+                break;
+            case '\b':
+                fputs("\\b", f);
+                break;
+            case '\f':
+                fputs("\\f", f);
+                break;
+            case '\n':
+                fputs("\\n", f);
+                break;
+            case '\r':
+                fputs("\\r", f);
+                break;
+            case '\t':
+                fputs("\\t", f);
+                break;
+            default:
+                if (*p < 0x20) {
+                    fprintf(f, "\\u%04x", *p);
+                } else {
+                    fputc(*p, f);
+                }
+                break;
+            }
+        }
+    }
+    fputc('"', f);
+}
+
+static unsigned rr_ptc_op_walk_arg_count(const TCGOp *op,
+                                         const TCGOpDef *def)
+{
+    if (!def) {
+        return op->nargs;
+    }
+    if (op->opc == INDEX_op_call) {
+        return TCGOP_CALLO(op) + TCGOP_CALLI(op) + 2;
+    }
+    return def->nb_args;
+}
+
+static void rr_ptc_op_walk_dump_temps(TCGContext *ctx, TranslationBlock *tb,
+                                      vaddr pc, FILE *f)
+{
+    int i;
+
+    for (i = 0; i < ctx->nb_temps; i++) {
+        TCGTemp *ts = &ctx->temps[i];
+        unsigned mem_base_index = 0;
+        bool has_mem_base = ts->mem_base &&
+            rr_ptc_op_walk_temp_index(ctx, ts->mem_base, &mem_base_index);
+
+        fprintf(f,
+                "{\"record\":\"temp\",\"event\":\"temp\","
+                "\"tb_pc\":\"0x%" VADDR_PRIx "\","
+                "\"pc\":\"0x%" VADDR_PRIx "\",\"tb_size\":%u,"
+                "\"tb_icount\":%u,\"tb_nb_ops\":%d,"
+                "\"temp_index\":%d,\"temp_id\":%d,"
+                "\"is_global\":%s,\"arg\":\"0x%" TCG_PRIlx "\","
+                "\"kind\":%u,\"kind_name\":\"%s\","
+                "\"val_type\":%u,\"val_type_name\":\"%s\","
+                "\"base_type\":%u,\"base_type_name\":\"%s\","
+                "\"type\":%u,\"type_name\":\"%s\","
+                "\"reg\":%u,\"val\":\"0x%" PRIx64 "\","
+                "\"val_s\":%" PRId64 ","
+                "\"mem_base_id\":",
+                tb->pc, pc, (unsigned)tb->size, (unsigned)tb->icount,
+                ctx->nb_ops, i, i, i < ctx->nb_globals ? "true" : "false",
+                temp_arg(ts), (unsigned)ts->kind,
+                rr_ptc_op_walk_temp_kind_name(ts->kind),
+                (unsigned)ts->val_type,
+                rr_ptc_op_walk_temp_val_name(ts->val_type),
+                (unsigned)ts->base_type,
+                rr_ptc_op_walk_type_name(ts->base_type),
+                (unsigned)ts->type,
+                rr_ptc_op_walk_type_name(ts->type),
+                (unsigned)ts->reg, (uint64_t)ts->val, (int64_t)ts->val);
+        if (has_mem_base) {
+            fprintf(f, "%u", mem_base_index);
+        } else {
+            fputs("null", f);
+        }
+        fprintf(f,
+                ",\"mem_base_arg\":");
+        if (ts->mem_base) {
+            fprintf(f, "\"0x%" TCG_PRIlx "\"", temp_arg(ts->mem_base));
+        } else {
+            fputs("null", f);
+        }
+        fprintf(f,
+                ",\"mem_offset\":%" PRIdPTR ","
+                "\"mem_offset_hex\":\"0x%" PRIxPTR "\","
+                "\"indirect_reg\":%u,\"indirect_base\":%u,"
+                "\"mem_coherent\":%u,\"mem_allocated\":%u,"
+                "\"temp_allocated\":%u,\"temp_subindex\":%u,"
+                "\"state\":\"0x%" PRIxPTR "\","
+                "\"state_ptr\":",
+                ts->mem_offset, (uintptr_t)ts->mem_offset,
+                (unsigned)ts->indirect_reg, (unsigned)ts->indirect_base,
+                (unsigned)ts->mem_coherent, (unsigned)ts->mem_allocated,
+                (unsigned)ts->temp_allocated, (unsigned)ts->temp_subindex,
+                (uintptr_t)ts->state);
+        if (ts->state_ptr) {
+            fprintf(f, "\"%p\"", ts->state_ptr);
+        } else {
+            fputs("null", f);
+        }
+        fprintf(f, ",\"temp_name\":");
+        if (ts->name) {
+            rr_ptc_op_walk_dump_json_string(f, ts->name);
+        } else {
+            fputs("null", f);
+        }
+        fputs("}\n", f);
+    }
+}
+
+static void rr_ptc_op_walk_dump(TCGContext *ctx, TranslationBlock *tb,
+                                vaddr pc, FILE *f)
+{
+    TCGOp *op;
+    unsigned op_index = 0;
+
+    fprintf(f,
+            "{\"record\":\"tb\",\"event\":\"tb\","
+            "\"tb_pc\":\"0x%" VADDR_PRIx "\","
+            "\"pc\":\"0x%" VADDR_PRIx "\",\"tb_size\":%u,"
+            "\"tb_icount\":%u,\"tb_nb_ops\":%d,\"nb_temps\":%d,"
+            "\"nb_globals\":%d}\n",
+            tb->pc, pc, (unsigned)tb->size, (unsigned)tb->icount,
+            ctx->nb_ops, ctx->nb_temps, ctx->nb_globals);
+
+    rr_ptc_op_walk_dump_temps(ctx, tb, pc, f);
+
+    QTAILQ_FOREACH(op, &ctx->ops, link) {
+        const TCGOpDef *def = NULL;
+        const char *name = "<invalid>";
+        unsigned arg_count;
+        unsigned dump_count;
+        unsigned i;
+
+        if ((size_t)op->opc < tcg_op_defs_max) {
+            def = &tcg_op_defs[op->opc];
+            name = def->name;
+        }
+
+        arg_count = rr_ptc_op_walk_arg_count(op, def);
+        dump_count = arg_count;
+        if (dump_count > op->nargs) {
+            dump_count = op->nargs;
+        }
+        if (dump_count > RR_PTC_OP_WALK_MAX_ARGS) {
+            dump_count = RR_PTC_OP_WALK_MAX_ARGS;
+        }
+
+        fprintf(f,
+                "{\"record\":\"op\",\"event\":\"op\","
+                "\"tb_pc\":\"0x%" VADDR_PRIx "\","
+                "\"pc\":\"0x%" VADDR_PRIx "\",\"tb_size\":%u,"
+                "\"tb_icount\":%u,\"tb_nb_ops\":%d,\"op_index\":%u,"
+                "\"opcode\":%u,\"name\":\"%s\",\"def_oargs\":%u,"
+                "\"def_iargs\":%u,\"def_cargs\":%u,\"def_args\":%u,"
+                "\"def_flags\":%u,\"arg_count\":%u,\"op_capacity\":%u,"
+                "\"param1\":%u,\"param2\":%u,\"life\":%u,\"args\":[",
+                tb->pc, pc, (unsigned)tb->size, (unsigned)tb->icount,
+                ctx->nb_ops, op_index, (unsigned)op->opc, name,
+                def ? (unsigned)def->nb_oargs : 0,
+                def ? (unsigned)def->nb_iargs : 0,
+                def ? (unsigned)def->nb_cargs : 0,
+                def ? (unsigned)def->nb_args : 0,
+                def ? (unsigned)def->flags : 0,
+                arg_count, (unsigned)op->nargs, (unsigned)op->param1,
+                (unsigned)op->param2, (unsigned)op->life);
+
+        for (i = 0; i < dump_count; i++) {
+            fprintf(f, "%s\"0x%" TCG_PRIlx "\"", i ? "," : "", op->args[i]);
+        }
+        fprintf(f, "],\"arg_temp_ids\":[");
+        for (i = 0; i < dump_count; i++) {
+            unsigned temp_id = 0;
+
+            if (i) {
+                fputc(',', f);
+            }
+            if (rr_ptc_op_walk_arg_temp_id(ctx, op->args[i], &temp_id)) {
+                fprintf(f, "%u", temp_id);
+            } else {
+                fputs("null", f);
+            }
+        }
+        fprintf(f, "],\"args_truncated\":%s",
+                arg_count > dump_count ? "true" : "false");
+        if (op->opc == INDEX_op_call) {
+            unsigned func_index = TCGOP_CALLO(op) + TCGOP_CALLI(op);
+            unsigned info_index = func_index + 1;
+
+            if (info_index < dump_count) {
+                uintptr_t func_ptr = (uintptr_t)op->args[func_index];
+                const TCGHelperInfo *helper_info =
+                    (const TCGHelperInfo *)(uintptr_t)op->args[info_index];
+
+                fprintf(f,
+                        ",\"call_helper\":{\"func\":\"0x%" PRIxPTR "\","
+                        "\"info\":\"0x%" PRIxPTR "\",\"flags\":%u,\"name\":",
+                        func_ptr, (uintptr_t)helper_info,
+                        helper_info ? (unsigned)helper_info->flags : 0);
+                if (helper_info && helper_info->name) {
+                    rr_ptc_op_walk_dump_json_string(f, helper_info->name);
+                } else {
+                    fputs("null", f);
+                }
+                fputc('}', f);
+            }
+        }
+        fputs("}\n", f);
+        op_index++;
+    }
+    fflush(f);
+}
+
 /*
  * Isolate the portion of code gen which can setjmp/longjmp.
  * Return the size of the generated code, or negative on error.
@@ -241,6 +565,8 @@ static int setjmp_gen_code(CPUArchState *env, TranslationBlock *tb,
                            int *max_insns, int64_t *ti)
 {
     int ret = sigsetjmp(tcg_ctx->jmp_trans, 0);
+    FILE *rr_ptc_op_walk_file;
+
     if (unlikely(ret != 0)) {
         return ret;
     }
@@ -252,6 +578,11 @@ static int setjmp_gen_code(CPUArchState *env, TranslationBlock *tb,
     tcg_ctx->cpu = cs;
     cs->cc->tcg_ops->translate_code(cs, tb, max_insns, pc, host_pc);

+    rr_ptc_op_walk_file = rr_ptc_op_walk_stream();
+    if (unlikely(rr_ptc_op_walk_file && rr_ptc_op_walk_pc_matches(pc))) {
+        rr_ptc_op_walk_dump(tcg_ctx, tb, pc, rr_ptc_op_walk_file);
+    }
+
     assert(tb->size != 0);
     tcg_ctx->cpu = NULL;
     *max_insns = tb->icount;
diff --git a/accel/tcg/cpu-exec.c b/accel/tcg/cpu-exec.c
--- a/accel/tcg/cpu-exec.c
+++ b/accel/tcg/cpu-exec.c
@@ -150,6 +150,84 @@ static void init_delay_params(SyncClocks *sc, const CPUState *cpu)
 }
 #endif /* CONFIG USER ONLY */

+static bool rr_ptc_op_walk_force_pc(vaddr *pc)
+{
+    const char *force = getenv("RR_PTC_OP_WALK_FORCE_PC");
+    const char *value;
+    unsigned long long wanted;
+
+    if (!force || !force[0] || g_strcmp0(force, "0") == 0) {
+        return false;
+    }
+
+    if (g_strcmp0(force, "1") == 0 ||
+        g_strcmp0(force, "true") == 0 ||
+        g_strcmp0(force, "yes") == 0) {
+        value = getenv("RR_PTC_OP_WALK_PC");
+    } else {
+        value = force;
+    }
+
+    if (!value || !value[0] || sscanf(value, "%llx", &wanted) != 1) {
+        fprintf(stderr,
+                "RR_PTC_OP_WALK_FORCE_PC: invalid requested pc '%s'\n",
+                value ? value : "");
+        exit(2);
+    }
+
+    *pc = (vaddr)wanted;
+    return true;
+}
+
+static void rr_ptc_op_walk_force_translate_once(CPUState *cpu)
+{
+    static bool done;
+    vaddr requested_pc;
+    TCGTBCPUState s;
+    TranslationBlock *tb;
+
+    if (done) {
+        return;
+    }
+    done = true;
+
+    if (!rr_ptc_op_walk_force_pc(&requested_pc)) {
+        return;
+    }
+
+    s = cpu->cc->tcg_ops->get_tb_cpu_state(cpu);
+    s.pc = requested_pc;
+    s.cflags = curr_cflags(cpu);
+    s.cflags = (s.cflags & ~CF_COUNT_MASK) |
+        CF_NO_GOTO_TB | CF_NO_GOTO_PTR;
+
+    mmap_lock();
+    tb = tb_gen_code(cpu, s);
+    mmap_unlock();
+
+    if (tb) {
+        fprintf(stderr,
+                "RR_PTC_OP_WALK_FORCE_PC: translated pc=0x%llx "
+                "tb_pc=0x%llx size=%u icount=%u\n",
+                (unsigned long long)requested_pc,
+                (unsigned long long)tb->pc,
+                (unsigned)tb->size,
+                (unsigned)tb->icount);
+    } else {
+        fprintf(stderr,
+                "RR_PTC_OP_WALK_FORCE_PC: tb_gen_code returned null "
+                "for pc=0x%llx\n",
+                (unsigned long long)requested_pc);
+        exit(1);
+    }
+
+    /*
+     * This QEMU binary is a metadata probe.  Once the requested TB has been
+     * generated, translate-all.c has already emitted the walker JSONL.
+     */
+    exit(0);
+}
+
 struct tb_desc {
     TCGTBCPUState s;
     CPUArchState *env;
@@ -933,6 +1009,8 @@ cpu_exec_loop(CPUState *cpu, SyncClocks *sc)
 {
     int ret;

+    rr_ptc_op_walk_force_translate_once(cpu);
+
     /* if an exception is pending, we execute it here */
     while (!cpu_handle_exception(cpu, &ret)) {
         TranslationBlock *last_tb = NULL;
PATCH
  echo "$patch_file"
}

print_manual_instructions() {
  local patch_file="$1"
  cat <<EOF
Patch file created:
  $patch_file

Manual run:
  mkdir -p "$SCRATCH_ROOT"
  cd "$SCRATCH_ROOT"
  curl -L --fail --retry 3 -o "$QEMU_TARBALL" "$QEMU_URL"
  printf '%s  %s\n' "$QEMU_SHA256" "$QEMU_TARBALL" | sha256sum -c -
  tar -xf "$QEMU_TARBALL"
  rm -rf "$PATCHED_SRC"
  cp -a "$BASE_SRC" "$PATCHED_SRC"
  cd "$PATCHED_SRC"
  patch -p1 < "$patch_file"
  mkdir -p "$BUILD_DIR"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip meson ninja
  cd "$BUILD_DIR"
  PATH="$VENV_DIR/bin:\$PATH" "$PATCHED_SRC/configure" --python="$VENV_DIR/bin/python3" --target-list=x86_64-linux-user --disable-system --disable-tools --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-curses --disable-slirp --disable-capstone --disable-werror --prefix="$SCRATCH_ROOT/install-$QEMU_VERSION-ptc-tcg-op-walker"
  PATH="$VENV_DIR/bin:\$PATH" ninja -C "$BUILD_DIR" -j "$JOBS" qemu-x86_64
  python3 "$RR_DIR/runnable/scripts/qemu_v2_probe_suite.py" --probe avx2-vex --probe avx512-evex --compile --objdump --build-dir "$PROBE_BUILD_DIR"
  mkdir -p "$OUT_DIR"
  (cd "$OUT_DIR" && ulimit -c 0 && RR_PTC_OP_WALK_DUMP="$OUT_DIR/avx2-vex.tcg-op-walk.jsonl" RR_PTC_OP_WALK_PC=\$(nm -n "$PROBE_BUILD_DIR/avx2-vex" | awk '/ _start$/ {print \$1; exit}') "$BUILD_DIR/qemu-x86_64" -cpu "$QEMU_CPU_MODEL" "$PROBE_BUILD_DIR/avx2-vex")
  (cd "$OUT_DIR" && ulimit -c 0 && RR_PTC_OP_WALK_DUMP="$OUT_DIR/avx512-evex.tcg-op-walk.jsonl" RR_PTC_OP_WALK_PC=\$(nm -n "$PROBE_BUILD_DIR/avx512-evex" | awk '/ _start$/ {print \$1; exit}') "$BUILD_DIR/qemu-x86_64" -cpu "$QEMU_CPU_MODEL" "$PROBE_BUILD_DIR/avx512-evex")
EOF
}

download_or_extract_qemu() {
  mkdir -p "$DOWNLOAD_DIR"
  if [[ -d "$BASE_SRC" ]]; then
    log "Using existing QEMU source: $BASE_SRC"
    return
  fi

  local tarball="$DOWNLOAD_DIR/$QEMU_TARBALL"
  if [[ ! -f "$tarball" ]]; then
    [[ "$SKIP_DOWNLOAD" -eq 0 ]] || die "missing $tarball and --skip-download was requested"
    require_tool curl
    log "Downloading QEMU $QEMU_VERSION"
    curl -L --fail --retry 3 -o "$tarball" "$QEMU_URL"
  fi

  require_tool sha256sum
  (cd "$DOWNLOAD_DIR" && printf '%s  %s\n' "$QEMU_SHA256" "$QEMU_TARBALL" | sha256sum -c -)

  log "Extracting QEMU source"
  tar -C "$SCRATCH_ROOT" -xf "$tarball"
  [[ -x "$BASE_SRC/configure" ]] || die "QEMU configure not found after extraction: $BASE_SRC/configure"
}

copy_source() {
  local source="$1"
  [[ -d "$source" ]] || die "QEMU source tree not found: $source"
  [[ -x "$source/configure" ]] || die "QEMU configure not found or not executable: $source/configure"
  [[ -f "$source/meson.build" ]] || die "QEMU source does not look like a modern QEMU tree: $source"

  if [[ -d "$PATCHED_SRC" ]]; then
    if [[ -f "$PATCHED_SRC/.rr-ptc-tcg-op-walker-patched" ]]; then
      log "Using existing patched source: $PATCHED_SRC"
      return
    fi
    die "patched source exists but was not created by this script: $PATCHED_SRC"
  fi

  log "Copying QEMU source to throwaway patched tree"
  cp -a "$source" "$PATCHED_SRC"
}

apply_qemu_patch() {
  local patch_file="$1"
  if [[ -f "$PATCHED_SRC/.rr-ptc-tcg-op-walker-patched" ]]; then
    return
  fi
  require_tool patch
  log "Applying C-side TCGOp walker patch"
  (cd "$PATCHED_SRC" && patch -p1 <"$patch_file")
  touch "$PATCHED_SRC/.rr-ptc-tcg-op-walker-patched"
}

setup_build_tools() {
  require_tool python3

  if [[ ! -x "$VENV_DIR/bin/python3" ]]; then
    log "Preparing Meson/Ninja venv under $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  if [[ ! -x "$VENV_DIR/bin/meson" || ! -x "$VENV_DIR/bin/ninja" ]]; then
    log "Installing Meson/Ninja into $VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip meson ninja
  fi

  BUILD_PYTHON="$VENV_DIR/bin/python3"
  export PATH="$VENV_DIR/bin:$PATH"
}

build_qemu() {
  setup_build_tools
  require_tool ninja
  mkdir -p "$BUILD_DIR"

  local configure_args=(
    "--target-list=x86_64-linux-user"
    "--disable-system"
    "--disable-tools"
    "--disable-docs"
    "--disable-gtk"
    "--disable-sdl"
    "--disable-vnc"
    "--disable-curses"
    "--disable-slirp"
    "--disable-capstone"
    "--disable-werror"
    "--prefix=$SCRATCH_ROOT/install-$QEMU_VERSION-ptc-tcg-op-walker"
  )

  if [[ -f "$BUILD_DIR/build.ninja" ]]; then
    log "Existing build.ninja found; skipping configure"
  else
    log "Configuring patched QEMU"
    (
      cd "$BUILD_DIR" &&
      PATH="$VENV_DIR/bin:$PATH" \
      "$PATCHED_SRC/configure" --python="$BUILD_PYTHON" "${configure_args[@]}"
    )
  fi

  log "Building qemu-x86_64"
  ninja -C "$BUILD_DIR" -j "$JOBS" qemu-x86_64
  [[ -x "$BUILD_DIR/qemu-x86_64" ]] || die "expected QEMU binary missing: $BUILD_DIR/qemu-x86_64"
  "$BUILD_DIR/qemu-x86_64" --version
}

probe_entry_pc() {
  local binary="$1"
  require_tool nm
  local pc
  pc="$(nm -n "$binary" | awk '/ _start$/ {print $1; exit}')"
  [[ -n "$pc" ]] || die "could not find _start symbol in $binary"
  printf '%s\n' "$pc"
}

summarize_names() {
  local dump_file="$1"
  sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "$dump_file" \
    | sort \
    | uniq -c \
    | sort -nr \
    | head -30
}

run_one_probe() {
  local probe="$1"
  local binary="$PROBE_BUILD_DIR/$probe"
  local dump_file="$OUT_DIR/$probe.tcg-op-walk.jsonl"
  local run_log="$OUT_DIR/$probe.run.log"
  local pc

  [[ -x "$binary" ]] || die "probe binary missing: $binary"
  pc="$(probe_entry_pc "$binary")"

  log "Running $probe with RR_PTC_OP_WALK_PC=0x$pc"
  set +e
  (
    cd "$OUT_DIR"
    ulimit -c 0
    RR_PTC_OP_WALK_DUMP="$dump_file" \
    RR_PTC_OP_WALK_PC="$pc" \
      "$BUILD_DIR/qemu-x86_64" -cpu "$QEMU_CPU_MODEL" "$binary"
  ) >"$run_log" 2>&1
  local rc=$?
  set -e

  printf '%s\n' "$rc" >"$OUT_DIR/$probe.exit-code"
  if [[ -s "$run_log" ]]; then
    sed -n '1,80p' "$run_log"
  fi

  if [[ -s "$dump_file" ]]; then
    local op_lines
    local temp_lines
    local tb_lines
    op_lines="$(grep -c '"record":"op"' "$dump_file" || true)"
    temp_lines="$(grep -c '"record":"temp"' "$dump_file" || true)"
    tb_lines="$(grep -c '"record":"tb"' "$dump_file" || true)"
    log "$probe walker dump: $dump_file ($tb_lines tb, $op_lines op, $temp_lines temp records, qemu rc=$rc)"
    sed -n '1,12p' "$dump_file"
    log "$probe top opcode names"
    summarize_names "$dump_file"
  else
    log "$probe produced no walker dump at $dump_file (qemu rc=$rc)"
  fi
}

run_external_binary() {
  local binary="$EXTERNAL_BINARY"
  local label="$EXTERNAL_LABEL"
  local pc="$EXTERNAL_ENTRY_PC"
  local run_dir="$EXTERNAL_RUN_DIR"
  local dump_file
  local run_log

  [[ -n "$binary" ]] || die "--external-binary is required"
  [[ -x "$binary" ]] || die "external binary missing or not executable: $binary"
  [[ -n "$pc" ]] || die "--external-entry is required with --external-binary"

  if [[ -z "$label" ]]; then
    label="$(basename "$binary")"
  fi
  if [[ -z "$run_dir" ]]; then
    run_dir="$(cd "$(dirname "$binary")" && pwd -P)"
  fi
  [[ -d "$run_dir" ]] || die "external run directory not found: $run_dir"

  mkdir -p "$OUT_DIR"
  dump_file="$OUT_DIR/$label.tcg-op-walk.jsonl"
  run_log="$OUT_DIR/$label.run.log"

  log "Running external binary $binary with RR_PTC_OP_WALK_PC=$pc"
  set +e
  (
    cd "$run_dir"
    ulimit -c 0
    RR_PTC_OP_WALK_DUMP="$dump_file" \
    RR_PTC_OP_WALK_PC="$pc" \
    RR_PTC_OP_WALK_FORCE_PC=1 \
      "$BUILD_DIR/qemu-x86_64" -cpu "$QEMU_CPU_MODEL" ${QEMU_GUEST_BASE:+-B "$QEMU_GUEST_BASE"} "$binary"
  ) >"$run_log" 2>&1
  local rc=$?
  set -e

  printf '%s\n' "$rc" >"$OUT_DIR/$label.exit-code"
  if [[ -s "$run_log" ]]; then
    sed -n '1,120p' "$run_log"
  fi

  if [[ -s "$dump_file" ]]; then
    local op_lines
    local temp_lines
    local tb_lines
    op_lines="$(grep -c '"record":"op"' "$dump_file" || true)"
    temp_lines="$(grep -c '"record":"temp"' "$dump_file" || true)"
    tb_lines="$(grep -c '"record":"tb"' "$dump_file" || true)"
    log "$label walker dump: $dump_file ($tb_lines tb, $op_lines op, $temp_lines temp records, qemu rc=$rc)"
    sed -n '1,12p' "$dump_file"
  else
    log "$label produced no walker dump at $dump_file (qemu rc=$rc)"
  fi
}

verify_avx2_dump() {
  local dump_file="$OUT_DIR/avx2-vex.tcg-op-walk.jsonl"
  [[ -s "$dump_file" ]] || die "avx2-vex walker dump is empty: $dump_file"

  local op_lines
  local temp_lines
  op_lines="$(grep -c '"record":"op"' "$dump_file" || true)"
  [[ "$op_lines" -gt 0 ]] || die "avx2-vex walker dump has no op records: $dump_file"

  temp_lines="$(grep -c '"record":"temp"' "$dump_file" || true)"
  [[ "$temp_lines" -gt 0 ]] || die "avx2-vex walker dump has no temp records: $dump_file"

  if ! grep -Eq '"record":"temp".*"temp_id":[0-9]+.*"kind":[0-9]+.*"base_type":[0-9]+.*"type":[0-9]+' "$dump_file"; then
    die "avx2-vex temp records lack required temp_id/kind/base_type/type fields: $dump_file"
  fi

  if ! grep -Eq '"name":"([a-z0-9_]*_vec|qemu_ld2|qemu_st2|qemu_ld|qemu_st)"' "$dump_file"; then
    die "avx2-vex walker dump lacks vector or memory op evidence: $dump_file"
  fi

  log "avx2-vex verification passed: non-empty JSONL with op and temp metadata records"
}

run_probes() {
  require_tool python3
  mkdir -p "$PROBE_BUILD_DIR" "$OUT_DIR"

  log "Compiling and objdump-checking selected Runnable probes"
  python3 "$RR_DIR/runnable/scripts/qemu_v2_probe_suite.py" \
    --probe avx2-vex \
    --probe avx512-evex \
    --compile \
    --objdump \
    --build-dir "$PROBE_BUILD_DIR"

  run_one_probe avx2-vex
  verify_avx2_dump
  run_one_probe avx512-evex

  cat <<EOF

Results:
  QEMU binary:      $BUILD_DIR/qemu-x86_64
  AVX2 walker:     $OUT_DIR/avx2-vex.tcg-op-walk.jsonl
  AVX512 walker:   $OUT_DIR/avx512-evex.tcg-op-walk.jsonl
  Exit codes:      $OUT_DIR/*.exit-code
  Run logs:        $OUT_DIR/*.run.log
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-root)
      SCRATCH_ROOT="$(abs_path "${2:?missing value for --scratch-root}")"
      shift 2
      ;;
    --qemu-src)
      BASE_SRC="$(abs_path "${2:?missing value for --qemu-src}")"
      shift 2
      ;;
    --jobs|-j)
      JOBS="${2:?missing value for --jobs}"
      shift 2
      ;;
    --cpu)
      QEMU_CPU_MODEL="${2:?missing value for --cpu}"
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
    --apply-patch-only)
      APPLY_PATCH_ONLY=1
      shift
      ;;
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --run-only)
      RUN_ONLY=1
      shift
      ;;
    --show-instructions)
      SHOW_INSTRUCTIONS=1
      shift
      ;;
    --external-binary)
      EXTERNAL_BINARY="$(abs_path "${2:?missing value for --external-binary}")"
      shift 2
      ;;
    --external-entry)
      EXTERNAL_ENTRY_PC="${2:?missing value for --external-entry}"
      shift 2
      ;;
    --external-label)
      EXTERNAL_LABEL="${2:?missing value for --external-label}"
      shift 2
      ;;
    --external-run-dir)
      EXTERNAL_RUN_DIR="$(abs_path "${2:?missing value for --external-run-dir}")"
      shift 2
      ;;
    --guest-base)
      QEMU_GUEST_BASE="${2:?missing value for --guest-base}"
      shift 2
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

SCRATCH_ROOT="$(abs_path "$SCRATCH_ROOT")"
USER_BASE_SRC="$BASE_SRC"
refresh_paths
if [[ -n "$USER_BASE_SRC" ]]; then
  BASE_SRC="$USER_BASE_SRC"
fi

PATCH_FILE="$(write_patch)"

if [[ "$SHOW_INSTRUCTIONS" -eq 1 ]]; then
  print_manual_instructions "$PATCH_FILE"
  exit 0
fi

if [[ "$FRESH" -eq 1 ]]; then
  log "Removing throwaway generated directories under $SCRATCH_ROOT"
  rm -rf "$PATCHED_SRC" "$BUILD_DIR" "$PROBE_BUILD_DIR" "$OUT_DIR"
fi

if [[ "$RUN_ONLY" -eq 0 ]]; then
  if [[ -z "$USER_BASE_SRC" ]]; then
    download_or_extract_qemu
  fi
  copy_source "$BASE_SRC"
  apply_qemu_patch "$PATCH_FILE"

  if [[ "$APPLY_PATCH_ONLY" -eq 1 ]]; then
    log "Patched source is ready: $PATCHED_SRC"
    exit 0
  fi

  build_qemu

  if [[ "$BUILD_ONLY" -eq 1 ]]; then
    log "Patched QEMU binary is ready: $BUILD_DIR/qemu-x86_64"
    exit 0
  fi
else
  [[ -x "$BUILD_DIR/qemu-x86_64" ]] || die "--run-only requires existing binary: $BUILD_DIR/qemu-x86_64"
fi

if [[ -n "$EXTERNAL_BINARY" ]]; then
  run_external_binary
  exit 0
fi

run_probes
