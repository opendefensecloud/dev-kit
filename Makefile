DEV_KIT_VERSION := main
DEV_KIT_NO_SELF_UPDATE := 1

# The shared configs live in this repository; there is nothing to bootstrap.
DEV_KIT_CONFIGS :=

include common.mk

# No Go code here, so golangci-lint is not installed and treefmt must not
# insist on it. Every other repository leaves TREEFMT_ARGS empty.
TREEFMT_ARGS := --allow-missing-formatter
