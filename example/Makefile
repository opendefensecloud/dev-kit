# Include ODC common make targets
# FIXME(user): replace with a static dev-kit release (https://github.com/opendefensecloud/dev-kit/releases)
DEV_KIT_VERSION := refs/heads/main

-include common.mk
common.mk:
	curl --fail -sSL https://raw.githubusercontent.com/opendefensecloud/dev-kit/$(DEV_KIT_VERSION)/common.mk -o common.mk.download && \
	mv common.mk.download $@

# Add you own custom make targets
my-target:
	@echo Hello World

# Install go binaries using the tools.lock
COBRA := $(LOCALGOBIN)/cobra-cli
cobra: $(COBRA)
	$(COBRA) help

scan:
	echo hello

fmt: # FIXME(user): Implement the fmt target or disable the pre-commit hook for it (flake.nix)

lint: # FIXME(user): Implement the lint target or disable the pre-commit hook for it (flake.nix)
