#!/bin/sh
# Install PocketWorld's local git hooks.
# ---------------------------------------------------------------------
# .git/hooks is NOT version controlled, so a fresh clone has none of this.
# Run this once per clone. Re-running is safe and idempotent.
#
# Chain-safe by construction: this repo already has git-lfs hooks
# (post-checkout / post-commit / post-merge / pre-push). We never
# overwrite an existing hook — if one is present and isn't ours, we refuse
# and tell you, rather than silently breaking LFS.

set -eu
ROOT=$(git rev-parse --show-toplevel)
HOOKS=$(git rev-parse --git-path hooks)
MARKER='# pocketworld-managed-hook'

install_hook() {
  name=$1; body=$2
  target="$HOOKS/$name"
  if [ -e "$target" ] && ! grep -q "$MARKER" "$target" 2>/dev/null; then
    echo "⚠️  $name already exists and is not ours — NOT overwriting."
    echo "    Merge this in by hand:"
    echo "    $body"
    return 0
  fi
  printf '%s\n' "$body" > "$target"
  chmod +x "$target"
  echo "✅ $name"
}

install_hook pre-commit "#!/bin/sh
$MARKER
# Block secrets before they enter history. Local, offline, sub-second.
#
# Why pre-commit and not just CI: once a secret is committed, rotating it
# is the ONLY remedy — rewriting history does not un-leak it, because the
# object may already have been pushed, fetched, or cached. The cheapest
# point of control is before the commit object exists.
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks git --staged --no-banner --redact -c \"\$(git rev-parse --show-toplevel)/.gitleaks.toml\" \"\$(git rev-parse --show-toplevel)\" || {
    echo ''
    echo '🔴 Secret detected in staged changes — commit blocked.'
    echo '   If it is a false positive, add a narrow rule to .gitleaks.toml'
    echo '   (narrow: a path or a line pattern, never a blanket exclusion).'
    echo '   To bypass in a genuine emergency: git commit --no-verify'
    exit 1
  }
else
  echo '⚠️  gitleaks not installed — secret scan SKIPPED. brew install gitleaks'
fi"

echo ""
echo "Hooks installed into $HOOKS"
echo "git-lfs hooks left untouched:"
ls "$HOOKS" | grep -E '^(post-checkout|post-commit|post-merge|pre-push)$' | sed 's/^/  /' || true
