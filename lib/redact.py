#!/usr/bin/env python3
"""Secret redaction and residual-risk scanning for linux-context.

Standard-library only. The redactor is intentionally conservative and idempotent.
Redacted values receive an HMAC fingerprint derived from an ephemeral per-run salt,
which lets an AI correlate repeated credentials without exposing a reusable hash.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
from recordio import read_records, write_records
import re
import sys
from typing import Any, Callable, Iterable

REDACTED_PREFIX = "[REDACTED-"
_SALT_TEXT = os.environ.get("LCTX_REDACTION_SALT", "")


def _redaction_salt() -> bytes:
    # Redaction markers are correlation aids, not reusable hashes. Never silently
    # fall back to a stable process-wide salt: that would make pseudonyms linkable
    # across independent bundles. The shell runtime creates 256 bits per run.
    if not _SALT_TEXT:
        raise RuntimeError("LCTX_REDACTION_SALT is required for redaction operations")
    return _SALT_TEXT.encode()


def marker(kind: str, value: str) -> str:
    if value.startswith(REDACTED_PREFIX):
        return value
    digest = hmac.new(_redaction_salt(), value.encode("utf-8", "replace"), hashlib.sha256).hexdigest()[:12]
    return f"[REDACTED-{kind}-{digest}]"


PRIVATE_BLOCK = re.compile(
    r"-----BEGIN (?P<label>(?:[A-Z0-9][A-Z0-9 -]* )?PRIVATE KEY(?: BLOCK)?)-----.*?"
    r"-----END (?P=label)-----",
    re.IGNORECASE | re.DOTALL,
)

# Exact credential-ish keys. Avoid broad substrings such as PasswordAuthentication,
# which describe policy and are valuable diagnostic evidence rather than secrets.
SECRET_CORE = (
    r"password|passwd|pwd|pass|passphrase|token|secret|credential|credentials|authorization|proxy[_-]?authorization|"
    r"api[_-]?key|apikey|auth[_-]?key|access[_-]?key|secret[_-]?key|private[_-]?key(?:[_-]?data)?|privatekey|"
    r"client[_-]?key(?:[_-]?data)?|client[_-]?secret|clientsecret|auth[_-]?token|authtoken|refresh[_-]?token|refreshtoken|session[_-]?token|sessiontoken|"
    r"identity[_-]?token|registry[_-]?token|security[_-]?token|password[_-]?hash|passwd[_-]?hash|"
    r"account[_-]?key|accountkey|master[_-]?key|masterkey|encryption[_-]?key|encryptionkey|signing[_-]?key|signingkey|shared[_-]?access[_-]?key|sharedaccesskey|pgpassword|rediscli[_-]?auth|docker[_-]?auth[_-]?config|identitytoken|registrytoken|personal[_-]?access[_-]?token|pat|"
    r"psk|pre[_-]?shared[_-]?key|totp[_-]?secret|otp[_-]?secret|"
    r"requirepass|masterauth|sas[_-]?token|shared[_-]?access[_-]?signature"
)

# Exact names plus separator-delimited namespaced forms such as DB_PASSWORD,
# AWS_SECRET_ACCESS_KEY, OPENAI_API_KEY and CF_API_TOKEN. Requiring a separator
# before a namespace suffix avoids diagnostic policy names like
# PasswordAuthentication / PubkeyAuthentication.
SECRET_KEY = rf"(?:{SECRET_CORE}|(?:[A-Za-z0-9]+[_.-]+)+(?:(?:{SECRET_CORE})))"
# CamelCase credential names need a case-sensitive word boundary (dbPassword,
# accessToken, clientSecret). Keeping them out of SECRET_KEY avoids treating
# ordinary names/policies such as libsecret or KerberosOrLocalPasswd as secrets.
CAMEL_SECRET_KEY = r"[A-Za-z0-9]+(?:Password|Passphrase|Token|Secret|ApiKey|AuthKey|AccessKey|SecretKey|PrivateKey|ClientSecret|RefreshToken|SessionToken|SharedAccessKey)"
# Query parameters called simply key/code/ticket are often bearer credentials
# (API keys, OAuth authorization codes, signed tickets). In URL query context it
# is safer to redact them even though those words are too broad as config keys.
QUERY_SECRET_KEY = rf"(?:{SECRET_KEY}|key|code|ticket|sig|signature|x-amz-signature|x-amz-security-token|x-goog-signature)"

# Quoted/unquoted JSON, YAML, INI, env and shell assignments.
KV_RE = re.compile(
    rf"(?P<prefix>(?<![A-Za-z0-9_.-])(?:export\s+)?(?P<q>[\"']?)"
    rf"(?!(?:SetCredential(?:Encrypted)?|systemd\.set_credential(?:_binary)?)\b)"
    rf"(?P<key>{SECRET_KEY})(?P=q)\s*[:=]\s*)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|\"(?:\\.|[^\"])*\"|'(?:\\.|[^'])*'|[^\s,;}}\]\"']+)",
    re.IGNORECASE,
)

CAMEL_KV_RE = re.compile(
    rf"(?P<prefix>(?<![A-Za-z0-9_.-])(?:export\s+)?(?P<q>[\"']?)(?P<key>{CAMEL_SECRET_KEY})(?P=q)\s*[:=]\s*)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|\"(?:\\.|[^\"])*\"|'(?:\\.|[^'])*'|[^\s,;}}\]\"']+)"
)

# netrc / loose config syntax where exact secret keys are followed by whitespace.
SPACE_KV_RE = re.compile(
    rf"(?P<prefix>^[ \t]*(?P<key>{SECRET_KEY})\b[ \t]+)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|\S+)[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)

# Context-specific formats where a credential does not use key=value syntax.
# These are kept narrow so ordinary log text (for example OpenSSH's
# "Failed password for ...") remains useful diagnostic evidence.
HAPROXY_USER_RE = re.compile(
    r"(?P<prefix>^[ \t]*user[ \t]+\S+[ \t]+(?:insecure-)?password[ \t]+)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|\S+)",
    re.IGNORECASE | re.MULTILINE,
)

WEB_SECRET_HEADER_RE = re.compile(
    r"(?P<prefix>\b(?:proxy_set_header|add_header|header_up|header_down|more_set_headers|"
    r"RequestHeader[ \t]+(?:set|add)|http-request[ \t]+set-header)[ \t]+"
    r"(?:Authorization|Proxy-Authorization|X-Api-Key|X-Auth-Token|X-Access-Token|Cookie)[ \t]+)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|\"(?:\\.|[^\"])*\"|'(?:\\.|[^'])*'|[^;\s]+)",
    re.IGNORECASE,
)

SSHPASS_RE = re.compile(
    r"(?P<prefix>\bsshpass\b[^\r\n]*?(?:-p|--password)(?:=|[ \t]+))"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|\S+)",
    re.IGNORECASE,
)

SYSTEMD_KERNEL_CREDENTIAL_RE = re.compile(
    r"(?P<prefix>\bsystemd\.set_credential(?:_binary)?=([^:\s=]+):)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|[^\s]+)",
    re.IGNORECASE,
)

# XML-style secrets, including names such as dbPassword/clientSecret. The tag
# must end in a credential semantic, which avoids tags like
# <PasswordAuthentication>.
XML_RE = re.compile(
    r"(?P<prefix><(?P<tag>[A-Za-z0-9_.-]*(?:password|passwd|passphrase|token|secret|api[_-]?key|client[_-]?secret|private[_-]?key))\b[^>]*>)"
    r"(?P<value>.*?)"
    r"(?P<suffix></(?P=tag)\s*>)",
    re.IGNORECASE | re.DOTALL,
)

CLI_RE = re.compile(
    rf"(?P<prefix>--(?:{SECRET_KEY})(?:=|\s+))(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|[^\s]+)",
    re.IGNORECASE,
)

HEADER_RE = re.compile(
    # Redact the complete header value regardless of auth scheme. This covers
    # Bearer/Basic as well as AWS4-HMAC-SHA256, Digest, token schemes, etc.
    r"(?P<prefix>\b(?:Authorization|Proxy-Authorization)\s*:\s*)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|[^\r\n]+)",
    re.IGNORECASE,
)

TOKEN_HEADER_RE = re.compile(
    r"(?P<prefix>\b(?:X-Api-Key|X-Goog-Api-Key|X-Auth-Token|X-Access-Token|Cookie|Set-Cookie)\s*:\s*)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|[^\r\n]+)",
    re.IGNORECASE,
)

URL_CREDS_RE = re.compile(
    r"(?P<scheme>[A-Za-z][A-Za-z0-9+.-]*://)"
    # Username may be empty (e.g. redis://:password@host).
    r"(?P<value>[^/@\s]*:[^/@\s]+)@"
)



# Credentials can appear outside canonical HTTP-header syntax in logs, shell
# snippets, systemd unit files and proxy configuration. Keep these rules
# contextual to avoid destroying useful policy/configuration evidence.
BARE_AUTH_RE = re.compile(
    r"(?P<prefix>\b(?:Bearer|Basic|Bot|Token|ApiKey)\s+)(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|[A-Za-z0-9._~+/=-]{12,})",
    re.IGNORECASE,
)

CURL_USER_RE = re.compile(
    r"(?P<prefix>(?:--user|--proxy-user|-u|-U)(?:=|\s+))"
    r"(?P<value>"
    r"\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]"
    r'|"(?:\\.|[^"\r\n])*:(?:\\.|[^"\r\n])+"'
    r"|'(?:\\.|[^'\r\n])*:(?:\\.|[^'\r\n])+'"
    r"|[^\s\"'`,;{}\[\]():]*:[^\s\"'`,;{}\[\]()]+"
    r")",
    re.IGNORECASE,
)

# Command syntax that carries a password without conventional key=value form.
MYSQL_SHORT_PASSWORD_RE = re.compile(
    r"(?P<prefix>\b(?:mysql|mariadb|mysqldump|mysqladmin)\b[^\r\n]*?\s-p)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|[^\s]+)",
    re.IGNORECASE,
)

# JDBC URLs add a transport prefix before the actual URI scheme, so the generic
# scheme://user:password@ matcher cannot see them.
JDBC_URL_CREDS_RE = re.compile(
    r"(?P<scheme>jdbc:[A-Za-z][A-Za-z0-9+.-]*://)"
    r"(?P<value>[^/@\s]*:[^/@\s]+)@",
    re.IGNORECASE,
)

SYSTEMD_CREDENTIAL_RE = re.compile(
    r"(?P<prefix>\bSetCredential(?:Encrypted)?\s*=\s*[^:\s=]+:)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|[^\s]+)",
    re.IGNORECASE,
)

NETRC_RE = re.compile(
    r"(?P<prefix>^[ \t]*(?:machine[ \t]+[^\s]+|default)(?:[ \t]+login[ \t]+[^\s]+)?[ \t]+password[ \t]+)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|[^\s]+)",
    re.IGNORECASE | re.MULTILINE,
)

DOCKER_AUTH_RE = re.compile(
    r'(?P<prefix>["\']auth["\']\s*:\s*["\'])(?P<value>[A-Za-z0-9+/=_-]{12,})(?P<suffix>["\'])',
    re.IGNORECASE,
)

# npm/yarn-style auth config commonly uses `_authToken` or `_auth`, often after
# a registry URL prefix. They do not fit ordinary shell variable naming.
NPM_AUTH_RE = re.compile(
    r"(?P<prefix>(?:^|[\s/:])_(?:authToken|auth)\s*=\s*)"
    r"(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|[^\s#;]+)",
    re.IGNORECASE | re.MULTILINE,
)

# Redis ACL configuration/commands can contain plaintext password additions (`>`)
# or reusable password hashes (`#`). Preserve user/rule topology but redact the
# credential token itself.
REDIS_ACL_CREDENTIAL_RE = re.compile(
    r"(?P<prefix>\b(?:ACL\s+SETUSER\s+|user\s+)\S+[^\r\n]*?[ \t])"
    r"(?P<op>[>#])(?P<value>[A-Za-z0-9!$%&()*+,.\-/:;<=>?@^_`{|}~]{8,})",
    re.IGNORECASE,
)

OPENVPN_STATIC_KEY_RE = re.compile(
    r"-----BEGIN OpenVPN Static key V1-----.*?-----END OpenVPN Static key V1-----",
    re.IGNORECASE | re.DOTALL,
)

AGE_SECRET_RE = re.compile(r"\bAGE-SECRET-KEY-1[0-9A-Z]{20,}\b", re.IGNORECASE)

# Authentication verifiers are not plaintext passwords, but they are still
# credential material and should not be exported to an AI bundle.
PASSWORD_HASH_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("bcrypt_hash", re.compile(r"\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}")),
    ("argon2_hash", re.compile(r"\$argon2(?:id|i|d)\$[^\s:;,'\"]{20,}")),
    ("apr1_hash", re.compile(r"\$apr1\$[^\s:;,'\"]{8,}")),
    ("md5_crypt_hash", re.compile(r"\$1\$[^\s:;,'\"]{8,}")),
    ("sha_crypt_hash", re.compile(r"\$[56]\$[^\s:;,'\"]{16,}")),
    ("ldap_password_hash", re.compile(r"\{(?:SSHA|SHA|SMD5|MD5|CRYPT)\}[A-Za-z0-9+/=.$]{12,}", re.I)),
    ("postgres_scram_verifier", re.compile(r"\bSCRAM-SHA-256\$[0-9]+:[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+\b")),
    ("grub_pbkdf2", re.compile(r"\bgrub\.pbkdf2\.sha512\.[0-9]+\.[A-Fa-f0-9.]{40,}\b")),
]

QUERY_RE = re.compile(
    rf"(?P<prefix>[?&](?:{QUERY_SECRET_KEY})=)(?P<value>\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd][^\]]*\]|[^&#\s]+)",
    re.IGNORECASE,
)

JWT_RE = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")

KNOWN_TOKEN_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("github_token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")),
    ("gitlab_token", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}\b")),
    ("slack_token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("google_api_key", re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b")),
    ("stripe_secret", re.compile(r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b")),
    # Modern OpenAI keys are namespaced. Legacy keys were long alphanumeric
    # strings. Do not use a generic ``sk-*`` rule: OpenSSH security-key
    # algorithms such as sk-ssh-ed25519 would be false positives.
    ("openai_key", re.compile(r"\b(?:sk-(?:proj-|svcacct-)[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,})\b")),
    ("huggingface_token", re.compile(r"\bhf_[A-Za-z0-9]{20,}\b")),
    ("npm_token", re.compile(r"\bnpm_[A-Za-z0-9]{20,}\b")),
    ("pypi_token", re.compile(r"\bpypi-[A-Za-z0-9_-]{20,}\b")),
    ("docker_pat", re.compile(r"\bdckr_pat_[A-Za-z0-9_-]{20,}\b")),
    ("digitalocean_token", re.compile(r"\bdop_v1_[A-Fa-f0-9]{32,}\b")),
    ("aws_access_key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("telegram_bot_token", re.compile(r"\b\d{6,12}:AA[A-Za-z0-9_-]{20,}\b")),
    ("anthropic_key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b")),
    ("tailscale_key", re.compile(r"\btskey-(?:auth|api|client)-[A-Za-z0-9_-]{16,}\b")),
    ("sendgrid_key", re.compile(r"\bSG\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{20,}\b")),
    ("vault_token", re.compile(r"\b(?:hvs\.[A-Za-z0-9_-]{20,}|s\.[A-Za-z0-9]{20,})\b")),
    ("onepassword_service_token", re.compile(r"\bops_[A-Za-z0-9_-]{20,}\b")),
    ("grafana_service_token", re.compile(r"\bglsa_[A-Za-z0-9_-]{20,}\b")),
    ("groq_key", re.compile(r"\bgsk_[A-Za-z0-9_-]{20,}\b")),
    ("google_oauth_client_secret", re.compile(r"\bGOCSPX-[A-Za-z0-9_-]{20,}\b")),
    ("replicate_token", re.compile(r"\br8_[A-Za-z0-9]{20,}\b")),
    ("linear_api_key", re.compile(r"\blin_api_[A-Za-z0-9_-]{20,}\b")),
    ("doppler_token", re.compile(r"\bdp\.(?:st|sa|ct)\.[A-Za-z0-9._-]{20,}\b")),
]

# Webhook URLs embed bearer-like credentials in path segments.
WEBHOOK_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("slack_webhook", re.compile(r"https://hooks\.slack\.com/services/[A-Za-z0-9/_-]{20,}", re.I)),
    ("discord_webhook", re.compile(r"https://(?:canary\.|ptb\.)?discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9._-]{20,}", re.I)),
]



# Non-secret persistent identifiers can still unnecessarily fingerprint a host.
# Redact labeled hardware/firmware serial-style identifiers while preserving a
# per-run HMAC marker so repeated appearances remain correlatable to the AI.
UNIQUE_IDENTIFIER_RE = re.compile(
    r"(?P<prefix>^[ \t]*(?:Serial(?:[ \t]+Number)?|Serial[ \t]+number|LU[ \t]+WWN[ \t]+Device[ \t]+Id|"
    r"Logical[ \t]+Unit[ \t]+id|World[ \t]+Wide[ \t]+Name|WWN|Product[ \t]+UUID|"
    r"Product[ \t]+Serial(?:[ \t]+Number)?|Board[ \t]+Serial(?:[ \t]+Number)?|"
    r"Chassis[ \t]+Serial(?:[ \t]+Number)?|Asset[ \t]+Tag)[ \t]*:[ \t]*)"
    r"(?P<value>[^\r\n]+)$",
    re.IGNORECASE | re.MULTILINE,
)

# Network hardware addresses are not credentials, but they are durable host/
# nearby-device identifiers and add little diagnostic value in raw form. Replace
# them with per-run HMAC pseudonyms so joins (interface/BSSID/controller) remain
# possible without retaining the original address.
MAC_ADDRESS_RE = re.compile(
    r"(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f])"
    r"|(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f])"
)

# Filesystem/partition/connection UUIDs are durable host identifiers. Their
# literal value is rarely useful to an AI; correlation is. Bluetooth SIG UUIDs
# are standardized capability identifiers, not per-host identifiers, so keep
# the well-known Bluetooth base UUID family intact.
UUID_RE = re.compile(
    r"(?<![0-9A-Fa-f])"
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    r"(?![0-9A-Fa-f])"
)
BLUETOOTH_BASE_UUID_SUFFIX = "-0000-1000-8000-00805f9b34fb"

# Filesystem identifiers are not always RFC-style UUIDs. FAT commonly uses
# XXXX-XXXX and PARTUUID may be an MBR disk signature plus partition suffix.
# Match them only in explicit persistent-ID contexts, preserving correlation via
# the same per-run HMAC marker instead of exporting a durable host identifier.
PERSISTENT_ID_ASSIGNMENT_RE = re.compile(
    r"(?P<prefix>\b(?:PARTUUID|PTUUID|UUID)\s*=\s*(?P<quote>[\"']?))"
    r"(?P<value>(?!\[REDACTED-)[A-Za-z0-9._:-]{4,})(?P=quote)",
    re.IGNORECASE,
)
PERSISTENT_ID_PATH_RE = re.compile(
    r"(?P<prefix>/dev/disk/by-(?:uuid|partuuid)/)"
    r"(?P<value>(?!\[REDACTED-)[^/\s,;]+)",
    re.IGNORECASE,
)

NSS_SOURCES = {
    "files", "systemd", "sss", "ldap", "compat", "nis", "nisplus", "winbind",
    "resolve", "myhostname", "mymachines", "dns", "mdns", "mdns4", "mdns6",
} 

def _strip_quotes(value: str) -> tuple[str, str, str]:
    if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
        return value[0], value[1:-1], value[-1]
    return "", value, ""


def _is_redacted_value(value: str) -> bool:
    _, raw, _ = _strip_quotes(value)
    return bool(re.fullmatch(r"(?:[^:\s]+:)?\[REDACTED-[^\]]+\]", raw, re.IGNORECASE))


def _looks_like_template_reference(value: str) -> bool:
    """Return True when a credential-shaped field contains only a reference.

    Configuration such as ``proxy_set_header X-Api-Key $upstream_api_key`` is
    diagnostically valuable and does not contain the credential itself. Preserve
    common variable/template forms while redacting literal values.
    """
    probe = value.strip()
    direct_prefixes = ("$", "${", "%{", "{env.", "{http.", "{{")
    if probe.startswith(direct_prefixes):
        return True
    parts = probe.split(None, 1)
    if len(parts) == 2 and parts[0].lower() in {"bearer", "basic", "bot"}:
        return parts[1].startswith(direct_prefixes)
    return False


def _preserve_contextual_nonsecret(match: re.Match[str], raw: str) -> bool:
    """Preserve credential-shaped syntax that is actually configuration state.

    The redactor should fail safe on ambiguous literals, but obvious NSS database
    selectors and bootctl state words are diagnostic semantics, not credentials.
    """
    key = (match.groupdict().get("key") or "").lower()
    value = raw.strip().lower()
    if key == "passwd" and value in NSS_SOURCES:
        # /etc/nsswitch.conf: ``passwd: files systemd``. KV_RE sees only the
        # first token; redacting it destroys resolver topology.
        line_start = match.string.rfind("\n", 0, match.start()) + 1
        before = match.string[line_start:match.start("value")].lower()
        if re.search(r"^\s*passwd\s*:\s*$", before):
            return True
    if key == "token" and value in {"set", "not", "unset", "present", "absent", "none", "configured", "unavailable"}:
        line_start = match.string.rfind("\n", 0, match.start()) + 1
        before = match.string[line_start:match.start("value")].lower()
        if "system token" in before:
            return True
    return False


def _replace_value(kind: str) -> Callable[[re.Match[str]], str]:
    def repl(m: re.Match[str]) -> str:
        value = m.group("value")
        if _is_redacted_value(value):
            return m.group(0)
        q1, raw, q2 = _strip_quotes(value)
        if _preserve_contextual_nonsecret(m, raw):
            return m.group(0)
        return f"{m.group('prefix')}{q1}{marker(kind, raw)}{q2}"
    return repl


def _redact_yaml_secret_blocks(text: str) -> str:
    """Redact YAML block scalars attached to credential-like keys.

    A simple key/value regex can replace ``password: |`` while accidentally
    leaving the indented secret body behind. This pass removes that body too.
    It intentionally handles only obvious mapping entries and leaves unrelated
    YAML untouched.
    """
    key_re = re.compile(
        rf"^(?P<indent>[ \t]*)(?P<prefix>(?:[\"']?(?:{SECRET_KEY})[\"']?)[ \t]*:[ \t]*)(?P<style>[|>])(?:[-+]?\d*)?[ \t]*(?:#.*)?$",
        re.IGNORECASE,
    )
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    i = 0
    while i < len(lines):
        raw = lines[i]
        body = raw.rstrip("\r\n")
        m = key_re.match(body)
        if not m:
            out.append(raw)
            i += 1
            continue
        base_indent = len(m.group("indent").expandtabs(8))
        consumed: list[str] = []
        j = i + 1
        while j < len(lines):
            candidate = lines[j]
            stripped = candidate.strip()
            if not stripped:
                consumed.append(candidate)
                j += 1
                continue
            leading = candidate[: len(candidate) - len(candidate.lstrip(" \t"))]
            indent = len(leading.expandtabs(8))
            if indent <= base_indent:
                break
            consumed.append(candidate)
            j += 1
        secret_body = "".join(consumed)
        newline = "\r\n" if raw.endswith("\r\n") else "\n" if raw.endswith("\n") else ""
        out.append(f"{m.group('indent')}{m.group('prefix')}{marker('yaml_secret_block', secret_body or m.group('style'))}{newline}")
        i = j
    return "".join(out)


def _replace_web_secret_header(m: re.Match[str]) -> str:
    value = m.group("value")
    if _is_redacted_value(value):
        return m.group(0)
    q1, raw, q2 = _strip_quotes(value)
    if _looks_like_template_reference(raw):
        return m.group(0)
    return f"{m.group('prefix')}{q1}{marker('web_header_secret', raw)}{q2}"


def _replace_xml(m: re.Match[str]) -> str:
    value = m.group("value")
    if _is_redacted_value(value):
        return m.group(0)
    return f"{m.group('prefix')}{marker('xml_secret', value)}{m.group('suffix')}"


def normalize_control_chars(text: str) -> str:
    """Make evidence deterministic/text-safe without hiding unusual bytes.

    Preserve TAB/LF/CR. Other C0/DEL controls are rendered as explicit escape
    sequences so they cannot manipulate terminals/parsers and so secret scanning
    still examines the surrounding content. Bracketed sentinels also preserve
    lexical boundaries around secrets. NUL is never a reason to skip an artifact.
    """
    out: list[str] = []
    for ch in text:
        code = ord(ch)
        if ch in "\t\n\r" or code >= 0x20 and code != 0x7F:
            out.append(ch)
        else:
            out.append(f"[CTRL-{code:02X}]")
    return "".join(out)


def _replace_docker_auth(m: re.Match[str]) -> str:
    value = m.group("value")
    if _is_redacted_value(value):
        return m.group(0)
    return f"{m.group('prefix')}{marker('docker_auth', value)}{m.group('suffix')}"


def _replace_redis_acl(m: re.Match[str]) -> str:
    value = m.group("value")
    if _is_redacted_value(value):
        return m.group(0)
    return f"{m.group('prefix')}{m.group('op')}{marker('redis_acl_credential', value)}"


def _replace_mac(m: re.Match[str]) -> str:
    # Canonicalize separators/case before hashing so the same address maps to the
    # same pseudonym even when tools render it differently.
    canonical = re.sub(r"[:-]", "", m.group(0)).lower()
    return marker("mac_address", canonical)


def _replace_uuid(m: re.Match[str]) -> str:
    value = m.group(0).lower()
    if value.endswith(BLUETOOTH_BASE_UUID_SUFFIX):
        return m.group(0)
    return marker("uuid", value)


def _replace_persistent_id(m: re.Match[str]) -> str:
    value = m.group("value")
    if _is_redacted_value(value):
        return m.group(0)
    # Avoid turning documented sentinel values into pseudo-identifiers.
    if value.lower() in {"none", "auto", "default"}:
        return m.group(0)
    prefix = m.group("prefix")
    quote = m.groupdict().get("quote") or ""
    return f"{prefix}{marker('persistent_id', value.lower())}{quote}"


def redact_text(text: str) -> str:
    text = normalize_control_chars(text)
    text = UNIQUE_IDENTIFIER_RE.sub(_replace_value("unique_identifier"), text)
    text = MAC_ADDRESS_RE.sub(_replace_mac, text)
    text = PERSISTENT_ID_ASSIGNMENT_RE.sub(_replace_persistent_id, text)
    text = PERSISTENT_ID_PATH_RE.sub(_replace_persistent_id, text)
    text = UUID_RE.sub(_replace_uuid, text)
    text = PRIVATE_BLOCK.sub(lambda m: marker("private_key_block", m.group(0)), text)
    text = OPENVPN_STATIC_KEY_RE.sub(lambda m: marker("openvpn_static_key", m.group(0)), text)
    text = AGE_SECRET_RE.sub(lambda m: marker("age_secret_key", m.group(0)), text)
    text = _redact_yaml_secret_blocks(text)
    text = XML_RE.sub(_replace_xml, text)
    text = HEADER_RE.sub(_replace_value("authorization"), text)
    text = TOKEN_HEADER_RE.sub(_replace_value("http_secret_header"), text)
    text = BARE_AUTH_RE.sub(_replace_value("authorization"), text)
    text = CURL_USER_RE.sub(_replace_value("basic_credentials"), text)
    text = SSHPASS_RE.sub(_replace_value("sshpass_password"), text)
    text = MYSQL_SHORT_PASSWORD_RE.sub(_replace_value("mysql_password"), text)
    text = SYSTEMD_CREDENTIAL_RE.sub(_replace_value("systemd_credential"), text)
    text = SYSTEMD_KERNEL_CREDENTIAL_RE.sub(_replace_value("systemd_credential"), text)
    text = HAPROXY_USER_RE.sub(_replace_value("haproxy_password"), text)
    text = WEB_SECRET_HEADER_RE.sub(_replace_web_secret_header, text)
    text = DOCKER_AUTH_RE.sub(_replace_docker_auth, text)
    text = NPM_AUTH_RE.sub(_replace_value("npm_auth"), text)
    text = REDIS_ACL_CREDENTIAL_RE.sub(_replace_redis_acl, text)
    text = JDBC_URL_CREDS_RE.sub(lambda m: f"{m.group('scheme')}{marker('jdbc_url_credentials', m.group('value'))}@", text)
    text = URL_CREDS_RE.sub(lambda m: f"{m.group('scheme')}{marker('url_credentials', m.group('value'))}@", text)
    text = QUERY_RE.sub(_replace_value("query_secret"), text)
    text = CLI_RE.sub(_replace_value("cli_secret"), text)
    text = CAMEL_KV_RE.sub(_replace_value("secret_value"), text)
    text = KV_RE.sub(_replace_value("secret_value"), text)
    text = SPACE_KV_RE.sub(_replace_value("secret_value"), text)
    # netrc may place multiple directives on one line; run after exact key/value
    # handling and exclude PAM control words that are configuration semantics.
    def netrc_repl(m: re.Match[str]) -> str:
        value = m.group("value")
        if value.lower() in {"required", "requisite", "sufficient", "optional", "include", "substack"}:
            return m.group(0)
        return f"{m.group('prefix')}{marker('netrc_password', value)}"
    text = NETRC_RE.sub(netrc_repl, text)
    text = JWT_RE.sub(lambda m: marker("jwt", m.group(0)), text)
    for kind, pat in PASSWORD_HASH_PATTERNS:
        text = pat.sub(lambda m, k=kind: marker(k, m.group(0)), text)
    for kind, pat in KNOWN_TOKEN_PATTERNS:
        text = pat.sub(lambda m, k=kind: marker(k, m.group(0)), text)
    for kind, pat in WEBHOOK_PATTERNS:
        text = pat.sub(lambda m, k=kind: marker(k, m.group(0)), text)
    return text



def _redact_json_value(value: Any, parent_key: str = "") -> Any:
    """Redact generated JSON structurally so regexes can never corrupt syntax."""
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key, child in value.items():
            if isinstance(child, str):
                redacted = redact_text(child)
                # Preserve key/value secret semantics without applying regexes to
                # serialized JSON punctuation or adjacent fields.
                combined = redact_text(f"{key}={redacted}")
                if "=" in combined:
                    _k, candidate = combined.split("=", 1)
                    redacted = candidate
                out[key] = redacted
            else:
                out[key] = _redact_json_value(child, str(key))
        return out
    if isinstance(value, list):
        return [_redact_json_value(x, parent_key) for x in value]
    if isinstance(value, str):
        return redact_text(value)
    return value


def _redact_json_file(path: Path) -> None:
    obj = json.loads(path.read_text(encoding="utf-8", errors="strict"))
    obj = _redact_json_value(obj)
    path.write_text(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")


def _json_text_for_scan(path: Path) -> str:
    obj = json.loads(path.read_text(encoding="utf-8", errors="strict"))
    lines: list[str] = []
    def walk(x: Any, key: str = "") -> None:
        if isinstance(x, dict):
            for k, v in x.items():
                if isinstance(v, (str, int, float, bool)) or v is None:
                    lines.append(str(v))
                    lines.append(f"{k}={v}")
                walk(v, str(k))
        elif isinstance(x, list):
            for v in x: walk(v, key)
        elif isinstance(x, str):
            lines.append(x)
    walk(obj)
    return "\n".join(lines)


_RECORD_KINDS = {
    "facts.records": "facts",
    "entities.records": "entities",
    "entity-attrs.records": "entity_attrs",
    "relations.records": "relations",
    "artifacts.records": "artifacts",
    "probes.records": "probes",
}


def _record_kind(path: Path):
    return _RECORD_KINDS.get(path.name)


def _redact_record_file(path: Path) -> None:
    """Redact structured staging without corrupting NUL field delimiters."""
    kind = _record_kind(path)
    if kind is None:
        return
    rows = read_records(path, kind)
    for row in rows:
        # Redact each textual field independently first.
        for key, value in list(row.items()):
            if isinstance(value, str):
                redacted = redact_text(value)
                if redacted != value:
                    row[key] = redacted
        # Facts/attributes intentionally separate semantic key and value fields.
        # Recombine them temporarily so generic key=value secret rules still apply.
        if kind in {"facts", "entity_attrs"}:
            key = str(row.get("key", ""))
            value = row.get("value")
            if key and isinstance(value, str):
                combined = redact_text(f"{key}={value}")
                if "=" in combined:
                    _k, candidate = combined.split("=", 1)
                    if candidate != value:
                        row["value"] = candidate
    write_records(path, kind, rows)


def _record_text_for_scan(path: Path) -> str:
    kind = _record_kind(path)
    if kind is None:
        return ""
    rows = read_records(path, kind)
    lines: list[str] = []
    for row in rows:
        for key, value in row.items():
            if isinstance(value, (str, int, float, bool)):
                lines.append(str(value))
        if kind in {"facts", "entity_attrs"}:
            lines.append(f"{row.get('key','')}={row.get('value','')}")
    return "\n".join(lines)

def is_probably_text(path: Path) -> bool:
    # First-party collectors are text-oriented. Do not skip NUL-containing output:
    # decode it lossily and normalize controls so anomalous/binary-ish evidence
    # still passes through redaction and residual scanning.
    try:
        path.open("rb").close()
        return True
    except OSError:
        return False


def redact_file(src: Path, dst: Path) -> None:
    if _record_kind(src):
        if src != dst:
            dst.write_bytes(src.read_bytes())
        _redact_record_file(dst)
        return
    if src.suffix == ".json":
        if src != dst:
            dst.write_bytes(src.read_bytes())
        _redact_json_file(dst)
        return
    data = src.read_text(encoding="utf-8", errors="replace")
    dst.write_text(redact_text(data), encoding="utf-8")


def redact_tree(root: Path) -> None:
    skip = {"manifest.sha256", "REDACTION-REPORT.md", "redaction.json"}
    for path in root.rglob("*"):
        if not path.is_file() or path.name in skip or not is_probably_text(path):
            continue
        if _record_kind(path):
            _redact_record_file(path)
            continue
        if path.suffix == ".json":
            _redact_json_file(path)
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        redacted = redact_text(text)
        if redacted != text:
            tmp = path.with_name(path.name + ".redacting")
            tmp.write_text(redacted, encoding="utf-8")
            os.chmod(tmp, path.stat().st_mode & 0o7777)
            os.replace(tmp, path)


# Residual patterns are deliberately high-confidence. The scan reports paths/categories
# only; it never copies the matched credential into the report.
RESIDUAL_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("unique_identifier", UNIQUE_IDENTIFIER_RE),
    ("mac_address", MAC_ADDRESS_RE),
    ("persistent_id_assignment", PERSISTENT_ID_ASSIGNMENT_RE),
    ("persistent_id_path", PERSISTENT_ID_PATH_RE),
    ("private_key_block", PRIVATE_BLOCK),
    ("openvpn_static_key", OPENVPN_STATIC_KEY_RE),
    ("age_secret_key", AGE_SECRET_RE),
    ("authorization_header", HEADER_RE),
    ("secret_header", TOKEN_HEADER_RE),
    ("bare_authorization", BARE_AUTH_RE),
    ("curl_basic_credentials", CURL_USER_RE),
    ("sshpass_password", SSHPASS_RE),
    ("mysql_short_password", MYSQL_SHORT_PASSWORD_RE),
    ("systemd_credential", SYSTEMD_CREDENTIAL_RE),
    ("systemd_kernel_credential", SYSTEMD_KERNEL_CREDENTIAL_RE),
    ("haproxy_password", HAPROXY_USER_RE),
    ("web_header_secret", WEB_SECRET_HEADER_RE),
    ("docker_auth", DOCKER_AUTH_RE),
    ("npm_auth", NPM_AUTH_RE),
    ("redis_acl_credential", REDIS_ACL_CREDENTIAL_RE),
    ("jdbc_url_credentials", JDBC_URL_CREDS_RE),
    ("url_credentials", URL_CREDS_RE),
    ("query_secret", QUERY_RE),
    ("cli_secret", CLI_RE),
    ("camel_key_value_secret", CAMEL_KV_RE),
    ("key_value_secret", KV_RE),
    ("space_key_value_secret", SPACE_KV_RE),
    ("xml_secret", XML_RE),
    ("jwt", JWT_RE),
    *PASSWORD_HASH_PATTERNS,
    *KNOWN_TOKEN_PATTERNS,
    *WEBHOOK_PATTERNS,
]


def count_markers(text: str) -> int:
    return text.count(REDACTED_PREFIX)


def _residual_match_is_safe(kind: str, match: re.Match[str]) -> bool:
    value = match.groupdict().get("value")
    if value is not None and _is_redacted_value(value):
        return True
    if kind == "web_header_secret" and value is not None:
        _, raw, _ = _strip_quotes(value)
        return _looks_like_template_reference(raw)
    if value is not None:
        _, raw, _ = _strip_quotes(value)
        if _preserve_contextual_nonsecret(match, raw):
            return True
    return False


def scan_tree(root: Path) -> dict:
    findings: dict[str, dict[str, int]] = {}
    marker_total = 0
    scanned_files = 0
    skipped_binary = 0
    skip = {"manifest.sha256", "REDACTION-REPORT.md", "redaction.json"}
    for path in root.rglob("*"):
        if not path.is_file() or path.name in skip:
            continue
        if not is_probably_text(path):
            skipped_binary += 1
            continue
        scanned_files += 1
        if _record_kind(path):
            text = _record_text_for_scan(path)
        elif path.suffix == ".json":
            text = _json_text_for_scan(path)
        else:
            text = path.read_text(encoding="utf-8", errors="replace")
        marker_total += count_markers(text)
        per: dict[str, int] = {}
        for kind, pat in RESIDUAL_PATTERNS:
            n = 0
            for match in pat.finditer(text):
                if _residual_match_is_safe(kind, match):
                    continue
                n += 1
            if n:
                per[kind] = n
        if per:
            findings[str(path.relative_to(root))] = per
    residual_count = sum(sum(v.values()) for v in findings.values())
    return {
        "schema": "linux-context-redaction-report",
        "schema_version": 1,
        "engine": os.environ.get("LCTX_REDACTION_ENGINE", "python-enhanced"),
        "assurance": os.environ.get("LCTX_REDACTION_ASSURANCE", "enhanced"),
        "redacted_marker_count": marker_total,
        "high_confidence_residual_count": residual_count,
        "files_with_high_confidence_residuals": len(findings),
        "scanned_text_files": scanned_files,
        "skipped_binary_files": skipped_binary,
        "residuals_by_file": findings,
    }


def write_reports(root: Path, report: dict) -> None:
    json_path = root / "meta" / "redaction.json"
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    md = root / "REDACTION-REPORT.md"
    lines = [
        "# Redaction report",
        "",
        f"- Engine: `{report['engine']}`",
        f"- Assurance: `{report['assurance']}`",
        f"- Redacted markers present: {report['redacted_marker_count']}",
        f"- High-confidence residual secret patterns: {report['high_confidence_residual_count']}",
        "",
        "The collector avoids known secret sources first, then applies content redaction, then performs a residual-risk scan. "
        "No automated system can prove arbitrary diagnostic text is secret-free, so this is defense in depth rather than a mathematical guarantee.",
        "",
    ]
    if report["high_confidence_residual_count"]:
        lines += ["## Files blocked by residual-risk scan", ""]
        for path, categories in sorted(report["residuals_by_file"].items()):
            lines.append(f"- `{path}` — {', '.join(sorted(categories))}")
    else:
        lines.append("No high-confidence residual credential patterns were detected after redaction.")
    md.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("redact")
    p.add_argument("input")
    p.add_argument("output")
    p = sub.add_parser("tree")
    p.add_argument("root")
    p = sub.add_parser("scan")
    p.add_argument("root")
    p = sub.add_parser("secure-tree")
    p.add_argument("root")
    args = ap.parse_args()

    if args.cmd == "redact":
        redact_file(Path(args.input), Path(args.output))
        return 0
    if args.cmd == "tree":
        redact_tree(Path(args.root))
        return 0
    if args.cmd == "scan":
        root = Path(args.root)
        report = scan_tree(root)
        write_reports(root, report)
        return 2 if report["high_confidence_residual_count"] else 0
    if args.cmd == "secure-tree":
        root = Path(args.root)
        redact_tree(root)
        report = scan_tree(root)
        write_reports(root, report)
        return 2 if report["high_confidence_residual_count"] else 0
    return 64


if __name__ == "__main__":
    raise SystemExit(main())
