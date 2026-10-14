#!/usr/bin/env python3
"""App Store Connect helpers for the build workflow: only the standard library, plus `openssl` to sign
the ES256 JWT and, on macOS, `security` to read the keychain.

Commands:
  check                Checks that the API key works and that at least one iOS device is registered.
  write-key PATH       Writes the API key to PATH as a .p8 file, for xcodebuild's -authenticationKeyPath.
  keychain-serials     Prints the serial numbers of the "Apple Development" certificates in the keychain.
  revoke-new FILE      Revokes, through the API, the "Apple Development" certificates in the keychain that
                       FILE (an earlier `keychain-serials` output) did not list: the ones xcodebuild created
                       during this run.

Environment: ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 (the contents of the .p8 file).
"""

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"


def fail(message):
    print(f"::error title=App Store Connect::{message}")
    sys.exit(1)


def warn(message):
    print(f"::warning title=App Store Connect::{message}")


def env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        fail(f"{name} is not set.")
    return value


def private_key():
    """The .p8 contents, also when the secret was saved base64-encoded or with literal \\n."""
    key = env("ASC_KEY_P8").replace("\\n", "\n").strip()
    if "-----BEGIN" not in key:
        try:
            decoded = base64.b64decode(key, validate=False).decode("utf-8", "replace")
        except ValueError:
            decoded = ""
        if "-----BEGIN" in decoded:
            key = decoded.strip()
    if "-----BEGIN PRIVATE KEY-----" not in key:
        fail("ASC_KEY_P8 does not look like a .p8 key: paste the whole file, BEGIN and END lines included.")
    return key + "\n"


def write_key(path):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as file:
        file.write(private_key())


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(signature):
    """openssl signs ECDSA as DER (SEQUENCE of two INTEGERs); a JWT wants r and s, 32 bytes each."""

    def read_length(index):
        length = signature[index]
        index += 1
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(signature[index:index + count], "big")
            index += count
        return length, index

    def read_integer(index):
        if signature[index] != 0x02:
            raise ValueError("expected an INTEGER")
        length, index = read_length(index + 1)
        value = signature[index:index + length].lstrip(b"\x00").rjust(32, b"\x00")
        return value, index + length

    if signature[0] != 0x30:
        raise ValueError("expected a SEQUENCE")
    _, index = read_length(1)
    r, index = read_integer(index)
    s, _ = read_integer(index)
    return r + s


def token():
    now = int(time.time())
    header = {"alg": "ES256", "kid": env("ASC_KEY_ID"), "typ": "JWT"}
    payload = {"iss": env("ASC_ISSUER_ID"), "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = ".".join(
        b64url(json.dumps(part, separators=(",", ":")).encode()) for part in (header, payload)
    )

    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "key.p8")
        write_key(path)
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", path],
            input=signing_input.encode(),
            capture_output=True,
        )
    if result.returncode != 0:
        fail(f"openssl could not sign with ASC_KEY_P8: {result.stderr.decode().strip()}")
    return f"{signing_input}.{b64url(der_to_raw(result.stdout))}"


def call(method, url, bearer):
    if not url.startswith("https://"):
        url = API + url
    request = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read()
            return response.status, json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        body = error.read()
        try:
            return error.code, json.loads(body)
        except ValueError:
            return error.code, None
    except urllib.error.URLError as error:
        fail(f"Could not reach App Store Connect: {error.reason}")


def errors_of(data):
    errors = (data or {}).get("errors") or []
    return "; ".join(f"{e.get('title', '')}: {e.get('detail', '')}".strip(": ") for e in errors) or "no details"


def get_all(path, query, bearer):
    """Every item of a list, following the pages."""
    url = f"{path}?{urllib.parse.urlencode(query)}"
    items = []
    while url:
        status, data = call("GET", url, bearer)
        if status != 200:
            return status, data, items
        items += data.get("data", [])
        url = (data.get("links") or {}).get("next")
    return 200, None, items


def check():
    bearer = token()
    query = {"filter[platform]": "IOS", "filter[status]": "ENABLED", "limit": 200}
    status, data, devices = get_all("/v1/devices", query, bearer)
    if status == 401:
        fail(f"App Store Connect rejected the API key (401): check ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8. {errors_of(data)}")
    if status == 403:
        fail(f"The API key is not allowed to list devices (403): it must be a Team Key with the Admin role. {errors_of(data)}")
    if status != 200:
        fail(f"App Store Connect answered {status}: {errors_of(data)}")
    if not devices:
        fail("The API key works, but no iOS device is registered: register an iPhone's UDID in "
             "developer.apple.com › Certificates, IDs & Profiles › Devices.")

    print(f"The API key works. {len(devices)} iOS device(s) registered:")
    for device in devices:
        attributes = device.get("attributes", {})
        print(f"  - {attributes.get('name', '?')} ({attributes.get('model') or attributes.get('deviceClass', '?')})")


def keychain_serials():
    """Serial numbers, normalised, of the "Apple Development" certificates in the keychain search list."""
    result = subprocess.run(
        ["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
        capture_output=True,
        text=True,
    )
    serials = []
    for pem in re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", result.stdout, re.S):
        output = subprocess.run(
            ["openssl", "x509", "-noout", "-serial"], input=pem, capture_output=True, text=True
        ).stdout
        match = re.search(r"serial=([0-9A-Fa-f]+)", output)
        if match:
            serials.append(normalise(match.group(1)))
    return sorted(set(serials))


def normalise(serial):
    return serial.strip().upper().lstrip("0") or "0"


def revoke_new(before_path):
    if not os.path.exists(before_path):
        print("The keychain was never read before the archive: nothing to revoke.")
        return
    with open(before_path) as file:
        before = {normalise(line) for line in file if line.strip()}

    new = [serial for serial in keychain_serials() if serial not in before]
    if not new:
        print("xcodebuild created no Apple Development certificate during this run.")
        return

    bearer = token()
    status, data, certificates = get_all("/v1/certificates", {"limit": 200}, bearer)
    if status != 200:
        warn(f"Could not list the certificates ({status}): {errors_of(data)}. Revoke by hand: {', '.join(new)}")
        return

    for serial in new:
        matches = [c for c in certificates if normalise(c["attributes"].get("serialNumber", "")) == serial]
        if not matches:
            warn(f"The certificate {serial} is in the keychain but not in App Store Connect: nothing to revoke.")
            continue
        for certificate in matches:
            name = certificate["attributes"].get("name", "")
            status, data = call("DELETE", f"/v1/certificates/{certificate['id']}", bearer)
            if status in (200, 204):
                print(f"Revoked {name} ({serial}).")
            else:
                warn(f"Could not revoke {name} ({serial}): {status} {errors_of(data)}")


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "check":
        check()
    elif command == "write-key" and len(sys.argv) == 3:
        write_key(sys.argv[2])
    elif command == "keychain-serials":
        print("\n".join(keychain_serials()))
    elif command == "revoke-new" and len(sys.argv) == 3:
        revoke_new(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
