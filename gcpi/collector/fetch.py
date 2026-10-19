"""
GCPI collectors (#92): the one way a collector or notary reaches a publisher. HTTPS to a declared host
only, no redirects, a size cap and a fresh cookie jar per retrieval, so two retrievals share no state.
"""

import http.cookiejar
import urllib.parse
import urllib.request

USER_AGENT = "GCPI-collector (https://github.com/bytesbrains/copra)"
MAX_BYTES = 5_000_000


class SourceError(Exception):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # A redirect could leave the declared host, so it is a failure, not something to follow.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SourceError(f"redirected ({code}) to {newurl}; redirects are not followed")


class Transport:
    """HTTPS GET and form POST to the hosts given, and nowhere else."""

    def __init__(self, hosts, timeout=90):
        self.hosts = set(hosts)
        self.timeout = timeout
        self._opener = urllib.request.build_opener(
            _NoRedirect, urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self._opener.addheaders = [("User-Agent", USER_AGENT)]

    def _open(self, url, data=None):
        u = urllib.parse.urlsplit(url)
        if u.scheme != "https" or u.hostname not in self.hosts:
            raise SourceError(f"{url}: not a declared https host")
        try:
            with self._opener.open(url, data, timeout=self.timeout) as resp:
                body = resp.read(MAX_BYTES + 1)
        except SourceError:
            raise
        except OSError as e:
            raise SourceError(f"{u.hostname}: {e}") from e
        if len(body) > MAX_BYTES:
            raise SourceError(f"{u.hostname}: response larger than {MAX_BYTES} bytes")
        return body

    def get(self, url):
        return self._open(url)

    def post(self, url, pairs):
        return self._open(url, urllib.parse.urlencode(pairs).encode())
