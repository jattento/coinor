#!/usr/bin/env python3
"""Cook the Grok fork changelog into the Coinor application bundle.

Downloads the fork releases from the GitHub API, compares each release against
the one published immediately before it (by date, not tag name), classifies
commits into fork-owned work and upstream (xAI) work, extracts the feature and
fix bullets from the release notes and the upstream sync commit bodies, and
writes the result to ``Coinor/Resources/GrokChangelog.json``. The application
reads the cooked file at runtime instead of calling the GitHub API.

Run this script before a release build. The cooked changelog is committed to
the repository so the application always shows the changelog of the Grok
version it was built against.

Usage:
    scripts/grok-changelog/cook.py

Requires the GitHub CLI (`gh`) to be installed and authenticated, because the
GitHub API rate limit is 60 requests/hour unauthenticated and the changelog
makes one release-list call plus one compare call per release.
"""

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
OUTPUT = REPO_ROOT / "Coinor" / "Resources" / "GrokChangelog.json"
FORK = "jattento/grok-build"
OLDEST_UPSTREAM_TAG = "c68e39f604"
BOILERPLATE_HEADINGS = {"validation", "verification", "security", "commit", "install"}


def gh_api(path: str) -> object:
    result = subprocess.run(
        ["gh", "api", path],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def fork_summary(notes: str) -> list[str]:
    """Feature bullets from the release notes, minus validation boilerplate."""
    bullets: list[str] = []
    paragraphs: list[str] = []
    skipping = False
    for line in notes.splitlines():
        trimmed = line.strip()
        lower = trimmed.lower()
        if trimmed.startswith("#"):
            heading = lower.lstrip("#").strip()
            skipping = any(heading.startswith(b) for b in BOILERPLATE_HEADINGS)
            continue
        if skipping:
            continue
        if trimmed.startswith("- "):
            bullets.append(trimmed[2:].strip())
        elif trimmed:
            paragraphs.append(trimmed)
    if bullets:
        return bullets
    return paragraphs[:1]


def upstream_summary(commits: list[dict]) -> list[str]:
    """Feature bullets from `Synced from monorepo` commit bodies."""
    bullets: list[str] = []
    for commit in commits:
        author = commit["commit"]["author"]["name"]
        if "grokkybara" not in author.lower():
            continue
        for line in commit["commit"]["message"].splitlines():
            trimmed = line.strip()
            if trimmed.startswith("- "):
                bullets.append(trimmed[2:].strip())
    return bullets


def main() -> None:
    releases = gh_api(f"repos/{FORK}/releases?per_page=100")
    by_date = sorted(releases, key=lambda r: r["published_at"])

    entries = []
    released_fork_subjects: set[str] = set()
    for index, release in enumerate(by_date):
        previous = by_date[index - 1]["tag_name"] if index > 0 else OLDEST_UPSTREAM_TAG
        compare = gh_api(f"repos/{FORK}/compare/{previous}...{release['tag_name']}")
        commits = compare.get("commits") or []
        # Remember every fork commit subject that a published release already
        # covers. The fork rebases its overlay commits on top of each upstream
        # sync, so a plain `tag...main` range for the unreleased section would
        # otherwise repeat old, already-released overlay commits.
        for commit in commits:
            author = commit["commit"]["author"]["name"]
            if "grokkybara" not in author.lower():
                released_fork_subjects.add(
                    commit["commit"]["message"].splitlines()[0]
                )
        entries.append(
            {
                "tag": release["tag_name"],
                "publishedAt": release["published_at"],
                "forkSummary": fork_summary(release.get("body") or ""),
                "upstreamSummary": upstream_summary(commits),
            }
        )

    # The fork's main branch usually carries work that has not been published
    # as a release yet: upstream syncs absorbed after the last release and the
    # overlay commits built on top of them. Surface that as an "Unreleased"
    # entry so the changelog reflects what the installed Grok actually
    # contains, not only what has been tagged.
    last_tag = by_date[-1]["tag_name"]
    unreleased = gh_api(f"repos/{FORK}/compare/{last_tag}...main")
    unreleased_commits = unreleased.get("commits") or []
    if unreleased_commits:
        entries.append(
            {
                "tag": "Unreleased",
                "publishedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "forkSummary": [
                    commit["commit"]["message"].splitlines()[0]
                    for commit in unreleased_commits
                    if "grokkybara" not in commit["commit"]["author"]["name"].lower()
                    and "delta budget" not in commit["commit"]["message"].lower()
                    and commit["commit"]["message"].splitlines()[0]
                    not in released_fork_subjects
                ],
                "upstreamSummary": upstream_summary(unreleased_commits),
            }
        )

    entries.sort(key=lambda e: e["publishedAt"], reverse=True)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps({"releases": entries}, indent=2) + "\n")
    print(f"Cooked {len(entries)} releases into {OUTPUT}")


if __name__ == "__main__":
    main()
