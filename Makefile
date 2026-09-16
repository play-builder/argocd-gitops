.PHONY: validate lint test package

# Helm/Kustomize render locally; schemas and chart archives are checksum pinned.
validate: lint
	ruby scripts/validate-rendered-manifests.rb --negative

lint:
	@set -eu; for env in dev prod; do \
	  helm lint charts/mini-commerce -f envs/$$env/values.yaml \
	    --set-string image.repository=example.invalid/mini-commerce \
	    --set-string image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; \
	done
	helm lint charts/mini-commerce-db-dev
	helm lint charts/mini-commerce-recovery --set-string snapshotHandle=snap-0123456789abcdef0

test:
	ruby tests/activation.rb
	bash tests/promotion.sh

package:
	bash scripts/package-chart.sh /tmp/mini-commerce-package
