'''Container boot regressions without starting or stopping the desktop.'''
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).absolute().parents[1]
HELPER = ROOT / 'scripts/lib/armada-gamescope-startup.sh'
AS_USER = ROOT / 'scripts/lib/as-user.sh'
DOCKERFILE = ROOT / 'ArmadaOS.Dockerfile'


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/lib' / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ArmadaBootTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT.parent / '.cache'
        cache.mkdir(exist_ok=True)
        self.work = Path(tempfile.mkdtemp(prefix='armada-boot-test-', dir=cache))
        self.addCleanup(shutil.rmtree, self.work)

    def run_wait(self, delay=0, fragments=None, alive=True, backend='anland'):
        fifo = self.work / 'startup.fifo'
        os.mkfifo(fifo)
        script = '''source "$1"
socket="$2"
BACKEND="$3"
sleep "$4" &
gamescope_pid=$!
if armada_wait_gamescope_startup; then
    printf 'READY=%s %s\n' "$response_x_display" "$response_wl_display"
    result=0
else
    result=1
fi
kill "$gamescope_pid" 2>/dev/null || true
wait "$gamescope_pid" 2>/dev/null || true
exit "$result"
'''
        process = subprocess.Popen(
            ['bash', '-c', script, 'wait-test', str(HELPER), str(fifo), backend,
             '30' if alive else '0.1'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        writer = None
        if alive:
            def write():
                time.sleep(delay)
                with fifo.open('w') as stream:
                    for chunk, pause in (fragments or [(':27 gamescope-0' + chr(10), 0)]):
                        stream.write(chunk)
                        stream.flush()
                        time.sleep(pause)
            writer = threading.Thread(target=write, daemon=True)
            writer.start()
        try:
            stdout, stderr = process.communicate(timeout=24)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        if writer:
            writer.join(timeout=1)
            self.assertFalse(writer.is_alive())
        return process.returncode, stdout, stderr

    def test_anland_consumer_can_connect_after_vendor_timeout(self):
        result, stdout, stderr = self.run_wait(delay=16.2)
        self.assertEqual(result, 0, stderr)
        self.assertEqual(stdout.strip(), 'READY=:27 gamescope-0')

    def test_partial_fifo_records_survive_timeout(self):
        result, stdout, stderr = self.run_wait(
            fragments=[(':2', 1.3), ('7 gamescope-0' + chr(10), 0)])
        self.assertEqual(result, 0, stderr)
        self.assertEqual(stdout.strip(), 'READY=:27 gamescope-0')

    def test_compositor_exit_is_not_an_infinite_wait(self):
        started = time.monotonic()
        result, stdout, stderr = self.run_wait(alive=False)
        self.assertEqual(result, 1, stderr)
        self.assertLess(time.monotonic() - started, 4)

    def test_other_backends_keep_the_vendor_read(self):
        result, stdout, stderr = self.run_wait(backend='sdl')
        self.assertEqual(result, 0, stderr)
        self.assertEqual(stdout.strip(), 'READY=:27 gamescope-0')

    def test_vendor_patch_preserves_lifecycle_and_is_idempotent(self):
        patch = load('patch-armada-gamescope-startup.py')
        path = self.work / 'session'
        vendor = ('before-startup\n'
                  'if read -r -t 15 response_x_display response_wl_display <>"$socket"; then\n'
                  'export DISPLAY="$response_x_display"\nelse\nkill -9 "$gamescope_pid"\nfi\nafter-startup\n')
        path.write_text(vendor)
        patch.patch_session(path)
        result = path.read_text()
        self.assertIn('source /usr/libexec/armada/gamescope-startup-wait', result)
        self.assertTrue(result.endswith(vendor.split('then\n', 1)[1]))
        patch.patch_session(path)
        self.assertEqual(path.read_text(), result)

    def test_unknown_vendor_startup_fails_before_modifying(self):
        patch = load('patch-armada-gamescope-startup.py')
        path = self.work / 'session'
        path.write_text('unknown session format')
        with self.assertRaises(RuntimeError):
            patch.patch_session(path)
        self.assertEqual(path.read_text(), 'unknown session format')

    def decky_root(self, machine):
        for folder in ['usr/share/decky-loader', 'usr/lib/decky-loader']:
            (self.work / folder).mkdir(parents=True)
        loader = self.work / 'usr/share/decky-loader/PluginLoader'
        loader.write_bytes(self.elf(machine))
        (loader.parent / '.loader.version').write_text('v3.3.0')
        sync = self.work / 'usr/lib/decky-loader/armada-decky-sync'
        sync.write_text('#!/bin/bash\nuser_name=armada\nhomebrew="/var/home/${user_name}/homebrew"\n')
        return loader, sync

    @staticmethod
    def elf(machine):
        return bytes([127, 69, 76, 70, 2, 1]) + bytes(12) + machine.to_bytes(2, 'little')

    def test_native_decky_keeps_version_and_rewrites_user_paths(self):
        decky = load('configure-armada-decky.py')
        loader, sync = self.decky_root(183)
        def no_download(url, output):
            self.fail('native loader must not be downloaded again')
        decky.configure('Gold', self.work, no_download)
        self.assertIn('user_name=Gold', sync.read_text())
        self.assertNotIn('/var/home', sync.read_text())
        dropin = self.work / 'etc/systemd/system/plugin_loader.service.d/zz-armada-container.conf'
        self.assertIn('ExecStart=/home/Gold/homebrew/services/PluginLoader', dropin.read_text())
        self.assertIn('DECKY_USER=Gold', dropin.read_text())
        self.assertTrue(decky.is_arm64(loader))
        decky.configure('Gold', self.work, no_download)

    def test_x86_decky_downloads_matching_arm64_asset(self):
        decky = load('configure-armada-decky.py')
        loader, sync = self.decky_root(62)
        calls = []
        def download(url, output):
            calls.append(url)
            if url.endswith('/tags/v3.3.0'):
                output.write_text(json.dumps({'assets': [
                    {'name': 'PluginLoader', 'browser_download_url': 'https://example.invalid/x86'},
                    {'name': 'PluginLoader-arm64', 'browser_download_url': 'https://example.invalid/arm64'}]}))
            else:
                self.assertEqual(url, 'https://example.invalid/arm64')
                output.write_bytes(self.elf(183))
        decky.configure('Gold', self.work, download)
        self.assertEqual(len(calls), 2)
        self.assertTrue(decky.is_arm64(loader))

    def test_wrong_arch_download_does_not_replace_bundled_loader(self):
        decky = load('configure-armada-decky.py')
        loader, sync = self.decky_root(62)
        before = loader.read_bytes()
        def download(url, output):
            if '/tags/' in url:
                output.write_text(json.dumps({'assets': [
                    {'name': 'PluginLoader-arm64', 'browser_download_url': 'https://example.invalid/bad'}]}))
            else:
                output.write_bytes(self.elf(62))
        with self.assertRaises(RuntimeError):
            decky.configure('Gold', self.work, download)
        self.assertEqual(loader.read_bytes(), before)
        self.assertFalse(list(loader.parent.glob('decky-arm64-*')))


class GamescopeBuildPrivilegeTests(unittest.TestCase):
    '''The gamescope build must not depend on a PAM session.

    CI failed with "runuser: cannot open session: Permission denied" because
    pam_limits needs CAP_SYS_RESOURCE to raise the @pipewire/@gamemode limits,
    and no buildkit RUN has that capability.
    '''

    def setUp(self):
        cache = ROOT.parent / '.cache'
        cache.mkdir(exist_ok=True)
        self.work = Path(tempfile.mkdtemp(prefix='armada-as-user-test-', dir=cache))
        self.addCleanup(shutil.rmtree, self.work)

    def test_dockerfile_never_calls_runuser_directly(self):
        text = DOCKERFILE.read_text()
        self.assertNotIn('runuser -u', text)
        self.assertIn('COPY scripts/lib/as-user.sh /usr/local/bin/as-user', text)

    def test_dockerfile_runs_build_through_the_wrapper(self):
        text = DOCKERFILE.read_text()
        calls = [line for line in text.splitlines()
                 if line.strip().startswith('/usr/local/bin/as-user')]
        self.assertEqual(len(calls), 2, calls)

    def test_wrapper_falls_back_to_setpriv_without_a_session(self):
        text = AS_USER.read_text()
        self.assertIn('setpriv --reuid=', text)
        self.assertIn('runuser -u "$user" -- true', text)
        # The fallback must be reachable even when runuser is present.
        self.assertLess(text.index('runuser -u "$user" -- true'),
                        text.index('setpriv --reuid='))

    def test_wrapper_keeps_a_usable_open_file_budget(self):
        text = AS_USER.read_text()
        self.assertIn('ulimit -Hn 524288', text)
        self.assertIn('ulimit -Sn 524288', text)

    def test_wrapper_rejects_bad_arguments(self):
        for args in ([], ['onlyuser']):
            proc = subprocess.run(['bash', str(AS_USER), *args],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2, proc.stderr)
            self.assertIn('usage: as-user', proc.stderr)

    def run_wrapper(self, *args):
        '''as-user needs root; elevate when the test suite is not root.'''
        command = ['bash', str(AS_USER), *args]
        if os.geteuid() == 0:
            return subprocess.run(command, capture_output=True, text=True)
        sudo = shutil.which('sudo')
        if not sudo:
            self.skipTest('needs root or sudo to switch users')
        probe = subprocess.run([sudo, '-n', 'true'], capture_output=True)
        if probe.returncode != 0:
            self.skipTest('passwordless sudo is not available')
        return subprocess.run([sudo, '-n', *command], capture_output=True, text=True)

    def test_wrapper_rejects_unknown_user(self):
        proc = self.run_wrapper('no-such-user-12345', 'true')
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn('no such user', proc.stderr)

    def test_wrapper_passes_command_and_environment(self):
        '''End to end: the wrapper really runs the command as the target user.'''
        target = 'nobody'
        proc = self.run_wrapper(
            target, 'env', 'AS_USER_PROBE=ok',
            'bash', '-c', 'printf "%s %s %s\\n" "$(id -un)" "$AS_USER_PROBE" "$HOME"')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        name, probe, home = proc.stdout.split()
        self.assertEqual(name, target)
        self.assertEqual(probe, 'ok')
        self.assertTrue(home)


if __name__ == '__main__':
    unittest.main(verbosity=2)