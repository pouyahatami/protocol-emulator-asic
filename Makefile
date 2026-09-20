.PHONY: help test clean

help:
	@echo "make test  - run the cocotb RTL test suite"
	@echo "make clean - remove cocotb build products"

test:
	$(MAKE) -C test -B

clean:
	$(MAKE) -C test clean
