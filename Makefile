# Image / container settings (override via environment or CLI, e.g. `make deploy TAG=abc123`)
DOCKERHUB_USERNAME ?=
TAG ?= latest
APP_PORT ?= 8080

IMAGE := $(DOCKERHUB_USERNAME)/goapp:$(TAG)
CONTAINER := goapp
COMPOSE := docker compose
# File holding the last TAG that passed the health check (server-side state, git-ignored).
PREV_TAG_FILE := .last-working-tag
# Manual override: `make rollback PREV_TAG=<old-sha>` rolls back to a specific tag.
PREV_TAG ?=

.PHONY: help check-env login pull up down start stop restart deploy update rollback logs ps health prune

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

check-env: ## Fail fast if required env vars are missing (used by deploy/pull)
	@if [ -z "$(DOCKERHUB_USERNAME)" ]; then echo "ERROR: DOCKERHUB_USERNAME is not set (export it or pass TAG/DOCKERHUB_USERNAME from CI)"; exit 1; fi
	@if [ -z "$(TAG)" ]; then echo "ERROR: TAG is not set"; exit 1; fi
	@echo "Using image: $(IMAGE)"

login: ## Log in to Docker Hub (needs DOCKERHUB_USERNAME + DOCKERHUB_TOKEN)
	@if [ -z "$$DOCKERHUB_USERNAME" ] || [ -z "$$DOCKERHUB_TOKEN" ]; then echo "ERROR: DOCKERHUB_USERNAME and DOCKERHUB_TOKEN must be set"; exit 1; fi
	@echo "$$DOCKERHUB_TOKEN" | docker login -u "$$DOCKERHUB_USERNAME" --password-stdin

pull: check-env ## Pull the new image from Docker Hub
	$(COMPOSE) pull app

up: ## (Re)create and start containers with the current image
	$(COMPOSE) up -d
	@docker ps --filter "name=$(CONTAINER)" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

down: ## Stop and remove containers (images kept)
	$(COMPOSE) down

start: ## Start existing (stopped) containers without recreating
	$(COMPOSE) start

stop: ## Stop running containers without removing them
	$(COMPOSE) stop

restart: ## Restart running containers
	$(COMPOSE) restart
	@docker ps --filter "name=$(CONTAINER)" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

deploy: check-env ## Full deploy with auto-rollback: login -> record prev tag -> pull -> up -> health (rollback on failure) -> prune (on success only)
	@$(MAKE) --no-print-directory login
	@PREV_TAG="$$(cat $(PREV_TAG_FILE) 2>/dev/null || true)"; \
	if [ -z "$$PREV_TAG" ]; then \
	  PREV_TAG="$$(docker inspect --format '{{.Config.Image}}' $(CONTAINER) 2>/dev/null | awk -F: '{print $$NF}' || true)"; \
	fi; \
	echo "Previous working tag: $${PREV_TAG:-<none>}"; \
	$(MAKE) --no-print-directory pull up || exit 1; \
	if $(MAKE) --no-print-directory health; then \
	  echo "$(TAG)" > $(PREV_TAG_FILE); \
	  $(MAKE) --no-print-directory prune; \
	  echo "Deploy succeeded: $(IMAGE)"; \
	else \
	  echo "Deploy failed health check — rolling back..."; \
	  if [ -z "$$PREV_TAG" ]; then echo "ERROR: no previous tag recorded, cannot roll back"; exit 1; fi; \
	  TAG="$$PREV_TAG" $(MAKE) --no-print-directory rollback || exit 1; \
	  exit 1; \
	fi

rollback: ## Roll back to the previous working tag (from .last-working-tag, running container, or PREV_TAG=<tag>)
	@ROLLBACK_TAG="$(PREV_TAG)"; \
	if [ -z "$$ROLLBACK_TAG" ]; then ROLLBACK_TAG="$$(cat $(PREV_TAG_FILE) 2>/dev/null || true)"; fi; \
	if [ -z "$$ROLLBACK_TAG" ]; then ROLLBACK_TAG="$$(docker inspect --format '{{.Config.Image}}' $(CONTAINER) 2>/dev/null | awk -F: '{print $$NF}' || true)"; fi; \
	if [ -z "$$ROLLBACK_TAG" ]; then echo "ERROR: no previous tag found (no $(PREV_TAG_FILE), no running container, no PREV_TAG=<tag>)"; exit 1; fi; \
	echo "Rolling back to $(DOCKERHUB_USERNAME)/goapp:$$ROLLBACK_TAG ..."; \
	TAG="$$ROLLBACK_TAG" $(MAKE) --no-print-directory up; \
	if TAG="$$ROLLBACK_TAG" $(MAKE) --no-print-directory health; then \
	  echo "$$ROLLBACK_TAG" > $(PREV_TAG_FILE); \
	  echo "Rollback succeeded: running $$ROLLBACK_TAG"; \
	else \
	  echo "ERROR: rollback health check FAILED — manual intervention required"; exit 1; \
	fi

update: deploy ## Alias for deploy

health: ## Wait for /health to return 200 (fails after ~30s)
	@echo "Waiting for app on port $(APP_PORT)..."
	@for i in $$(seq 1 15); do \
		if curl -sf http://localhost:$(APP_PORT)/health >/dev/null; then echo "App is healthy ($(IMAGE))"; exit 0; fi; \
		echo "  attempt $$i/15: not ready yet..."; sleep 2; \
	done; \
	echo "App never became healthy"; docker logs $(CONTAINER) --tail 50; exit 1

logs: ## Tail container logs (use `make logs` or `ARGS="--tail 100" make logs`)
	docker logs -f $(CONTAINER) $(ARGS)

ps: ## Show status of the app container
	@docker ps -a --filter "name=$(CONTAINER)" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

prune: ## Remove old dangling images to free disk space
	docker image prune -f
