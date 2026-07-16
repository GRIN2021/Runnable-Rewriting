import tarfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = REPO_ROOT / "archive" / "runnable-libcrypto-wsl-repro-2026-07-14.tar.gz"
PREFIX = "runnable-libcrypto-wsl-repro-2026-07-14"


class WslReproArchiveContractTests(unittest.TestCase):
    def test_archive_contains_no_docker_full_entrypoints(self):
        with tarfile.open(ARCHIVE, "r:gz") as archive:
            names = set(archive.getnames())
            self.assertIn(f"{PREFIX}/build-libtinycode-qemuv2.sh", names)
            self.assertIn(f"{PREFIX}/run-libcrypto-full-qemuv2.sh", names)

            top_script = archive.extractfile(f"{PREFIX}/run-libcrypto-ubuntu2404.sh")
            self.assertIsNotNone(top_script)
            text = top_script.read().decode("utf-8")
            readme = archive.extractfile(f"{PREFIX}/README-WSL.md")
            self.assertIsNotNone(readme)
            readme_text = readme.read().decode("utf-8")

        self.assertIn("RUNNABLE_LIBCRYPTO_NO_DOCKER", text)
        self.assertIn("run-libcrypto-full-qemuv2.sh", text)
        self.assertNotIn("error: docker is required on the host", text)
        self.assertIn("Docker is optional", readme_text)
        self.assertNotIn("Docker available from WSL", readme_text)


if __name__ == "__main__":
    unittest.main()
