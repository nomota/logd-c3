a:
	@echo make all
	@echo make clean
	@echo "make fetch|update|remove"
	@echo "make pull|push"

all:
	@make build/logd
	@make build/logd_test
	
C3C = c3c compile
LIB = ./build/unpacked_c3l/ext.c3l/ext/*/*.c3

build/logd: src/logd.c3
	c3c build
	$(C3C) $^ $(LIB) -o $@
	
build/logd_test: test/logd_test.c3
	$(C3C) $^ $(LIB) -o $@
	
clean:
	@rm -rf ./build/*

fetch:
	@c3l fetch https://github.com/nomota/ext.c3l

update:
	@c3l update ext.c3l

remove:
	@c3l remove ext.c3l

push:
	@make clean
	@make pull
	@git add .
	@git commit -m "update"
	@git push origin main

pull:
	@git pull origin main
