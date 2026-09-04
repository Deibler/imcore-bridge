# Builds the dylib that gets injected into Messages.app.
#
# Two non-obvious requirements, both load-bearing:
#
#   * -arch arm64e — Messages is x86_64/arm64e and runs as arm64e on Apple
#     silicon. A plain arm64 dylib is silently refused at load time.
#   * ad-hoc signature — an unsigned dylib will not load into a hardened,
#     library-validated host even with library validation disabled.

BUILD_DIR := build
DYLIB     := $(BUILD_DIR)/imcore-bridge.dylib
SRCS      := $(wildcard src/*.m)

CC        := clang
ARCHS     := -arch arm64e
FRAMEWORKS := -framework Foundation -framework ImageIO -framework CoreGraphics
# sqlite3 reads the message store directly; it is part of the OS.
LIBS      := -lsqlite3
CFLAGS    := -dynamiclib -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter -O2

# Messages runs x86_64 on Intel hardware; build both when UNIVERSAL=1.
ifeq ($(UNIVERSAL),1)
ARCHS := -arch arm64e -arch x86_64
endif

.PHONY: all clean
all: $(DYLIB)

$(DYLIB): $(SRCS) src/bridge.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(ARCHS) $(FRAMEWORKS) $(LIBS) -o $@ $(SRCS)
	codesign -f -s - --options runtime $@
	@echo "built $@"

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
