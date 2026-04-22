-include common.mk

fmt:
	yq -i . renovate.json

lint:
	yq renovate.json
