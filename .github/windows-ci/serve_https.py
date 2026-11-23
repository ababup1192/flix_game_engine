"""Windows の CI（.github/workflows/windows.yml）で、出す前の版を GitHub の Release の代わりに https で配る。

    python serve_https.py <配るフォルダ> <port> <cert.pem> <key.pem>

<配るフォルダ>/dl/ に fge-windows-amd64.exe・fge-SHA256SUMS.txt・install.ps1・engine の zip・SHA256SUMS.txt、
<配るフォルダ>/api/repos/<owner>/<repo>/releases/latest に Release の JSON を置く（FGE_DOWNLOAD_URL・FGE_RELEASES_API が指す）。

WhyNot: 平文の http で配らない — fge は zip と照合の値が同じ経路で来るので http の置き場を断る（fetchengine の lookUp）。
"""

import functools
import http.server
import ssl
import sys


def main() -> None:
    root, port, cert, key = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
