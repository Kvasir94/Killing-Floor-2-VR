"""Public release notices. Enabled for fresh installs; explicit opt-outs are preserved.

When enabled under Setup, the window asks GitHub's public releases
API once per start, in the background, with a short time limit. The request
carries no player, machine or install details beyond what any web request
does. Any failure is silent: launching never depends on it, and nothing is
downloaded or installed.
"""
import json
import re
import urllib.request

REPOSITORY = "Kvasir94/Killing-Floor-2-VR"
RELEASES_API = f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=30"
RELEASES_PAGE = f"https://github.com/{REPOSITORY}/releases"
VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)")
DATE = re.compile(r"(?<!\d)(20\d{6})(?!\d)")


def parse(version):
    """(major, minor, patch) from tags like 'v0.2.0-alpha' or '0.1.0-alpha'; None if absent."""
    match = VERSION.search(str(version or ""))
    return tuple(int(part) for part in match.groups()) if match else None


def newer(latest, current):
    def key(value):
        base = parse(value)
        if base is None: return None
        suffix = str(value).split("-",1)[1] if "-" in str(value) else ""
        channel = 0 if suffix.startswith("alpha") else 1 if suffix.startswith("beta") else 2 if suffix.startswith("rc") else 3
        sequence = tuple(int(n) for n in re.findall(r"\d+",suffix))
        return base, channel, sequence
    latest, current = key(latest), key(current)
    return bool(latest and current and latest > current)


def latest_release(timeout=5):
    """(tag, page URL) of the newest published release, or None."""
    request = urllib.request.Request(RELEASES_API, headers={"Accept": "application/vnd.github+json",
                                                             "User-Agent": "KF2-VR-launcher"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = json.loads(response.read(1024 * 1024).decode("utf-8"))
    except (OSError, ValueError):
        return None
    releases = data if isinstance(data,list) else [data] if isinstance(data,dict) else []
    published = [item for item in releases if isinstance(item,dict) and not item.get("draft") and isinstance(item.get("tag_name"),str) and parse(item["tag_name"])]
    if not published: return None
    selected = published[0]
    for candidate in published[1:]:
        if newer(candidate["tag_name"],selected["tag_name"]): selected=candidate
    tag, url = selected["tag_name"], selected.get("html_url")
    return tag, url if isinstance(url,str) and url.startswith(RELEASES_PAGE + "/tag/") else RELEASES_PAGE



def stamp(value):
    """UTC build date (YYYYMMDD) in a tag or build ID, or None."""
    match = DATE.search(str(value or ""))
    return match.group(1) if match else None


def available_update(current, timeout=5, build=""):
    """(tag, URL) when a newer release than current exists, else None.

    A release dated before this build is never offered, even if its version
    number reads higher: the installed build already contains it."""
    found = latest_release(timeout)
    if not found or not newer(found[0], current): return None
    released, built = stamp(found[0]), stamp(build)
    return None if released and built and released < built else found
