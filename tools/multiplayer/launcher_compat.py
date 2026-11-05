"""Repository launch context for the pinned OptimumBox player window.

No UI, profile writes, deployment or runtime changes belong here.
"""

def contextual_arguments(arguments, saved, context):
    """Only repository dependency locations differ from an ordinary portable launch."""
    result = list(arguments)
    if not context.workspace:
        return result
    result += ["--cache-root", str(saved.cache_root)]
    if "--host" in result:
        result += ["--server-root", str(saved.server_root)]
    if saved.prepare_only:
        result.append("--prepare-only")
    for flag in ("--damage-popups", "--no-damage-popups"):
        if flag in context.initial_arguments and "--host" in result:
            result.append(flag)
    if "--test-map-players" in context.initial_arguments and "--host" in result:
        result += ["--test-map-players", str(saved.test_map_players)]
    return result



def host_form_identity(saved, fallback):
    """Explicit command-line choices override this release's remembered host.

    Empty password is an explicit public-host choice; None means no override.
    """
    name, password = fallback
    return (saved.server_name or name,
            "" if saved.open_server else saved.password if saved.password is not None else password)
