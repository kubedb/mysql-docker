SHELL=/bin/bash -o pipefail

REGISTRY ?= kubedb
BIN      := mysql
IMAGE    := $(REGISTRY)/$(BIN)
TAG      := 5.7.25

.PHONY: push
push: container
	docker push $(IMAGE):$(TAG)

.PHONY: container
container:
	wget -qO peer-finder https://github.com/kmodules/peer-finder/releases/download/v1.0.1-ac/peer-finder
	chmod +x peer-finder
	chmod +x on-start.sh
	docker build --pull -t $(IMAGE):$(TAG) .
	rm peer-finder
