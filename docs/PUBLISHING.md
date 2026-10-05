# Maintaining a clean public source repository

Keep the working development repository private. It contains preserved chats,
history, local research and generated-data references that do not belong in a
public Git repository. A clean export is a content snapshot, not a branch of
that private repository. This workflow prepares files locally; it does not
create a remote, upload, push or publish anything.

The public source repository is
[Kvasir94/Killing-Floor-2-VR](https://github.com/Kvasir94/Killing-Floor-2-VR),
displayed as **Killing Floor 2 VR**. Keep its history independent of the private
development repository. Source publication does not authorize playable ZIP
uploads or binary GitHub releases.

## First public source snapshot

1. Finish and commit the reviewed source/documentation changes in the private
   development checkout. Run the relevant compile/fast gate for code changes.
2. Run `python tools/export_public_source.py` (or `tools/export-public-tree.ps1`).
   The exporter selects committed source, documented current non-game assets
   and the pinned MinHook source/licence; it excludes private history, internal
   notes, local data, generated game packages and the unneeded generation prompt.
3. Review the new folder and its sibling `.manifest.json`: source commit,
   per-file hashes, ZIP hash, exclusion counts, rewrites and pattern findings.
   Check README/build/known-issue statements and any new dependency or asset
   provenance. A zero pattern count is not proof that every secret is recognizable.
4. Inspect the ZIP; it must contain source and documented inputs, with no `.git`
   history, user profiles, session logs, game extracts or compiled playable packages.
   The source ZIP is separate from the invited runnable ZIP.
5. Copy the reviewed export folder to a new public-repository staging directory.
   Initialize a **new** Git repository there and make an initial commit using
   your intended public author identity. Do not copy the private `.git` folder,
   push a private branch, or preserve private commit ancestry. Configure/remotely
   publish it yourself only when ready.

The review manifest stays beside the export and is not included in the source
ZIP. It avoids listing private transcript filenames. Keep the private development
checkout, historical packages and older exports intact for rollback.

## Later private-to-public updates

Repeat the same export from the new reviewed private commit into a **new** output
folder. Existing nonempty exports are never overwritten or deleted. Compare
`files_sha256` against the previous published snapshot to identify added,
changed and removed content. Review the changed files and updated exclusions;
do not assume an earlier privacy review covers new content.

Keep a private publication record beside the exports with the published public
commit, export manifest/ZIP paths and ZIP SHA-256. Use that manifest as the next
comparison baseline; do not include audit records or private handoffs in the
public tree.

In a checkout of the public repository, apply only those reviewed file changes.
Preserve that public checkout's `.git` directory and any public-only files.
Review removals individually; do not mirror-delete the public tree or copy an
entire private checkout over it. Use normal public commits (or patches/draft PRs)
with the change and relevant checks. Do not merge/cherry-pick a private branch
that imports private ancestry, and never force-push the development history.
A private source commit/hash can identify the export without exposing its history.

Keep public code/licence/build instructions and known limitations accurate.
The exact private playable build still needs local game/SDK inputs and the
missing current hand authoring scene listed in [BUILDING](BUILDING.md). Do not
label an exported source snapshot as a self-contained playable download.
Public binary distribution remains a separate asset/provenance decision;
private invited-test asset review is deferred, not public redistribution clearance.

When updating the invited runnable package, use a fresh immutable release and
new ZIP identity, preserve the prior release, and keep all required mod assets
and launcher runtimes. Never patch the frozen selected folder in place. Fill
package-specific IDs/hashes and private download/report destinations in delivery
messages before sending. The user handles posting; no service is assumed here.
