"""Safe construction of PostgREST text filters from user input.

PostgREST `or=(a.ilike.*x*,b.ilike.*x*)` is a mini-language: commas, parentheses, quotes and backslashes in user text
could add or alter clauses. Everything user-supplied is reduced to a conservative alphabet BEFORE it is placed in a
filter, and LIKE wildcards are escaped so input is always matched literally.
"""
import re

_DISALLOWED = re.compile(r"[^\w\s\-./+']", re.UNICODE)  # keep letters, digits, _, space, - . / + '
_SPACES = re.compile(r"\s+")


def sanitize_term(raw: str, max_len: int = 100) -> str:
    cleaned = _DISALLOWED.sub(" ", raw or "")
    return _SPACES.sub(" ", cleaned).strip()[:max_len]


def like_escape(term: str) -> str:
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def contains_pattern(term: str) -> str:
    """PostgREST pattern for 'contains' (uses * as the wildcard)."""
    return f"*{like_escape(term)}*"


def slugify(text: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug[:80]
