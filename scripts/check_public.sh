#!/bin/bash
# Fails if anything that must not be public is tracked or staged: files under data/, databases, env files,
# licensed-data columns (KenPom ratings, betting lines) in tracked CSVs, secrets, or betting language in prose.
#   scripts/check_public.sh        (from the repo root; run before every push)
cd "$(dirname "$0")/.." || exit 1
fail=0
files=$( { git ls-files; git diff --cached --name-only; } | sort -u)
bad_paths=$(echo "$files" | grep -E '^data/|\.db$|\.sqlite$|(^|/)\.env' || true)
[ -n "$bad_paths" ] && { echo "FAIL tracked private files:"; echo "$bad_paths"; fail=1; }
csvs=$(echo "$files" | grep -E '\.csv$' || true)
if [ -n "$csvs" ]; then
    # column names only (the header row): licensed ratings and market columns must never be published
    hits=$(for f in $csvs; do [ -f "$f" ] && head -1 "$f" | grep -q -i -E 'adj_?em|adj_?oe|adj_?de|adj_?tempo|consensus_spread|moneyline|spread_line|odds|kenpom_rank|home_wp' && echo "$f"; done)
    [ -n "$hits" ] && { echo "FAIL licensed-data columns in:"; echo "$hits"; fail=1; }
fi
secrets=$(echo "$files" | xargs grep -l -E '(sk-ant-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16}|api[_-]?key\s*=\s*["'"'"'][A-Za-z0-9]{16,}|Bearer [A-Za-z0-9._-]{20,})' 2>/dev/null || true)
[ -n "$secrets" ] && { echo "FAIL possible secrets in:"; echo "$secrets"; fail=1; }
md=$(echo "$files" | grep -E '\.md$' || true)
if [ -n "$md" ]; then
    bet=$(echo "$md" | xargs grep -n -i -E '\b(ROI|units? (won|lost|profit)|STRONG_BET|VERY_HIGH|bet labels? (win|hit)|against the spread record|ATS record|best bets?|locks?\b of the)' 2>/dev/null || true)
    [ -n "$bet" ] && { echo "FAIL betting language:"; echo "$bet"; fail=1; }
fi
[ $fail -eq 0 ] && echo "check_public: ok ($(echo "$files" | grep -c .) files)"
exit $fail
