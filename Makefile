# Bedrock — an S3-compatible object store with least-privilege access.
#
# Everything runs in Docker. The only host requirements are Docker Desktop
# (with the Compose plugin) and uv, which runs the one credential helper.
#
#   make help        list targets
#   make secrets     fill .env with strong random credentials
#   make up          start the store
#   make bootstrap   create buckets, policies and keys (idempotent)
#   make test        prove least privilege holds
#   make down        stop the store (data is kept)
#
# Two files are yours and gitignored; the repository carries an example of
# each: .env (from .env.example) and bootstrap/buckets.conf (from
# bootstrap/buckets.conf.example). Both are created on first use.

SHELL := /bin/bash
COMPOSE := docker compose
UV := uv

.DEFAULT_GOAL := help
.PHONY: help secrets up down destroy rebuild bootstrap test logs status console ps lint

help: ## Show this help
	@printf '\nBedrock targets:\n\n'
	@grep -hE '^[a-zA-Z_ -]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

.env:
	@printf 'No .env found. Creating one from .env.example ...\n'
	@cp .env.example .env
	@printf 'Now run: make secrets\n'
	@exit 1

# The bucket declaration is deployment state, like .env: the store you run is
# yours, the store the repository describes is an example. So buckets.conf is
# gitignored and buckets.conf.example is committed. Unlike .env, the example is
# a complete, working declaration, so a missing file is copied into place and
# the target carries on rather than stopping to ask for edits.
BUCKETS_CONF := bootstrap/buckets.conf

$(BUCKETS_CONF):
	@printf 'No %s found. Creating one from %s.example ...\n' '$(BUCKETS_CONF)' '$(BUCKETS_CONF)'
	@cp $(BUCKETS_CONF).example $(BUCKETS_CONF)

secrets: $(BUCKETS_CONF) ## Fill .env with strong random credentials (never overwrites real ones)
	@test -f .env || cp .env.example .env
	@$(UV) run python scripts/generate_secrets.py .env

up: .env ## Start the object store
	@$(COMPOSE) up -d rustfs
	@printf '\nWaiting for the store to report healthy ...\n'
	@for i in $$(seq 1 40); do \
		status=$$(docker inspect -f '{{.State.Health.Status}}' bedrock-rustfs 2>/dev/null || echo starting); \
		if [ "$$status" = "healthy" ]; then printf 'healthy.\n'; break; fi; \
		sleep 2; \
	done
	@$(COMPOSE) ps

bootstrap: .env $(BUCKETS_CONF) ## Create buckets, policies and keys (safe to re-run)
	@$(COMPOSE) run --rm bootstrap

test: .env $(BUCKETS_CONF) ## Assert the access policies deny what they must
	@$(COMPOSE) run --rm smoke

down: .env ## Stop the store; the data volume is kept
	@$(COMPOSE) --profile bootstrap --profile test down

destroy: .env ## Stop the store AND DELETE ALL DATA. Asks first.
	@printf '\033[31mThis deletes the bedrock-rustfs-data volume and everything in it.\033[0m\n'
	@read -r -p 'Type the word DESTROY to confirm: ' reply; \
	if [ "$$reply" = "DESTROY" ]; then \
		$(COMPOSE) --profile bootstrap --profile test down --volumes; \
		printf 'Gone.\n'; \
	else \
		printf 'Aborted; nothing was deleted.\n'; \
	fi

# Recreates the containers, not the data: `down` without --volumes keeps
# bedrock-rustfs-data. Use `make destroy` to throw the data away as well.
rebuild: .env $(BUCKETS_CONF) ## Pull the pinned images, recreate the containers, bootstrap and verify
	@$(COMPOSE) --profile bootstrap --profile test pull
	@$(COMPOSE) --profile bootstrap --profile test down
	@$(MAKE) --no-print-directory up
	@$(MAKE) --no-print-directory bootstrap
	@$(MAKE) --no-print-directory test

logs: .env ## Follow the store's logs
	@$(COMPOSE) logs -f rustfs

ps status: .env ## Show what is running
	@$(COMPOSE) ps

console: .env ## Print the console URL
	@set -a; . ./.env; set +a; \
	printf 'Console: http://%s:%s\n' "$${RUSTFS_BIND_ADDRESS:-127.0.0.1}" "$${RUSTFS_CONSOLE_PORT:-9001}"

lint: ## Lint the credential helper and the shell scripts
	@$(UV) run ruff check scripts
	@$(UV) run ruff format --check scripts
	@bash -n bootstrap/bootstrap.sh
	@bash -n tests/smoke.sh
