# Container environment

You are running inside a container connected to a GitHub Enterprise Server
instance whose hostname is in `$GHES_HOST`. Credentials are handled for you;
never ask for, print, or store tokens.

## Git

- Clone with `git clone https://$GHES_HOST/<owner>/<repo>.git` into
  `~/workspace`. SSH-style URLs are rewritten to HTTPS automatically.
- Fetches use a read-only GitHub App; pushes use a separate write App. Both are
  picked automatically by the git credential helper.
- You may only push branches whose name starts with `$AGENT_BRANCH_PREFIX`
  (default `agent/`). Create a branch such as `agent/<short-topic>` before
  committing, and never push to the default branch. Pushes elsewhere are
  rejected by a pre-push hook and by server-side rules.
- Do not bypass hooks (`--no-verify`) or change `core.hooksPath`.

## gh

`gh` is preconfigured for `$GHES_HOST`. Read commands (`view`, `list`, `diff`,
`checks`, GET `gh api` calls) use the read App; anything that changes state
(`pr create`, `pr comment`, `issue create`, ...) uses the write App. Run it
inside a cloned repository or pass `-R <owner>/<repo>`.

Typical flow for a change: clone, `git switch -c agent/<topic>`, commit,
`git push -u origin HEAD`, then `gh pr create --fill` (or with an explicit
title and body).
