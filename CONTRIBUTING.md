# Contributing and reporting issues

Read [BUILDING](docs/BUILDING.md), [contributor workflow](AGENTS.md) and the
[known issues](docs/public-alpha/RELEASE-NOTES-DRAFT.md) before changing a feature.
Keep fixes focused and describe the affected behavior, reason and relevant checks.
Do not commit game extracts, compiled packages, local logs or personal data.

Use the feedback channel linked from the [release](https://github.com/Kvasir94/Killing-Floor-2-VR/releases).
For a useful report, include:

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

Use **Save logs for a bug report** and review the ZIP before sharing. Recognized
identifiers and credentials are sanitized, but free-form text can need manual
removal. Keep passwords, join codes, raw session folders, configs and crash dumps
private. For reloads add normal/elite, empty/tactical and left/right hand. For
online issues identify which player saw it and whether they were outside the
host's network. Contact the maintainer privately for sensitive reports; never
post an exposed credential in a public issue or channel.
