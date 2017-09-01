FORCE:

deps: FORCE
	mix deps.get

test: FORCE
	mix test
	make test-distributed

test-distributed: FORCE
	epmd -daemon
	mix test --only distributed
	make kill-all-epmd

build-cli:
	mix escript.build

test-cli:
	make build-cli
	./cingi --file test/mission_plans/when.plan

test-multi-cli:
	make build-cli
	./cingi --file test/mission_plans/when.plan

test-hq-cli:
	make build-cli
	./cingi --file test/mission_plans/when.plan --minbranches 2 --name one@localhost --cookie test

test-branch-cli:
	make build-cli
	./cingi --file test/mission_plans/when.plan --connectto one@localhost --name two@localhost --cookie test

kill-all-epmd: FORCE
	for pid in $$(ps -ef | grep -v "grep" | grep "epmd -daemon" | awk '{print $$2}'); do kill -9 $$pid; done
