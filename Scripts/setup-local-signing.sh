#!/bin/sh
set -eu

identity_name="RiftBuilder Local Development"
login_keychain=$(/usr/bin/security login-keychain | /usr/bin/xargs)

if /usr/bin/security find-identity -v -p codesigning "$login_keychain" | /usr/bin/grep -Fq "\"$identity_name\""; then
    echo "$identity_name is already available."
    exit 0
fi

temporary_directory=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/riftbuilder-local-signing.XXXXXX")
private_key="$temporary_directory/private-key.pem"
certificate="$temporary_directory/certificate.pem"
identity_archive="$temporary_directory/identity.p12"
archive_password=$(/usr/bin/openssl rand -hex 24)

cleanup() {
    /bin/rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

if /usr/bin/security find-certificate -c "$identity_name" "$login_keychain" >/dev/null 2>&1; then
    /usr/bin/security find-certificate -c "$identity_name" -p "$login_keychain" > "$certificate"
else
    /usr/bin/openssl req \
        -new \
        -newkey rsa:3072 \
        -x509 \
        -sha256 \
        -days 3650 \
        -nodes \
        -keyout "$private_key" \
        -out "$certificate" \
        -subj "/CN=$identity_name/O=RiftBuilder Local" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" \
        -addext "extendedKeyUsage=codeSigning"

    /usr/bin/openssl pkcs12 \
        -export \
            -out "$identity_archive" \
        -inkey "$private_key" \
        -in "$certificate" \
        -name "$identity_name" \
        -passout "pass:$archive_password"

    /usr/bin/security import "$identity_archive" \
        -k "$login_keychain" \
        -P "$archive_password" \
        -T /usr/bin/codesign
fi

echo "macOS may request one password authorization to trust this certificate for code signing."
/usr/bin/security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$login_keychain" \
    "$certificate"

if ! /usr/bin/security find-identity -v -p codesigning "$login_keychain" | /usr/bin/grep -Fq "\"$identity_name\""; then
    echo "The local signing identity was imported but is not trusted for code signing." >&2
    exit 1
fi

echo "$identity_name is ready. Future local builds will keep a stable Keychain identity."
