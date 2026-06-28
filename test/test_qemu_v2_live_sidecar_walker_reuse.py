from pathlib import Path


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "runnable"
    / "scripts"
    / "qemu_v2_ptc_live_sidecar_translate_smoke.sh"
)


def test_external_sidecar_reuses_shared_walker_build_root() -> None:
    script = SCRIPT_PATH.read_text(encoding="utf-8")

    assert 'SHARED_WALKER_ROOT="$SCRATCH_ROOT/external/shared-walker"' in script
    assert '--scratch-root "$SHARED_WALKER_ROOT"' in script
    assert 'walker_args+=(--run-only)' in script
    assert 'with_sidecar_lock "$SHARED_WALKER_LOCK" run_external_walker_shared' in script
    assert '--scratch-root "$EXTERNAL_ROOT/walker"' not in script
