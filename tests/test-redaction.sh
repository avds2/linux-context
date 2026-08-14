#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/common.sh"
source "$ROOT/lib/redact.sh"
init_redaction
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/in" <<'DATA'
DB_PASSWORD=supersecret
"token": "json-secret-token"
client_secret: yamlsecret
clientSecret=json-camel-client-secret
dbPassword=camel-db-password
AWS_SECRET_ACCESS_KEY=aws-super-secret
OPENAI_API_KEY=not-a-real-openai-key
db_password: |
  multiline-secret-line-1
  multiline-secret-line-2
<dbPassword>xml-super-secret</dbPassword>
password hunter2
Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345
Proxy-Authorization: Basic dXNlcjpwYXNz
X-Api-Key: my-api-key-value
X-Goog-Api-Key: google-header-secret
Authorization: AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/20260812/region/service/aws4_request, SignedHeaders=host, Signature=aws-signature-secret
Cookie: session=abc123
BareAuth=Bearer abcdefghijklmnopqrstuvwxyz987654
curl -u bob:curlpass https://example.test
SetCredential=database:systemd-credential-secret
requirepass=redis-secret
requirepass redis-space-secret
masterauth redis-master-secret
PGPASSWORD=postgres-env-secret
REDISCLI_AUTH=redis-cli-auth-secret
user api insecure-password haproxy-user-secret
proxy_set_header X-Api-Key nginx-header-secret;
header_up Authorization caddy-header-secret
proxy_set_header X-Api-Key $upstream_api_key;
sshpass -p sshpass-secret ssh host
systemd.set_credential=db:kernel-credential-secret
netrc=machine example.test login alice password netrc-secret
docker={"auth":"dXNlcjpkb2NrZXItc2VjcmV0"}
//registry.npmjs.org/:_authToken=npmrc-secret-token
_auth=npmrc-basic-secret
ACL SETUSER alice on >redis-acl-plaintext ~* +@all
user bob on #0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef ~cached:* +get
url=https://alice:hunter2@example.test/path
redis=redis://:redis-url-secret@example.test/0
endpoint=https://example.test/api?token=querysecret&ok=1
signed=https://example.test/blob?sv=1&sig=azure-signature-secret&ok=1
oauth=https://example.test/callback?code=oauth-code-secret&state=public-state
apikeyquery=https://example.test/v1?key=query-key-secret&resource=42
curl --token cli-secret-value https://example.test
jwt=eyJabcdefghijk.abcdefghijk.abcdefghijk
github=ghp_abcdefghijklmnopqrstuvwxyz012345
-----BEGIN OPENSSH PRIVATE KEY-----
abc123
-----END OPENSSH PRIVATE KEY-----
-----BEGIN ENCRYPTED PRIVATE KEY-----
encrypted-pem-secret
-----END ENCRYPTED PRIVATE KEY-----
-----BEGIN PGP PRIVATE KEY BLOCK-----
pgp-private-secret
-----END PGP PRIVATE KEY BLOCK-----
-----BEGIN OpenVPN Static key V1-----
openvpn-static-secret
-----END OpenVPN Static key V1-----
age=AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ
htpasswd=user:$2y$12$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ0123456
md5crypt=user:$1$salt1234$abcdefghijklmnopqrstuv
ldap=user:{SSHA}U29tZUJhc2U2NEhhc2hWYWx1ZQ==
pgscram=SCRAM-SHA-256$4096:c2FsdA==$c3RvcmVkS2V5:U2VydmVyS2V5
anthropic=sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789
tailscale=tskey-auth-abcdefghijklmnopqrstuvwxyz0123456789
sendgrid=SG.abcdefghijklmnop.qrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
Environment="TOKEN=systemd-env-secret"
mysql -uroot -pmysql-short-secret exampledb
jdbc=jdbc:postgresql://alice:jdbc-secret@example.test/db
groq=gsk_abcdefghijklmnopqrstuvwxyz0123456789
google_oauth=GOCSPX-abcdefghijklmnopqrstuvwxyz0123456789
replicate=r8_abcdefghijklmnopqrstuvwxyz0123456789
linear=lin_api_abcdefghijklmnopqrstuvwxyz0123456789
doppler=dp.st.abcdefghijklmnopqrstuvwxyz0123456789
shared_access_key=azure-storage-secret-value
dbPassword=camel-secret-value
libsecret 0.21.7-1
KerberosOrLocalPasswd yes
PasswordAuthentication yes
PubkeyAuthentication yes
Failed password for invalid user alice from 203.0.113.10 port 2222 ssh2
# Max number of login retries if password is bad
HostKeyAlgorithms sk-ssh-ed25519@openssh.com,sk-ecdsa-sha2-nistp256@openssh.com
normal=value
passwd: files systemd
System Token: set
System Token: not set
Serial number: 2318E6D1F4A7
Serial Number: 511221208151002047
Interface MAC: AA:BB:CC:DD:EE:FF
BSSID: aa-bb-cc-dd-ee-ff
root=UUID=6e5a806e-4cfc-49ce-bbdd-0e9b94dcc3b0
efi=UUID=8E21-C33E
part=PARTUUID=4f2a1c09-02
path=/dev/disk/by-uuid/8E21-C33E
Bluetooth UUID: 00001800-0000-1000-8000-00805f9b34fb
DATA
redact_file "$tmp/in" "$tmp/out"
# Final enhanced pass is intentionally one whole-bundle operation, not one Python
# process per artifact.
mkdir -p "$tmp/bundle/meta"
cp "$tmp/out" "$tmp/bundle/evidence.txt"
sanitize_bundle_text_in_place "$tmp/bundle"
cp "$tmp/bundle/evidence.txt" "$tmp/out"
for secret in 2318E6D1F4A7 511221208151002047 AA:BB:CC:DD:EE:FF aa-bb-cc-dd-ee-ff supersecret json-secret-token yamlsecret aws-super-secret not-a-real-openai-key multiline-secret-line-1 multiline-secret-line-2 xml-super-secret hunter2 abcdefghijklmnopqrstuvwxyz012345 abcdefghijklmnopqrstuvwxyz987654 dXNlcjpwYXNz my-api-key-value google-header-secret aws-signature-secret json-camel-client-secret camel-db-password curlpass systemd-credential-secret redis-secret redis-space-secret redis-master-secret postgres-env-secret redis-cli-auth-secret haproxy-user-secret nginx-header-secret caddy-header-secret sshpass-secret kernel-credential-secret netrc-secret dXNlcjpkb2NrZXItc2VjcmV0 npmrc-secret-token npmrc-basic-secret redis-acl-plaintext 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef redis-url-secret querysecret azure-signature-secret oauth-code-secret query-key-secret cli-secret-value abc123 encrypted-pem-secret pgp-private-secret openvpn-static-secret AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789 tskey-auth-abcdefghijklmnopqrstuvwxyz0123456789 SG.abcdefghijklmnop.qrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ghp_abcdefghijklmnopqrstuvwxyz012345 systemd-env-secret mysql-short-secret jdbc-secret gsk_abcdefghijklmnopqrstuvwxyz0123456789 GOCSPX-abcdefghijklmnopqrstuvwxyz0123456789 r8_abcdefghijklmnopqrstuvwxyz0123456789 lin_api_abcdefghijklmnopqrstuvwxyz0123456789 dp.st.abcdefghijklmnopqrstuvwxyz0123456789 azure-storage-secret-value camel-secret-value; do
    ! grep -Fq "$secret" "$tmp/out"
done
! grep -Fq 'eyJabcdefghijk.abcdefghijk.abcdefghijk' "$tmp/out"
! grep -Fq '$2y$12$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ0123456' "$tmp/out"
! grep -Fq '$1$salt1234$abcdefghijklmnopqrstuv' "$tmp/out"
! grep -Fq '{SSHA}U29tZUJhc2U2NEhhc2hWYWx1ZQ==' "$tmp/out"
! grep -Fq 'SCRAM-SHA-256$4096:c2FsdA==$c3RvcmVkS2V5:U2VydmVyS2V5' "$tmp/out"
grep -Fq 'proxy_set_header X-Api-Key $upstream_api_key;' "$tmp/out"
grep -Fq 'https://[REDACTED-url_credentials-' "$tmp/out"
grep -Fq 'PasswordAuthentication yes' "$tmp/out"
grep -Fq 'PubkeyAuthentication yes' "$tmp/out"
grep -Fq 'Failed password for invalid user alice' "$tmp/out"
grep -Fq '# Max number of login retries if password is bad' "$tmp/out"
grep -Fq 'sk-ssh-ed25519@openssh.com' "$tmp/out"
grep -Fq 'sk-ecdsa-sha2-nistp256@openssh.com' "$tmp/out"
grep -Fq 'normal=value' "$tmp/out"
grep -Fq 'libsecret 0.21.7-1' "$tmp/out"
grep -Fq 'KerberosOrLocalPasswd yes' "$tmp/out"
grep -Fq 'passwd: files systemd' "$tmp/out"
grep -Fq 'System Token: set' "$tmp/out"
grep -Fq 'System Token: not set' "$tmp/out"
grep -Eq '^Serial number: \[REDACTED-unique_identifier-[0-9a-f]{12}\]$' "$tmp/out"
grep -Eq '^Serial Number: \[REDACTED-unique_identifier-[0-9a-f]{12}\]$' "$tmp/out"
mac_count=$(grep -oE '\[REDACTED-mac_address-[0-9a-f]{12}\]' "$tmp/out" | sort -u | wc -l)
[[ "$mac_count" -eq 1 ]] || { echo 'mac pseudonyms were not generated/correlated' >&2; exit 1; }
grep -Eq 'root=UUID=\[REDACTED-persistent_id-[0-9a-f]{12}\]' "$tmp/out"
grep -Eq 'efi=UUID=\[REDACTED-persistent_id-[0-9a-f]{12}\]' "$tmp/out"
grep -Eq 'part=PARTUUID=\[REDACTED-persistent_id-[0-9a-f]{12}\]' "$tmp/out"
grep -Eq 'path=/dev/disk/by-uuid/\[REDACTED-persistent_id-[0-9a-f]{12}\]' "$tmp/out"
grep -Fq 'Bluetooth UUID: 00001800-0000-1000-8000-00805f9b34fb' "$tmp/out"
grep -Fq '[REDACTED-' "$tmp/out"
# Quoted systemd Environment syntax must remain syntactically closed after redaction.
grep -Eq '^Environment="TOKEN=\[REDACTED-secret_value-[0-9a-f]{12}\]"$' "$tmp/out"
# NUL/control bytes must never make a file bypass enhanced redaction/scanning.
printf 'prefix\0PASSWORD=nul-secret-value\0suffix\n' > "$tmp/bundle/nul-evidence.txt"
sanitize_bundle_text_in_place "$tmp/bundle"
! grep -aFq 'nul-secret-value' "$tmp/bundle/nul-evidence.txt"
grep -aFq '[REDACTED-' "$tmp/bundle/nul-evidence.txt"
# Residual scan must accept preserved variable references while blocking literals.
scan_bundle_for_secret_risk "$tmp/bundle"
python3 -B -S - "$tmp/bundle/meta/redaction.json" <<'PYSCAN'
import json, sys
r=json.load(open(sys.argv[1], encoding='utf-8'))
assert r['high_confidence_residual_count'] == 0, r
assert r['redacted_marker_count'] > 0, r
PYSCAN
# Idempotence: a second pass must not manufacture new fingerprints or expose data.
cp "$tmp/out" "$tmp/bundle/evidence.txt"
sanitize_bundle_text_in_place "$tmp/bundle"
cp "$tmp/bundle/evidence.txt" "$tmp/out2"
cmp -s "$tmp/out" "$tmp/out2"
printf 'redaction test: ok (%s)\n' "$LCTX_REDACTION_ENGINE"
