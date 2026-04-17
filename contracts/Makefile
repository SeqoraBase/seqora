.PHONY: build test fmt coverage snapshot deploy-schema deploy clean

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

deploy-schema:
	source .env && forge script script/RegisterSchema.s.sol:RegisterSchema \
		--rpc-url base_sepolia --broadcast -vvvv

deploy:
	source .env && forge script script/DeploySeqora.s.sol:DeploySeqora \
		--rpc-url base_sepolia --broadcast --verify -vvvv

clean:
	forge clean
