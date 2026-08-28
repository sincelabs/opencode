# Self-hosting opencode on Coolify

This deploys your fork of opencode as a **website**: one container, one domain,
the full opencode web UI behind a login, with your projects living on a
persistent volume on your own server.

---

## Read this first

`opencode serve` exposes an agent that runs arbitrary shell commands, reads and
writes files, and installs packages — as root, inside the container, with no
sandbox. Putting it on a public domain means **anyone who gets past the login
gets a shell on that container**, plus whatever your provider API keys can spend.

The only authentication opencode itself ships is HTTP basic auth, enabled by
setting `OPENCODE_SERVER_PASSWORD`. If that variable is empty the server starts
completely open and only prints a warning to its logs.

So: set a strong password, and read [Hardening](#7-hardening) before you put
anything sensitive in the workspace.

---

## What actually gets deployed

A single compiled binary serving both the API and the UI on port 4096.

| Piece | Where it comes from |
| --- | --- |
| HTTP API + web UI | `opencode serve` — the UI is mounted at `/*`, the API under `/global`, `/project`, etc. |
| The UI itself | `packages/app`, compiled by `packages/opencode/script/build.ts` and embedded into the binary |
| Login | HTTP basic auth, `OPENCODE_SERVER_PASSWORD` / `OPENCODE_SERVER_USERNAME` |
| Sessions, auth, logs | `/data` (XDG dirs, see `packages/core/src/global.ts`) |
| Your code | `/workspace` |

One detail worth knowing: the web UI is embedded into the binary **only** by
`script/build.ts`. If you run the CLI straight from source, the server can't
find the embedded bundle and silently falls back to proxying
`https://app.opencode.ai` instead. The Dockerfile here compiles a real binary,
so your deployment serves your fork's UI and never phones home for it.

---

## 1. Fork and push

```bash
# Fork anomalyco/opencode on GitHub, then:
git clone https://github.com/<you>/opencode.git
cd opencode
git remote add upstream https://github.com/anomalyco/opencode.git
```

Make sure these files are on the branch you intend to deploy:

- `deploy/coolify/Dockerfile` — the build
- `deploy/coolify/docker-entrypoint.sh` — starts the server, or forwards to the CLI
- `docker-compose.coolify.yaml` — optional, for the Compose build pack
- `deploy/coolify/.env.example` — the variables you'll paste into Coolify

Deploy from a branch you control (e.g. `main` on your fork), not from
`dev` — you want to choose when a rebuild happens.

---

## 2. Connect Coolify to your fork with a GitHub App

In Coolify:

1. **Sources → + Add → GitHub App**
2. Name it (`github-<you>`), leave the defaults, and pick
   **Register a new GitHub App**. Choose your personal account or the org that
   owns the fork.
3. Coolify sends you to GitHub to create the app. Accept, then **Install** it.
4. On the install screen choose **Only select repositories** and pick your
   `opencode` fork. Don't grant all repositories.
5. Back in Coolify the source should show as connected.

The GitHub App is what gives you private-repo cloning and automatic redeploys on
push, without putting a personal access token on the server.

---

## 3. Create the application

**Projects → your project → + New → Application → Private Repository (with
GitHub App)**, then pick your source, the `opencode` fork, and your branch.

Then choose one of the two build packs:

### Option A — Dockerfile build pack (recommended)

Simplest. Coolify handles the domain, TLS and volumes from its own UI.

| Setting | Value |
| --- | --- |
| Build Pack | `Dockerfile` |
| Base Directory | `/` |
| Dockerfile Location | `/deploy/coolify/Dockerfile` |
| Ports Exposes | `4096` |

Keep those two fields straight: **Base Directory** stays `/` because it is the
build context, and the Dockerfile needs the repo root to `COPY . .` from. Putting
the Dockerfile path there instead fails the deploy before the build starts, with
`mkdir: can't create directory '.../deploy/coolify/Dockerfile': File exists`.

### Option B — Docker Compose build pack

Keeps volumes and the healthcheck declared in the repo.

| Setting | Value |
| --- | --- |
| Build Pack | `Docker Compose` |
| Base Directory | `/` |
| Docker Compose Location | `/docker-compose.coolify.yaml` |

With Option B, Coolify creates the volumes and reads
`SERVICE_FQDN_OPENCODE_4096` to wire up your domain automatically.

> **Build resources.** This compiles the whole toolchain — TypeScript, the Solid
> web app, then a Bun single-file binary. Budget **~4 GB of free RAM and ~10 GB
> of disk** on the build machine and 10–25 minutes for a cold build. On a small
> VPS, either add swap or point Coolify at a dedicated build server
> (**Servers → Build Server**).

---

## 4. Environment variables

**Configuration → Environment Variables.** Copy from
`deploy/coolify/.env.example`. All of these are *runtime* variables — leave
"Is Build Variable?" off, so your keys never get baked into an image layer.

| Variable | Required | Notes |
| --- | --- | --- |
| `OPENCODE_SERVER_PASSWORD` | **yes** | `openssl rand -base64 24`. Empty = no auth at all. |
| `OPENCODE_SERVER_USERNAME` | no | Defaults to `opencode`. |
| `ANTHROPIC_API_KEY` (or `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, …) | one, unless using a custom provider | Any env name models.dev lists for that provider is picked up automatically. |
| `OPENCODE_CONFIG_CONTENT` | for a custom provider | A whole `opencode.json` as a string. See [Using your own OpenAI-compatible provider](#using-your-own-openai-compatible-provider). |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | recommended | Identity for commits the agent makes. |
| `OPENCODE_CORS_ORIGIN` | no | Only if you call the API from a *different* domain. Same-origin is already allowed. |

You do **not** need to configure CORS for normal use: the server allows any
request whose `Origin` matches the `Host` it was served on, and Coolify's proxy
passes the real host through.

---

### Using your own OpenAI-compatible provider

If your models come from your own gateway rather than a public provider, declare
it in config instead of setting a vendor API key. `@ai-sdk/openai-compatible` is
statically imported by opencode's provider plugin, so it is already compiled into
the binary — nothing is fetched from npm at runtime, and this works on a server
with no outbound access to a package registry.

Put the whole config in `OPENCODE_CONFIG_CONTENT` as a single-line string, and
keep the key itself in a separate variable so the config stays readable and the
secret stays a secret:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "mycorp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "MyCorp Gateway",
      "options": {
        "baseURL": "https://llm.internal.example.com/v1",
        "apiKey": "{env:MYCORP_API_KEY}"
      },
      "models": {
        "mycorp-large": {
          "name": "MyCorp Large",
          "tool_call": true,
          "limit": { "context": 128000, "output": 8192 }
        }
      }
    }
  },
  "model": "mycorp/mycorp-large"
}
```

Then set two Coolify variables: `OPENCODE_CONFIG_CONTENT` to that JSON, and
`MYCORP_API_KEY` to the key. `{env:...}` is resolved by opencode when it reads
the config, so the key never appears in the config value itself.

What each part does:

| Field | Meaning |
| --- | --- |
| `npm` | The AI SDK package. `@ai-sdk/openai-compatible` for any OpenAI-shaped API. |
| `options.baseURL` | Your endpoint, including the version prefix. opencode appends `/chat/completions`. |
| `options.apiKey` | Sent as `Authorization: Bearer <key>`. |
| `models` | Your model IDs. The key is what gets sent as `model` in the request body. |
| `model` | The default `provider/model` for new sessions. |

`tool_call: true` matters — opencode is an agent, and a model advertised without
tool support won't be offered for agentic work. Set `limit.context` and
`limit.output` to your gateway's real numbers so context management behaves.

To sanity-check it before wiring up the domain:

```bash
docker exec -it <container> opencode models | grep mycorp
```

The provider also has to appear in the server's own view, which is what the web
UI reads:

```bash
curl -u opencode:$OPENCODE_SERVER_PASSWORD https://opencode.example.com/provider
```

---

## 5. Persistent storage

Without this, every redeploy wipes your sessions, your provider logins and your
code. **Storages → + Add** two volume mounts:

| Name | Mount path | What's in it |
| --- | --- | --- |
| `opencode-data` | `/data` | provider credentials, session database, logs, model cache |
| `opencode-workspace` | `/workspace` | the repositories you work on |

(With the Compose build pack these already exist — skip this step.)

---

## 6. Domain, TLS and deploy

1. Point a DNS `A` record at your Coolify server, e.g.
   `opencode.example.com`.
2. In the application, set **Domains** to `https://opencode.example.com`.
   Coolify's Traefik will request the certificate. WebSockets — which the UI
   uses for live session updates — are proxied without extra configuration.
3. Hit **Deploy** and watch the build logs.
4. When the container is healthy, open the domain **with the credentials in the
   URL** the first time:

   ```bash
   # prints the URL to open
   echo "https://opencode.example.com/?auth_token=$(printf 'opencode:YOUR_PASSWORD' | base64 -w0)"
   ```

   The browser's own basic-auth prompt is enough for ordinary API calls, but the
   UI also needs the credentials *in JavaScript* to open the terminal
   WebSocket — a browser can't attach basic auth to a `new WebSocket()`. Loading
   the page once with `?auth_token=` hands them over; the app then strips the
   parameter from the address bar and remembers the connection. You can also
   enter them later under the server/connection settings dialog in the UI.

The healthcheck polls `/site.webmanifest`, which is one of the few paths that
deliberately bypasses auth — so a healthy container is a real signal even with
the password set.

---

### Running one-off CLI commands

The entrypoint forwards any arguments to the CLI, so the same image doubles as
the CLI on that server:

```bash
docker exec -it <container> opencode --version
docker exec -it <container> opencode run "summarize the failing test"
```

---

## 7. Hardening

Basic auth on a public domain is the floor, not the ceiling. Pick at least one:

- **Restrict by network.** Don't give it a public domain at all — put the server
  on Tailscale or WireGuard and reach it over the private address. This is the
  safest option and costs you nothing.
- **Restrict by IP.** Add a Traefik middleware in the application's
  **Advanced → Custom Labels** limiting source IPs to your office/home.
- **Put an identity proxy in front.** Authelia, Authentik, Pocket ID or
  Cloudflare Access, deployed alongside in Coolify, gives you real SSO and MFA
  instead of a shared password.
- **Scope the API keys.** Use a provider key with a spend limit, dedicated to
  this server, so a compromise is bounded and revocable.
- **Don't mount the Docker socket** into this container, and don't run it with
  `privileged`. The agent is already root inside the container; don't hand it
  the host.
- **Back up the `/data` volume.** Coolify's scheduled backups work on it.

---

## 8. Keeping your fork current

```bash
git fetch upstream
git rebase upstream/dev          # or merge, if you prefer
git push origin main
```

Coolify redeploys on push if you left automatic deployments on. Because the
image compiles from source, a rebuild is the only thing needed to pick up
upstream changes — there is no separate binary to update, and
`OPENCODE_DISABLE_AUTOUPDATE=1` in the image keeps the server from trying to
update itself underneath you.

---

## 9. Troubleshooting

**The UI loads but looks like the hosted app / your fork's UI changes don't show.**
The embedded bundle wasn't found and the server fell back to proxying
`app.opencode.ai`. Check the build logs for `Building Web UI to embed in the
binary` — if that line is missing, the build didn't run `script/build.ts`.

**Build fails in `bun install` on a native module.**
Usually node-gyp, and usually the Node major. node-gyp 13 needs Node >= 22 — on
Node 20 it dies with `webidl.util.markAsUncloneable is not a function`. Debian
ships Node 20 and apt will happily install it, so the build stage pulls a pinned
Node 24 tarball from nodejs.org rather than trusting a repository. If you changed
that step, or dropped `build-essential` / `python3-setuptools`, put them back.

**Build gets OOM-killed.**
Add swap on the build machine or use a dedicated Coolify build server. 2 GB is
not enough.

**Browser asks for the password over and over.**
`OPENCODE_SERVER_USERNAME` defaults to `opencode`, not your email or `admin`.

**The terminal panel won't connect, everything else works.**
The UI doesn't have the credentials in JavaScript. Reload once with
`?auth_token=$(printf 'opencode:YOUR_PASSWORD' | base64 -w0)`, or set the
username/password in the UI's server connection dialog.

**Deploy fails at `mkdir`: `can't create directory '.../deploy/coolify/Dockerfile': File exists`.**
The Dockerfile path was put in **Base Directory** instead of **Dockerfile
Location**. Coolify `mkdir -p`s the base directory before building, so it tries
to create your Dockerfile as a folder and collides with the file the clone just
wrote. Base Directory is the build *context* and must be `/` — the Dockerfile
does `COPY . .` from the repo root — while the path to the file itself goes in
Dockerfile Location.

**The UI loads and the model picker is empty.**
No provider is configured. Set a vendor key (`ANTHROPIC_API_KEY` and friends) or
`OPENCODE_CONFIG_CONTENT` for your own gateway. The server starts and serves the
UI happily with no provider at all — it just has no models to offer, so nothing
agentic works until you add one.

**Container is healthy but the domain 502s.**
Coolify needs to know the port. Set **Ports Exposes** to `4096`
(Dockerfile build pack) or make sure `SERVICE_FQDN_OPENCODE_4096` is present in
the Compose environment.

**Everything disappeared after a redeploy.**
The `/data` volume isn't mounted. See step 5.
