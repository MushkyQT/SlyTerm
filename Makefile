.PHONY: build install run clean

build:
	./build.sh

install:
	./build.sh --install

run: build
	pkill -x SlyTerm || true
	open dist/SlyTerm.app

clean:
	rm -rf .build dist
