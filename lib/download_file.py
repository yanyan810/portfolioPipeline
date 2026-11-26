"""Google Drive download helper. Never publish partial downloads or OAuth tokens."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile

SCOPES = ['https://www.googleapis.com/auth/drive.readonly']
EXPORTS = {
    'application/vnd.google-apps.presentation': ('application/pdf', '.pdf'),
    'application/vnd.google-apps.document': ('application/pdf', '.pdf'),
    'application/vnd.google-apps.spreadsheet': (
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', '.xlsx'
    ),
}


def clean_filename(name: str) -> str:
    name = re.sub(r'[\\/*?:"<>|\x00-\x1f]', '_', name).strip().rstrip('. ')
    if not name:
        name = 'file'
    if re.match(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)', name, re.I):
        name = '_' + name
    return name


def atomic_write(path: Path, writer) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.download_', suffix='.part', delete=False) as stream:
            temporary = Path(stream.name)
            writer(stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


class GoogleDriveClient:
    def __init__(self, *, service=None, downloader_factory=None, allow_browser=True):
        self.downloader_factory = downloader_factory
        if service is None:
            from googleapiclient.discovery import build
            credentials = self._get_credentials(allow_browser=allow_browser)
            service = build('drive', 'v3', credentials=credentials, cache_discovery=False)
        self.service = service

    def _get_credentials(self, *, allow_browser):
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        from google_auth_oauthlib.flow import InstalledAppFlow

        script_dir = Path(__file__).resolve().parent
        token_path = script_dir / 'token.json'
        credentials_path = script_dir / 'credentials.json'
        credentials = None
        if token_path.exists():
            credentials = Credentials.from_authorized_user_file(str(token_path), SCOPES)
        if not credentials or not credentials.valid:
            if credentials and credentials.expired and credentials.refresh_token:
                credentials.refresh(Request())
            else:
                if not allow_browser:
                    raise RuntimeError('Authentication required. Run: python lib/download_file.py --auth-only')
                if not credentials_path.is_file():
                    raise FileNotFoundError('Place your Desktop OAuth client file at lib/credentials.json.')
                flow = InstalledAppFlow.from_client_secrets_file(str(credentials_path), SCOPES)
                credentials = flow.run_local_server(port=0)
            token_text = credentials.to_json().encode('utf-8')
            atomic_write(token_path, lambda stream: stream.write(token_text))
        return credentials

    def download_file_from_drive(self, file_id: str, output_dir: str | Path) -> Path:
        if not re.fullmatch(r'[A-Za-z0-9_-]+', file_id):
            raise ValueError('Pass a Google Drive file ID, not a URL.')
        files = self.service.files()
        metadata = files.get(fileId=file_id, fields='name,mimeType,capabilities(canDownload)', supportsAllDrives=True).execute(num_retries=3)
        if metadata.get('capabilities', {}).get('canDownload') is False:
            raise PermissionError('This file does not allow download.')
        mime_type = metadata['mimeType']
        name = clean_filename(metadata.get('name', 'file'))
        # Do not allow a remote file name to overwrite authentication or provenance.
        if name.lower() in {'credentials.json', 'token.json', 'collection.json', 'pipeline-result.json'}:
            raise ValueError('Reserved download filename.')
        if mime_type in EXPORTS:
            export_type, suffix = EXPORTS[mime_type]
            if not name.lower().endswith(suffix):
                name += suffix
            request = files.export_media(fileId=file_id, mimeType=export_type)
        elif mime_type.startswith('application/vnd.google-apps.'):
            raise ValueError('Unsupported Google Workspace type (folders and shortcuts are not files).')
        else:
            request = files.get_media(fileId=file_id, supportsAllDrives=True)
        output_path = Path(output_dir) / name
        if output_path.exists() and output_path.is_dir():
            raise IsADirectoryError(f'Download would overwrite a directory: {output_path}')
        factory = self.downloader_factory
        if factory is None:
            from googleapiclient.http import MediaIoBaseDownload
            factory = MediaIoBaseDownload

        def write_chunks(stream):
            downloader = factory(stream, request)
            done = False
            while not done:
                status, done = downloader.next_chunk(num_retries=3)
                if status:
                    print(f'Download: {int(status.progress() * 100)}%')

        atomic_write(output_path, write_chunks)
        return output_path


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file_id', nargs='?')
    parser.add_argument('output_dir', nargs='?')
    parser.add_argument('--auth-only', action='store_true')
    parser.add_argument('--no-browser', action='store_true')
    args = parser.parse_args(argv)
    if not args.auth_only and (not args.file_id or not args.output_dir):
        parser.error('Provide FILE_ID OUTPUT_DIR, or use --auth-only.')
    try:
        client = GoogleDriveClient(allow_browser=not args.no_browser)
        if args.auth_only:
            print('Authentication ready (read-only Drive access).')
        else:
            saved = client.download_file_from_drive(args.file_id, args.output_dir)
            print(json.dumps({'saved_file': str(saved)}, ensure_ascii=True))
        return 0
    except Exception as error:
        # Never print exception payloads that could include a request URL or token.
        if isinstance(error, (FileNotFoundError, ValueError, RuntimeError, PermissionError, IsADirectoryError)):
            print(f'Failed: {error}', file=sys.stderr)
        else:
            status = getattr(getattr(error, 'resp', None), 'status', None)
            print(f'Download/authentication failed ({type(error).__name__}, HTTP {status or "unknown"}). Check access, file ID, credentials and network.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
