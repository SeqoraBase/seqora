.PHONY: build test fmt fmt-check coverage snapshot snapshot-check storage storage-check deploy-schema deploy clean

build:
	forge build --sizes

test:
	forge test -vv

fmt:
	forge fmt

fmt-check:
	forge fmt --check

coverage:
	forge coverage --ir-minimum --no-match-coverage "(test|script)" --report summary

snapshot:
	forge snapshot --snap .gas-snapshot

snapshot-check:
	forge snapshot --check --snap .gas-snapshot

# Regenerate storage-layout baselines for the three upgradeable contracts. CI diffs these
# against the working tree to catch accidental storage rearrangement between releases.
storage:
	@mkdir -p storage
	@for name in LicenseRegistry BiosafetyCourt ProvenanceRegistry; do \
		forge inspect $$name storageLayout --json > storage/$$name.json; \
		echo "wrote storage/$$name.json"; \
	done

storage-check:
	@mkdir -p .tmp-storage
	@failed=0; \
	for name in LicenseRegistry BiosafetyCourt ProvenanceRegistry; do \
		forge inspect $$name storageLayout --json > .tmp-storage/$$name.json; \
		if ! diff -u storage/$$name.json .tmp-storage/$$name.json; then \
			echo "storage layout drift in $$name"; failed=1; \
		fi; \
	done; \
	rm -rf .tmp-storage; \
	exit $$failed

deploy-schema:
	source .env && forge script script/RegisterSchema.s.sol:RegisterSchema \
		--rpc-url base --broadcast -vvvv

deploy:
	source .env && forge script script/DeploySeqora.s.sol:DeploySeqora \
		--rpc-url base --broadcast --verify -vvvv

clean:
	forge clean
