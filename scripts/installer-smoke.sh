#!/usr/bin/env bash
# Proves `mix clementine.install` and `mix clementine.gen.agent` against a
# real, freshly generated Phoenix app: install, install again (no change),
# generate an agent, generate it again (no change), then the app's own
# gates. The generated test runs the agent end to end through Clementine's
# runtime on Postgres, so it proves the glue: the child spec, the
# migration, the test config, and the test case. The generated code must
# also pass `credo --strict`.
#
# Then it adds the chat example in scripts/installer-smoke/chat, the way
# an app would write it by hand: a conversation table of its own, a chat
# agent whose history/1 reads it, and a host module that stores each turn
# in run_finished/2 and streams runs through run_event/2,
# run_transition/2, and run_committed/2. Its test holds a two-turn
# conversation through the runtime.
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

perl -0pi -e "s|(\{:bandit, \"[^\"]+\"\})|\$1,\n      {:oban, \"~> 2.19\"},\n      {:igniter, \"~> 0.8.4\", only: [:dev, :test]},\n      {:credo, \"~> 1.7\", only: [:dev, :test], runtime: false},\n      {:clementine, path: \"$clementine\"}|" mix.exs
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

cp -R "$clementine/scripts/installer-smoke/chat/." .
perl -0pi -e 's/agents: \[ClementineSmoke\.Agents\.Weather\]/agents: [ClementineSmoke.Agents.Weather, ClementineSmoke.Agents.Chat],\n     host: ClementineSmoke.Agents.Host/' "lib/$app/application.ex"
grep -q 'host: ClementineSmoke.Agents.Host' "lib/$app/application.ex" ||
  { echo "FAIL: could not add the chat agent and host to the child spec" >&2; exit 1; }
mix format "lib/$app/application.ex"
git_commit "Chat example"

mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
# What the generators wrote must pass credo's default checks at --strict
# (nesting depth, logger metadata keys, alias order and usage, and the
# rest), and so must the chat example. Phoenix's own files are not ours
# to judge, so filter to ours.
generated="lib/$app/agents|lib/$app/conversations|test/$app/agents|test/support/agents_case.ex"
issues="$({ mix credo --strict --format oneline || true; } | grep -E "$generated" || true)"
if [ -n "$issues" ]; then
  echo "$issues"
  echo "FAIL: credo --strict flags generated code" >&2
  exit 1
fi
# A test database left by an earlier run would hold tables from migrations
# with other timestamps.
MIX_ENV=test mix ecto.drop --quiet
mix test
MIX_ENV=test mix ecto.drop --quiet

echo "installer smoke: OK ($work/$app)"
