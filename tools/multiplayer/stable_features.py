"""Source gate for parked content, not a profile or command-line preference."""

def experimental_content_enabled():
    return False


def filter_mutators(value):
    return ",".join(item.strip() for item in str(value).split(",")
                    if item.strip() and not item.strip().lower().startswith(("kf2breacher.", "kf2td.")))
