# tmux-chat Makefile

PROJECT_ROOT := $(shell pwd)
TMUX_CHATD_PATH := $(PROJECT_ROOT)/target/release/tmux-chatd
CLOUDFLARED_PATH := $(shell which cloudflared)
CARGO := $(HOME)/.cargo/bin/cargo
DOCKER ?= docker
LOG_DIR := $(HOME)/Library/Logs/tmux-chat
LAUNCH_AGENTS_DIR := $(HOME)/Library/LaunchAgents
PUSH_SERVER_IMAGE ?= tmux-chat-push-server:local
PUSH_SERVER_DEV_IMAGE ?= tmux-chat-push-server-dev:local
PUSH_SERVER_CONTAINER_NAME ?= tmux-chat-push-server
PUSH_SERVER_ENV_FILE ?= ops/deploy/push-server.env
# Optional: explicitly pin host data dir for push-server container.
# If empty, ops/deploy/push-server-deploy.sh resolves a safe default.
PUSH_SERVER_HOST_DATA_DIR ?=
PUSH_SERVER_HOST_PORT ?= 127.0.0.1:8790
PUSH_SERVER_CONTAINER_PORT ?= 8790

# Push-server forwarding configuration (override in config.local.mk)
PUSH_SERVER_BASE_URL ?= http://127.0.0.1:8790
PUSH_SERVER_COMPAT_NOTIFY_TOKEN ?=

# Include local config if exists
-include config.local.mk

.PHONY: all build install uninstall start stop restart reinstall logs clean fmt fmt-check install-hooks uninstall-hooks \
	push-server-docker-dev-image push-server-docker-fmt push-server-docker-test \
	push-server-docker-build push-server-docker-image push-server-docker-run \
	push-server-env-init push-server-deploy push-server-stop push-server-status push-server-logs \
	tailscale-only-init

all: build

# Build tmux-chatd
build:
	$(CARGO) build --release -p tmux-chatd

# Install launchd services
install: build
	@mkdir -p $(LOG_DIR)
	@mkdir -p $(LAUNCH_AGENTS_DIR)
	@sed -e 's|{{TMUX_CHATD_PATH}}|$(TMUX_CHATD_PATH)|g' \
	     -e 's|{{LOG_DIR}}|$(LOG_DIR)|g' \
	     -e 's|{{PUSH_SERVER_BASE_URL}}|$(PUSH_SERVER_BASE_URL)|g' \
	     -e 's|{{PUSH_SERVER_COMPAT_NOTIFY_TOKEN}}|$(PUSH_SERVER_COMPAT_NOTIFY_TOKEN)|g' \
	     launchd/com.allenneverland.tmux-chatd.plist > $(LAUNCH_AGENTS_DIR)/com.allenneverland.tmux-chatd.plist
	@sed -e 's|{{CLOUDFLARED_PATH}}|$(CLOUDFLARED_PATH)|g' \
	     -e 's|{{LOG_DIR}}|$(LOG_DIR)|g' \
	     launchd/com.allenneverland.cloudflared-tmux-chat.plist > $(LAUNCH_AGENTS_DIR)/com.allenneverland.cloudflared-tmux-chat.plist
	@echo "Installed launchd services"
	@echo "  - $(LAUNCH_AGENTS_DIR)/com.allenneverland.tmux-chatd.plist"
	@echo "  - $(LAUNCH_AGENTS_DIR)/com.allenneverland.cloudflared-tmux-chat.plist"
	@echo ""
	@echo "Run 'make start' to start services"

# Uninstall launchd services
uninstall: stop
	@rm -f $(LAUNCH_AGENTS_DIR)/com.allenneverland.tmux-chatd.plist
	@rm -f $(LAUNCH_AGENTS_DIR)/com.allenneverland.cloudflared-tmux-chat.plist
	@echo "Uninstalled launchd services"

# Start services
start:
	@launchctl load $(LAUNCH_AGENTS_DIR)/com.allenneverland.tmux-chatd.plist 2>/dev/null || true
	@launchctl load $(LAUNCH_AGENTS_DIR)/com.allenneverland.cloudflared-tmux-chat.plist 2>/dev/null || true
	@echo "Started services"

# Stop services
stop:
	@launchctl unload $(LAUNCH_AGENTS_DIR)/com.allenneverland.tmux-chatd.plist 2>/dev/null || true
	@launchctl unload $(LAUNCH_AGENTS_DIR)/com.allenneverland.cloudflared-tmux-chat.plist 2>/dev/null || true
	@echo "Stopped services"

# Restart services
restart: stop start

reinstall: stop install start

# View logs
logs:
	@echo "=== tmux-chatd logs ==="
	@tail -50 $(LOG_DIR)/tmux-chatd.log 2>/dev/null || echo "No logs yet"
	@echo ""
	@echo "=== tmux-chatd error logs ==="
	@tail -20 $(LOG_DIR)/tmux-chatd.error.log 2>/dev/null || echo "No error logs"
	@echo ""
	@echo "=== cloudflared logs ==="
	@tail -50 $(LOG_DIR)/cloudflared-tmux-chat.log 2>/dev/null || echo "No logs yet"

# Follow logs in real-time
logs-follow:
	@tail -f $(LOG_DIR)/tmux-chatd.log $(LOG_DIR)/cloudflared-tmux-chat.log

# Check service status
status:
	@echo "=== Service Status ==="
	@launchctl list | grep -E "allenneverland\.(tmux-chatd|cloudflared)" || echo "No services running"
	@echo ""
	@echo "=== Process Check ==="
	@ps aux | grep -E "(tmux-chatd|cloudflared.*tmux-chat)" | grep -v grep || echo "No processes found"

# Install coding agent hooks (Claude Code + Codex)
install-hooks:
	@tmux-chatd hooks install

# Uninstall coding agent hooks (Claude Code + Codex)
uninstall-hooks:
	@tmux-chatd hooks uninstall

# Clean build artifacts
clean:
	$(CARGO) clean

# Format all Rust code in the workspace
fmt:
	$(CARGO) fmt --all

# Check Rust formatting without writing changes
fmt-check:
	$(CARGO) fmt --all -- --check

# Build push-server development image (for fmt/test/build inside Docker)
push-server-docker-dev-image:
	$(DOCKER) build -f push-server/Dockerfile --target dev -t $(PUSH_SERVER_DEV_IMAGE) .

# Run push-server formatting check in Docker
push-server-docker-fmt: push-server-docker-dev-image
	$(DOCKER) run --rm -v "$(PROJECT_ROOT):/workspace" -w /workspace $(PUSH_SERVER_DEV_IMAGE) \
		cargo fmt -p push-server -- --check

# Run push-server tests in Docker
push-server-docker-test: push-server-docker-dev-image
	$(DOCKER) run --rm -v "$(PROJECT_ROOT):/workspace" -w /workspace $(PUSH_SERVER_DEV_IMAGE) \
		cargo test -p push-server

# Build push-server binary in Docker
push-server-docker-build: push-server-docker-dev-image
	$(DOCKER) run --rm -v "$(PROJECT_ROOT):/workspace" -w /workspace $(PUSH_SERVER_DEV_IMAGE) \
		cargo build --release -p push-server

# Build push-server runtime image
push-server-docker-image:
	$(DOCKER) build -f push-server/Dockerfile --target runtime -t $(PUSH_SERVER_IMAGE) .

# Run push-server runtime container
push-server-docker-run: push-server-docker-image
	$(DOCKER) run --rm -p 127.0.0.1:8790:8790 $(PUSH_SERVER_IMAGE)

# Initialize local push-server env file from sample (contains APNs placeholders).
push-server-env-init:
	@test -f "$(PUSH_SERVER_ENV_FILE)" || cp ops/deploy/push-server.env.sample "$(PUSH_SERVER_ENV_FILE)"
	@echo "Env file ready: $(PUSH_SERVER_ENV_FILE)"
	@echo "Fill in APNs values before first deploy."

# One-click push-server deployment (Docker + env-file; no secrets in command line).
push-server-deploy:
	@DOCKER="$(DOCKER)" \
		PUSH_SERVER_ENV_FILE="$(PUSH_SERVER_ENV_FILE)" \
		PUSH_SERVER_IMAGE="$(PUSH_SERVER_IMAGE)" \
		PUSH_SERVER_CONTAINER_NAME="$(PUSH_SERVER_CONTAINER_NAME)" \
		PUSH_SERVER_HOST_DATA_DIR="$(PUSH_SERVER_HOST_DATA_DIR)" \
		PUSH_SERVER_HOST_PORT="$(PUSH_SERVER_HOST_PORT)" \
		PUSH_SERVER_CONTAINER_PORT="$(PUSH_SERVER_CONTAINER_PORT)" \
		ops/deploy/push-server-deploy.sh

# Stop/remove deployed push-server container.
push-server-stop:
	@$(DOCKER) rm -f "$(PUSH_SERVER_CONTAINER_NAME)" >/dev/null 2>&1 || true
	@echo "Stopped $(PUSH_SERVER_CONTAINER_NAME)"

# Show push-server container status.
push-server-status:
	@$(DOCKER) ps -a --filter "name=^/$(PUSH_SERVER_CONTAINER_NAME)$$"

# Follow push-server logs.
push-server-logs:
	@$(DOCKER) logs -f "$(PUSH_SERVER_CONTAINER_NAME)"

# One-click Tailscale-only initialization for local config files.
tailscale-only-init:
	@PUSH_SERVER_ENV_FILE="$(PUSH_SERVER_ENV_FILE)" \
		ops/deploy/tailscale-only-init.sh
