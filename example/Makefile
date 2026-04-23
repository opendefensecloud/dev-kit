# Include ODC common make targets
DEV_KIT_VERSION := v1.0.0
-include common.mk
common.mk:
	curl -sSL https://raw.githubusercontent.com/opendefensecloud/dev-kit/$(DEV_KIT_VERSION)/common.mk -o $@

# Add you own custom make targets
my-target:
	@echo Hello World

# Install go binaries using the tools.lock
COBRA := $(LOCALGOBIN)/cobra-cli
cobra: $(COBRA)
	$(COBRA) help

scan:
	echo hello
