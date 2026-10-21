# SPDX-License-Identifier: Apache-2.0
# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# Run inside the kube-devenv image. Platform values arrive as Make variables:
#   BASE_REF  commit the branch started from; empty skips commit-messages

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS    ?= /usr/share/kube-devenv/checks
PROVIDERS := aws proxmox
SCRIPTS   := $(wildcard kube-node/packer/*/*.sh) $(wildcard kube-devbox/packer/*/*.sh) $(wildcard .devcontainer/*.sh) .githooks/pre-commit
BASE_REF  ?= $(shell git rev-parse --verify --quiet origin/main)

# This repo has no DCO, so commits need no Signed-off-by line.
export REQUIRE_SIGNOFF := 0

.PHONY: test-commit test-fast hooks fmt lint-scripts lint-yaml lint-ansible \
	lint-pipelines validate validate-devbox secrets commit-messages

test-commit: test-fast lint-scripts lint-yaml lint-ansible lint-pipelines validate commit-messages

test-fast: fmt secrets

hooks:
	git config core.hooksPath .githooks

fmt:
	packer fmt -check -recursive kube-node/packer kube-node/tests kube-devbox/packer kube-devbox/tests
	tofu fmt -check -recursive kube-node/packer/proxmox/seed

lint-scripts:
	bash -n $(SCRIPTS)
	shellcheck -S warning $(SCRIPTS)

lint-yaml:
	yamllint --strict .

lint-ansible:
	ansible-lint kube-node/ansible/ kube-devbox/ansible/

lint-pipelines:
	$(CHECKS)/pipeline-lint.sh .

# Fixture variables stand in for the real ones, so no cloud access is needed.
validate: $(addprefix validate-packer-,$(PROVIDERS)) validate-seed validate-devbox

validate-packer-aws:
	cd kube-node/packer/aws && packer init . && packer validate -var-file=$(CURDIR)/kube-node/tests/aws.pkrvars.hcl .

# Packer reads the key file at validate time, so give it a throwaway one.
validate-packer-proxmox:
	rm -f /tmp/validate-key /tmp/validate-key.pub
	ssh-keygen -q -t ed25519 -N '' -f /tmp/validate-key
	cd kube-node/packer/proxmox && packer init . && packer validate 		-var-file=$(CURDIR)/kube-node/tests/proxmox.pkrvars.hcl -var ssh_private_key_file=/tmp/validate-key .

# The dev box template needs no cloud access either. It reads the same throwaway key.
validate-devbox:
	rm -f /tmp/validate-devbox-key /tmp/validate-devbox-key.pub
	ssh-keygen -q -t ed25519 -N '' -f /tmp/validate-devbox-key
	cd kube-devbox/packer/proxmox && packer init . && packer validate -var-file=$(CURDIR)/kube-devbox/tests/proxmox.pkrvars.hcl -var ssh_private_key_file=/tmp/validate-devbox-key .

validate-seed:
	rm -rf /tmp/validate-seed && cp -r kube-node/packer/proxmox/seed /tmp/validate-seed
	cd /tmp/validate-seed && tofu init -backend=false -input=false && tofu validate

secrets:
	$(CHECKS)/secrets.sh .

commit-messages:
	$(CHECKS)/commit-messages.sh "$(BASE_REF)"
