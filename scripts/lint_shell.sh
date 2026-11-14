#!/bin/sh
# Static analysis of all shell scripts in the project.
#
# Single file for two contexts: local check and scripts-lint job in GitLab.
#
# The project is driven by scripts: they verify, build and deploy it.
# An error in a script looks like an error in the project, so analysis is required.
#
# Warning level is chosen deliberately: with -o all shellcheck requires braces
# around every variable, drowning useful findings in style noise.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# .claude/hooks is not in the public slice: shellcheck would fail on the unexpanded glob.
# In the repository (plan/ is there) the hooks are always checked, so losing them is an error.
set -- scripts/*.sh
if [ -d plan ] || ls .claude/hooks/*.sh >/dev/null 2>&1; then set -- "$@" .claude/hooks/*.sh; fi
shellcheck --severity=warning "$@"
echo "shell lint passed"
