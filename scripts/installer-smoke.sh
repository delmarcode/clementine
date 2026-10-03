#!/usr/bin/env bash
# Proves `mix clementine.install` and `mix clementine.gen.agent` against a
# real, freshly generated Phoenix app: install, install again (no change),
# generate an agent, generate it again (no change), then the app's own
# gates. Its test suite runs Clementine's conformance suite against the
# generated lifecycle on Postgres, and the generated agent end to end.
#
# Needs the phx_new archive (`mix archive.install hex phx_new`; set
# MIX_ARCHIVES to use one outside ~/.mix) and a Postgres the generated
# app's default config reaches (postgres:postgres@localhost).
#
#   scripts/installer-smoke.sh [workdir]   # default: a new temp directory
set -euo pipefail

clementine="$(cd "$(dirname "$0")/.." && pwd)"
work="${1:-$(mktemp -d)}"
app=clementine_smoke

git_commit() {
  git add -A
  git -c user.name=smoke -c user.email=smoke@example.com commit -qm "$1"
}

assert_unchanged() {
  if [ -n "$(git status --porcelain)" ]; then
    git status --short
    git --no-pager diff
    echo "FAIL: $1 changed the project" >&2
    exit 1
  fi
}

mkdir -p "$work"
cd "$work"
rm -rf "$app"
mix phx.new "$app" --no-assets --no-mailer --no-dashboard --no-gettext --no-install
cd "$app"

perl -0pi -e "s|(\{:bandit, \"[^\"]+\"\})|\$1,\n      {:oban, \"~> 2.19\"},\n      {:igniter, \"~> 0.8.4\", only: [:dev, :test]},\n      {:clementine, path: \"$clementine\"}|" mix.exs
grep -q ':clementine, path:' mix.exs || { echo "FAIL: could not add deps to mix.exs" >&2; exit 1; }

mix deps.get
mix oban.install --yes
# A long app name can leave phx.new output unformatted; start from formatted
# code so the check below judges only what the generators wrote.
mix format
git init -q
git_commit "Phoenix app with Oban"

mix clementine.install --yes
git_commit "clementine.install"
mix clementine.install --yes
assert_unchanged "a second clementine.install"

mix clementine.gen.agent Weather --yes
git_commit "clementine.gen.agent Weather"
mix clementine.gen.agent Weather --yes
assert_unchanged "a second clementine.gen.agent"

mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix test
MIX_ENV=test mix ecto.drop --quiet

echo "installer smoke: OK ($work/$app)"
