SHELL=/bin/bash -o pipefail

REGISTRY ?= kubedb
BIN      := mysql
IMAGE    := $(REGISTRY)/$(BIN)
PATCH	 := 8.0.14
TAG      := $(shell git describe --exact-match --abbrev=0 2>/dev/null || echo "")

.PHONY: push
push: container
	docker push $(IMAGE):$(TAG)

.PHONY: container
container:
	docker pull $(IMAGE):$(PATCH)
	docker tag $(IMAGE):$(PATCH) $(IMAGE):$(TAG)
