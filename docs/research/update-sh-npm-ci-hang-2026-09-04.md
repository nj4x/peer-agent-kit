# Bug: update.sh Hangs at Extension Rebuild Step

**Status:** Root cause identified (npm behavior with stderr redirect)  
**Severity:** Critical — update.sh hangs indefinitely, blocking all updates  
**Reproduced:** Yes

## Symptom

Running `/Users/r.herasymenk/.local/share/peer-agent-kit/update.sh` halts at:

```
[peer-agent-kit] Rebuilding VS Code extension...
```

Process never completes; must kill manually. User reports hanging after multiple runs; manifest never updates.

## Root Cause: npm ci with Stderr Redirect Hangs on Input Prompt

The bug is at `/Users/r.herasymenk/.local/share/peer-agent-kit/update.sh` line 125:

```bash
npm ci 2>/dev/null || fail "extension npm ci failed"
```

### Why It Hangs

npm v10.8.2 (user's version) by default runs two interactive prompts when installing:

1. **Fund prompt:** "found 0 vulnerabilities / run `npm fund` for details"
2. **Audit prompt:** security/package vulnerability reports

When stderr is redirected to `/dev/null` (`2>/dev/null`), npm cannot display these prompts but still **waits for user input on stdin**. The process blocks indefinitely waiting for a keypress, despite being in a non-interactive shell context.

**Evidence:**

Tested in `/Users/r.herasymenk/.local/share/peer-agent-kit/extension`:

```bash
# HANGS indefinitely:
timeout 3 bash -c 'npm ci 2>/dev/null && echo OK'
# TIMEOUT or FAIL: 124

# Also hangs with full redirect:
timeout 3 bash -c 'npm ci > /dev/null 2>&1 && echo OK'
# TIMEOUT or FAIL: 124

# Works without redirect:
timeout 3 bash -c 'npm ci && echo OK'
# (completes in ~300ms)

# Works with flags to disable prompts:
timeout 3 bash -c 'npm ci --no-fund --no-audit 2>/dev/null && echo OK'
# added 6 packages in 317ms
# OK
```

### Secondary Observation: "New commits available" → "Already up to date" Oddity

User reported seeing both messages in output:

```
[peer-agent-kit] New commits available (aba9c2d → df03f08)
...
[peer-agent-kit] Already up to date
```

This is **not a bug**, but a consequence of stale manifest + git state:

1. Line 82: `git fetch origin` fetches remote metadata
2. Line 86: REMOTE_SHA resolves to `df03f08` (latest on origin/main)
3. Line 89: CURRENT_KIT_SHA read from manifest as `aba9c2dec...` (old)
4. Line 100: Script prints "New commits available" correctly
5. Line 119: `git pull origin main --ff-only` runs
6. **Git output:** "Already up to date" — because installed copy is already at df03f08 (from a prior incomplete/manual update)
7. **Missing:** manifest.kitSha never updates to df03f08 because the `npm ci 2>/dev/null` hang at line 125 blocks the entire script

Manifest remains at old SHA forever; next run repeats the same sequence.

**Evidence:** After failed update run, manifest state:

```json
{
  "kitSha": "aba9c2dec653d78f09b6b6d747d3ace3f17607ea",  // old
  "completed": true
}
```

Installed copy HEAD:

```bash
$ git -C ~/.local/share/peer-agent-kit rev-parse HEAD
df03f084c47b57f606bf0b6eb0cbd397fa375c82  # current, matches remote
```

## Fix

Add `--no-fund --no-audit` flags to `npm ci` command to suppress interactive prompts:

**File:** `/Users/r.herasymenk/.local/share/peer-agent-kit/update.sh` (and workspace repo version)

**Line 125:** Change from:

```bash
npm ci 2>/dev/null || fail "extension npm ci failed"
```

To:

```bash
npm ci --no-fund --no-audit 2>/dev/null || fail "extension npm ci failed"
```

This eliminates the input-wait behavior while preserving the output suppression intent.

### Alternative Fix (Less Preferred)

Explicitly redirect stdin to /dev/null:

```bash
npm ci 2>/dev/null </dev/null || fail "extension npm ci failed"
```

**Why less preferred:** Does not guarantee future versions of npm won't hang on other prompts. Flag-based suppression is more explicit and forwards-compatible.

## Testing

After applying fix:

```bash
cd /Users/r.herasymenk/.local/share/peer-agent-kit/extension
npm ci --no-fund --no-audit 2>/dev/null && echo OK
# added 6 packages in ~300ms
# OK
```

No timeout observed.

## Impact

- **Scope:** All users running `update.sh` (installed copies at `~/.local/share/peer-agent-kit`)
- **Trigger:** Any `npm ci` where node_modules already exist and lockfile is up-to-date (most common case)
- **Workaround:** Kill update.sh, manually run:
  ```bash
  cd ~/.local/share/peer-agent-kit/extension && npm ci && npm run install-dev
  cd ~/.local/share/peer-agent-kit && ./update.sh
  ```
  (second run will proceed past npm ci since node_modules already populated)

## Files Involved

- `/Users/r.herasymenk/.local/share/peer-agent-kit/update.sh` — line 125 (installed copy)
- `/Users/r.herasymenk/workspace/peer-agent-kit/update.sh` — line 125 (source)
- `/Users/r.herasymenk/.local/share/peer-agent-kit/extension/package.json` — npm version constrained via package-lock.json v3
- `/Users/r.herasymenk/.local/share/peer-agent-kit/extension/package-lock.json` — valid v3, contains 6 packages

## Related ADRs

- ADR 0084 ("Extension rebuild") — references this build step; should be updated to document the --no-fund --no-audit requirement
