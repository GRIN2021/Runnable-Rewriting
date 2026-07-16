#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RR_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
SUBSET_SCRIPT="$SCRIPT_DIR/qemu_v2_ptc_libcrypto_canonical_subset.sh"
SCRATCH_ROOT="${RUNNABLE_QEMU_V2_LIBCRYPTO_SWEEP_SCRATCH_ROOT:-/tmp/rr-qemu-v2-libcrypto-canonical-sweep}"
LABEL_PREFIX="${RUNNABLE_QEMU_V2_LIBCRYPTO_SWEEP_LABEL_PREFIX:-sweep}"
SYMBOL_FILE=""
PROFILE_NAME=""
SUMMARY_BASENAME="qemu_v2_ptc_libcrypto_canonical_sweep"

declare -a SYMBOL_SPECS=()
declare -a PASSTHROUGH_ARGS=()
declare -a STATIC_FALLBACK_PROFILES=()
declare -a STATIC_FALLBACK_SYMBOL_REGEXES=()

usage() {
  cat <<'EOF'
Usage:
  qemu_v2_ptc_libcrypto_canonical_sweep.sh [options] [-- subset-args...]

Options:
  --scratch-root DIR
  --label-prefix NAME
  --symbol NAME
  --symbol-spec LABEL=SYMBOL
  --symbol-file PATH
  --profile NAME
  --runnable-lift PATH
  --libtinycode PATH
  --helpers PATH
  --early-linked PATH
  --live-sidecar-root DIR
  --force-bionic-rebuild MODE
  --binary PATH
  --timeout-sec N
  --parallel-workers N
  --keep-worker-fragments
  --static-fallback-profile PROFILE
  --static-fallback-symbol-regex REGEX
  --skip-cmp
  -h, --help

Profiles:
  broad-mini
    RSA_size, RSA_bits, BIO_read
  next-family
    HMAC_Update, HMAC_Final, BN_exp, BN_mod_mul,
    PKCS5_PBKDF2_HMAC, EVP_Digest, EVP_EncryptUpdate
  broad-family
    EVP_DigestInit_ex, EVP_DigestInit, EVP_EncryptInit_ex2,
    EVP_MD_CTX_copy_ex, PKCS7_sign, PKCS7_set_type, PKCS12_init_ex,
    BN_mod_sqr, BN_div, RSA_size, RSA_bits, BIO_read, BIO_write_ex

Symbol file format:
  One entry per line. Blank lines and lines starting with '#' are ignored.
  Supported forms:
    SYMBOL
    LABEL=SYMBOL
    LABEL<TAB>SYMBOL

All args after '--' are forwarded to
qemu_v2_ptc_libcrypto_canonical_subset.sh.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$PWD" "$input"
  fi
}

sanitize_label_component() {
  local raw="$1"
  printf '%s' "$raw" | tr '@[:upper:]' '-[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

append_profile_symbols() {
  case "$1" in
    broad-mini)
      SYMBOL_SPECS+=(
        "rsa-size=RSA_size@@OPENSSL_3.0.0"
        "rsa-bits=RSA_bits@@OPENSSL_3.0.0"
        "bio-read=BIO_read@@OPENSSL_3.0.0"
      )
      ;;
    next-family)
      SYMBOL_SPECS+=(
        "hmac-update=HMAC_Update@@OPENSSL_3.0.0"
        "hmac-final=HMAC_Final@@OPENSSL_3.0.0"
        "bn-exp=BN_exp@@OPENSSL_3.0.0"
        "bn-mod-mul=BN_mod_mul@@OPENSSL_3.0.0"
        "pkcs5-pbkdf2-hmac=PKCS5_PBKDF2_HMAC@@OPENSSL_3.0.0"
        "evp-digest=EVP_Digest@@OPENSSL_3.0.0"
        "evp-encrypt-update=EVP_EncryptUpdate@@OPENSSL_3.0.0"
      )
      ;;
    broad-family)
      SYMBOL_SPECS+=(
        "evp-digest-init-ex=EVP_DigestInit_ex@@OPENSSL_3.0.0"
        "evp-digest-init=EVP_DigestInit@@OPENSSL_3.0.0"
        "evp-encrypt-init-ex2=EVP_EncryptInit_ex2@@OPENSSL_3.0.0"
        "evp-md-ctx-copy-ex=EVP_MD_CTX_copy_ex@@OPENSSL_3.0.0"
        "pkcs7-sign=PKCS7_sign@@OPENSSL_3.0.0"
        "pkcs7-set-type=PKCS7_set_type@@OPENSSL_3.0.0"
        "pkcs12-init-ex=PKCS12_init_ex@@OPENSSL_3.0.0"
        "bn-mod-sqr=BN_mod_sqr@@OPENSSL_3.0.0"
        "bn-div=BN_div@@OPENSSL_3.0.0"
        "rsa-size=RSA_size@@OPENSSL_3.0.0"
        "rsa-bits=RSA_bits@@OPENSSL_3.0.0"
        "bio-read=BIO_read@@OPENSSL_3.0.0"
        "bio-write-ex=BIO_write_ex@@OPENSSL_3.0.0"
      )
      ;;
    *)
      die "unknown --profile: $1"
      ;;
  esac
}

load_symbol_file() {
  local path="$1"
  [[ -f "$path" ]] || die "symbol file not found: $path"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" == *$'\t'* ]]; then
      local label="${line%%$'\t'*}"
      local symbol="${line#*$'\t'}"
      SYMBOL_SPECS+=("${label}=${symbol}")
    else
      SYMBOL_SPECS+=("$line")
    fi
  done < "$path"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-root)
      SCRATCH_ROOT="$(abs_path "${2:?missing value for --scratch-root}")"
      shift 2
      ;;
    --label-prefix)
      LABEL_PREFIX="${2:?missing value for --label-prefix}"
      shift 2
      ;;
    --symbol)
      SYMBOL_SPECS+=("${2:?missing value for --symbol}")
      shift 2
      ;;
    --symbol-spec)
      SYMBOL_SPECS+=("${2:?missing value for --symbol-spec}")
      shift 2
      ;;
    --symbol-file)
      SYMBOL_FILE="$(abs_path "${2:?missing value for --symbol-file}")"
      shift 2
      ;;
    --profile)
      PROFILE_NAME="${2:?missing value for --profile}"
      shift 2
      ;;
    --runnable-lift|--libtinycode|--helpers|--early-linked|--live-sidecar-root|--force-bionic-rebuild|--binary|--timeout-sec|--parallel-workers)
      PASSTHROUGH_ARGS+=("$1" "${2:?missing value for $1}")
      shift 2
      ;;
    --static-fallback-profile)
      STATIC_FALLBACK_PROFILES+=("${2:?missing value for --static-fallback-profile}")
      PASSTHROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --static-fallback-symbol-regex)
      STATIC_FALLBACK_SYMBOL_REGEXES+=("${2:?missing value for --static-fallback-symbol-regex}")
      PASSTHROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --keep-worker-fragments|--skip-cmp)
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --)
      shift
      PASSTHROUGH_ARGS+=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -x "$SUBSET_SCRIPT" ]] || die "subset script is not executable: $SUBSET_SCRIPT"
mkdir -p "$SCRATCH_ROOT"

if [[ -n "$PROFILE_NAME" ]]; then
  append_profile_symbols "$PROFILE_NAME"
fi

if [[ -n "$SYMBOL_FILE" ]]; then
  load_symbol_file "$SYMBOL_FILE"
fi

[[ "${#SYMBOL_SPECS[@]}" -gt 0 ]] || die "no symbols specified"

RUN_ROOT="$SCRATCH_ROOT/$LABEL_PREFIX"
ITEM_ROOT="$RUN_ROOT/items"
SUBSET_SCRATCH_ROOT="$RUN_ROOT/subset-runs"
mkdir -p "$ITEM_ROOT"

declare -a ITEM_JSONS=()

for spec in "${SYMBOL_SPECS[@]}"; do
  symbol="$spec"
  label_suffix=""
  if [[ "$spec" == *=* ]]; then
    label_suffix="${spec%%=*}"
    symbol="${spec#*=}"
  fi
  if [[ -z "$label_suffix" || "$label_suffix" == "$symbol" ]]; then
    label_suffix="$(sanitize_label_component "${symbol%%@@*}")"
  fi
  item_label="${LABEL_PREFIX}-${label_suffix}"
  item_dir="$ITEM_ROOT/$item_label"
  mkdir -p "$item_dir"

  stdout_path="$item_dir/subset.stdout"
  stderr_path="$item_dir/subset.stderr"
  wrapper_json="$item_dir/result.json"
  subset_summary="$SUBSET_SCRATCH_ROOT/$item_label/qemu_v2_ptc_libcrypto_canonical_subset.summary.json"

  set +e
  bash "$SUBSET_SCRIPT" \
    --scratch-root "$SUBSET_SCRATCH_ROOT" \
    --label "$item_label" \
    --symbol "$symbol" \
    "${PASSTHROUGH_ARGS[@]}" \
    >"$stdout_path" 2>"$stderr_path"
  subset_rc=$?
  set -e

  python3 - "$wrapper_json" "$item_label" "$symbol" "$subset_rc" "$subset_summary" "$stdout_path" "$stderr_path" <<'PY'
import json
import sys
from pathlib import Path

out_path = Path(sys.argv[1])
label = sys.argv[2]
symbol = sys.argv[3]
subset_rc = int(sys.argv[4])
subset_summary = Path(sys.argv[5])
stdout_path = Path(sys.argv[6])
stderr_path = Path(sys.argv[7])

payload = {
    "label": label,
    "symbol": symbol,
    "subset_rc": subset_rc,
    "subset_summary_json": str(subset_summary),
    "stdout_path": str(stdout_path),
    "stderr_path": str(stderr_path),
}

if subset_summary.is_file():
    subset_payload = json.loads(subset_summary.read_text(encoding="utf-8"))
    payload.update(
        {
            "entry": subset_payload.get("entry"),
            "result": subset_payload.get("result"),
            "failure_class": subset_payload.get("failure_class"),
            "blocker_code": subset_payload.get("blocker_code"),
            "lift_rc": subset_payload.get("lift_rc"),
            "cmp_rc": subset_payload.get("cmp_rc"),
            "cmp_json": subset_payload.get("cmp_json"),
            "cmp_verdict": subset_payload.get("cmp_verdict"),
            "cmp_verdict_ok": subset_payload.get("cmp_verdict_ok"),
            "run_dir": subset_payload.get("run_dir"),
            "eval_dir": subset_payload.get("eval_dir"),
            "static_fallback_profiles": subset_payload.get("static_fallback_profiles"),
            "static_fallback_symbol_regexes": subset_payload.get("static_fallback_symbol_regexes"),
            "static_fallback": subset_payload.get("static_fallback"),
        }
    )
else:
    stderr_text = stderr_path.read_text(encoding="utf-8", errors="replace").strip()
    payload.update(
        {
            "entry": None,
            "result": "failed",
            "failure_class": "subset-script-failed",
            "blocker_code": stderr_text.splitlines()[-1] if stderr_text else "subset-script-failed",
            "lift_rc": None,
            "cmp_rc": None,
            "cmp_json": None,
            "cmp_verdict": None,
            "run_dir": None,
            "eval_dir": None,
        }
    )

payload["status"] = "PASS" if payload["result"] == "passed" else "FAIL"
out_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(payload, sort_keys=True))
PY

  ITEM_JSONS+=("$wrapper_json")
done

SUMMARY_JSON="$RUN_ROOT/${SUMMARY_BASENAME}.summary.json"
SUMMARY_TABLE="$RUN_ROOT/${SUMMARY_BASENAME}.table.md"
PASSTHROUGH_ARGS_FILE="$RUN_ROOT/.passthrough_args"
STATIC_FALLBACK_PROFILES_FILE="$RUN_ROOT/.static_fallback_profiles"
STATIC_FALLBACK_SYMBOL_REGEXES_FILE="$RUN_ROOT/.static_fallback_symbol_regexes"

printf '%s\n' "${PASSTHROUGH_ARGS[@]}" > "$PASSTHROUGH_ARGS_FILE"
printf '%s\n' "${STATIC_FALLBACK_PROFILES[@]}" > "$STATIC_FALLBACK_PROFILES_FILE"
printf '%s\n' "${STATIC_FALLBACK_SYMBOL_REGEXES[@]}" > "$STATIC_FALLBACK_SYMBOL_REGEXES_FILE"

python3 - "$SUMMARY_JSON" "$SUMMARY_TABLE" "$LABEL_PREFIX" "$PASSTHROUGH_ARGS_FILE" "$STATIC_FALLBACK_PROFILES_FILE" "$STATIC_FALLBACK_SYMBOL_REGEXES_FILE" "${ITEM_JSONS[@]}" <<'PY'
import json
from collections import Counter
import sys
from pathlib import Path

summary_json = Path(sys.argv[1])
summary_table = Path(sys.argv[2])
label_prefix = sys.argv[3]
passthrough_args_path = Path(sys.argv[4])
static_fallback_profiles_path = Path(sys.argv[5])
static_fallback_symbol_regexes_path = Path(sys.argv[6])
item_paths = [Path(p) for p in sys.argv[7:]]


def read_lines(path):
    if not path.is_file():
        return []
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def parse_cmp_verdict(verdict_path_str):
    if not verdict_path_str:
        return None, None
    verdict_path = Path(verdict_path_str)
    if not verdict_path.is_file():
        return None, None
    ok_value = None
    reasons = []
    in_reasons = False
    for raw_line in verdict_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("ok:"):
            ok_token = line.split(":", 1)[1].strip().lower()
            if ok_token == "true":
                ok_value = True
            elif ok_token == "false":
                ok_value = False
        elif line == "[reasons]":
            in_reasons = True
        elif in_reasons:
            reasons.append(line)
    return ok_value, reasons


def load_cmp_payload(cmp_json_path_str):
    if not cmp_json_path_str:
        return None
    cmp_json_path = Path(cmp_json_path_str)
    if not cmp_json_path.is_file():
        return None
    return json.loads(cmp_json_path.read_text(encoding="utf-8"))


def classify_effective_outcome(item):
    raw_result = item.get("result")
    raw_failure_class = item.get("failure_class")
    raw_blocker_code = item.get("blocker_code")
    cmp_rc = item.get("cmp_rc")
    cmp_verdict_ok = item.get("cmp_verdict_ok")

    effective_result = "passed" if raw_result == "passed" else "failed"
    effective_failure_class = raw_failure_class
    effective_blocker_code = raw_blocker_code

    if effective_result != "passed":
        return effective_result, effective_failure_class, effective_blocker_code

    # Passing wrapper/lift return codes are not sufficient; a failed or missing
    # compare verdict must downgrade the item outcome.
    if cmp_rc is None:
        return "failed", "cmp-missing", raw_blocker_code or "blocked:cmp-missing"
    try:
        cmp_rc_int = int(cmp_rc)
    except (TypeError, ValueError):
        cmp_rc_int = None
    if cmp_rc_int not in (None, 0):
        return "failed", "cmp-failed", raw_blocker_code or "blocked:canonical-cmp-failed"
    if cmp_verdict_ok is False:
        return "failed", "cmp-verdict-failed", raw_blocker_code or "blocked:cmp-verdict-failed"
    if cmp_verdict_ok is None:
        return "failed", "cmp-verdict-missing", raw_blocker_code or "blocked:cmp-verdict-missing"
    return effective_result, effective_failure_class, effective_blocker_code


items = []
for path in item_paths:
    item = json.loads(path.read_text(encoding="utf-8"))
    cmp_payload = load_cmp_payload(item.get("cmp_json"))
    verdict_ok, verdict_reasons = parse_cmp_verdict(item.get("cmp_verdict"))
    if verdict_ok is None and item.get("cmp_verdict_ok") is not None:
        verdict_ok = item.get("cmp_verdict_ok")
    item["cmp_verdict_ok"] = verdict_ok
    item["cmp_verdict_reasons"] = verdict_reasons
    if cmp_payload is not None:
        cmp_static_fallback = cmp_payload.get("static_fallback")
        item["cmp_metrics"] = {
            "precision": cmp_payload.get("precision"),
            "recall": cmp_payload.get("recall"),
            "hit": cmp_payload.get("hit"),
            "ll_count": cmp_payload.get("ll_count"),
            "obj_count": cmp_payload.get("obj_count"),
            "false_positive": cmp_payload.get("false_positive"),
            "false_negative": cmp_payload.get("false_negative"),
            "mismatch": cmp_payload.get("mismatch"),
            "static_fallback": cmp_static_fallback,
        }
        item["static_fallback"] = cmp_static_fallback
    else:
        item["cmp_metrics"] = None
    item["raw_result"] = item.get("result")
    item["raw_status"] = item.get("status")
    item["raw_failure_class"] = item.get("failure_class")
    item["raw_blocker_code"] = item.get("blocker_code")
    item["result"], item["failure_class"], item["blocker_code"] = classify_effective_outcome(item)
    item["status"] = "PASS" if item["result"] == "passed" else "FAIL"
    items.append(item)

pass_count = sum(1 for item in items if item["status"] == "PASS")
fail_count = len(items) - pass_count

cmp_rc_counts = Counter(str(item.get("cmp_rc")) if item.get("cmp_rc") is not None else "null" for item in items)
lift_rc_counts = Counter(str(item.get("lift_rc")) if item.get("lift_rc") is not None else "null" for item in items)
failure_class_counts = Counter(item.get("failure_class") or "null" for item in items)
blocker_code_counts = Counter(item.get("blocker_code") or "null" for item in items)
verdict_counts = Counter(
    "true" if item.get("cmp_verdict_ok") is True else
    "false" if item.get("cmp_verdict_ok") is False else
    "unknown"
    for item in items
)

cmp_metric_items = [item["cmp_metrics"] for item in items if item.get("cmp_metrics")]
cmp_metric_summary = None
if cmp_metric_items:
    cmp_metric_summary = {
        "cmp_json_count": len(cmp_metric_items),
        "precision_avg": sum(float(m["precision"]) for m in cmp_metric_items) / len(cmp_metric_items),
        "precision_min": min(float(m["precision"]) for m in cmp_metric_items),
        "precision_max": max(float(m["precision"]) for m in cmp_metric_items),
        "recall_avg": sum(float(m["recall"]) for m in cmp_metric_items) / len(cmp_metric_items),
        "recall_min": min(float(m["recall"]) for m in cmp_metric_items),
        "recall_max": max(float(m["recall"]) for m in cmp_metric_items),
        "hit_sum": sum(int(m["hit"]) for m in cmp_metric_items),
        "ll_count_sum": sum(int(m["ll_count"]) for m in cmp_metric_items),
        "obj_count_sum": sum(int(m["obj_count"]) for m in cmp_metric_items),
        "false_positive_sum": sum(int(m["false_positive"]) for m in cmp_metric_items),
        "false_negative_sum": sum(int(m["false_negative"]) for m in cmp_metric_items),
        "mismatch_sum": sum(int(m["mismatch"]) for m in cmp_metric_items),
    }

summary = {
    "label_prefix": label_prefix,
    "passthrough_args": read_lines(passthrough_args_path),
    "static_fallback_profiles": read_lines(static_fallback_profiles_path),
    "static_fallback_symbol_regexes": read_lines(static_fallback_symbol_regexes_path),
    "item_count": len(items),
    "pass_count": pass_count,
    "fail_count": fail_count,
    "cmp_rc_counts": dict(sorted(cmp_rc_counts.items())),
    "cmp_verdict_counts": dict(sorted(verdict_counts.items())),
    "failure_class_counts": dict(sorted(failure_class_counts.items())),
    "blocker_code_counts": dict(sorted(blocker_code_counts.items())),
    "lift_rc_counts": dict(sorted(lift_rc_counts.items())),
    "cmp_metric_summary": cmp_metric_summary,
    "items": items,
}
summary_json.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

lines = [
    "| Label | Symbol | Entry | lift_rc | cmp_rc | cmp_verdict | precision | recall | failure_class | blocker_code | Result |",
    "| --- | --- | --- | ---: | ---: | --- | ---: | ---: | --- | --- | --- |",
]
for item in items:
    cmp_metrics = item.get("cmp_metrics") or {}
    cmp_verdict = (
        "true" if item.get("cmp_verdict_ok") is True else
        "false" if item.get("cmp_verdict_ok") is False else
        "unknown"
    )
    lines.append(
        "| `{label}` | `{symbol}` | `{entry}` | {lift_rc} | {cmp_rc} | `{cmp_verdict}` | {precision} | {recall} | `{failure_class}` | `{blocker_code}` | {status} |".format(
            label=item["label"],
            symbol=item["symbol"],
            entry=item["entry"] or "null",
            lift_rc="null" if item["lift_rc"] is None else item["lift_rc"],
            cmp_rc="null" if item["cmp_rc"] is None else item["cmp_rc"],
            cmp_verdict=cmp_verdict,
            precision="null" if cmp_metrics.get("precision") is None else f'{float(cmp_metrics["precision"]):.6f}',
            recall="null" if cmp_metrics.get("recall") is None else f'{float(cmp_metrics["recall"]):.6f}',
            failure_class=item["failure_class"] or "null",
            blocker_code=item["blocker_code"] or "null",
            status=item["status"],
        )
    )
summary_table.write_text("\n".join(lines) + "\n", encoding="utf-8")

print(json.dumps(summary, indent=2, sort_keys=True))
print("\n".join(lines))
PY

printf 'summary_json=%s\n' "$SUMMARY_JSON"
printf 'summary_table=%s\n' "$SUMMARY_TABLE"
