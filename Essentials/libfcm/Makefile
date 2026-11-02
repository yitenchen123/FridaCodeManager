# Makefile
#
# libfcm
# Meow :3
# Created by SeanIsNotAConstant on October the 12th 2024
#

# config
# 越狱设备上 /var/jb/bin/sh 才存在；macOS / 其他环境退回 /bin/sh。
ifeq ($(wildcard /var/jb/bin/sh),)
SHELL := /bin/sh
else
SHELL := /var/jb/bin/sh
endif
SDKROOT := ./sdk
CC := clang
CF := -target arm64-apple-ios15 -arch arm64

# finding all C and Objective-C files
CFILES := $(shell find . -name "*.c")
MFILES := $(shell find . -name '*.m')

# compiling them to libsean16
# fishy patch
uuid := uuid

all: compile bind

compile:
	@if [ -d tmp ]; then \
		rm -rf tmp; \
		mkdir tmp tmp/out tmp/lib; \
	else \
		mkdir tmp tmp/out tmp/lib; \
	fi
	@for file in $(CFILES); do \
		$(CC) -isysroot $(SDKROOT) $(CF) -c $$file -o "tmp/out/$$($(uuid)).o"; \
	done
	@for file in $(MFILES); do \
		$(CC) -isysroot $(SDKROOT) $(CF) -c $$file -o "tmp/out/$$($(uuid)).o"; \
	done

bind:
	@ar rcs tmp/lib/libfcm.a tmp/out/*.o

clean:
	@rm -rf tmp
