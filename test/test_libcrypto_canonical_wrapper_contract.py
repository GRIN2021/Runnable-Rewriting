import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SUBSET_SCRIPT = REPO_ROOT / "runnable" / "scripts" / "qemu_v2_ptc_libcrypto_canonical_subset.sh"
SWEEP_SCRIPT = REPO_ROOT / "runnable" / "scripts" / "qemu_v2_ptc_libcrypto_canonical_sweep.sh"


class LibcryptoCanonicalWrapperContractTests(unittest.TestCase):
    def test_subset_defaults_to_qemu_v2_runtime_image_contract(self):
        content = SUBSET_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            'DOCKER_IMAGE="${RUNNABLE_QEMU_V2_LIBCRYPTO_IMAGE:-${RUNNABLE_QEMU_V2_IMAGE:-rr_qemu_v2_runtime:latest}}"',
            content,
        )
        self.assertIn("llvm-config --libdir", content)
        self.assertNotIn("RUNNABLE_QEMU_V2_LIBCRYPTO_IMAGE:-rr_bionic_exportfs", content)
        self.assertNotIn("LLVM 7", content)

    def test_subset_accepts_and_forwards_static_fallback_flags(self):
        content = SUBSET_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("--static-fallback-profile PROFILE", content)
        self.assertIn("--static-fallback-symbol-regex REGEX", content)
        self.assertIn("STATIC_FALLBACK_PROFILES+=(", content)
        self.assertIn("STATIC_FALLBACK_SYMBOL_REGEXES+=(", content)
        self.assertIn('CMP_ARGS+=(--static-fallback-profile "$profile")', content)
        self.assertIn('CMP_ARGS+=(--static-fallback-symbol-regex "$regex")', content)

    def test_subset_summary_reflects_static_fallback_config(self):
        content = SUBSET_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(".static_fallback_profiles", content)
        self.assertIn(".static_fallback_symbol_regexes", content)
        self.assertIn('"static_fallback_profiles": read_lines', content)
        self.assertIn('"static_fallback_symbol_regexes": read_lines', content)
        self.assertIn('"static_fallback": cmp_static_fallback', content)

    def test_sweep_accepts_and_passes_static_fallback_flags_to_subset(self):
        content = SWEEP_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("--static-fallback-profile PROFILE", content)
        self.assertIn("--static-fallback-symbol-regex REGEX", content)
        self.assertIn("STATIC_FALLBACK_PROFILES+=(", content)
        self.assertIn("STATIC_FALLBACK_SYMBOL_REGEXES+=(", content)
        self.assertIn('"${PASSTHROUGH_ARGS[@]}"', content)

    def test_sweep_summary_reflects_static_fallback_config(self):
        content = SWEEP_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(".static_fallback_profiles", content)
        self.assertIn(".static_fallback_symbol_regexes", content)
        self.assertIn('"static_fallback_profiles": read_lines', content)
        self.assertIn('"static_fallback_symbol_regexes": read_lines', content)
        self.assertIn('"passthrough_args": read_lines', content)
        self.assertIn('"static_fallback": cmp_static_fallback', content)


if __name__ == "__main__":
    unittest.main()
