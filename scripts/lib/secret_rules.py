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


# How much of a file is read before deciding whether it is text. Git's own
# binary heuristic looks at the first 8000 bytes, and matching it means this
# agrees with the tool every reader here already has in their hands.
TEXT_SNIFF_BYTES = 8000


def is_text(raw):
    """Whether this content is text at all, rather than bytes that merely decode.

    backstage#36. THE MAILBOX RULE IS THE ONLY ONE LOOSE ENOUGH FOR NOISE TO
    SATISFY IT. Every credential rule needs a documented prefix and a run of
    twenty or more characters, which random bytes do not produce. A local part, an
    at sign, a domain and a two letter suffix is six characters at its shortest,
    and a Swift compiler intermediate that is 62% printable produced two of them
    on 2026-09-19, refusing a green push that passed again once the build cache
    was rebuilt (L491).

    THE SHAPE IS DESCRIBED IN WORDS RATHER THAN WRITTEN OUT, because this file is
    scanned by the guard that imports it: an example address here is refused on
    sight, and it is refused inside every throwaway tree a suite copies this
    library into (L245).

    A NUL byte in the first 8000, or content that does not decode as UTF-8, means
    the bytes are not text and an address found among them is not an address.

    THE LIMIT SAID OUT LOUD: content in UTF-16 or another encoding is not text by
    this rule, so a real mailbox written in one would not be found. Every file
    this repository tracks is UTF-8, measured rather than assumed: all 62 of them
    are text by this predicate, so nothing that is protected today loses it.
    """
    if b"\x00" in raw[:TEXT_SNIFF_BYTES]:
        return False
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


def findings_in_bytes(raw):
    """Every finding in one file's bytes, which is what both guards actually hold.

    The decode and the text decision are made HERE rather than at each call site,
    so the two guards cannot come to disagree about what is text any more than
    they can about what is a secret (L370).
    """
    # Decoded with replacement rather than skipped on a bad byte: a scanner that
    # gives up on a file holding one binary byte stops examining it and says so
    # in a way that reads as clean (L329). The credential rules still read every
    # byte of it; only the mailbox rule stands down.
    return findings_in(raw.decode("utf-8", errors="replace"), mailboxes=is_text(raw))


def findings_in(text, mailboxes=True):
    """Every finding in one text, as (rule, line number, the matched value).

    `mailboxes` is False for content that is not text. It is a parameter rather
    than something worked out in here so that a test can drive both branches
    directly, and so the decision has exactly one home, in findings_in_bytes.

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
        if not mailboxes:
            continue
        for address in EMAIL.findall(line):
            if not mailbox_is_reserved(address):
                found.append(("mailbox", number, address))
    return found


