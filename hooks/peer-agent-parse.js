#!/usr/bin/env node
// peer-agent-kit — parses a user prompt for a peer-agent mode change.
'use strict';

const { VALID_MODES, getDefaultMode } = require('./peer-agent-config');

// Returns the mode to set, or null for no match. 'off' is a real mode value
// (ADR 0004): it is set the same way as lite/full/max, never a scope-revert.
function parseModeChange(promptRaw) {
  const prompt = (promptRaw || '').trim().toLowerCase().replace(/\s+/g, ' ');
  if (!prompt) return null;

  // Deactivation checked first so "turn peer-agent mode off" never falls through
  // to an activation pattern below.
  const wantsOff =
    /\b(stop|disable|deactivate|quit|exit|kill)\s+(the\s+)?peer-agent\b/.test(prompt) ||
    /\bpeer-agent(\s+mode)?\s+(off|stop|disabled?)\b/.test(prompt) ||
    /\bturn\s+off\s+(the\s+)?peer-agent\b/.test(prompt) ||
    // "stop delegating" as a leading command or aimed at the peer/cline —
    // never mid-sentence advice about someone else's delegating.
    /^(please\s+)?stop\s+delegating\b/.test(prompt) ||
    (/\bstop\s+delegating\b/.test(prompt) && /\b(peer-agent|cline)\b/.test(prompt));
  // Note: "normal mode" is NOT an off-trigger here — it belongs to caveman-kit,
  // which may be installed alongside; reacting to it would couple the two kits.
  if (wantsOff) return 'off';

  // Questions about peer-agent are not activation commands.
  const isQuestion = /^(what|whats|what's|how|why|when|where|who|does|do|did|is|are|can|could|would|should|tell me|explain)\b/.test(prompt);
  if (!isQuestion) {
    // "delegate everything" is an explicit ask for the max policy, not the default.
    if (/\bdelegate\s+(everything|as much as (you can|possible))\b/.test(prompt)) {
      return 'max';
    }
    if (/\b(activate|enable|start|turn on|use|switch to|want|give me)\b[^.]{0,40}\bpeer-agent\b/.test(prompt) ||
        /\bpeer-agent\s+mode\s+(on|please|now)\b/.test(prompt) ||
        /^peer-agent(\s+mode)?\s*[.!]*$/.test(prompt)) {
      const mode = getDefaultMode();
      return mode !== 'off' ? mode : null;
    }
  }

  if (prompt.startsWith('/peer-agent')) {
    const parts = prompt.split(/\s+/);
    if (parts[0] !== '/peer-agent') return null; // e.g. /peer-agent-foo — not us
    const arg = parts[1] || '';
    if (!arg) return getDefaultMode();
    if (arg === 'off' || arg === 'stop' || arg === 'disable') return 'off';
    if (VALID_MODES.includes(arg)) return arg;
    return null; // unknown level — leave flag untouched
  }

  return null;
}

module.exports = { parseModeChange };
