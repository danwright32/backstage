"""What counts as a credential or a real mailbox in this repository.

backstage#11. TWO guards ask this question: scripts/check-secrets.sh reads the
working tree, and scripts/check-secrets-history.sh reads every blob ever
committed. They must not be able to disagree about what a secret is, so the
rules and the predicate that applies them live here once and both import them.

Sharing only the DATA while each guard wrote its own matching would not be
consolidation: the shared constant reads as the single source of truth and
nobody asks whether the logic beside it was duplicated (L370).

Imported, never run.
"""
import os
import re

# Domains reserved by RFC 2606 and RFC 6761 precisely so that they can be written
# down without reaching anybody. An address at one of these is documentation.
RESERVED_DOMAINS = ("example.com", "example.org", "example.net")
RESERVED_TLDS = (".invalid", ".test", ".example", ".localhost")

# THE REASON, not the case: an SSH login at a code host is a transport identity
# that receives no mail. Any host offering git over SSH satisfies it.
CODE_HOSTS = ("github.com", "gitlab.com", "bitbucket.org", "codeberg.org")

EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")

CONTENT_RULES = (
    # A Google OAuth client secret carries its own documented prefix.
    ("oauth-client-secret", re.compile(r"GOCSPX-[A-Za-z0-9_\-]{20,}")),
    ("oauth-client-id", re.compile(r"\d{6,}-[A-Za-z0-9_\-]{10,}\.apps\.googleusercontent\.com")),
    # ya29. is an access token, 1//0 a refresh token. Both are bearer values.
    ("oauth-token", re.compile(r"(?:ya29\.|1//0)[A-Za-z0-9_\-]{20,}")),
)

# Named for what they ARE, so a new file matching the reason is caught too.
CREDENTIAL_FILENAMES = re.compile(
    r"^(credentials|client_secret.*|token|tokens|refresh_token)\.json$|"
    r"\.(keychain|keychain-db|p12|pfx|pem|key)$",
    re.IGNORECASE,
)

def mailbox_is_reserved(address):
    domain = address.rsplit("@", 1)[1].lower()
    local = address.rsplit("@", 1)[0].lower()
    # A SUBDOMAIN of a reserved domain is reserved too (backstage#18, Dan's sign off 2026-09-19):
    # everything beneath example.com belongs to it. Matched as the whole domain or a dot then the
    # whole domain, never a bare suffix, so notexample.com and example.com.attacker.org, both real
    # and registrable, are still refused. That is the risk of widening a privacy control, and a
    # test pins each shape.
    if any(domain == d or domain.endswith("." + d) for d in RESERVED_DOMAINS):
        return True
    if domain.endswith(RESERVED_TLDS):
        return True
    if local == "git" and domain in CODE_HOSTS:
        return True
    return False


def findings_in(text):
    """Every finding in one text, as (rule, line number, the matched value).

    The value is carried so that occurrences of the SAME secret can be grouped.
    It is never printed, and never leaves this process: a guard that reports a
    leaked secret by quoting it has leaked it a second time (L222).
    """
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        for rule, pattern in CONTENT_RULES:
            match = pattern.search(line)
            if match:
                found.append((rule, number, match.group()))
        for address in EMAIL.findall(line):
            if not mailbox_is_reserved(address):
                found.append(("mailbox", number, address))
    return found


