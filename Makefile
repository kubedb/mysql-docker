SHELL=/bin/bash -o pipefail

REGISTRY ?= kubedb
BIN      := mysql
IMAGE    := $(REGISTRY)/$(BIN)
TAG      := 8.0.14

.PHONY: push
push: container
	docker push $(IMAGE):$(TAG)

.PHONY: container
container:
	docker pull $(BIN):$(TAG)
	docker tag $(BIN):$(TAG) $(IMAGE):$(TAG)
