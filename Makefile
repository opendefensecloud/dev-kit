# dev-kit is the source of common.mk, so it includes its own copy directly. The
# self-update check skips repositories where common.mk is tracked by git, and
# DEV_KIT_CONFIGS resolves to nothing here because the shared configs live in
# this repository already.
DEV_KIT_VERSION := main
DEV_KIT_FORMATTING := on
include common.mk
