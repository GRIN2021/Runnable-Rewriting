import importlib.util
import json
import os
import tempfile
import sys
import unittest
from concurrent.futures import Future
from unittest import mock
from pathlib import Path


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "runnable"
    / "scripts"
    / "libcrypto_dynamic_parallel_lift.py"
)


def load_module():
    spec = importlib.util.spec_from_file_location(
        "libcrypto_dynamic_parallel_lift", SCRIPT_PATH
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class LibcryptoDynamicParallelLiftTests(unittest.TestCase):
    def test_parser_defaults_to_hdd_and_dynamic_image(self):
        module = load_module()

        with mock.patch.dict(os.environ, {}, clear=True):
            parser = module.build_parser()
            args = parser.parse_args([])

        self.assertEqual(args.hdd_root, Path("/hdd/runnable-libcrypto-dynamic-parallel"))
        self.assertEqual(args.docker_image, module.DEFAULT_RUNNABLE_IMAGE)
        self.assertEqual(args.runnable_base, 0x50000000)
        self.assertIsNone(args.seed_start)
        self.assertEqual(args.execution_model, "single-container-shards")
        self.assertEqual(args.shard_byte_budget, 4096)
        self.assertEqual(args.shard_max_seeds, 64)
        self.assertTrue(args.streaming_merge)
        self.assertEqual(args.hdd_min_free_gb, 50.0)
        self.assertIsNone(args.libtinycode_path)
        self.assertIsNone(args.libtinycode_helpers_path)
        self.assertEqual(args.static_fallback_profile, [])
        self.assertEqual(args.static_fallback_symbol_regex, [])

    def test_parser_default_image_uses_qemu_v2_env_override(self):
        with mock.patch.dict(os.environ, {"RUNNABLE_QEMU_V2_IMAGE": "rr_qemu_v2_runtime:test"}):
            module = load_module()
            parser = module.build_parser()

        args = parser.parse_args([])

        self.assertEqual(args.docker_image, "rr_qemu_v2_runtime:test")

    def test_build_defaults_use_system_llvm_contract(self):
        content = SCRIPT_PATH.read_text(encoding="utf-8")

        self.assertIn("llvm-config --cmakedir", content)
        self.assertIn('-DLLVM_DIR="$LLVM_DIR"', content)
        self.assertIn('"/usr/lib/llvm-18/lib"', content)
        self.assertNotIn("-DLLVM_DIR=/root/Runnable-Rewriting/root/lib/cmake/llvm", content)
        self.assertNotIn(":/root/Runnable-Rewriting/root/bin:", content)

    def test_static_fallback_cli_options_are_repeatable_and_saved_in_config(self):
        module = load_module()
        parser = module.build_parser()

        with tempfile.TemporaryDirectory() as tmp:
            args = parser.parse_args(
                [
                    "--hdd-root",
                    tmp,
                    "--run-label",
                    "demo",
                    "--static-fallback-profile",
                    "avx512",
                    "--static-fallback-profile",
                    "simd-heavy",
                    "--static-fallback-profile",
                    "all-functions",
                    "--static-fallback-profile",
                    "all-text",
                    "--static-fallback-symbol-regex",
                    "^OPENSSL_",
                    "--static-fallback-symbol-regex",
                    "sha512",
                ]
            )
            with mock.patch.object(module, "detect_total_memory_gb", return_value=64.0):
                config = module.load_config(args)

        self.assertEqual(
            config.static_fallback_profiles,
            ("avx512", "simd-heavy", "all-functions", "all-text"),
        )
        self.assertEqual(
            config.static_fallback_symbol_regexes,
            ("^OPENSSL_", "sha512"),
        )

    def test_memory_budget_limits_workers_per_coordinator(self):
        module = load_module()

        workers, coordinators = module.estimate_parallel_workers(
            requested_parallel_workers=8,
            max_concurrent_coordinators=3,
            worker_memory_gb=3.0,
            container_memory_limit_gb=10.0,
        )

        self.assertEqual(coordinators, 3)
        self.assertEqual(workers, 1)

    def test_map_host_path_to_container_supports_workspace_and_hdd(self):
        module = load_module()
        layout = module.build_layout(Path("/hdd/runs-root"), "demo")
        self.assertEqual(layout.shared_install_dir, Path("/hdd/runs-root/shared-install-runnable"))
        config = module.LiftConfig(
            workspace_root=Path("/repo/workspace"),
            repo_root=Path("/repo/workspace/Runnable-Rewriting"),
            groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
            layout=layout,
            docker_image=module.DEFAULT_RUNNABLE_IMAGE,
            gt_x86_image="bin2415/x86_gt:0.1",
            gt_py_image="bin2415/py_gt",
            runnable_base=0x50000000,
            min_function_size=64,
            max_seeds=0,
            seed_start=None,
            requested_parallel_workers=4,
            max_concurrent_coordinators=2,
            worker_memory_gb=3.0,
            build_memory_gb=16.0,
            memory_headroom_gb=8.0,
            container_memory_limit_gb=24.0,
            rebuild_lift=True,
            ensure_groundtruth=True,
            dry_run=True,
            lift_timeout_sec=1800,
            skip_cmp=False,
            groundtruth_version="canonical",
            groundtruth_openssl_version="3.4.4",
            run_label="demo",
            coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
            execution_model="single-container-shards",
            shard_byte_budget=4096,
            shard_max_seeds=64,
            shard_concurrency=2,
            container_cpus=30.0,
            preserve_success_seed_logs=False,
            streaming_merge=True,
            merge_workers=2,
            merge_batch_size=64,
            merge_poll_interval_sec=1.0,
        )

        self.assertEqual(
            module.map_host_path_to_container(
                config, Path("/repo/workspace/GroudTruth/file.bin")
            ),
            "/workspace/GroudTruth/file.bin",
        )
        self.assertEqual(
            module.map_host_path_to_container(
                config, Path("/hdd/runs-root/runs/demo/out.txt")
            ),
            "/hdd-work/runs/demo/out.txt",
        )

    def test_stage_libtinycode_runtime_assets_targets_runtime_search_dir(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            layout = module.build_layout(root, "demo")
            module.materialize_layout(layout)
            libtinycode = root / "libtinycode-x86_64.so"
            helpers = root / "libtinycode-helpers-x86_64.ll"
            libtinycode.write_text("so\n", encoding="utf-8")
            helpers.write_text("ll\n", encoding="utf-8")
            config = module.LiftConfig(
                workspace_root=Path("/repo/workspace"),
                repo_root=Path("/repo/workspace/Runnable-Rewriting"),
                groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
                layout=layout,
                docker_image=module.DEFAULT_RUNNABLE_IMAGE,
                gt_x86_image="bin2415/x86_gt:0.1",
                gt_py_image="bin2415/py_gt",
                runnable_base=0x50000000,
                min_function_size=64,
                max_seeds=0,
                seed_start=None,
                requested_parallel_workers=4,
                max_concurrent_coordinators=2,
                worker_memory_gb=3.0,
                build_memory_gb=16.0,
                memory_headroom_gb=8.0,
                container_memory_limit_gb=24.0,
                rebuild_lift=True,
                ensure_groundtruth=True,
                dry_run=True,
                lift_timeout_sec=1800,
                skip_cmp=False,
                groundtruth_version="canonical",
                groundtruth_openssl_version="3.4.4",
                run_label="demo",
                coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
                execution_model="single-container-shards",
                shard_byte_budget=4096,
                shard_max_seeds=64,
                shard_concurrency=2,
                container_cpus=30.0,
                preserve_success_seed_logs=False,
                streaming_merge=True,
                merge_workers=2,
                merge_batch_size=64,
                merge_poll_interval_sec=1.0,
                libtinycode_override=libtinycode,
                libtinycode_helpers_override=helpers,
            )

            staged_build = module.stage_libtinycode_runtime_assets(config, layout.build_dir)
            self.assertEqual(staged_build, layout.build_dir)
            self.assertEqual(
                (layout.build_dir / "libtinycode-x86_64.so").read_text(encoding="utf-8"),
                "so\n",
            )
            self.assertEqual(
                (layout.build_dir / "libtinycode-helpers-x86_64.ll").read_text(encoding="utf-8"),
                "ll\n",
            )

            staged_install = module.stage_libtinycode_runtime_assets(config, layout.install_dir)
            self.assertEqual(staged_install, layout.install_dir / "lib")
            self.assertEqual(
                (layout.install_dir / "lib" / "libtinycode-x86_64.so").read_text(encoding="utf-8"),
                "so\n",
            )
            self.assertEqual(
                (layout.install_dir / "lib" / "libtinycode-helpers-x86_64.ll").read_text(encoding="utf-8"),
                "ll\n",
            )
            self.assertEqual(
                (layout.install_dir / "bin" / "libtinycode-x86_64.so").read_text(encoding="utf-8"),
                "so\n",
            )
            self.assertEqual(
                (layout.install_dir / "bin" / "libtinycode-helpers-x86_64.ll").read_text(encoding="utf-8"),
                "ll\n",
            )

    def test_stage_libtinycode_runtime_assets_auto_discovers_repo_runtime(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo_root = root / "repo"
            runtime_dir = repo_root / "build-codex-dynamic-current" / "tools" / "runnable-lift"
            runtime_dir.mkdir(parents=True)
            (runtime_dir / "libtinycode-x86_64.so").write_text("so\n", encoding="utf-8")
            (runtime_dir / "libtinycode-helpers-x86_64.ll").write_text("ll\n", encoding="utf-8")
            layout = module.build_layout(root / "hdd", "demo")
            module.materialize_layout(layout)
            config = module.LiftConfig(
                workspace_root=Path("/repo/workspace"),
                repo_root=repo_root,
                groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
                layout=layout,
                docker_image=module.DEFAULT_RUNNABLE_IMAGE,
                gt_x86_image="bin2415/x86_gt:0.1",
                gt_py_image="bin2415/py_gt",
                runnable_base=0x50000000,
                min_function_size=64,
                max_seeds=0,
                seed_start=None,
                requested_parallel_workers=4,
                max_concurrent_coordinators=2,
                worker_memory_gb=3.0,
                build_memory_gb=16.0,
                memory_headroom_gb=8.0,
                container_memory_limit_gb=24.0,
                rebuild_lift=True,
                ensure_groundtruth=True,
                dry_run=True,
                lift_timeout_sec=1800,
                skip_cmp=False,
                groundtruth_version="canonical",
                groundtruth_openssl_version="3.4.4",
                run_label="demo",
                coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
                execution_model="single-container-shards",
                shard_byte_budget=4096,
                shard_max_seeds=64,
                shard_concurrency=2,
                container_cpus=30.0,
                preserve_success_seed_logs=False,
                streaming_merge=True,
                merge_workers=2,
                merge_batch_size=64,
                merge_poll_interval_sec=1.0,
            )

            staged_install = module.stage_libtinycode_runtime_assets(config, layout.install_dir)

            self.assertEqual(staged_install, layout.install_dir / "lib")
            self.assertEqual(
                (layout.install_dir / "lib" / "libtinycode-x86_64.so").read_text(encoding="utf-8"),
                "so\n",
            )
            self.assertEqual(
                (layout.install_dir / "bin" / "libtinycode-helpers-x86_64.ll").read_text(encoding="utf-8"),
                "ll\n",
            )

    def test_stage_libtinycode_runtime_assets_ignores_source_tree_stub(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo_root = root / "repo"
            runtime_dir = repo_root / "runnable" / "tools" / "runnable-lift"
            runtime_dir.mkdir(parents=True)
            (runtime_dir / "libtinycode-x86_64.so").write_text("stub\n", encoding="utf-8")
            (runtime_dir / "libtinycode-helpers-x86_64.ll").write_text("ll\n", encoding="utf-8")
            layout = module.build_layout(root / "hdd", "demo")
            module.materialize_layout(layout)
            config = module.LiftConfig(
                workspace_root=Path("/repo/workspace"),
                repo_root=repo_root,
                groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
                layout=layout,
                docker_image=module.DEFAULT_RUNNABLE_IMAGE,
                gt_x86_image="bin2415/x86_gt:0.1",
                gt_py_image="bin2415/py_gt",
                runnable_base=0x50000000,
                min_function_size=64,
                max_seeds=0,
                seed_start=None,
                requested_parallel_workers=4,
                max_concurrent_coordinators=2,
                worker_memory_gb=3.0,
                build_memory_gb=16.0,
                memory_headroom_gb=8.0,
                container_memory_limit_gb=24.0,
                rebuild_lift=True,
                ensure_groundtruth=True,
                dry_run=False,
                lift_timeout_sec=1800,
                skip_cmp=False,
                groundtruth_version="canonical",
                groundtruth_openssl_version="3.4.4",
                run_label="demo",
                coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
                execution_model="single-container-shards",
                shard_byte_budget=4096,
                shard_max_seeds=64,
                shard_concurrency=2,
                container_cpus=30.0,
                preserve_success_seed_logs=False,
                streaming_merge=True,
                merge_workers=2,
                merge_batch_size=64,
                merge_poll_interval_sec=1.0,
            )

            with self.assertRaisesRegex(RuntimeError, "missing libtinycode runtime assets"):
                module.stage_libtinycode_runtime_assets(config, layout.install_dir)

    def test_plan_shards_groups_small_adjacent_and_keeps_large_seed(self):
        module = load_module()
        layout = module.build_layout(Path("/hdd/runs-root"), "demo")
        config = module.LiftConfig(
            workspace_root=Path("/repo/workspace"),
            repo_root=Path("/repo/workspace/Runnable-Rewriting"),
            groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
            layout=layout,
            docker_image=module.DEFAULT_RUNNABLE_IMAGE,
            gt_x86_image="bin2415/x86_gt:0.1",
            gt_py_image="bin2415/py_gt",
            runnable_base=0x50000000,
            min_function_size=64,
            max_seeds=0,
            seed_start=None,
            requested_parallel_workers=4,
            max_concurrent_coordinators=2,
            worker_memory_gb=3.0,
            build_memory_gb=16.0,
            memory_headroom_gb=8.0,
            container_memory_limit_gb=24.0,
            rebuild_lift=True,
            ensure_groundtruth=True,
            dry_run=True,
            lift_timeout_sec=1800,
            skip_cmp=False,
            groundtruth_version="canonical",
            groundtruth_openssl_version="3.4.4",
            run_label="demo",
            coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
            execution_model="single-container-shards",
            shard_byte_budget=256,
            shard_max_seeds=2,
            shard_concurrency=2,
            container_cpus=30.0,
            preserve_success_seed_logs=False,
            streaming_merge=True,
            merge_workers=2,
            merge_batch_size=64,
            merge_poll_interval_sec=1.0,
        )
        seeds = [
            module.SeedFunction(start=0x1000, size=64, end_exclusive=0x1040, name="a", binding="symtab"),
            module.SeedFunction(start=0x1040, size=96, end_exclusive=0x10A0, name="b", binding="symtab"),
            module.SeedFunction(start=0x10A0, size=512, end_exclusive=0x12A0, name="big", binding="symtab"),
            module.SeedFunction(start=0x12A0, size=64, end_exclusive=0x12E0, name="c", binding="symtab"),
        ]

        shards = module.plan_shards(config, seeds)

        self.assertEqual(len(shards), 3)
        self.assertEqual([seed.name for seed in shards[0].seeds], ["a", "b"])
        self.assertEqual([seed.name for seed in shards[1].seeds], ["big"])
        self.assertEqual([seed.name for seed in shards[2].seeds], ["c"])

    def test_write_shard_manifests_emits_overview_and_per_shard_files(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            layout = module.build_layout(Path(tmp), "demo")
            module.materialize_layout(layout)
            shard = module.LiftShard(
                shard_id="shard_00000_0000000000001000",
                seeds=(
                    module.SeedFunction(start=0x1000, size=64, end_exclusive=0x1040, name="a", binding="symtab"),
                ),
                total_size=64,
            )

            module.write_shard_manifests(layout, [shard])

            overview = layout.shard_manifests_dir / "shards.json"
            per_shard = layout.shard_manifests_dir / f"{shard.shard_id}.json"
            self.assertTrue(overview.exists())
            self.assertTrue(per_shard.exists())

    def test_load_completed_seed_tags_reads_seed_lift_events(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            layout = module.build_layout(Path(tmp), "demo")
            module.materialize_layout(layout)
            seed_lift_events = module.merge_state_paths(layout)["seed_lift_events"]
            seed_lift_events.write_text(
                json.dumps({"tag": "fn_0000000000001000"}) + "\n"
                + json.dumps({"tag": "fn_0000000000002000"}) + "\n",
                encoding="utf-8",
            )

            completed = module.load_completed_seed_tags(layout)

            self.assertEqual(
                completed,
                {"fn_0000000000001000", "fn_0000000000002000"},
            )

    def test_filter_pending_shards_keeps_only_unfinished_seeds(self):
        module = load_module()
        shard_a = module.LiftShard(
            shard_id="shard_00000_0000000000001000",
            seeds=(
                module.SeedFunction(start=0x1000, size=64, end_exclusive=0x1040, name="a", binding="symtab"),
                module.SeedFunction(start=0x1040, size=64, end_exclusive=0x1080, name="b", binding="symtab"),
            ),
            total_size=128,
        )
        shard_b = module.LiftShard(
            shard_id="shard_00001_0000000000002000",
            seeds=(
                module.SeedFunction(start=0x2000, size=64, end_exclusive=0x2040, name="c", binding="symtab"),
            ),
            total_size=64,
        )

        pending = module.filter_pending_shards(
            [shard_a, shard_b],
            completed_tags={"fn_0000000000001000", "fn_0000000000002000"},
        )

        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0].shard_id, shard_a.shard_id)
        self.assertEqual([seed.name for seed in pending[0].seeds], ["b"])
        self.assertEqual(pending[0].total_size, 64)

    def test_merge_state_paths_live_under_merge_state_dir(self):
        module = load_module()
        layout = module.build_layout(Path("/hdd/runs-root"), "demo")

        paths = module.merge_state_paths(layout)

        self.assertEqual(paths["seed_lift_events"], layout.merge_state_dir / "seed-lift-events.jsonl")
        self.assertEqual(paths["progress"], layout.merge_state_dir / "merge-progress.json")
        self.assertEqual(paths["frontier"], layout.merge_state_dir / "merge-frontier.json")

    def test_load_incremental_results_uses_offsets_and_skips_known_tags(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "results.jsonl"
            initial_rows = [
                {"tag": "fn_00000001", "start": 1},
                {"tag": "fn_00000002", "start": 2},
            ]
            path.write_text(
                "".join(json.dumps(row) + "\n" for row in initial_rows),
                encoding="utf-8",
            )

            known = set()
            first_batch, offset = module.load_incremental_results(
                path,
                known_tags=known,
                start_offset=0,
            )

            self.assertEqual([item["tag"] for item in first_batch], ["fn_00000001", "fn_00000002"])
            self.assertGreater(offset, 0)
            known.update(str(item["tag"]) for item in first_batch)

            with path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps({"tag": "fn_00000002", "start": 2}) + "\n")
                handle.write(json.dumps({"tag": "fn_00000003", "start": 3}) + "\n")

            second_batch, second_offset = module.load_incremental_results(
                path,
                known_tags=known,
                start_offset=offset,
            )

            self.assertEqual([item["tag"] for item in second_batch], ["fn_00000003"])
            self.assertGreaterEqual(second_offset, offset)

    def test_load_incremental_results_resets_offset_after_file_truncation(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "results.jsonl"
            initial_rows = [
                {"tag": "fn_00000001", "start": 1},
                {"tag": "fn_00000002", "start": 2},
            ]
            path.write_text(
                "".join(json.dumps(row) + "\n" for row in initial_rows),
                encoding="utf-8",
            )

            first_batch, offset = module.load_incremental_results(
                path,
                known_tags=set(),
                start_offset=0,
            )
            self.assertEqual([item["tag"] for item in first_batch], ["fn_00000001", "fn_00000002"])

            path.write_text(
                json.dumps({"tag": "fn_00000003", "start": 3}) + "\n",
                encoding="utf-8",
            )
            second_batch, second_offset = module.load_incremental_results(
                path,
                known_tags={"fn_00000001", "fn_00000002"},
                start_offset=offset,
            )

            self.assertEqual([item["tag"] for item in second_batch], ["fn_00000003"])
            self.assertGreater(second_offset, 0)

    def test_drain_completed_futures_consumes_callback_ready_queue_once(self):
        module = load_module()
        future_map = {}
        completed = module.queue.SimpleQueue()
        first = Future()
        second = Future()

        module.track_future_completion(future_map, completed, first, "first")
        module.track_future_completion(future_map, completed, second, "second")
        first.set_result("done-1")

        ready = module.drain_completed_futures(future_map, completed)
        self.assertEqual(ready, [first])
        self.assertEqual(module.drain_completed_futures(future_map, completed), [])

        second.set_result("done-2")
        ready = module.drain_completed_futures(future_map, completed)
        self.assertEqual(ready, [second])

    def test_write_summary_if_changed_skips_identical_payloads(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "summary.json"
            cache = {}
            first = {"value": 1, "state": "ok"}
            second = {"value": 2, "state": "ok"}

            self.assertTrue(module.write_summary_if_changed(path, first, cache))
            self.assertFalse(module.write_summary_if_changed(path, first, cache))
            self.assertTrue(module.write_summary_if_changed(path, second, cache))
            self.assertEqual(
                path.read_text(encoding="utf-8"),
                module.render_summary(second),
            )

    def test_measure_tree_bytes_accepts_du_size_when_du_exits_nonzero(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = module.subprocess.CompletedProcess(
                args=["du", "-sb", str(root)],
                returncode=1,
                stdout=f"123\t{root}\n",
                stderr="du: cannot access 'gone.ll': No such file or directory\n",
            )

            with mock.patch.object(module, "run_cmd", return_value=result) as run_cmd:
                size = module.measure_tree_bytes(root)

            self.assertEqual(size, 123)
            run_cmd.assert_called_once_with(
                ["du", "-sb", str(root)],
                capture_output=True,
                check=False,
            )

    def test_measure_tree_bytes_raises_when_du_has_no_parseable_size(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = module.subprocess.CompletedProcess(
                args=["du", "-sb", str(root)],
                returncode=1,
                stdout="",
                stderr="du: cannot access root: No such file or directory\n",
            )

            with (
                mock.patch.object(module, "run_cmd", return_value=result),
                mock.patch.object(module.time, "sleep"),
            ):
                with self.assertRaisesRegex(RuntimeError, "du -sb failed"):
                    module.measure_tree_bytes(root)

    def test_measure_tree_bytes_retries_deleted_file_race_without_stdout(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            transient = module.subprocess.CompletedProcess(
                args=["du", "-sb", str(root)],
                returncode=1,
                stdout="",
                stderr="du: cannot access 'gone.ll': No such file or directory\n",
            )
            success = module.subprocess.CompletedProcess(
                args=["du", "-sb", str(root)],
                returncode=0,
                stdout=f"456\t{root}\n",
                stderr="",
            )

            with (
                mock.patch.object(module, "run_cmd", side_effect=[transient, success]) as run_cmd,
                mock.patch.object(module.time, "sleep") as sleep,
            ):
                size = module.measure_tree_bytes(root)

            self.assertEqual(size, 456)
            self.assertEqual(run_cmd.call_count, 2)
            sleep.assert_called_once_with(module.DU_TRANSIENT_RETRY_DELAY_SEC)

    def test_collect_disk_budget_snapshot_flags_low_free_space(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            layout = module.build_layout(Path(tmp), "demo")
            module.materialize_layout(layout)
            config = module.LiftConfig(
                workspace_root=Path("/repo/workspace"),
                repo_root=Path("/repo/workspace/Runnable-Rewriting"),
                groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
                layout=layout,
                docker_image=module.DEFAULT_RUNNABLE_IMAGE,
                gt_x86_image="bin2415/x86_gt:0.1",
                gt_py_image="bin2415/py_gt",
                runnable_base=0x50000000,
                min_function_size=64,
                max_seeds=0,
                seed_start=None,
                requested_parallel_workers=4,
                max_concurrent_coordinators=2,
                worker_memory_gb=3.0,
                build_memory_gb=16.0,
                memory_headroom_gb=8.0,
                container_memory_limit_gb=24.0,
                rebuild_lift=True,
                ensure_groundtruth=True,
                dry_run=True,
                lift_timeout_sec=1800,
                skip_cmp=False,
                groundtruth_version="canonical",
                groundtruth_openssl_version="3.4.4",
                run_label="demo",
                coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
                execution_model="single-container-shards",
                shard_byte_budget=4096,
                shard_max_seeds=64,
                shard_concurrency=2,
                container_cpus=30.0,
                preserve_success_seed_logs=False,
                streaming_merge=True,
                merge_workers=2,
                merge_batch_size=64,
                merge_poll_interval_sec=1.0,
                hdd_min_free_gb=50.0,
            )

            with mock.patch.object(
                module.shutil,
                "disk_usage",
                return_value=module.shutil._ntuple_diskusage(
                    total=200 * 1024 ** 3,
                    used=160 * 1024 ** 3,
                    free=40 * 1024 ** 3,
                ),
            ):
                snapshot = module.collect_disk_budget_snapshot(config)

            self.assertTrue(snapshot["limit_exceeded"])
            self.assertEqual(snapshot["limit_reason_codes"], ["hdd_min_free_exceeded"])
            self.assertIn("hdd_free_gb=40.00", snapshot["limit_message"])

    def test_build_merge_batch_plan_reduces_successful_shards_only(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            layout = module.build_layout(Path(tmp), "demo")
            config = module.LiftConfig(
                workspace_root=Path("/repo/workspace"),
                repo_root=Path("/repo/workspace/Runnable-Rewriting"),
                groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
                layout=layout,
                docker_image=module.DEFAULT_RUNNABLE_IMAGE,
                gt_x86_image="bin2415/x86_gt:0.1",
                gt_py_image="bin2415/py_gt",
                runnable_base=0x50000000,
                min_function_size=64,
                max_seeds=0,
                seed_start=None,
                requested_parallel_workers=4,
                max_concurrent_coordinators=2,
                worker_memory_gb=3.0,
                build_memory_gb=16.0,
                memory_headroom_gb=8.0,
                container_memory_limit_gb=24.0,
                rebuild_lift=True,
                ensure_groundtruth=True,
                dry_run=True,
                lift_timeout_sec=1800,
                skip_cmp=False,
                groundtruth_version="canonical",
                groundtruth_openssl_version="3.4.4",
                run_label="demo",
                coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
                execution_model="single-container-shards",
                shard_byte_budget=4096,
                shard_max_seeds=64,
                shard_concurrency=2,
                container_cpus=30.0,
                preserve_success_seed_logs=False,
                streaming_merge=True,
                merge_workers=2,
                merge_batch_size=2,
                merge_poll_interval_sec=1.0,
            )
            module.materialize_layout(layout)
            good1 = layout.shard_merged_dir / "shard_1.ll"
            good2 = layout.shard_merged_dir / "shard_2.ll"
            good3 = layout.shard_merged_dir / "shard_3.ll"
            for path in (good1, good2, good3):
                path.write_text("; ok\n", encoding="utf-8")

            plan = module.build_merge_batch_plan(
                config,
                [
                    {"shard_id": "shard_1", "start": 0x1000, "status": "ok", "merged_ll": str(good1)},
                    {"shard_id": "shard_2", "start": 0x2000, "status": "partial", "merged_ll": str(good2)},
                    {"shard_id": "shard_3", "start": 0x3000, "status": "failed", "merged_ll": str(good3)},
                    {"shard_id": "shard_4", "start": 0x4000, "status": "ok", "merged_ll": str(good3) + ".missing"},
                ],
            )

            self.assertEqual(len(plan), 1)
            self.assertEqual(plan[0].children, ("shard_1", "shard_2"))

    def test_start_long_lived_container_dry_run_uses_sanitized_name(self):
        module = load_module()
        layout = module.build_layout(Path("/hdd/runs-root"), "demo unsafe/run")
        config = module.LiftConfig(
            workspace_root=Path("/repo/workspace"),
            repo_root=Path("/repo/workspace/Runnable-Rewriting"),
            groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
            layout=layout,
            docker_image=module.DEFAULT_RUNNABLE_IMAGE,
            gt_x86_image="bin2415/x86_gt:0.1",
            gt_py_image="bin2415/py_gt",
            runnable_base=0x50000000,
            min_function_size=64,
            max_seeds=0,
            seed_start=None,
            requested_parallel_workers=4,
            max_concurrent_coordinators=2,
            worker_memory_gb=3.0,
            build_memory_gb=16.0,
            memory_headroom_gb=8.0,
            container_memory_limit_gb=24.0,
            rebuild_lift=True,
            ensure_groundtruth=True,
            dry_run=True,
            lift_timeout_sec=1800,
            skip_cmp=False,
            groundtruth_version="canonical",
            groundtruth_openssl_version="3.4.4",
            run_label="demo unsafe/run",
            coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
            execution_model="single-container-shards",
            shard_byte_budget=4096,
            shard_max_seeds=64,
            shard_concurrency=2,
            container_cpus=30.0,
            preserve_success_seed_logs=False,
            streaming_merge=True,
            merge_workers=2,
            merge_batch_size=64,
            merge_poll_interval_sec=1.0,
        )

        container_name = module.start_long_lived_container(
            config,
            {"PATH": "/bin", "LD_LIBRARY_PATH": "/lib", "PYTHONPATH": "/py"},
        )

        self.assertEqual(container_name, "rr-libcrypto-demo-unsafe-run")

    def test_parser_can_disable_streaming_merge(self):
        module = load_module()
        parser = module.build_parser()

        args = parser.parse_args(["--no-streaming-merge"])

        self.assertFalse(args.streaming_merge)

    def test_run_canonical_cmp_dry_run_forwards_static_fallback_flags(self):
        module = load_module()
        parser = module.build_parser()

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args = parser.parse_args(
                [
                    "--hdd-root",
                    str(root),
                    "--run-label",
                    "demo",
                    "--repo-root",
                    str(root / "repo"),
                    "--dry-run",
                    "--static-fallback-profile",
                    "avx512",
                    "--static-fallback-profile",
                    "simd-heavy",
                    "--static-fallback-profile",
                    "all-functions",
                    "--static-fallback-profile",
                    "all-text",
                    "--static-fallback-symbol-regex",
                    "custom_avx",
                ]
            )
            with mock.patch.object(module, "detect_total_memory_gb", return_value=64.0):
                config = module.load_config(args)

            with mock.patch.object(module, "detect_text_start", return_value=0xCEF80):
                payload = module.run_canonical_cmp(
                    config=config,
                    binary=root / "libcrypto.so.3",
                    groundtruth_pb=root / "libcrypto.gtBlock.pb",
                    ll_path=root / "libcrypto.ll",
                    cmp_tool=root / "run_cmp_eval.py",
                    blocks_pb2=root / "blocks_pb2.py",
                )

            cmd = payload["cmd"]
            self.assertEqual(payload["status"], "dry-run")
            self.assertEqual(
                [
                    cmd[index + 1]
                    for index, token in enumerate(cmd)
                    if token == "--static-fallback-profile"
                ],
                ["avx512", "simd-heavy", "all-functions", "all-text"],
            )
            self.assertEqual(
                [
                    cmd[index + 1]
                    for index, token in enumerate(cmd)
                    if token == "--static-fallback-symbol-regex"
                ],
                ["custom_avx"],
            )

    def test_plan_merge_batches_returns_root_for_multi_level_tree(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            layout = module.build_layout(Path(tmp), "demo")
            module.materialize_layout(layout)
            config = module.LiftConfig(
                workspace_root=Path("/repo/workspace"),
                repo_root=Path("/repo/workspace/Runnable-Rewriting"),
                groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
                layout=layout,
                docker_image=module.DEFAULT_RUNNABLE_IMAGE,
                gt_x86_image="bin2415/x86_gt:0.1",
                gt_py_image="bin2415/py_gt",
                runnable_base=0x50000000,
                min_function_size=64,
                max_seeds=0,
                seed_start=None,
                requested_parallel_workers=4,
                max_concurrent_coordinators=2,
                worker_memory_gb=3.0,
                build_memory_gb=16.0,
                memory_headroom_gb=8.0,
                container_memory_limit_gb=24.0,
                rebuild_lift=True,
                ensure_groundtruth=True,
                dry_run=True,
                lift_timeout_sec=1800,
                skip_cmp=False,
                groundtruth_version="canonical",
                groundtruth_openssl_version="3.4.4",
                run_label="demo",
                coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
                execution_model="single-container-shards",
                shard_byte_budget=4096,
                shard_max_seeds=64,
                shard_concurrency=2,
                container_cpus=30.0,
                preserve_success_seed_logs=False,
                streaming_merge=True,
                merge_workers=2,
                merge_batch_size=2,
                merge_poll_interval_sec=1.0,
            )
            shard_paths = []
            for name in ("s1", "s2", "s3"):
                path = layout.shard_merged_dir / f"{name}.ll"
                path.write_text("; ok\n", encoding="utf-8")
                shard_paths.append(path)

            plan, root_id, ready = module.plan_merge_batches(
                config,
                [
                    {"shard_id": "s1", "start": 0x1000, "status": "ok", "merged_ll": str(shard_paths[0])},
                    {"shard_id": "s2", "start": 0x2000, "status": "ok", "merged_ll": str(shard_paths[1])},
                    {"shard_id": "s3", "start": 0x3000, "status": "ok", "merged_ll": str(shard_paths[2])},
                ],
            )

            self.assertEqual([item["shard_id"] for item in ready], ["s1", "s2", "s3"])
            self.assertEqual(len(plan), 2)
            self.assertEqual(root_id, plan[-1].node_id)

    def test_plan_merge_batches_changes_node_identity_when_children_change(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            layout = module.build_layout(Path(tmp), "demo")
            module.materialize_layout(layout)
            config = module.LiftConfig(
                workspace_root=Path("/repo/workspace"),
                repo_root=Path("/repo/workspace/Runnable-Rewriting"),
                groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
                layout=layout,
                docker_image=module.DEFAULT_RUNNABLE_IMAGE,
                gt_x86_image="bin2415/x86_gt:0.1",
                gt_py_image="bin2415/py_gt",
                runnable_base=0x50000000,
                min_function_size=64,
                max_seeds=0,
                seed_start=None,
                requested_parallel_workers=4,
                max_concurrent_coordinators=2,
                worker_memory_gb=3.0,
                build_memory_gb=16.0,
                memory_headroom_gb=8.0,
                container_memory_limit_gb=24.0,
                rebuild_lift=True,
                ensure_groundtruth=True,
                dry_run=True,
                lift_timeout_sec=1800,
                skip_cmp=False,
                groundtruth_version="canonical",
                groundtruth_openssl_version="3.4.4",
                run_label="demo",
                coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
                execution_model="single-container-shards",
                shard_byte_budget=4096,
                shard_max_seeds=64,
                shard_concurrency=2,
                container_cpus=30.0,
                preserve_success_seed_logs=False,
                streaming_merge=True,
                merge_workers=2,
                merge_batch_size=2,
                merge_poll_interval_sec=1.0,
            )
            shard_paths = {}
            for name in ("s1", "s2", "s3", "s4"):
                path = layout.shard_merged_dir / f"{name}.ll"
                path.write_text("; ok\n", encoding="utf-8")
                shard_paths[name] = path

            plan_a, _, _ = module.plan_merge_batches(
                config,
                [
                    {"shard_id": "s1", "start": 0x1000, "status": "ok", "merged_ll": str(shard_paths["s1"])},
                    {"shard_id": "s2", "start": 0x2000, "status": "ok", "merged_ll": str(shard_paths["s2"])},
                    {"shard_id": "s3", "start": 0x3000, "status": "ok", "merged_ll": str(shard_paths["s3"])},
                ],
            )
            plan_b, _, _ = module.plan_merge_batches(
                config,
                [
                    {"shard_id": "s1", "start": 0x1000, "status": "ok", "merged_ll": str(shard_paths["s1"])},
                    {"shard_id": "s2", "start": 0x2000, "status": "ok", "merged_ll": str(shard_paths["s2"])},
                    {"shard_id": "s3", "start": 0x3000, "status": "ok", "merged_ll": str(shard_paths["s3"])},
                    {"shard_id": "s4", "start": 0x4000, "status": "ok", "merged_ll": str(shard_paths["s4"])},
                ],
            )

            node_a = next(node for node in plan_a if node.level == 1 and node.index == 0)
            node_b = next(node for node in plan_b if node.level == 1 and node.index == 0)
            self.assertNotEqual(node_a.children, node_b.children)
            self.assertNotEqual(node_a.node_id, node_b.node_id)
            self.assertNotEqual(node_a.output, node_b.output)
            self.assertNotEqual(node_a.summary_out, node_b.summary_out)

    def test_merge_module_paths_uses_unique_temp_batches_per_invocation(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            layout = module.build_layout(Path(tmp), "demo")
            module.materialize_layout(layout)
            config = module.LiftConfig(
                workspace_root=Path("/repo/workspace"),
                repo_root=Path("/repo/workspace/Runnable-Rewriting"),
                groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
                layout=layout,
                docker_image=module.DEFAULT_RUNNABLE_IMAGE,
                gt_x86_image="bin2415/x86_gt:0.1",
                gt_py_image="bin2415/py_gt",
                runnable_base=0x50000000,
                min_function_size=64,
                max_seeds=0,
                seed_start=None,
                requested_parallel_workers=4,
                max_concurrent_coordinators=2,
                worker_memory_gb=3.0,
                build_memory_gb=16.0,
                memory_headroom_gb=8.0,
                container_memory_limit_gb=24.0,
                rebuild_lift=True,
                ensure_groundtruth=True,
                dry_run=False,
                lift_timeout_sec=1800,
                skip_cmp=False,
                groundtruth_version="canonical",
                groundtruth_openssl_version="3.4.4",
                run_label="demo",
                coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
                execution_model="single-container-shards",
                shard_byte_budget=4096,
                shard_max_seeds=64,
                shard_concurrency=2,
                container_cpus=30.0,
                preserve_success_seed_logs=False,
                streaming_merge=True,
                merge_workers=2,
                merge_batch_size=2,
                merge_poll_interval_sec=1.0,
            )
            inputs_a = []
            inputs_b = []
            for name in ("a1", "a2", "b1", "b2"):
                path = layout.shard_merged_dir / f"{name}.ll"
                path.write_text(f"; {name}\n", encoding="utf-8")
                if name.startswith("a"):
                    inputs_a.append(path)
                else:
                    inputs_b.append(path)

            def fake_run_cmd(cmd, **_kwargs):
                if cmd[0] == "python3":
                    output = Path(cmd[cmd.index("--output") + 1])
                    summary = Path(cmd[cmd.index("--summary-out") + 1])
                    output.write_text("; merged batch\n", encoding="utf-8")
                    summary.write_text("{}", encoding="utf-8")
                elif cmd[0] == "cp":
                    Path(cmd[2]).write_text(Path(cmd[1]).read_text(encoding="utf-8"), encoding="utf-8")
                else:
                    raise AssertionError(f"unexpected command: {cmd}")

            with mock.patch.object(module, "run_cmd", side_effect=fake_run_cmd):
                module.merge_module_paths(
                    config,
                    inputs=inputs_a,
                    entry_pc=0x50001000,
                    final_output=layout.eval_dir / "final-a.ll",
                    summary_name="final-a.json",
                )
                module.merge_module_paths(
                    config,
                    inputs=inputs_b,
                    entry_pc=0x50002000,
                    final_output=layout.eval_dir / "final-b.ll",
                    summary_name="final-b.json",
                )

            temp_batch_dir = layout.manifests_dir / "merge-batches"
            batch_outputs = sorted(
                path.name for path in temp_batch_dir.glob("round00-batch0000-*.ll")
            )
            batch_summaries = sorted(
                path.name for path in temp_batch_dir.glob("round00-batch0000-*.json")
            )

            self.assertEqual(len(batch_outputs), 2)
            self.assertEqual(len(batch_summaries), 2)
            self.assertNotEqual(batch_outputs[0], batch_outputs[1])
            self.assertNotEqual(batch_summaries[0], batch_summaries[1])

    def test_restore_streaming_merge_state_recovers_completed_outputs(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            layout = module.build_layout(Path(tmp), "demo")
            module.materialize_layout(layout)
            config = module.LiftConfig(
                workspace_root=Path("/repo/workspace"),
                repo_root=Path("/repo/workspace/Runnable-Rewriting"),
                groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
                layout=layout,
                docker_image=module.DEFAULT_RUNNABLE_IMAGE,
                gt_x86_image="bin2415/x86_gt:0.1",
                gt_py_image="bin2415/py_gt",
                runnable_base=0x50000000,
                min_function_size=64,
                max_seeds=0,
                seed_start=None,
                requested_parallel_workers=4,
                max_concurrent_coordinators=2,
                worker_memory_gb=3.0,
                build_memory_gb=16.0,
                memory_headroom_gb=8.0,
                container_memory_limit_gb=24.0,
                rebuild_lift=True,
                ensure_groundtruth=True,
                dry_run=True,
                lift_timeout_sec=1800,
                skip_cmp=False,
                groundtruth_version="canonical",
                groundtruth_openssl_version="3.4.4",
                run_label="demo",
                coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
                execution_model="single-container-shards",
                shard_byte_budget=4096,
                shard_max_seeds=64,
                shard_concurrency=2,
                container_cpus=30.0,
                preserve_success_seed_logs=False,
                streaming_merge=True,
                merge_workers=2,
                merge_batch_size=2,
                merge_poll_interval_sec=1.0,
            )
            shard1 = module.LiftShard(
                shard_id="shard_1",
                seeds=(
                    module.SeedFunction(start=0x1000, size=64, end_exclusive=0x1040, name="a", binding="symtab"),
                    module.SeedFunction(start=0x1100, size=64, end_exclusive=0x1140, name="b", binding="symtab"),
                ),
                total_size=128,
            )
            shard2 = module.LiftShard(
                shard_id="shard_2",
                seeds=(
                    module.SeedFunction(start=0x2000, size=64, end_exclusive=0x2040, name="c", binding="symtab"),
                ),
                total_size=64,
            )
            module.write_shard_manifests(layout, [shard1, shard2])

            seed_a_raw = layout.raw_dir / "fn_0000000000001000.raw.ll"
            seed_a_merged = layout.merged_dir / "fn_0000000000001000.ll"
            seed_b_raw = layout.raw_dir / "fn_0000000000001100.raw.ll"
            seed_b_merged = layout.merged_dir / "fn_0000000000001100.ll"
            seed_c_raw = layout.raw_dir / "fn_0000000000002000.raw.ll"
            seed_c_merged = layout.merged_dir / "fn_0000000000002000.ll"
            for path in (seed_a_raw, seed_a_merged, seed_b_raw, seed_b_merged, seed_c_raw, seed_c_merged):
                path.write_text("; ok\n", encoding="utf-8")

            (layout.manifests_dir / "fn_0000000000001000.merge.json").write_text("{}", encoding="utf-8")
            (layout.manifests_dir / "fn_0000000000001100.merge.json").write_text("{}", encoding="utf-8")
            (layout.manifests_dir / "fn_0000000000002000.merge.json").write_text("{}", encoding="utf-8")

            shard1_ll = layout.shard_merged_dir / "shard_1.ll"
            shard2_ll = layout.shard_merged_dir / "shard_2.ll"
            shard1_ll.write_text("; shard1\n", encoding="utf-8")
            shard2_ll.write_text("; shard2\n", encoding="utf-8")
            (layout.manifests_dir / "shard_1.summary.json").write_text("{}", encoding="utf-8")
            (layout.manifests_dir / "shard_2.summary.json").write_text("{}", encoding="utf-8")

            batch_plan = module.build_merge_batch_plan(
                config,
                [
                    {"shard_id": "shard_1", "start": 0x1000, "status": "ok", "merged_ll": str(shard1_ll)},
                    {"shard_id": "shard_2", "start": 0x2000, "status": "ok", "merged_ll": str(shard2_ll)},
                ],
            )
            self.assertEqual(len(batch_plan), 1)
            batch_ll = batch_plan[0].output
            batch_json = batch_plan[0].summary_out
            batch_ll.write_text("; batch\n", encoding="utf-8")
            batch_json.write_text("{}", encoding="utf-8")

            seed_lift_events = [
                {
                    "shard_id": "shard_1",
                    "tag": "fn_0000000000001000",
                    "name": "a",
                    "start": 0x1000,
                    "entry_pc": 0x50001000,
                    "size": 64,
                    "status": "ok",
                    "rc": 0,
                    "elapsed_sec": 1.0,
                    "workers_spawned": 0,
                    "raw_ll": str(seed_a_raw),
                    "merged_ll": str(seed_a_merged),
                    "fragment_dir": str(layout.fragments_dir / "fn_0000000000001000"),
                    "stdout_log": str(layout.shard_logs_dir / "fn_0000000000001000.stdout.log"),
                    "stderr_log": str(layout.shard_logs_dir / "fn_0000000000001000.stderr.log"),
                    "merge_summary": None,
                },
                {
                    "shard_id": "shard_1",
                    "tag": "fn_0000000000001100",
                    "name": "b",
                    "start": 0x1100,
                    "entry_pc": 0x50001100,
                    "size": 64,
                    "status": "ok",
                    "rc": 0,
                    "elapsed_sec": 1.0,
                    "workers_spawned": 0,
                    "raw_ll": str(seed_b_raw),
                    "merged_ll": str(seed_b_merged),
                    "fragment_dir": str(layout.fragments_dir / "fn_0000000000001100"),
                    "stdout_log": str(layout.shard_logs_dir / "fn_0000000000001100.stdout.log"),
                    "stderr_log": str(layout.shard_logs_dir / "fn_0000000000001100.stderr.log"),
                    "merge_summary": None,
                },
                {
                    "shard_id": "shard_2",
                    "tag": "fn_0000000000002000",
                    "name": "c",
                    "start": 0x2000,
                    "entry_pc": 0x50002000,
                    "size": 64,
                    "status": "ok",
                    "rc": 0,
                    "elapsed_sec": 1.0,
                    "workers_spawned": 0,
                    "raw_ll": str(seed_c_raw),
                    "merged_ll": str(seed_c_merged),
                    "fragment_dir": str(layout.fragments_dir / "fn_0000000000002000"),
                    "stdout_log": str(layout.shard_logs_dir / "fn_0000000000002000.stdout.log"),
                    "stderr_log": str(layout.shard_logs_dir / "fn_0000000000002000.stderr.log"),
                    "merge_summary": None,
                },
            ]
            paths = module.merge_state_paths(layout)
            paths["seed_lift_events"].write_text(
                "".join(json.dumps(item, sort_keys=True) + "\n" for item in seed_lift_events),
                encoding="utf-8",
            )

            restored = module.restore_streaming_merge_state(
                config,
                planned_shards=[shard1, shard2],
            )

            self.assertEqual(restored.progress.lift_completed, 3)
            self.assertEqual(restored.progress.seed_merged, 3)
            self.assertEqual(restored.progress.shard_merged, 2)
            self.assertEqual(restored.progress.batch_merged, 1)
            self.assertEqual(restored.frontier_root_id, batch_plan[0].node_id)
            self.assertEqual(restored.frontier_root_output, batch_ll)
            self.assertIn("fn_0000000000001000", restored.state.seed_merge_completed)
            self.assertIn("shard_1", restored.state.shard_merge_completed)
            self.assertIn(batch_plan[0].node_id, restored.state.batch_merge_completed)

    def test_streaming_merge_scheduler_overlaps_and_deduplicates_seed_merges(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            layout = module.build_layout(Path(tmp), "demo")
            module.materialize_layout(layout)
            config = module.LiftConfig(
                workspace_root=Path("/repo/workspace"),
                repo_root=Path("/repo/workspace/Runnable-Rewriting"),
                groudtruth_repo_root=Path("/repo/workspace/GroudTruth"),
                layout=layout,
                docker_image=module.DEFAULT_RUNNABLE_IMAGE,
                gt_x86_image="bin2415/x86_gt:0.1",
                gt_py_image="bin2415/py_gt",
                runnable_base=0x50000000,
                min_function_size=64,
                max_seeds=0,
                seed_start=None,
                requested_parallel_workers=4,
                max_concurrent_coordinators=2,
                worker_memory_gb=3.0,
                build_memory_gb=16.0,
                memory_headroom_gb=8.0,
                container_memory_limit_gb=24.0,
                rebuild_lift=True,
                ensure_groundtruth=True,
                dry_run=True,
                lift_timeout_sec=1800,
                skip_cmp=False,
                groundtruth_version="canonical",
                groundtruth_openssl_version="3.4.4",
                run_label="demo",
                coordinator_flags=tuple(module.DEFAULT_COORDINATOR_EXTRA_FLAGS),
                execution_model="single-container-shards",
                shard_byte_budget=4096,
                shard_max_seeds=64,
                shard_concurrency=2,
                container_cpus=30.0,
                preserve_success_seed_logs=False,
                streaming_merge=True,
                merge_workers=2,
                merge_batch_size=2,
                merge_poll_interval_sec=0.01,
            )
            shard1 = module.LiftShard(
                shard_id="shard_1",
                seeds=(
                    module.SeedFunction(start=0x1000, size=64, end_exclusive=0x1040, name="a", binding="symtab"),
                ),
                total_size=64,
            )
            shard2 = module.LiftShard(
                shard_id="shard_2",
                seeds=(
                    module.SeedFunction(start=0x2000, size=64, end_exclusive=0x2040, name="b", binding="symtab"),
                ),
                total_size=64,
            )
            results_jsonl = layout.shard_dir / "shard-results.jsonl"
            seed_a = {
                "shard_id": "shard_1",
                "tag": "fn_0000000000001000",
                "name": "a",
                "start": 0x1000,
                "entry_pc": 0x50001000,
                "size": 64,
                "status": "ok",
                "rc": 0,
                "elapsed_sec": 1.0,
                "workers_spawned": 0,
                "raw_ll": str(layout.raw_dir / "fn_0000000000001000.raw.ll"),
                "merged_ll": str(layout.merged_dir / "fn_0000000000001000.ll"),
                "fragment_dir": str(layout.fragments_dir / "fn_0000000000001000"),
                "stdout_log": str(layout.shard_logs_dir / "fn_0000000000001000.stdout.log"),
                "stderr_log": str(layout.shard_logs_dir / "fn_0000000000001000.stderr.log"),
                "merge_summary": None,
            }
            seed_b = {
                "shard_id": "shard_2",
                "tag": "fn_0000000000002000",
                "name": "b",
                "start": 0x2000,
                "entry_pc": 0x50002000,
                "size": 64,
                "status": "ok",
                "rc": 0,
                "elapsed_sec": 1.0,
                "workers_spawned": 0,
                "raw_ll": str(layout.raw_dir / "fn_0000000000002000.raw.ll"),
                "merged_ll": str(layout.merged_dir / "fn_0000000000002000.ll"),
                "fragment_dir": str(layout.fragments_dir / "fn_0000000000002000"),
                "stdout_log": str(layout.shard_logs_dir / "fn_0000000000002000.stdout.log"),
                "stderr_log": str(layout.shard_logs_dir / "fn_0000000000002000.stderr.log"),
                "merge_summary": None,
            }
            results_jsonl.write_text(
                "".join(json.dumps(item, sort_keys=True) + "\n" for item in (seed_a, seed_a, seed_b)),
                encoding="utf-8",
            )

            class FakeProc:
                def __init__(self):
                    self.poll_count = 0
                    self.finished = False

                def poll(self):
                    self.poll_count += 1
                    if self.poll_count < 4:
                        return None
                    self.finished = True
                    return 0

                def wait(self):
                    self.finished = True
                    return 0

            proc = FakeProc()
            merge_calls = []
            overlap_flags = []

            def fake_merge_seed_result(_config, result):
                merge_calls.append(str(result["tag"]))
                overlap_flags.append(not proc.finished)
                merged_ll = layout.merged_dir / f"{result['tag']}.ll"
                merge_summary = layout.manifests_dir / f"{result['tag']}.merge.json"
                merged_ll.write_text("; merged\n", encoding="utf-8")
                merge_summary.write_text("{}", encoding="utf-8")
                updated = dict(result)
                updated["merged_ll"] = str(merged_ll)
                updated["merge_summary"] = str(merge_summary)
                return updated

            def fake_summarize_shard_payload(_config, *, shard_id, seed_results, expected_seed_count, shard_start):
                merged_ll = layout.shard_merged_dir / f"{shard_id}.ll"
                summary = layout.manifests_dir / f"{shard_id}.summary.json"
                merged_ll.write_text("; shard\n", encoding="utf-8")
                summary.write_text("{}", encoding="utf-8")
                return {
                    "shard_id": shard_id,
                    "start": shard_start,
                    "seed_count": expected_seed_count,
                    "ok_seed_count": len(seed_results),
                    "failed_seed_count": 0,
                    "status": "ok",
                    "merged_ll": str(merged_ll),
                    "merge_summary": str(summary),
                    "log_path": str(layout.shard_logs_dir / f"{shard_id}.log"),
                }

            def fake_execute_merge_batch_node(_config, *, node, available_inputs, entry_pc):
                node.output.write_text("; batch\n", encoding="utf-8")
                node.summary_out.write_text("{}", encoding="utf-8")
                return {
                    "node_id": node.node_id,
                    "level": node.level,
                    "index": node.index,
                    "children": list(node.children),
                    "output": str(node.output),
                    "summary_out": str(node.summary_out),
                }

            with mock.patch.object(module, "merge_seed_result", side_effect=fake_merge_seed_result), \
                 mock.patch.object(module, "summarize_shard_payload", side_effect=fake_summarize_shard_payload), \
                 mock.patch.object(module, "execute_merge_batch_node", side_effect=fake_execute_merge_batch_node):
                seed_results, shard_summaries, merge_payload = module.run_streaming_merge_scheduler(
                    config,
                    shard_runner_proc=proc,
                    shard_results_jsonl=results_jsonl,
                    planned_shards=[shard1, shard2],
                )

            self.assertEqual(sorted(merge_calls), ["fn_0000000000001000", "fn_0000000000002000"])
            self.assertEqual(len(merge_calls), 2)
            self.assertTrue(all(overlap_flags))
            self.assertEqual(len(seed_results), 2)
            self.assertEqual(len(shard_summaries), 2)
            self.assertEqual(merge_payload["seed_merge_completed"], 2)
            self.assertEqual(merge_payload["shard_merge_completed"], 2)
            self.assertEqual(merge_payload["batch_merge_completed"], 1)
            self.assertTrue(Path(str(merge_payload["final_frontier_output"])).exists())

    def test_readelf_function_seeds_finds_many_libcrypto_entries(self):
        module = load_module()
        binary = (
            SCRIPT_PATH.parents[3]
            / "GroudTruth"
            / "groundtruth-gap-analysis-skill"
            / "results"
            / "libcrypto-artifacts"
            / "libcrypto.so.3"
        )

        seeds = module.readelf_function_seeds(binary, min_function_size=64)

        self.assertGreater(len(seeds), 1000)
        self.assertEqual(seeds[0].start, min(seed.start for seed in seeds))

    def test_seed_start_can_target_a_specific_libcrypto_function(self):
        module = load_module()
        binary = (
            SCRIPT_PATH.parents[3]
            / "GroudTruth"
            / "groundtruth-gap-analysis-skill"
            / "results"
            / "libcrypto-artifacts"
            / "libcrypto.so.3"
        )

        seeds = module.readelf_function_seeds(binary, min_function_size=64)
        target = next(seed for seed in seeds if seed.name == "X509_ALGOR_set_md")
        filtered = [seed for seed in seeds if seed.start == target.start]

        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0].name, "X509_ALGOR_set_md")


if __name__ == "__main__":
    unittest.main()
