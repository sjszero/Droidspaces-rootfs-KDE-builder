"""Round-trip and failure tests for Release ZIP volumes.

Run: python3 -m unittest discover -s tests -v
Set RUN_LARGE_ZIP_TESTS=1 to exercise the 4,936,509,568-byte CI failure case.
ZIP_TEST_7ZIP can select an older 7-Zip (for example Ubuntu's 23.01).
"""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).absolute().parents[1]
PACKER = ROOT / 'scripts/split-release-assets.sh'
SEVEN_ZIP = os.environ.get('ZIP_TEST_7ZIP') or shutil.which('7zz') or shutil.which('7z')


@unittest.skipUnless(SEVEN_ZIP and shutil.which('zip') and shutil.which('split'),
                     'requires zip, split, and 7-Zip')
class ReleaseZipTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT.parent / '.cache'
        cache.mkdir(exist_ok=True)
        self.work = Path(tempfile.mkdtemp(prefix='rootfs-zip-test-', dir=cache))
        self.addCleanup(shutil.rmtree, self.work)
        self.assets = self.work / 'assets with spaces'
        self.assets.mkdir()
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        (self.bin / '7zz').symlink_to(SEVEN_ZIP)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])

    def archive(self, name='rootfs test.tar.xz'):
        path = self.assets / name
        with tarfile.open(path, 'w:xz') as archive:
            data = os.urandom(160 * 1024)
            info = tarfile.TarInfo('etc/test-payload')
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        return path

    def pack(self, limit):
        return subprocess.run(
            ['bash', str(PACKER), '--assets', str(self.assets), '--limit', str(limit)],
            env=self.env, capture_output=True, text=True, timeout=300)

    def digest(self, path):
        with path.open('rb') as stream:
            return hashlib.file_digest(stream, 'sha256').hexdigest()

    def extract(self, first_volume):
        output = self.work / 'extracted'
        output.mkdir()
        result = subprocess.run(
            [SEVEN_ZIP, 'x', '-y', '-bd', '-bso0', '-o' + str(output), str(first_volume)],
            capture_output=True, text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return output

    def test_zip_volumes_extract_original_tar_xz(self):
        archive = self.archive()
        original = archive.read_bytes()
        result = self.pack(10000)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(archive.exists())
        parts = Path(str(archive) + '.parts').read_text().splitlines()
        self.assertGreater(len(parts), 10)
        self.assertEqual(parts, [archive.name + f'.zip.{i:03d}' for i in range(1, len(parts) + 1)])
        self.assertTrue(all(0 < (self.assets / part).stat().st_size <= 10000 for part in parts))
        self.assertEqual(Path(str(archive) + '.size').read_text().strip(), str(len(original)))
        self.assertEqual(Path(str(archive) + '.sha256').read_text().split()[0],
                         hashlib.sha256(original).hexdigest())
        output = self.extract(self.assets / parts[0])
        self.assertEqual([p.name for p in output.iterdir()], [archive.name])
        self.assertEqual((output / archive.name).read_bytes(), original)
        with tarfile.open(output / archive.name, 'r:xz') as recovered:
            self.assertEqual(recovered.getnames(), ['etc/test-payload'])

    def test_small_archive_stays_whole(self):
        archive = self.archive()
        digest = self.digest(archive)
        result = self.pack(archive.stat().st_size)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(list(self.assets.iterdir()), [archive])
        self.assertEqual(self.digest(archive), digest)

    def test_existing_volume_is_not_overwritten(self):
        archive = self.archive()
        volume = Path(str(archive) + '.zip.001')
        volume.write_bytes(b'existing volume')
        result = self.pack(10000)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(archive.exists())
        self.assertEqual(volume.read_bytes(), b'existing volume')

    def assert_failed_tool_preserves_input(self, tool):
        archive = self.archive()
        digest = self.digest(archive)
        shim = self.bin / tool
        if shim.is_symlink():
            shim.unlink()
        shim.write_text(chr(10).join(['#!/bin/sh', 'printf partial-zip', 'exit 42', '']))
        shim.chmod(0o755)
        result = self.pack(10000)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.digest(archive), digest)
        self.assertEqual(list(self.assets.iterdir()), [archive])

    def test_failed_zip_preserves_original(self):
        self.assert_failed_tool_preserves_input('zip')

    def test_failed_split_preserves_original(self):
        self.assert_failed_tool_preserves_input('split')

    def test_failed_validation_preserves_original(self):
        self.assert_failed_tool_preserves_input('7zz')

    @unittest.skipUnless(os.environ.get('RUN_LARGE_ZIP_TESTS') == '1',
                         'set RUN_LARGE_ZIP_TESTS=1 for the >4 GiB regression')
    def test_ci_sized_zip64_round_trip(self):
        # Sparse payload exercises ZIP64 size/offset handling without allocating
        # gigabytes of random test data. Small tests above use a real tar.xz.
        archive = self.assets / 'ci-sized.tar.xz'
        size = 4936509568
        limit = 1900 * 1024 * 1024
        with archive.open('wb') as stream:
            stream.truncate(size)
            for offset in [0, 2**31 - 16, 2**32 - 16, size - 16]:
                stream.seek(offset)
                stream.write(b'ZIP64-boundary!!')
        digest = self.digest(archive)
        print(f'ZIP64 regression: packing {size} bytes with {limit}-byte volumes', flush=True)
        result = self.pack(limit)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout, end='', flush=True)
        parts = Path(str(archive) + '.parts').read_text().splitlines()
        self.assertEqual(parts, [archive.name + f'.zip.{i:03d}' for i in range(1, 4)])
        self.assertTrue(all(0 < (self.assets / part).stat().st_size <= limit for part in parts))
        self.assertEqual(Path(str(archive) + '.size').read_text().strip(), str(size))
        self.assertEqual(Path(str(archive) + '.sha256').read_text().split()[0], digest)
        print('ZIP64 regression: extracting .zip.001 and checking recovered SHA-256', flush=True)
        output = self.extract(self.assets / parts[0])
        recovered = output / archive.name
        self.assertEqual([p.name for p in output.iterdir()], [archive.name])
        self.assertEqual(recovered.stat().st_size, size)
        self.assertEqual(self.digest(recovered), digest)
        self.assertFalse(archive.exists())
        print('ZIP64 regression: extracted original filename, size, and SHA-256 all match', flush=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
