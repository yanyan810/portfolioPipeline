import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

MODULE_PATH = Path(__file__).resolve().parents[1] / 'lib' / 'download_file.py'
spec = importlib.util.spec_from_file_location('download_file', MODULE_PATH)
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)


class Downloader:
    def __init__(self, stream, request):
        self.stream = stream

    def next_chunk(self, num_retries):
        self.stream.write(b'complete file')
        return None, True


class BrokenDownloader(Downloader):
    def next_chunk(self, num_retries):
        self.stream.write(b'incomplete')
        raise OSError('simulated disconnect')


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name)
        self.files = Mock()
        self.service = Mock()
        self.service.files.return_value = self.files
        self.files.get.return_value.execute.return_value = {
            'name': 'program.zip', 'mimeType': 'application/zip'
        }

    def client(self, factory=Downloader):
        return download.GoogleDriveClient(service=self.service, downloader_factory=factory)

    def test_binary_download_and_filename(self):
        saved = self.client().download_file_from_drive('file_1', self.output)
        self.assertEqual(saved.read_bytes(), b'complete file')
        self.files.get_media.assert_called_once_with(fileId='file_1', supportsAllDrives=True)
        self.assertEqual(list(self.output.glob('*.part')), [])

    def test_slides_are_exported_as_pdf(self):
        self.files.get.return_value.execute.return_value = {
            'name': 'Presentation', 'mimeType': 'application/vnd.google-apps.presentation'
        }
        saved = self.client().download_file_from_drive('slides_1', self.output)
        self.assertEqual(saved.name, 'Presentation.pdf')
        self.files.export_media.assert_called_once_with(fileId='slides_1', mimeType='application/pdf')
        self.files.get_media.assert_not_called()

    def test_failed_transfer_keeps_previous_file_and_removes_partial(self):
        previous = self.output / 'program.zip'
        previous.write_bytes(b'previous successful download')
        with self.assertRaises(OSError):
            self.client(BrokenDownloader).download_file_from_drive('file_1', self.output)
        self.assertEqual(previous.read_bytes(), b'previous successful download')
        self.assertEqual([f.name for f in self.output.iterdir()], ['program.zip'])

    def test_failed_new_transfer_leaves_no_file(self):
        with self.assertRaises(OSError):
            self.client(BrokenDownloader).download_file_from_drive('file_1', self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_traversal_name_is_sanitized(self):
        self.files.get.return_value.execute.return_value['name'] = '../bad:name.zip'
        saved = self.client().download_file_from_drive('file_1', self.output)
        self.assertEqual(saved.parent, self.output)
        self.assertNotIn('/', saved.name)
        self.assertNotIn(':', saved.name)

    def test_reserved_windows_name(self):
        self.assertEqual(download.clean_filename('CON.txt'), '_CON.txt')
        self.assertEqual(download.clean_filename('..'), 'file')

    def test_download_permission_is_checked(self):
        self.files.get.return_value.execute.return_value['capabilities'] = {'canDownload': False}
        with self.assertRaises(PermissionError):
            self.client().download_file_from_drive('file_1', self.output)
        self.files.get_media.assert_not_called()

    def test_auth_and_provenance_names_cannot_be_overwritten(self):
        for name in ('token.json', 'credentials.json', 'collection.json', 'pipeline-result.json'):
            with self.subTest(name=name):
                self.files.get.return_value.execute.return_value['name'] = name
                with self.assertRaises(ValueError):
                    self.client().download_file_from_drive('file_1', self.output)

    def test_google_folder_is_rejected(self):
        self.files.get.return_value.execute.return_value['mimeType'] = 'application/vnd.google-apps.folder'
        with self.assertRaises(ValueError):
            self.client().download_file_from_drive('file_1', self.output)

    def test_url_instead_of_id_is_rejected(self):
        with self.assertRaises(ValueError):
            self.client().download_file_from_drive('https://drive.google.com/file/d/a', self.output)
        self.files.get.assert_not_called()

    def test_cli_returns_nonzero_and_hides_unexpected_exception_payload(self):
        stderr = io.StringIO()
        with patch.object(download, 'GoogleDriveClient', side_effect=OSError('private token content')):
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(download.main(['file_1', str(self.output), '--no-browser']), 1)
        self.assertNotIn('private token content', stderr.getvalue())

    def test_atomic_write_failure_preserves_existing_file(self):
        target = self.output / 'token.json'
        target.write_bytes(b'old')

        def fail(stream):
            stream.write(b'partial token')
            raise RuntimeError('write failed')

        with self.assertRaises(RuntimeError):
            download.atomic_write(target, fail)
        self.assertEqual(target.read_bytes(), b'old')
        self.assertEqual(len(list(self.output.iterdir())), 1)


if __name__ == '__main__':
    unittest.main()
