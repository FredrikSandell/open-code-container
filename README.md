# open-code-container

A Docker image that runs [opencode](https://opencode.ai) as a standalone
service. It uses a GitHub Copilot subscription for models and works against a
GitHub Enterprise Server (GHES) instance through two GitHub Apps: one for
reading, one for writing.

- **Interfaces:** opencode's stock web UI, plus its HTTP API for
  `opencode attach` / `opencode run --attach` from any machine.
- **Access control:** opencode's built-in HTTP basic auth. Terminate TLS in
  front of it (Kubernetes ingress).
- **Models:** GitHub Copilot via a pre-obtained OAuth token injected at start.
- **GHES:** git and `gh` get short-lived GitHub App installation tokens on
  demand. Fetches use the read app and pushes use the write app. Pushes are
  limited to `agent/*` branches.

```
 browser ──┐                       ┌──────────── container ─────────────┐
           ├─ TLS ─ ingress ─ :4096│ opencode web (basic auth)          │── api.githubcopilot.com
 opencode ─┘                       │   └ agent tools: git, gh           │
   attach                          │       └ git-credential-ghapp ──┐   │
                                   │       └ gh wrapper ────────────┤   │
                                   │         ghapp-token (JWT → installation token)
                                   └────────────────────────────────┴───┘── GHES (git + REST/GraphQL)
```

## 1. Prerequisites

### GitHub Apps on GHES

Create two apps on the GHES instance (Settings → Developer settings → GitHub
Apps) and install both on every org/user whose repos the agent should reach.
The container finds the installation per repo owner, so no installation IDs
need configuring.

| App   | Repository permissions (suggested)                                                 |
| ----- | ---------------------------------------------------------------------------------- |
| read  | Contents: read, Metadata: read, Pull requests: read, Issues: read, Checks: read, Actions: read |
| write | Contents: write, Metadata: read, Pull requests: write, Issues: write              |

Generate a private key for each app and note the App IDs. Webhooks can be
disabled.

**Protect branches on the server.** The in-container push guard is a
guardrail, not a security boundary. Add a GHES ruleset (org- or repo-level)
that allows the write app to update only `refs/heads/agent/**`, and do not
add the app as a bypass actor.

### Copilot token

opencode authenticates to Copilot with a GitHub OAuth token obtained through a
device flow. Get one on any machine with a browser:

```sh
make copilot-login        # writes secrets/copilot-token
```

This runs the same device flow as opencode's `/connect` command, against
github.com, using opencode's OAuth client ID. Alternatively, run `opencode`
locally, `/connect` → GitHub Copilot, and copy `."github-copilot".refresh` from
`~/.local/share/opencode/auth.json`. The token is long-lived; revoke it under
github.com → Settings → Applications.

## 2. Configuration

Secrets are read from files in `/run/secrets/occ/` (one Kubernetes Secret
mounted there). Each one can instead be passed as an env var, or as a
`<VAR>_FILE` env var pointing at a file.

| File in `/run/secrets/occ/` | Env alternative            | Purpose                                 |
| --------------------------- | -------------------------- | --------------------------------------- |
| `server-password`           | `OPENCODE_SERVER_PASSWORD` | Basic auth password (required)          |
| `copilot-token`             | `COPILOT_TOKEN`            | Copilot OAuth token                     |
| `ghapp-read.pem`            | `GHAPP_READ_KEY_FILE`      | Read app private key (path)             |
| `ghapp-write.pem`           | `GHAPP_WRITE_KEY_FILE`     | Write app private key (path)            |
| `ca.crt` (optional)         | `EXTRA_CA_CERTS_FILE`      | Private CA for GHES (PEM, may hold several certs) |

| Env var                    | Default                     | Purpose                                                        |
| -------------------------- | --------------------------- | -------------------------------------------------------------- |
| `GHES_HOST`                | —                           | GHES hostname; enables the git/gh integration                  |
| `GHES_API_URL`             | `https://$GHES_HOST/api/v3` | REST API base                                                  |
| `GHAPP_READ_ID`            | —                           | Read app ID                                                    |
| `GHAPP_WRITE_ID`           | —                           | Write app ID                                                   |
| `AGENT_BRANCH_PREFIX`      | `agent/`                    | Branches the container may push; empty disables the guard      |
| `GHAPP_DEFAULT_OWNER`      | —                           | Owner for `gh` when it can't infer one                         |
| `OPENCODE_SERVER_USERNAME` | `opencode`                  | Basic auth username                                            |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | write app's bot user | Commit identity                                               |
| `OCC_PORT`                 | `4096`                      | Listen port                                                    |
| `OCC_OPENCODE_ARGS`        | —                           | Extra args for `opencode web`                                  |
| `OPENCODE_CONFIG_CONTENT`  | —                           | Extra opencode config JSON, merged over the image's defaults (e.g. `{"model":"github-copilot/gpt-5.4"}`) |
| `OPENCODE_DISABLE_MODELS_FETCH` | —                      | Set to `1` if `models.opencode.ai` is unreachable; opencode then uses its bundled model catalog |

## 3. Build and run locally

```sh
make build                      # OPENCODE_VERSION=1.19.3 by default
cp .env.example .env            # fill in GHES_HOST and app IDs
mkdir -p secrets && chmod 700 secrets
openssl rand -base64 24 | tr -d '\n' > secrets/server-password
cp ~/Downloads/read-app.*.pem  secrets/ghapp-read.pem
cp ~/Downloads/write-app.*.pem secrets/ghapp-write.pem
make copilot-login
chmod 644 secrets/*             # the container runs as uid 10001
make run                        # http://127.0.0.1:4096, user "opencode"
```

## 4. Deploy to Kubernetes

`k8s/` holds a kustomization: PVC, ConfigMap, Deployment, Service and an
nginx Ingress example. Edit the ConfigMap values, image name and ingress host,
then:

```sh
kubectl create namespace opencode
kubectl -n opencode create secret generic opencode-secrets \
  --from-file=server-password=secrets/server-password \
  --from-file=copilot-token=secrets/copilot-token \
  --from-file=ghapp-read.pem=secrets/ghapp-read.pem \
  --from-file=ghapp-write.pem=secrets/ghapp-write.pem
  # add --from-file=ca.crt=secrets/ca.crt for a private GHES CA
kubectl apply -k k8s/
```

Notes:

- **Single replica with `Recreate`.** opencode keeps sessions in SQLite on
  the PVC, so the pod must not run twice.
- **Read-only root filesystem.** The pod runs as uid 10001 with a read-only
  root. `/home/opencode` (PVC) holds the opencode DB, config and
  `~/workspace`; `/tmp` is an emptyDir.
- **Probes.** The health endpoint needs basic auth, so readiness runs
  `/opt/occ/bin/occ-healthcheck` and liveness uses a TCP check.
- **Egress** the pod needs:
  - the GHES host;
  - `api.githubcopilot.com`;
  - optionally `models.opencode.ai`, for model catalog refresh;
  - the npm registry, if you add opencode plugins.

  Standard `HTTPS_PROXY`/`NO_PROXY` env vars are honoured.

## 5. Connect

- **Web UI:** `https://opencode.example.com`, log in with `opencode` /
  `<server-password>`. Repos live under `~/workspace`; ask the agent to clone
  `https://<GHES_HOST>/<owner>/<repo>.git`.
- **TUI from your machine:**
  `opencode attach https://opencode.example.com -u opencode -p "$PW"`.
- **One-shot:**
  `opencode run --attach https://opencode.example.com -p "$PW" --dir /home/opencode/workspace/<repo> "…"`.

Web and attached terminals share the same sessions.

## How the GHES credentials work

- `ghapp-token <read|write> <owner>` signs an app JWT with the private key,
  looks up the app's installation for that owner and mints an installation
  token (valid 1 h). Tokens are cached in `/tmp/occ/tokens` until five
  minutes before they expire.
- **git:** `git-credential-ghapp` is the credential helper for
  `https://$GHES_HOST`. git doesn't tell helpers which operation they serve,
  so the helper checks whether it runs under a `git push`. If so it uses the
  write app; otherwise (clone/fetch/pull) the read app. `git@host:` and
  `ssh://` URLs are rewritten to HTTPS.
- **gh:** `/opt/occ/bin/gh` wraps the real CLI. Read-only commands (`view`,
  `list`, `diff`, `checks`, GET or GraphQL-query `gh api`) use the read app;
  everything else uses the write app. The owner comes from `-R`, `GH_REPO`,
  the API path, the `origin` remote, or `GHAPP_DEFAULT_OWNER`. Override the
  choice with `GHAPP_ROLE=read|write`.
- **Push guard:** `core.hooksPath` is forced to `/opt/occ/git-hooks` through
  `GIT_CONFIG_*` env vars, which outrank repo config. The dispatcher there
  runs the branch guard on `pre-push`, then the repository's own hooks
  (`core.hooksPath` such as husky, or `.git/hooks`), so those keep working.
- **Commit identity:** at startup the write app's slug and bot user are
  looked up, and commits are authored as `<slug>[bot]`.
- **Agent guidance:** opencode loads `/etc/opencode/AGENTS.md`, which tells
  the agent the conventions above. `/etc/opencode/opencode.json` disables
  autoupdate and sharing, and denies obvious guard bypasses (`--no-verify`,
  changing `core.hooksPath`).

## Security model

- Everything the agent can do, it does as uid 10001. That includes reading
  the mounted private keys and the server password. Within the container
  this is a single trust domain. The hard limits are the apps' permissions,
  their installation scope, and GHES rulesets.
- If leaked app private keys are a concern, a follow-up option is a small
  token broker running as a separate user. It would hold the keys and hand
  out only 1-hour tokens.
- Basic auth goes over the ingress's TLS. Use a long random password.

## Upgrading opencode

Bump `OPENCODE_VERSION` (Makefile / build arg) and rebuild. The entrypoint
writes the Copilot credential into opencode's `auth.json`, which is where
1.19.x keeps credentials. opencode's development branch moves credentials
into its SQLite DB and imports `auth.json` only once. After such an upgrade,
check that rotating `copilot-token` still takes effect.
