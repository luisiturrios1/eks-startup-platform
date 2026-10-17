"""Exercise the production MySQL connector against hostile loopback handshakes."""
from concurrent.futures import ThreadPoolExecutor
import importlib.util
from pathlib import Path
import socket
import ssl
import struct
import subprocess

import pymysql
from pymysql.constants import CLIENT, CR
import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('credential_manager_tls', ROOT/'components/credential-manager/handler.py')
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


@pytest.fixture
def certificates(tmp_path):
    for name, identity in [('server', 'IP:127.0.0.1'), ('wrong', 'DNS:wrong.example'), ('other', 'DNS:other.example')]:
        subprocess.run([
            'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-keyout', str(tmp_path/f'{name}.key'), '-out', str(tmp_path/f'{name}.pem'),
            '-subj', '/CN=test-only', '-addext', 'subjectAltName=' + identity,
        ], check=True, capture_output=True)
    return tmp_path


@pytest.mark.parametrize('attack', ['plaintext', 'wrong_hostname', 'untrusted_ca'])
def test_mysql_rejects_tls_downgrade_and_invalid_identity(attack, certificates, monkeypatch):
    # A protocol-v10 greeting is enough to exercise TLS before any authentication.
    capabilities = CLIENT.PROTOCOL_41 | CLIENT.SECURE_CONNECTION
    if attack != 'plaintext':
        capabilities |= CLIENT.SSL
    greeting = (b'\x0a8.0.0\x00' + struct.pack('<I', 1) + b'12345678\x00'
                + struct.pack('<HBHHB', capabilities & 0xffff, 45, 2, capabilities >> 16, 21)
                + b'\x00' * 10 + b'abcdefghijkl\x00')
    packet = len(greeting).to_bytes(3, 'little') + b'\x00' + greeting
    presented = 'wrong' if attack == 'wrong_hostname' else 'server'
    trusted = 'other' if attack == 'untrusted_ca' else presented
    monkeypatch.setenv('RDS_CA_BUNDLE', str(certificates/f'{trusted}.pem'))

    with socket.socket() as listener, ThreadPoolExecutor(max_workers=1) as executor:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(5)

        def hostile_server():
            with listener.accept()[0] as connection:
                connection.settimeout(5)
                connection.sendall(packet)
                first = connection.recv(4)
                if attack == 'plaintext':
                    assert first == b'', 'Client must not send credentials without TLS'
                    return
                assert len(first) == 4
                length = int.from_bytes(first[:3], 'little')
                request = bytearray()
                while len(request) < length:
                    chunk = connection.recv(length - len(request))
                    assert chunk
                    request.extend(chunk)
                assert len(request) == 32, 'Only SSLRequest may precede verified TLS'
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(certificates/f'{presented}.pem', certificates/f'{presented}.key')
                with pytest.raises(ssl.SSLError):
                    context.wrap_socket(connection, server_side=True)

        server = executor.submit(hostile_server)
        with pytest.raises(pymysql.OperationalError) as error:
            manager.connect({'engine': 'mysql', 'host': '127.0.0.1', 'port': listener.getsockname()[1]},
                            {'username': 'probe', 'password': 'test-only'})
        if attack == 'plaintext':
            assert error.value.args[0] == CR.CR_SSL_CONNECTION_ERROR
        else:
            assert isinstance(error.value.original_exception, ssl.SSLCertVerificationError)
        server.result(timeout=6)
