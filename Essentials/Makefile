# Makefile
#
# Compile all FridaCodeManager essentials
# :3
#

# 越狱设备上 /var/jb/bin/bash 才存在；macOS / 其他环境退回 /bin/sh。
# 命令行传入 SHELL=... 时仍以命令行值为准。
ifeq ($(wildcard /var/jb/bin/bash),)
SHELL := /bin/sh
else
SHELL := /var/jb/bin/bash
endif

all: prepare libfcm-compile

prepare:
	@if [ -d lib/build ]; then \
		rm -rf lib/build; \
		mkdir lib/build; \
	else \
		mkdir lib/build; \
	fi

libfcm-compile:
	@$(MAKE) -C libfcm all
	@cp libfcm/tmp/lib/libfcm.a lib/build/libfcm.a
	@$(MAKE) -C libfcm clean

clean:
	@rm -rf lib/build
