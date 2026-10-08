"""TEST ONLY: delayed real Core filesystem operations, never production-loaded."""
import importlib.util
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('controlled_adapter', ROOT / 'integrations/music-renamer/adapter.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
load = adapter._load_core
case = Path(os.environ['YAD_TEST_CONTROL'])
scenario = os.environ['YAD_TEST_SCENARIO']


def barrier():
    (case / 'ready').write_text(str(os.getpid()), encoding='ascii')
    deadline = time.monotonic() + 25
    while not (case / 'release').exists():
        if time.monotonic() > deadline:
            raise RuntimeError('test barrier timed out')
        time.sleep(.02)


def controlled_load(manifest):
    if scenario == 'cancel_before':
        barrier()
    core, identity = load(manifest)
    from music_renamer_core.filesystem import LocalFileSystem, RenamePhase
    executor = core.RenameExecutor
    class DelayedFileSystem(LocalFileSystem):
        def rename_no_replace(self, source, destination, *, phase):
            if phase is RenamePhase.STAGE:
                super().rename_no_replace(source, destination, phase=phase)
                barrier()  # actual staged file; adapter must not be killed here
                if scenario in ('crash_execution','cancel_crash'):
                    os._exit(9)
                return
            if phase is RenamePhase.COMMIT and scenario in ('cancel_rollback','cancel_incomplete'):
                raise OSError('controlled commit failure')
            if phase is RenamePhase.ROLLBACK_RESTORE and scenario == 'cancel_incomplete':
                raise OSError('controlled rollback failure')
            return super().rename_no_replace(source, destination, phase=phase)
    if scenario in ('cancel_before','cancel_planning','cancel_preflight'):
        if scenario == 'cancel_planning':
            planner = core.RenamePlanner
            class DelayedPlanner(planner):
                def plan(self, paths):
                    barrier()
                    return super().plan(paths)
            core.RenamePlanner = DelayedPlanner
        elif scenario == 'cancel_preflight':
            preflight = core.preflight
            def delayed_preflight(plan):
                barrier()
                return preflight(plan)
            core.preflight = delayed_preflight
    else:
        core.RenameExecutor = lambda: executor(filesystem=DelayedFileSystem())
    return core, identity


adapter._load_core = controlled_load
raise SystemExit(adapter.main())
