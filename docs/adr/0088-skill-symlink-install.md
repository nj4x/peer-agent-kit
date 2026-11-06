---
artifact-type: adr
lineage-rules: exempt
title: Install the peer-agent skill as a symlink to the kit copy
status: accepted
date: 2026-11-06
authors: Roman Herasymenko
---

# ADR 0088: Install the peer-agent Skill as a Symlink to the Kit Copy

**Status:** Accepted
**Date:** 2026-11-06
**Context:** Issue #33. `install.sh` copied the skill only when `$CLAUDE_DIR/skills/peer-agent/SKILL.md` was missing, and `update.sh` refreshed it only when `skillInstalledByKit` was `true`. A pre-existing copy therefore stayed in place forever. The SessionStart hook injects that file into every session, so sessions got delegation rules that named an MCP tool (`ask_peer_agent`) the server no longer has. Even a kit-installed skill was a `cp -r` copy, unlike the "bundled, not fetched" rule the hooks and MCP server follow.

## Decision

1. **Symlink, not copy.** When nothing exists at `$CLAUDE_DIR/skills/peer-agent`, `install.sh` creates a directory symlink to `$KIT_DIR/skills/peer-agent` and records `skillInstalledByKit: true`. `pluginRoot` (resolved with `cd -P`) then points at the kit, so the SessionStart hook reads the kit's `SKILL.md` directly. When the kit replaces a copy (decisions 2 and 4), the replacing script also sets `pluginRoot` to the kit directory, because the old value can lead through the replaced link to another tree; `update.sh` then reruns `settings-patch.js`, which repoints the hook commands, on the up-to-date path as well.
2. **Stale pre-existing copy: warn, then offer.** When the existing `SKILL.md` differs from the kit's, `install.sh` and `update.sh` print a warning. They replace the copy with the symlink only after the user agrees: a `(Y/n)` prompt on a terminal, or `PEER_AGENT_KIT_REPLACE_SKILL=1` in advance. Without a terminal, or with `PEER_AGENT_KIT_REPLACE_SKILL=0`, or with `--no-install-skill` (install only), they keep the copy and print the manual `ln -s` command. A copy identical to the kit's is left alone; the next update checks it again.
3. **Replaced copy is backed up and restored.** The copy moves to `~/.peer-agent-kit-skill-backup`, outside `~/.peer-agent-kit`: `install.sh` deletes that directory to clean up an incomplete install, and the copy must survive it. The manifest field `skillReplacedBackup` records the path **before** the move. Restore (`skill_restore_backup`) puts the copy back only over the kit symlink or an empty path; a copy the user put in place since is kept, with a warning naming the backup. It runs in:
   - `uninstall.sh` (also the install rollback path), right after the manifest reads and before the unpatch steps, so a failing unpatch under `set -e` cannot strand the copy; without a manifest it checks the fixed backup path. An unreadable manifest stops uninstall before the restore; the copy then stays at the backup path;
   - `install.sh`, before it cleans up an incomplete prior install (for example, after Ctrl-C at a later prompt).

   A recorded path with no backup means the move never ran, so the copy is still in place and is left alone. There is one backup slot: while it is taken, neither script replaces again; they print the manual command.
4. **Older kit-installed copies are converted.** When `skillInstalledByKit` is `true` and the skill is a copy identical to the kit's, or is missing, `update.sh` links the kit copy without asking. The flag cannot tell a kit copy from one the user edited or put there since, so a differing copy takes the consent-and-backup path of decisions 2 and 3.
5. **Skill check runs on every update.** `update.sh` checks the skill also when the kit is already up to date, because a stale copy can sit behind a current `kitSha`. On the full path the skill step now runs after the pull and before the settings repatch (old ADR 0080 step 10 came after step 9), so a relink's new `pluginRoot` reaches `settings.json`. A failure in the skill step stops the update with settings unpatched, like any other step after step 3; so does Ctrl-C at its replace prompt. Rerunning `update.sh` recovers, because `kitSha` is written only at the end. A kit-installed copy is compared with `SKILL.md` as of the previous `kitSha` (`git show`), so a pull that edits `SKILL.md` still relinks the kit's own copy without a prompt.
6. **No frontmatter patch through the symlink.** The kit's `SKILL.md` already carries `disable-model-invocation: true` (the key `install.sh`'s frontmatter patch adds; a test asserts it). `install.sh` skips `skill-patch.js` when the skill resolves into the kit, and `update.sh` no longer runs it, so neither script writes into the kit's git tree.

## Consequences

- Kit updates (`git pull`) reach sessions with no copy step; a restart is still needed for SessionStart to re-read the file.
- Moving or deleting the kit directory breaks the skill symlink. This matches the hooks and MCP server, which also run from the kit directory.
- Amends ADR 0080: step 10 ("overwrite `$CLAUDE_DIR/skills/peer-agent` from repo and repatch its frontmatter") is replaced by decisions 2, 4 and 6; step 2's immediate exit when up to date now runs the skill check first (decision 5); the "Skill updates only if `skillInstalledByKit=true`" rationale no longer holds.
