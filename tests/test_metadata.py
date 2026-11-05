"""plasmoid/metadata.json: only the GitHub no-reply address, never a personal email."""

import json
import re
from pathlib import Path


METADATA = Path(__file__).resolve().parent.parent / "plasmoid" / "metadata.json"
ALLOWED_EMAIL = "104578369+flybytech-prog@users.noreply.github.com"
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def email_problems(text):
    """Problems with the emails in metadata ``text``; an empty list means it is clean."""
    problems = []
    if "@gmail.com" in text.lower():
        problems.append("a @gmail.com address appears in the file")
    for author in json.loads(text)["KPlugin"].get("Authors", []):
        if author.get("Email", ALLOWED_EMAIL) != ALLOWED_EMAIL:
            problems.append("an author email is not the GitHub no-reply address")
    if any(found != ALLOWED_EMAIL for found in EMAIL.findall(text)):
        problems.append("an email other than the GitHub no-reply address appears in the file")
    return problems


def test_metadata_uses_only_the_no_reply_address():
    text = METADATA.read_text(encoding="utf-8")
    assert email_problems(text) == []
    authors = json.loads(text)["KPlugin"]["Authors"]
    assert [author["Email"] for author in authors] == [ALLOWED_EMAIL]


def test_a_gmail_author_is_caught():
    # Mutated in memory only; the real file is never written.
    metadata = json.loads(METADATA.read_text(encoding="utf-8"))
    metadata["KPlugin"]["Authors"][0]["Email"] = "someone@gmail.com"
    assert len(email_problems(json.dumps(metadata))) == 3


def test_a_gmail_address_outside_the_authors_is_caught():
    metadata = json.loads(METADATA.read_text(encoding="utf-8"))
    metadata["KPlugin"]["Description"] += " (mail Someone@GMail.com)"
    assert email_problems(json.dumps(metadata)) != []
