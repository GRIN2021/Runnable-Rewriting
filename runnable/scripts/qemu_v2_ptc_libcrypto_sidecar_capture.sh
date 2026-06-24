#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

SCRATCH_ROOT="${RUNNABLE_QEMU_V2_LIBCRYPTO_SIDECAR_ROOT:-}"
BINARY_PATH="${RUNNABLE_QEMU_V2_LIBCRYPTO_BINARY:-}"
SYMBOL_NAME="${RUNNABLE_QEMU_V2_LIBCRYPTO_SYMBOL:-SHA1@@OPENSSL_3.0.0}"
ENTRY_HEX="${RUNNABLE_QEMU_V2_LIBCRYPTO_ENTRY:-}"
RUNNABLE_BASE="${RUNNABLE_QEMU_V2_LIBCRYPTO_BASE:-0x50000000}"
WALKER_ROOT="${RUNNABLE_QEMU_V2_LIBCRYPTO_WALKER_ROOT:-}"
QEMU_BIN_OVERRIDE="${RUNNABLE_QEMU_V2_LIBCRYPTO_QEMU_BIN:-}"
QEMU_CPU_MODEL="${RUNNABLE_QEMU_V2_LIBCRYPTO_QEMU_CPU:-max}"
FRESH=0
SYMBOL_SHORT_NAME=""
SYMBOL_LABEL=""
MATERIALIZER_SCRIPT="$SCRIPT_DIR/qemu_v2_ptc_materialize_walker_sidecar.py"

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_libcrypto_sidecar_capture.sh [options]

Options:
  --scratch-root DIR   Output scratch directory.
                       Default: /tmp/rr-qemu-v2-libcrypto-sidecar-<symbol>
  --binary PATH        Path to libcrypto.so.3 to stage and probe.
  --symbol NAME        Versioned symbol name for reporting only.
                       Default: SHA1@@OPENSSL_3.0.0
  --entry HEX          Expected runnable entry address to print.
                       Default: resolve from --symbol via readelf.
  --runnable-base HEX  Runnable base address to print.
                       Default: 0x50000000
  --walker-root DIR    Scratch root for qemu_v2_ptc_tcg_op_walker_probe.sh.
                       Default: <scratch-root>/walker
  --qemu-bin PATH      Reuse an already built patched qemu-x86_64.
  --qemu-cpu MODEL     QEMU linux-user CPU model. Default: max.
  --fresh              Remove the scratch root before running.
  -h, --help           Show this help.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$PWD" "$input"
  fi
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

extract_sha1_addr() {
  local log_file="$1"
  python3 - "$log_file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
match = re.search(r"symbol_addr=(0x[0-9a-fA-F]+)", text)
if match:
    print(match.group(1))
PY
}

sanitize_label_component() {
  local raw="$1"
  printf '%s' "$raw" | tr '@[:upper:]' '-[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

resolve_symbol_entry() {
  local binary_path="$1"
  local symbol_name="$2"
  python3 - "$binary_path" "$symbol_name" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

binary = Path(sys.argv[1]).resolve()
symbol = sys.argv[2]
output = subprocess.check_output(["readelf", "-Ws", str(binary)], text=True)
pattern = re.compile(r"^\s*\d+:\s*([0-9a-fA-F]+)\s+\d+\s+FUNC\s+\S+\s+\S+\s+\S+\s+(.+?)\s*$")
for line in output.splitlines():
    match = pattern.match(line)
    if not match:
        continue
    value_hex, name = match.groups()
    if name == symbol:
        print(hex(int(value_hex, 16)))
        raise SystemExit(0)
raise SystemExit(f"symbol not found in {binary}: {symbol}")
PY
}

emit_call_snippet() {
  case "$1" in
    SHA1)
      cat <<'EOF'
  {
    typedef unsigned char *(*symbol_fn_t)(const unsigned char *, size_t, unsigned char *);
    static const unsigned char input[] = "abc";
    unsigned char digest[20] = {0};
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    unsigned char *result = symbol_fn(input, sizeof(input) - 1u, digest);
    printf("symbol_call_ptr=%p\n", result);
    if (result != NULL) {
      printf("sha1_digest_prefix=%02x%02x%02x%02x\n",
             digest[0], digest[1], digest[2], digest[3]);
    }
  }
EOF
      ;;
    EVP_DigestInit_ex)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, const void *, void *);
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    printf("symbol_call_rc=%d\n", symbol_fn(NULL, NULL, NULL));
  }
EOF
      ;;
    EVP_DigestInit|EVP_MD_CTX_copy_ex)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, const void *);
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    printf("symbol_call_rc=%d\n", symbol_fn(NULL, NULL));
  }
EOF
      ;;
    PKCS5_PBKDF2_HMAC)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(const char *, int, const unsigned char *, int, int, const void *, int, unsigned char *);
    typedef const void *(*evp_sha256_fn_t)(void);
    static const char password[] = "sidecar-password";
    static const unsigned char salt[] = "sidecar-salt";
    unsigned char output[32] = {0};
    void *md_symbol;
    evp_sha256_fn_t evp_sha256_fn;
    const void *md;
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;

    dlerror();
    md_symbol = dlsym(handle, "EVP_sha256");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    evp_sha256_fn = (evp_sha256_fn_t)md_symbol;
    md = evp_sha256_fn();
    printf("symbol_call_rc=%d\n",
           symbol_fn(password,
                     (int)(sizeof(password) - 1u),
                     salt,
                     (int)(sizeof(salt) - 1u),
                     1000,
                     md,
                     (int)sizeof(output),
                     output));
    printf("pkcs5_pbkdf2_hmac_prefix=%02x%02x%02x%02x\n",
           output[0], output[1], output[2], output[3]);
  }
EOF
      ;;
    EVP_Digest)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(const void *, size_t, unsigned char *, unsigned int *, const void *, void *);
    typedef const void *(*evp_sha256_fn_t)(void);
    static const unsigned char input[] = "sidecar-digest-input";
    unsigned char output[64] = {0};
    unsigned int output_len = 0;
    void *md_symbol;
    evp_sha256_fn_t evp_sha256_fn;
    const void *md;
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;

    dlerror();
    md_symbol = dlsym(handle, "EVP_sha256");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    evp_sha256_fn = (evp_sha256_fn_t)md_symbol;
    md = evp_sha256_fn();
    printf("symbol_call_rc=%d\n",
           symbol_fn(input,
                     sizeof(input) - 1u,
                     output,
                     &output_len,
                     md,
                     NULL));
    printf("evp_digest_len=%u\n", output_len);
    printf("evp_digest_prefix=%02x%02x%02x%02x\n",
           output[0], output[1], output[2], output[3]);
  }
EOF
      ;;
    HMAC_Update)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, const unsigned char *, size_t);
    typedef void *(*hmac_ctx_new_fn_t)(void);
    typedef int (*hmac_init_ex_fn_t)(void *, const void *, int, const void *, void *);
    typedef const void *(*evp_sha256_fn_t)(void);
    typedef void (*hmac_ctx_free_fn_t)(void *);
    static const unsigned char key[] = "sidecar-hmac-key";
    static const unsigned char input[] = "sidecar-hmac-update-input";
    void *ctx_new_symbol;
    void *init_symbol;
    void *md_symbol;
    void *free_symbol;
    hmac_ctx_new_fn_t hmac_ctx_new_fn;
    hmac_init_ex_fn_t hmac_init_ex_fn;
    evp_sha256_fn_t evp_sha256_fn;
    hmac_ctx_free_fn_t hmac_ctx_free_fn;
    void *ctx;
    const void *md;
    int init_rc;
    int update_rc;
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;

    dlerror();
    ctx_new_symbol = dlsym(handle, "HMAC_CTX_new");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    init_symbol = dlsym(handle, "HMAC_Init_ex");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    md_symbol = dlsym(handle, "EVP_sha256");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    free_symbol = dlsym(handle, "HMAC_CTX_free");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    hmac_ctx_new_fn = (hmac_ctx_new_fn_t)ctx_new_symbol;
    hmac_init_ex_fn = (hmac_init_ex_fn_t)init_symbol;
    evp_sha256_fn = (evp_sha256_fn_t)md_symbol;
    hmac_ctx_free_fn = (hmac_ctx_free_fn_t)free_symbol;

    ctx = hmac_ctx_new_fn();
    printf("hmac_ctx_ptr=%p\n", ctx);
    if (ctx == NULL) {
      fprintf(stderr, "hmac_ctx_new_failed\n");
      dlclose(handle);
      return 1;
    }

    md = evp_sha256_fn();
    init_rc = hmac_init_ex_fn(ctx, key, (int)(sizeof(key) - 1u), md, NULL);
    printf("hmac_init_rc=%d\n", init_rc);
    update_rc = symbol_fn(ctx, input, sizeof(input) - 1u);
    printf("symbol_call_rc=%d\n", update_rc);

    hmac_ctx_free_fn(ctx);
  }
EOF
      ;;
    HMAC_Final)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, unsigned char *, unsigned int *);
    typedef void *(*hmac_ctx_new_fn_t)(void);
    typedef int (*hmac_init_ex_fn_t)(void *, const void *, int, const void *, void *);
    typedef int (*hmac_update_fn_t)(void *, const unsigned char *, size_t);
    typedef const void *(*evp_sha256_fn_t)(void);
    typedef void (*hmac_ctx_free_fn_t)(void *);
    static const unsigned char key[] = "sidecar-hmac-key";
    static const unsigned char input[] = "sidecar-hmac-final-input";
    unsigned char output[64] = {0};
    unsigned int output_len = 0;
    void *ctx_new_symbol;
    void *init_symbol;
    void *update_symbol;
    void *md_symbol;
    void *free_symbol;
    hmac_ctx_new_fn_t hmac_ctx_new_fn;
    hmac_init_ex_fn_t hmac_init_ex_fn;
    hmac_update_fn_t hmac_update_fn;
    evp_sha256_fn_t evp_sha256_fn;
    hmac_ctx_free_fn_t hmac_ctx_free_fn;
    void *ctx;
    const void *md;
    int init_rc;
    int prep_update_rc;
    int final_rc;
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;

    dlerror();
    ctx_new_symbol = dlsym(handle, "HMAC_CTX_new");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    init_symbol = dlsym(handle, "HMAC_Init_ex");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    update_symbol = dlsym(handle, "HMAC_Update");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    md_symbol = dlsym(handle, "EVP_sha256");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    free_symbol = dlsym(handle, "HMAC_CTX_free");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    hmac_ctx_new_fn = (hmac_ctx_new_fn_t)ctx_new_symbol;
    hmac_init_ex_fn = (hmac_init_ex_fn_t)init_symbol;
    hmac_update_fn = (hmac_update_fn_t)update_symbol;
    evp_sha256_fn = (evp_sha256_fn_t)md_symbol;
    hmac_ctx_free_fn = (hmac_ctx_free_fn_t)free_symbol;

    ctx = hmac_ctx_new_fn();
    printf("hmac_ctx_ptr=%p\n", ctx);
    if (ctx == NULL) {
      fprintf(stderr, "hmac_ctx_new_failed\n");
      dlclose(handle);
      return 1;
    }

    md = evp_sha256_fn();
    init_rc = hmac_init_ex_fn(ctx, key, (int)(sizeof(key) - 1u), md, NULL);
    printf("hmac_init_rc=%d\n", init_rc);
    prep_update_rc = hmac_update_fn(ctx, input, sizeof(input) - 1u);
    printf("hmac_prep_update_rc=%d\n", prep_update_rc);
    final_rc = symbol_fn(ctx, output, &output_len);
    printf("symbol_call_rc=%d\n", final_rc);
    printf("hmac_final_len=%u\n", output_len);
    printf("hmac_final_prefix=%02x%02x%02x%02x\n",
           output[0], output[1], output[2], output[3]);

    hmac_ctx_free_fn(ctx);
  }
EOF
      ;;
    BN_exp)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, const void *, const void *, void *);
    typedef void *(*bn_new_fn_t)(void);
    typedef void (*bn_free_fn_t)(void *);
    typedef int (*bn_set_word_fn_t)(void *, unsigned long);
    typedef void *(*bn_ctx_new_fn_t)(void);
    typedef void (*bn_ctx_free_fn_t)(void *);
    void *bn_new_symbol;
    void *bn_free_symbol;
    void *bn_set_word_symbol;
    void *bn_ctx_new_symbol;
    void *bn_ctx_free_symbol;
    bn_new_fn_t bn_new_fn;
    bn_free_fn_t bn_free_fn;
    bn_set_word_fn_t bn_set_word_fn;
    bn_ctx_new_fn_t bn_ctx_new_fn;
    bn_ctx_free_fn_t bn_ctx_free_fn;
    void *result_bn;
    void *base_bn;
    void *exp_bn;
    void *ctx;
    int set_base_rc;
    int set_exp_rc;
    int exp_rc;
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;

    dlerror();
    bn_new_symbol = dlsym(handle, "BN_new");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    bn_free_symbol = dlsym(handle, "BN_free");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    bn_set_word_symbol = dlsym(handle, "BN_set_word");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    bn_ctx_new_symbol = dlsym(handle, "BN_CTX_new");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    bn_ctx_free_symbol = dlsym(handle, "BN_CTX_free");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    bn_new_fn = (bn_new_fn_t)bn_new_symbol;
    bn_free_fn = (bn_free_fn_t)bn_free_symbol;
    bn_set_word_fn = (bn_set_word_fn_t)bn_set_word_symbol;
    bn_ctx_new_fn = (bn_ctx_new_fn_t)bn_ctx_new_symbol;
    bn_ctx_free_fn = (bn_ctx_free_fn_t)bn_ctx_free_symbol;

    result_bn = bn_new_fn();
    base_bn = bn_new_fn();
    exp_bn = bn_new_fn();
    ctx = bn_ctx_new_fn();
    printf("bn_result_ptr=%p\n", result_bn);
    printf("bn_base_ptr=%p\n", base_bn);
    printf("bn_exp_ptr=%p\n", exp_bn);
    printf("bn_ctx_ptr=%p\n", ctx);
    if (result_bn == NULL || base_bn == NULL || exp_bn == NULL || ctx == NULL) {
      fprintf(stderr, "bn_alloc_failed\n");
      if (ctx != NULL) {
        bn_ctx_free_fn(ctx);
      }
      if (exp_bn != NULL) {
        bn_free_fn(exp_bn);
      }
      if (base_bn != NULL) {
        bn_free_fn(base_bn);
      }
      if (result_bn != NULL) {
        bn_free_fn(result_bn);
      }
      dlclose(handle);
      return 1;
    }

    set_base_rc = bn_set_word_fn(base_bn, 3ul);
    set_exp_rc = bn_set_word_fn(exp_bn, 5ul);
    printf("bn_set_base_rc=%d\n", set_base_rc);
    printf("bn_set_exp_rc=%d\n", set_exp_rc);
    exp_rc = symbol_fn(result_bn, base_bn, exp_bn, ctx);
    printf("symbol_call_rc=%d\n", exp_rc);
    printf("bn_exp_inputs=3^5\n");

    bn_ctx_free_fn(ctx);
    bn_free_fn(exp_bn);
    bn_free_fn(base_bn);
    bn_free_fn(result_bn);
  }
EOF
      ;;
    BN_mod_mul)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, const void *, const void *, const void *, void *);
    typedef void *(*bn_new_fn_t)(void);
    typedef void (*bn_free_fn_t)(void *);
    typedef int (*bn_set_word_fn_t)(void *, unsigned long);
    typedef void *(*bn_ctx_new_fn_t)(void);
    typedef void (*bn_ctx_free_fn_t)(void *);
    void *bn_new_symbol;
    void *bn_free_symbol;
    void *bn_set_word_symbol;
    void *bn_ctx_new_symbol;
    void *bn_ctx_free_symbol;
    bn_new_fn_t bn_new_fn;
    bn_free_fn_t bn_free_fn;
    bn_set_word_fn_t bn_set_word_fn;
    bn_ctx_new_fn_t bn_ctx_new_fn;
    bn_ctx_free_fn_t bn_ctx_free_fn;
    void *result_bn;
    void *a_bn;
    void *b_bn;
    void *mod_bn;
    void *ctx;
    int set_a_rc;
    int set_b_rc;
    int set_mod_rc;
    int mod_mul_rc;
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;

    dlerror();
    bn_new_symbol = dlsym(handle, "BN_new");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    bn_free_symbol = dlsym(handle, "BN_free");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    bn_set_word_symbol = dlsym(handle, "BN_set_word");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    bn_ctx_new_symbol = dlsym(handle, "BN_CTX_new");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    bn_ctx_free_symbol = dlsym(handle, "BN_CTX_free");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    bn_new_fn = (bn_new_fn_t)bn_new_symbol;
    bn_free_fn = (bn_free_fn_t)bn_free_symbol;
    bn_set_word_fn = (bn_set_word_fn_t)bn_set_word_symbol;
    bn_ctx_new_fn = (bn_ctx_new_fn_t)bn_ctx_new_symbol;
    bn_ctx_free_fn = (bn_ctx_free_fn_t)bn_ctx_free_symbol;

    result_bn = bn_new_fn();
    a_bn = bn_new_fn();
    b_bn = bn_new_fn();
    mod_bn = bn_new_fn();
    ctx = bn_ctx_new_fn();
    printf("bn_result_ptr=%p\n", result_bn);
    printf("bn_a_ptr=%p\n", a_bn);
    printf("bn_b_ptr=%p\n", b_bn);
    printf("bn_mod_ptr=%p\n", mod_bn);
    printf("bn_ctx_ptr=%p\n", ctx);
    if (result_bn == NULL || a_bn == NULL || b_bn == NULL || mod_bn == NULL || ctx == NULL) {
      fprintf(stderr, "bn_alloc_failed\n");
      if (ctx != NULL) {
        bn_ctx_free_fn(ctx);
      }
      if (mod_bn != NULL) {
        bn_free_fn(mod_bn);
      }
      if (b_bn != NULL) {
        bn_free_fn(b_bn);
      }
      if (a_bn != NULL) {
        bn_free_fn(a_bn);
      }
      if (result_bn != NULL) {
        bn_free_fn(result_bn);
      }
      dlclose(handle);
      return 1;
    }

    set_a_rc = bn_set_word_fn(a_bn, 6ul);
    set_b_rc = bn_set_word_fn(b_bn, 7ul);
    set_mod_rc = bn_set_word_fn(mod_bn, 11ul);
    printf("bn_set_a_rc=%d\n", set_a_rc);
    printf("bn_set_b_rc=%d\n", set_b_rc);
    printf("bn_set_mod_rc=%d\n", set_mod_rc);
    mod_mul_rc = symbol_fn(result_bn, a_bn, b_bn, mod_bn, ctx);
    printf("symbol_call_rc=%d\n", mod_mul_rc);
    printf("bn_mod_mul_inputs=(6*7)%%11\n");

    bn_ctx_free_fn(ctx);
    bn_free_fn(mod_bn);
    bn_free_fn(b_bn);
    bn_free_fn(a_bn);
    bn_free_fn(result_bn);
  }
EOF
      ;;
    EVP_EncryptInit_ex2)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, const void *, const unsigned char *, const unsigned char *, const void *);
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    printf("symbol_call_rc=%d\n", symbol_fn(NULL, NULL, NULL, NULL, NULL));
  }
EOF
      ;;
    EVP_EncryptUpdate)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, unsigned char *, int *, const unsigned char *, int);
    typedef void *(*evp_cipher_ctx_new_fn_t)(void);
    typedef void (*evp_cipher_ctx_free_fn_t)(void *);
    typedef int (*evp_encrypt_init_ex2_fn_t)(void *, const void *, const unsigned char *, const unsigned char *, const void *);
    typedef int (*evp_encrypt_init_ex_fn_t)(void *, const void *, void *, const unsigned char *, const unsigned char *);
    typedef const void *(*evp_aes_128_cbc_fn_t)(void);
    static const unsigned char key[16] = {
      0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
      0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f
    };
    static const unsigned char iv[16] = {
      0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
      0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf
    };
    static const unsigned char input[16] = {
      0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
      0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f
    };
    unsigned char output[32] = {0};
    void *ctx_new_symbol;
    void *ctx_free_symbol;
    void *init_ex2_symbol;
    void *init_ex_symbol;
    void *cipher_symbol;
    evp_cipher_ctx_new_fn_t evp_cipher_ctx_new_fn;
    evp_cipher_ctx_free_fn_t evp_cipher_ctx_free_fn;
    evp_encrypt_init_ex2_fn_t evp_encrypt_init_ex2_fn;
    evp_encrypt_init_ex_fn_t evp_encrypt_init_ex_fn;
    evp_aes_128_cbc_fn_t evp_aes_128_cbc_fn;
    void *ctx;
    const void *cipher;
    int init_rc = -1;
    int update_rc;
    int out_len = -1;
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;

    dlerror();
    ctx_new_symbol = dlsym(handle, "EVP_CIPHER_CTX_new");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    ctx_free_symbol = dlsym(handle, "EVP_CIPHER_CTX_free");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    dlerror();
    init_ex2_symbol = dlsym(handle, "EVP_EncryptInit_ex2");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        init_ex2_symbol = NULL;
      }
    }

    dlerror();
    init_ex_symbol = dlsym(handle, "EVP_EncryptInit_ex");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        init_ex_symbol = NULL;
      }
    }

    if (init_ex2_symbol == NULL && init_ex_symbol == NULL) {
      fprintf(stderr, "encrypt_init_symbol_missing\n");
      dlclose(handle);
      return 1;
    }

    dlerror();
    cipher_symbol = dlsym(handle, "EVP_aes_128_cbc");
    {
      const char *error_text = dlerror();
      if (error_text != NULL) {
        fprintf(stderr, "dlsym_failed=%s\n", error_text);
        dlclose(handle);
        return 1;
      }
    }

    evp_cipher_ctx_new_fn = (evp_cipher_ctx_new_fn_t)ctx_new_symbol;
    evp_cipher_ctx_free_fn = (evp_cipher_ctx_free_fn_t)ctx_free_symbol;
    evp_encrypt_init_ex2_fn = (evp_encrypt_init_ex2_fn_t)init_ex2_symbol;
    evp_encrypt_init_ex_fn = (evp_encrypt_init_ex_fn_t)init_ex_symbol;
    evp_aes_128_cbc_fn = (evp_aes_128_cbc_fn_t)cipher_symbol;

    ctx = evp_cipher_ctx_new_fn();
    printf("evp_cipher_ctx_ptr=%p\n", ctx);
    if (ctx == NULL) {
      fprintf(stderr, "evp_cipher_ctx_new_failed\n");
      dlclose(handle);
      return 1;
    }

    cipher = evp_aes_128_cbc_fn();
    printf("evp_cipher_ptr=%p\n", cipher);
    if (cipher == NULL) {
      fprintf(stderr, "evp_cipher_lookup_failed\n");
      evp_cipher_ctx_free_fn(ctx);
      dlclose(handle);
      return 1;
    }

    if (evp_encrypt_init_ex2_fn != NULL) {
      init_rc = evp_encrypt_init_ex2_fn(ctx, cipher, key, iv, NULL);
      printf("evp_encrypt_init_variant=ex2\n");
    } else {
      init_rc = evp_encrypt_init_ex_fn(ctx, cipher, NULL, key, iv);
      printf("evp_encrypt_init_variant=ex\n");
    }
    printf("evp_encrypt_init_rc=%d\n", init_rc);

    update_rc = symbol_fn(ctx, output, &out_len, input, (int)sizeof(input));
    printf("symbol_call_rc=%d\n", update_rc);
    printf("evp_encrypt_update_out_len=%d\n", out_len);
    printf("evp_encrypt_update_prefix=%02x%02x%02x%02x\n",
           output[0], output[1], output[2], output[3]);

    evp_cipher_ctx_free_fn(ctx);
  }
EOF
      ;;
    PKCS7_sign)
      cat <<'EOF'
  {
    typedef void *(*symbol_fn_t)(void *, void *, void *, void *, int);
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    printf("symbol_call_ptr=%p\n", symbol_fn(NULL, NULL, NULL, NULL, 0));
  }
EOF
      ;;
    PKCS7_set_type)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, int);
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    printf("symbol_call_rc=%d\n", symbol_fn(NULL, 0));
  }
EOF
      ;;
    PKCS12_init_ex)
      cat <<'EOF'
  {
    typedef void *(*symbol_fn_t)(int, const char *, int, void *, const char *);
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    printf("symbol_call_ptr=%p\n", symbol_fn(0, NULL, 0, NULL, NULL));
  }
EOF
      ;;
    BN_mod_sqr)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, const void *, const void *, void *);
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    printf("symbol_call_rc=%d\n", symbol_fn(NULL, NULL, NULL, NULL));
  }
EOF
      ;;
    BN_div)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, void *, const void *, const void *, void *);
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    printf("symbol_call_rc=%d\n", symbol_fn(NULL, NULL, NULL, NULL, NULL));
  }
EOF
      ;;
    RSA_size|RSA_bits)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(const void *);
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    printf("symbol_call_rc=%d\n", symbol_fn(NULL));
  }
EOF
      ;;
    BIO_read)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, void *, int);
    unsigned char scratch[1] = {0};
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    printf("symbol_call_rc=%d\n", symbol_fn(NULL, scratch, 0));
  }
EOF
      ;;
    BIO_write_ex)
      cat <<'EOF'
  {
    typedef int (*symbol_fn_t)(void *, const void *, size_t, size_t *);
    size_t written = 0;
    static const unsigned char scratch[] = "";
    symbol_fn_t symbol_fn = (symbol_fn_t)symbol;
    printf("symbol_call_rc=%d\n", symbol_fn(NULL, scratch, 0u, &written));
    printf("symbol_call_written=%zu\n", written);
  }
EOF
      ;;
    *)
      die "symbol not supported for libcrypto sidecar capture: $1"
      ;;
  esac
}

jsonl_stats() {
  local jsonl_path="$1"
  python3 - "$jsonl_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
tb = op = temp = 0
for line in path.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        continue
    kind = rec.get("record")
    if kind == "tb":
        tb += 1
    elif kind == "op":
        op += 1
    elif kind == "temp":
        temp += 1
print(f"{tb} {op} {temp}")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-root)
      SCRATCH_ROOT="$(abs_path "${2:?missing value for --scratch-root}")"
      shift 2
      ;;
    --binary)
      BINARY_PATH="$(abs_path "${2:?missing value for --binary}")"
      shift 2
      ;;
    --symbol)
      SYMBOL_NAME="${2:?missing value for --symbol}"
      shift 2
      ;;
    --entry)
      ENTRY_HEX="${2:?missing value for --entry}"
      shift 2
      ;;
    --runnable-base)
      RUNNABLE_BASE="${2:?missing value for --runnable-base}"
      shift 2
      ;;
    --walker-root)
      WALKER_ROOT="$(abs_path "${2:?missing value for --walker-root}")"
      shift 2
      ;;
    --qemu-bin)
      QEMU_BIN_OVERRIDE="$(abs_path "${2:?missing value for --qemu-bin}")"
      shift 2
      ;;
    --qemu-cpu)
      QEMU_CPU_MODEL="${2:?missing value for --qemu-cpu}"
      shift 2
      ;;
    --fresh)
      FRESH=1
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

[[ -n "$BINARY_PATH" ]] || die "--binary is required"

SYMBOL_SHORT_NAME="${SYMBOL_NAME%%@@*}"
SYMBOL_LABEL="$(sanitize_label_component "$SYMBOL_SHORT_NAME")"
[[ -n "$SYMBOL_LABEL" ]] || die "failed to derive symbol label from: $SYMBOL_NAME"

if [[ -z "$SCRATCH_ROOT" ]]; then
  SCRATCH_ROOT="/tmp/rr-qemu-v2-libcrypto-sidecar-$SYMBOL_LABEL"
fi
SCRATCH_ROOT="$(abs_path "$SCRATCH_ROOT")"
BINARY_PATH="$(abs_path "$BINARY_PATH")"
if [[ -n "$WALKER_ROOT" ]]; then
  WALKER_ROOT="$(abs_path "$WALKER_ROOT")"
else
  WALKER_ROOT="$SCRATCH_ROOT/walker"
fi
if [[ -n "$QEMU_BIN_OVERRIDE" ]]; then
  QEMU_BIN_OVERRIDE="$(abs_path "$QEMU_BIN_OVERRIDE")"
fi

[[ -f "$BINARY_PATH" ]] || die "binary not found: $BINARY_PATH"
[[ -f "$MATERIALIZER_SCRIPT" ]] || die "sidecar materializer not found: $MATERIALIZER_SCRIPT"

require_tool cc
require_tool bash
require_tool python3
require_tool setarch
require_tool tee
require_tool sed
require_tool grep
require_tool wc

if [[ -z "$ENTRY_HEX" ]]; then
  ENTRY_HEX="$(resolve_symbol_entry "$BINARY_PATH" "$SYMBOL_NAME")"
fi

if [[ "$FRESH" -eq 1 ]]; then
  rm -rf "$SCRATCH_ROOT"
fi
mkdir -p "$SCRATCH_ROOT"

STAGED_LIB="$SCRATCH_ROOT/libcrypto.so.3"
HARNESS_C="$SCRATCH_ROOT/libcrypto_${SYMBOL_LABEL}_harness.c"
HARNESS_BIN="$SCRATCH_ROOT/libcrypto_${SYMBOL_LABEL}_harness"
HARNESS_LOG="$SCRATCH_ROOT/libcrypto_${SYMBOL_LABEL}_harness.log"
WALKER_JSONL="$SCRATCH_ROOT/walker/${SYMBOL_LABEL}.tcg-op-walk.jsonl"
WALKER_LOG1="$SCRATCH_ROOT/walker/${SYMBOL_LABEL}.entry.run.log"
WALKER_LOG2="$SCRATCH_ROOT/walker/${SYMBOL_LABEL}.actual.run.log"
WALKER_EXIT1="$SCRATCH_ROOT/walker/${SYMBOL_LABEL}.entry.exit-code"
WALKER_EXIT2="$SCRATCH_ROOT/walker/${SYMBOL_LABEL}.actual.exit-code"
RUN_SUMMARY="$SCRATCH_ROOT/qemu_${SYMBOL_LABEL}_capture.summary.txt"
MANIFEST_JSON="$SCRATCH_ROOT/walker/${SYMBOL_LABEL}.ptc-v2-manifest.json"
MANIFEST_HEADER="$SCRATCH_ROOT/walker/${SYMBOL_LABEL}.ptc-v2-manifest.h"
MODEL_JSON="$SCRATCH_ROOT/walker/${SYMBOL_LABEL}.walker.model.json"
INVENTORY_JSON="$SCRATCH_ROOT/walker/${SYMBOL_LABEL}.derived.ptc-inventory.json"
SIDECAR_PAYLOAD="$SCRATCH_ROOT/sidecar/sidecar.payload.txt"
SIDECAR_MODEL="$SCRATCH_ROOT/sidecar/sidecar.model.json"
SIDECAR_SUMMARY="$SCRATCH_ROOT/sidecar/sidecar.summary.json"

log "Staging libcrypto.so.3"
cp -f "$BINARY_PATH" "$STAGED_LIB"

CALL_SNIPPET="$(emit_call_snippet "$SYMBOL_SHORT_NAME")"

log "Writing $SYMBOL_SHORT_NAME harness"
cat >"$HARNESS_C" <<EOF
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>

int main(void) {
  void *handle;
  void *symbol;

  printf("expected_entry=%s\n", "${ENTRY_HEX}");
  printf("runnable_base=%s\n", "${RUNNABLE_BASE}");
  printf("requested_symbol=%s\n", "${SYMBOL_NAME}");

  handle = dlopen("./libcrypto.so.3", RTLD_NOW);
  if (handle == NULL) {
    fprintf(stderr, "dlopen_failed=%s\n", dlerror());
    return 1;
  }

  dlerror();
  symbol = dlsym(handle, "${SYMBOL_SHORT_NAME}");
  {
    const char *error_text = dlerror();
    if (error_text != NULL) {
      fprintf(stderr, "dlsym_failed=%s\n", error_text);
      dlclose(handle);
      return 1;
    }
  }

  printf("symbol_addr=%p\n", symbol);
  fflush(stdout);

${CALL_SNIPPET}
  printf("symbol_call_attempted=1\n");
  fflush(stdout);

  dlclose(handle);
  return 0;
}
EOF

log "Compiling harness"
cc -O2 -Wall -Wextra -o "$HARNESS_BIN" "$HARNESS_C" -ldl

log "Running harness natively"
set +e
(
  cd "$SCRATCH_ROOT"
  "./$(basename "$HARNESS_BIN")"
) | tee "$HARNESS_LOG"
NATIVE_HARNESS_RC=${PIPESTATUS[0]}
set -e

if [[ -n "$QEMU_BIN_OVERRIDE" ]]; then
  [[ -x "$QEMU_BIN_OVERRIDE" ]] || die "patched QEMU binary missing or not executable: $QEMU_BIN_OVERRIDE"
  QEMU_BIN="$QEMU_BIN_OVERRIDE"
else
  log "Building or reusing patched walker QEMU"
  bash "$SCRIPT_DIR/qemu_v2_ptc_tcg_op_walker_probe.sh" \
    --scratch-root "$WALKER_ROOT" \
    --build-only
  QEMU_BIN="$WALKER_ROOT/build-10.2.3-ptc-tcg-op-walker/qemu-x86_64"
fi
[[ -x "$QEMU_BIN" ]] || die "patched QEMU binary not found: $QEMU_BIN"

mkdir -p "$(dirname "$WALKER_JSONL")"
rm -f "$WALKER_JSONL" "$WALKER_LOG1" "$WALKER_LOG2" "$WALKER_EXIT1" "$WALKER_EXIT2" \
  "$MANIFEST_JSON" "$MANIFEST_HEADER" "$MODEL_JSON" "$INVENTORY_JSON" \
  "$SIDECAR_PAYLOAD" "$SIDECAR_MODEL" "$SIDECAR_SUMMARY"

run_qemu_capture() {
  local pc="$1"
  local run_log="$2"
  local exit_code_file="$3"

  log "Running harness under patched QEMU with RR_PTC_OP_WALK_PC=$pc"
  set +e
  (
    cd "$SCRATCH_ROOT"
    ulimit -c 0
    RR_PTC_OP_WALK_DUMP="$WALKER_JSONL" \
    RR_PTC_OP_WALK_PC="$pc" \
      setarch x86_64 -R "$QEMU_BIN" -cpu "$QEMU_CPU_MODEL" "./$(basename "$HARNESS_BIN")"
  ) >"$run_log" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$exit_code_file"
}

run_qemu_capture "$ENTRY_HEX" "$WALKER_LOG1" "$WALKER_EXIT1"

QEMU_SYMBOL_ADDR="$(extract_sha1_addr "$WALKER_LOG1" || true)"
[[ -n "$QEMU_SYMBOL_ADDR" ]] || die "failed to parse symbol_addr from QEMU run log: $WALKER_LOG1"

ACTUAL_WALK_PC="$ENTRY_HEX"
SECOND_RUN_REASON=""
if [[ "$QEMU_SYMBOL_ADDR" != "$ENTRY_HEX" ]]; then
  SECOND_RUN_REASON="QEMU-reported symbol_addr differs from requested entry"
  rm -f "$WALKER_JSONL"
  run_qemu_capture "$QEMU_SYMBOL_ADDR" "$WALKER_LOG2" "$WALKER_EXIT2"
  ACTUAL_WALK_PC="$QEMU_SYMBOL_ADDR"
fi

if [[ -s "$WALKER_JSONL" ]]; then
  read -r TB_LINES OP_LINES TEMP_LINES < <(jsonl_stats "$WALKER_JSONL")
else
  TB_LINES=0
  OP_LINES=0
  TEMP_LINES=0
fi

FIRST_LOG="$WALKER_LOG1"
SECOND_LOG_VALUE="${WALKER_LOG2:-}"
FIRST_RC="$(cat "$WALKER_EXIT1")"
SECOND_RC=""
if [[ -f "$WALKER_EXIT2" ]]; then
  SECOND_RC="$(cat "$WALKER_EXIT2")"
fi

{
  printf 'patched_qemu=%s\n' "$QEMU_BIN"
  printf 'native_harness_log=%s\n' "$HARNESS_LOG"
  printf 'native_harness_rc=%s\n' "$NATIVE_HARNESS_RC"
  printf 'qemu_first_log=%s\n' "$WALKER_LOG1"
  printf 'qemu_second_log=%s\n' "${SECOND_LOG_VALUE:-}"
  printf 'requested_walk_pc=%s\n' "$ENTRY_HEX"
  printf 'actual_symbol_addr=%s\n' "$QEMU_SYMBOL_ADDR"
  printf 'used_walk_pc=%s\n' "$ACTUAL_WALK_PC"
  printf 'first_qemu_rc=%s\n' "$FIRST_RC"
  printf 'second_qemu_rc=%s\n' "${SECOND_RC:-}"
  printf 'jsonl_path=%s\n' "$WALKER_JSONL"
  printf 'jsonl_exists=%s\n' "$([[ -s "$WALKER_JSONL" ]] && echo true || echo false)"
  printf 'jsonl_tb_lines=%s\n' "$TB_LINES"
  printf 'jsonl_op_lines=%s\n' "$OP_LINES"
  printf 'jsonl_temp_lines=%s\n' "$TEMP_LINES"
  if [[ -n "$SECOND_RUN_REASON" ]]; then
    printf 'second_run_reason=%s\n' "$SECOND_RUN_REASON"
  fi
} >"$RUN_SUMMARY"

if [[ -s "$WALKER_JSONL" ]]; then
  log "Walker JSONL produced at $WALKER_JSONL"
  python3 "$SCRIPT_DIR/qemu_v2_ptc_v2_manifest.py" \
    --inventory "$INVENTORY_JSON" \
    --walker-jsonl "$WALKER_JSONL" \
    --source-filter walker-jsonl \
    --tmp-dir "$SCRATCH_ROOT/walker/manifest-tmp" \
    --json-out "$MANIFEST_JSON" \
    --header-out "$MANIFEST_HEADER"
  python3 "$SCRIPT_DIR/qemu_v2_ptc_convert_walker_jsonl.py" \
    --walker-jsonl "$WALKER_JSONL" \
    --manifest "$MANIFEST_JSON" \
    --json-out "$MODEL_JSON"
fi

[[ -s "$WALKER_JSONL" ]] || die "walker JSONL not produced for $SYMBOL_NAME: $WALKER_JSONL"
[[ -f "$MODEL_JSON" ]] || die "walker model not produced for $SYMBOL_NAME: $MODEL_JSON"
[[ -f "$MANIFEST_JSON" ]] || die "walker manifest not produced for $SYMBOL_NAME: $MANIFEST_JSON"

python3 "$MATERIALIZER_SCRIPT" \
  --model-json "$MODEL_JSON" \
  --manifest-json "$MANIFEST_JSON" \
  --output-root "$SCRATCH_ROOT" \
  --captured-pc "$ACTUAL_WALK_PC" \
  --canonical-pc "$ENTRY_HEX" \
  --normalize-debug-pc

[[ -f "$SIDECAR_PAYLOAD" ]] || die "sidecar payload not produced: $SIDECAR_PAYLOAD"
[[ -f "$SIDECAR_MODEL" ]] || die "sidecar model not produced: $SIDECAR_MODEL"
[[ -f "$SIDECAR_SUMMARY" ]] || die "sidecar summary not produced: $SIDECAR_SUMMARY"

{
  printf 'sidecar_payload=%s\n' "$SIDECAR_PAYLOAD"
  printf 'sidecar_model=%s\n' "$SIDECAR_MODEL"
  printf 'sidecar_summary=%s\n' "$SIDECAR_SUMMARY"
} >>"$RUN_SUMMARY"

log "Capture summary written to $RUN_SUMMARY"
printf 'sidecar_root=%s\n' "$SCRATCH_ROOT"
printf 'sidecar_payload=%s\n' "$SIDECAR_PAYLOAD"
printf 'sidecar_model=%s\n' "$SIDECAR_MODEL"
printf 'sidecar_summary=%s\n' "$SIDECAR_SUMMARY"
