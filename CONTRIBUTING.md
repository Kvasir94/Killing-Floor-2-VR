# Contributing and reporting issues

Please read [AGENTS](AGENTS.md) for the repository workflow and allowed tests,
[source setup](docs/BUILDING.md) for build limits, and [known issues](docs/public-alpha/RELEASE-NOTES-DRAFT.md)
before changing or reporting a feature. Keep fixes focused. Include the reason,
affected behavior and relevant compile/fast-gate result in a change description.
Do not include game extracts, compiled packages, local logs or personal data in commits.

Invited players should use the report destination supplied with their invitation.
If the project owner later enables public GitHub issues, the same template works:

```text
Build ID or source commit:
Solo / Host / Join; VR / Desktop:
Headset + connection/OpenXR runtime; GPU:
Map, perk, character, weapon:
Relevant options (reload mode, optional content, etc.):
Steps / expected result / actual result:
Does it repeat?
Sanitized log ZIP or screenshot, if useful:
```

Use Save logs for a bug report and review the ZIP before attaching it. The
collector replaces recognized identifiers and removes recognized credentials;
free-form text may still need manual removal. Keep passwords/join codes, raw
session folders, configs and crash dumps private. For reloads add normal/elite,
empty/tactical and left/right hand. For online issues identify which player saw
the problem and whether they were outside the host's network.

Send suspected credential exposure privately to the project owner via the
invitation contact rather than putting the secret in an issue. No specific
public/private reporting service is announced by this source export.
