IMAGE ?= open-code-container
TAG ?= dev
OPENCODE_VERSION ?= 1.19.3
BASE_IMAGE ?= node:22-trixie-slim
PORT ?= 4096

.PHONY: build run shell copilot-login lint

build:
	docker build \
	  --build-arg OPENCODE_VERSION=$(OPENCODE_VERSION) \
	  --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  -t $(IMAGE):$(TAG) .

# Runs the image locally with ./.env and ./secrets mounted like the k8s Secret.
run:
	docker run --rm -it --name occ \
	  --env-file .env \
	  -v $(CURDIR)/secrets:/run/secrets/occ:ro \
	  -v occ-home:/home/opencode \
	  -p 127.0.0.1:$(PORT):4096 \
	  $(IMAGE):$(TAG)

shell:
	docker exec -it occ bash

copilot-login:
	scripts/copilot-login.sh secrets/copilot-token

lint:
	shellcheck -x -P SCRIPTDIR rootfs/opt/occ/entrypoint.sh rootfs/opt/occ/bin/* rootfs/opt/occ/git-hooks/dispatch scripts/*.sh
