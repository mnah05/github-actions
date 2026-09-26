# How It Works

End-to-end flow for this repo: push to `main` → CI checks → deploy to server over SSH → new Docker image pulled and container restarted.

## 1. Pieces

| File | Role |
|---|---|
| `main.go` | Go HTTP server on `:8080` (`/` hello, `/health` health check). |
| `Dockerfile` | Multi-stage build: `golang:1.23-alpine` compiles `/app/server`, `alpine:3.20` runs it. |
| `.github/workflows/ci.yml` | CI: runs `go test`, builds image `goapp:<sha>`, smoke-tests `/health` in a throwaway container. |
| `.github/workflows/deploy.yml` | Deploy: triggers only after CI succeeds on `main`, SSHes to server, runs `git pull` + `make deploy`. |
| `docker-compose.yml` | Server-side container definition: image `${DOCKERHUB_USERNAME}/goapp:${TAG}`, name `goapp`, port `8080`, `restart: unless-stopped`. |
| `Makefile` | Server-side commands: login → pull → (re)start → health-check → prune, with auto-rollback to the previous healthy tag. |

## 2. Flow diagram

```
git push (main)
  → CI workflow (test → build → run container → curl /health → rm container)
  → Deploy workflow [workflow_run: CI completed, success, head_branch == main]
      → appleboy/ssh-action → server:
            cd /opt/goapp && git pull && make deploy (else make rollback, exit 1)
              → docker login
              → record previous tag (from .last-working-tag, else running container)
              → docker compose pull app      (fetch <user>/goapp:<TAG>)
              → docker compose up -d         (recreate goapp on new image)
              → curl localhost:8080/health
                  success → save TAG to .last-working-tag, prune old images
                  failure → TAG=<prev> up + health (rollback), exit 1
```

## 2b. Rollback details

- Previous tag source (first non-empty wins): `.last-working-tag` file (written on every healthy deploy) → image of the currently running `goapp` container → manual `PREV_TAG=<tag>` override.
- Rollback = `docker compose up -d` with the old `TAG`, then the same `/health` poll. `prune` runs only after a successful health check, so the previous image is never deleted before a rollback might need it.
- Two layers: `make deploy` auto-rollbacks by itself; if that still fails, `deploy.yml` runs `make rollback` once more as a safety net, then exits 1 so the workflow shows failed and you get alerted.
- Manual: `make rollback` (uses recorded tag) or `make rollback PREV_TAG=<old-sha>` for a specific version.

## 3. How the workflows connect

- `deploy.yml` uses `on: workflow_run: workflows: ["CI"]`. The string must equal `name: CI` in `ci.yml` — it does.
- Guard in `deploy.yml`: `if: conclusion == 'success' && head_branch == 'main'` → deploys only green `main` builds.
- `TAG` passed to the server is `github.event.workflow_run.head_sha` (the exact commit CI tested), so the server pulls the image for that commit — not `latest`.
- Secrets used: `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`. The `envs:` key in the ssh-action forwards the last three into the remote shell, where `Makefile`/`docker-compose.yml` consume them.

## 4. What `make deploy` does on the server

| Step | Target | Command |
|---|---|---|
| 1 | `check-env` | Fails fast if `DOCKERHUB_USERNAME`/`TAG` empty; prints `Using image: <user>/goapp:<TAG>`. |
| 2 | `login` | `echo $DOCKERHUB_TOKEN \| docker login -u $DOCKERHUB_USERNAME --password-stdin` (private repo pulls need this). |
| 3 | `pull` | `docker compose pull app` — downloads the new image only, touches nothing running. |
| 4 | `up` | `docker compose up -d` — recreates `goapp` if the image changed, then lists it via `docker ps`. |
| 5 | `prune` | `docker image prune -f` — deletes dangling (untagged old) images to save disk. |
| 6 | `health` | Polls `http://localhost:8080/health` 15×2s; on success prints `App is healthy`, on failure dumps `docker logs goapp`. |

Other targets for manual use: `make pull`, `make up`, `make stop` (stop, keep container), `make start` (start stopped container), `make restart`, `make down` (stop + remove container, keep image), `make logs`, `make ps`, `make health`. `make help` lists them.

## 5. Local / manual equivalent

```bash
export DOCKERHUB_USERNAME=<you> TAG=<sha> APP_PORT=8080
make pull     # fetch image
make up       # start / recreate
make health   # check /health
make logs     # follow logs
make stop     # pause without deleting
make start    # resume
make down     # remove container
```

## 6. Known gaps (read before relying on deploy)

1. **CI never pushes to Docker Hub.** `ci.yml` builds `goapp:<sha>` on the CI runner and deletes the test container — the image is never pushed to `<user>/goapp:<sha>`. So `make deploy`'s `pull` step currently has nothing to fetch and will fail until CI gets a `docker/login-action` + `docker/build-push-action` step pushing that tag.
2. **Server path is now fixed to `/opt/goapp`.** That dir must already be a `git clone` of this repo (branch `main`), with `make`, `docker`, `docker compose`, and `curl` installed. Note `git pull` fails on a dirty tree — keep the server checkout clean.

Fix those two and the documented flow works as written.
