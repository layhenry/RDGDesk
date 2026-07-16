#!/usr/bin/env python3
import pathlib
import socket
import ssl
import sys


CERTIFICATE = """-----BEGIN CERTIFICATE-----
MIICpDCCAYwCCQCKEz47R8e4xjANBgkqhkiG9w0BAQsFADAUMRIwEAYDVQQDDAls
b2NhbGhvc3QwHhcNMjYwNzE0MDkzODQ5WhcNMzYwNzExMDkzODQ5WjAUMRIwEAYD
VQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCu
BksNCdka509wy7qPOI7hzA60O8nJdsr8JHyuZWNaygiTABdRpwfIrxwPE39Ofccu
VxSYwQBpX+ZwnuUHqPhEWpI9N1t58BHtZR86VIFeChfDH3iWZulkmwQ7EdRBNcwi
3HK1niiPerTUXoIEcJjzhArF1fvUxQwdUiDTuQ6AIvQQExMADfwAE7yIpZLQaesw
Eh2ZB/pelBVrE7k/b/4xlcrVIyfWoqvusoGDyj4u1fOH4cLDmCXI1riypGjS37n1
zz09Q9s5o10ZfqXnBaEvnIyMCrGETn7Y0KCevmp+3mocKnA29jMG7Aen2cvk0bGM
jl/ugdikWt6YxnLBs7u7AgMBAAEwDQYJKoZIhvcNAQELBQADggEBAINJfuPPq0aV
GCA6c8YHMYk8z7GPhO0sWj1KJ1swEehHLCRwJTh3DjyVYdCaTwbZF52sq0ajkJEr
8BXaknijgqUCvcSeUAb1t1ZYudCvMlqw60piNrhK6nJvk4cMAmqZgb/v4fTBu0xR
b8IOI2i4tprN5IzCDGucYATx8Jip23hi4XOFRq/MTFjylxqMQkCGDUmBtnpQU5iW
nodjlUa26rmYEeyjeuI0e0i6YY0Azs2/MAWxii8La5SK93O1xDvMYuN4wq6VViwX
Iwdlt2ciBVfuaIRFAh82h1ANwaKKUKh9zPkmA0a8QsEutewQl3qnNGDx0oeNY4be
bPSBkwYTrZ8=
-----END CERTIFICATE-----
"""

# Throwaway key for the localhost-only TLS integration fixture. It is never used
# by the application or for a real server. Its exact scanner fingerprint is
# documented in .gitleaksignore so other private keys remain detectable.
PRIVATE_KEY = """-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCuBksNCdka509w
y7qPOI7hzA60O8nJdsr8JHyuZWNaygiTABdRpwfIrxwPE39OfccuVxSYwQBpX+Zw
nuUHqPhEWpI9N1t58BHtZR86VIFeChfDH3iWZulkmwQ7EdRBNcwi3HK1niiPerTU
XoIEcJjzhArF1fvUxQwdUiDTuQ6AIvQQExMADfwAE7yIpZLQaeswEh2ZB/pelBVr
E7k/b/4xlcrVIyfWoqvusoGDyj4u1fOH4cLDmCXI1riypGjS37n1zz09Q9s5o10Z
fqXnBaEvnIyMCrGETn7Y0KCevmp+3mocKnA29jMG7Aen2cvk0bGMjl/ugdikWt6Y
xnLBs7u7AgMBAAECggEANf6B3sPFdtF6Fnc/pRxZSLm1fjpmu3l+NYlknf+bOhoh
WurWUWFPyvZ58DuObl4cJMaj/1kytX8p0puaWCwXC65GXXQFj+nqxgtwCvsZQIJF
KSdklNXNaIeoYmN/xdPZSJ+5f5xY3VunK5U/Jf2Bl1zKsuNXxYZ14csPoGF0nFC4
3j1jHjKGjHygUozfauwjYlvr6JUiXqB7xDZLyg7dhOnBa2c7c5gcnfyf+DP8gS5I
FEgOmkZk0+k07woWLML2tfEQHLY1xzF3vDt0Pytci93EHaf8dmSE9xdbEXI8wgvQ
1LqjtLtK8Sj7VMOwhiMtgjLe9/mII3grgY3a8thscQKBgQDeOr2KKLUvx64ImRu4
iDEBICqajGu3P7Cvfi6bd2NdJmgffRTQ7ZVdQlboZHGeLh9PQ4se8DScNLMzM7OD
Z1mQDC7bSK8s7iWzyuPEk3norB7NmW8OVp4LBPjojtoBTRrAm7j+fWTcfkoLVvLR
KBp5UkD9bYDJXJj4xOwURZKabQKBgQDIeER4jieP+mptKp6mvgSDC+jX0oIWtP9r
ALxTVXL9NBQ73BbQcQBpqhnnxdVn3Oxowrzh/WAstnuwf9WpbogCKv7OGqxeW4O3
yf6pF7lmY0hdlfimJRc31GR+3oyVDbM1d7zZ82R45eYKJIxeDBxE+fbAqiQiIIyO
J+92kqXVxwKBgQDGS+X7VS2v796kP3LT63rGxVwewfQP9R4EynRuN08LvIympGch
sw5XxC1metJDUmaPxPZr6e0YAZJxus2REHSDq8tX0ni1f99WmlE5hFsAui1WSnYl
djbaIFq2sVloVdPsUEf3lg6dDXemvLQ43C8bWMEzIjYL97tsJ9N8l0Qk1QKBgDm5
X8Xy8PNlYPXUOuC6gGQXrtFOfUT6kz2FdbTtOvIr59OguTUGBN9oKpNxhNSmabB0
upy8L9BQL2eQN77U4/bz2HESfyWgZloqoNihyzHvTqwb/gAhWAEseE+L16En072G
n+uGSR0C3e13vq9p/03hSCsMEuF8y9w3JZ3X9kaLAoGBANi+Kxkef+H6uLxx0Lgs
xqK3ak7LDbKQFQqmrvuvYwAXs+ZjUhPKRkLU48X0ocPcelspnRzIHi5eHqPUjmLI
cXbZnDGogdlJXqlWIUOFJIDi9nmM4ZHRZe0F1yIMvGy8+LewfrojEiKz1G/SpI4c
EQe5quhYKdYYsD04i0HN/CdO
-----END PRIVATE KEY-----
"""


def receive_tpkt(connection):
    packet = b""
    while len(packet) < 4:
        packet += connection.recv(4096)
    length = int.from_bytes(packet[2:4], "big")
    while len(packet) < length:
        packet += connection.recv(4096)


def main():
    directory = pathlib.Path(sys.argv[1])
    directory.mkdir(parents=True, exist_ok=True)
    certificate_path = directory / "server.crt"
    key_path = directory / "server.key"
    ready_path = directory / "ready"
    handshake_path = directory / "handshake-complete"
    certificate_path.write_text(CERTIFICATE)
    key_path.write_text(PRIVATE_KEY)

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate_path, key_path)
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        ready_path.write_text(str(listener.getsockname()[1]))
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(10)
            receive_tpkt(connection)
            connection.sendall(bytes.fromhex(
                "030000130ed000001234000200080001000000"
            ))
            with context.wrap_socket(connection, server_side=True) as tls:
                handshake_path.write_text("ok")
                tls.settimeout(2)
                try:
                    tls.recv(4096)
                except socket.timeout:
                    pass


if __name__ == "__main__":
    main()
