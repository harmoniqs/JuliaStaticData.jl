CC ?= gcc
CFLAGS ?= -Wall -Wextra -O2 -std=c99
PREFIX ?= /usr/local

SRCDIR = .
BUILDDIR = build

HEADER_SRC = $(SRCDIR)/jlstaticdata_header.c
REMAP_SRC = $(SRCDIR)/jlstaticdata_remap.c
CLI_SRC = $(SRCDIR)/jlstaticdata_cli.c
HEADER = $(SRCDIR)/libjlstaticdata.h

LIB_SRCS = $(HEADER_SRC) $(REMAP_SRC)
LIB_OBJS = $(BUILDDIR)/jlstaticdata_header.o $(BUILDDIR)/jlstaticdata_remap.o
CLI_OBJ = $(BUILDDIR)/jlstaticdata_cli.o

SHARED_LIB = $(BUILDDIR)/libjlstaticdata.so
STATIC_LIB = $(BUILDDIR)/libjlstaticdata.a
CLI_BIN = $(BUILDDIR)/jlsd-remap

.PHONY: all clean install lib cli

all: lib cli

lib: $(SHARED_LIB) $(STATIC_LIB)

cli: $(CLI_BIN)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(BUILDDIR)/%.o: $(SRCDIR)/%.c $(HEADER) | $(BUILDDIR)
	$(CC) $(CFLAGS) -fPIC -c -o $@ $<

$(SHARED_LIB): $(LIB_OBJS) | $(BUILDDIR)
	$(CC) $(CFLAGS) -shared -o $@ $(LIB_OBJS)

$(STATIC_LIB): $(LIB_OBJS) | $(BUILDDIR)
	ar rcs $@ $(LIB_OBJS)

$(CLI_BIN): $(CLI_OBJ) $(STATIC_LIB) | $(BUILDDIR)
	$(CC) $(CFLAGS) -o $@ $(CLI_OBJ) $(STATIC_LIB)

clean:
	rm -rf $(BUILDDIR)

install: all
	install -d $(PREFIX)/bin $(PREFIX)/lib $(PREFIX)/include
	install -m 755 $(CLI_BIN) $(PREFIX)/bin/
	install -m 644 $(SHARED_LIB) $(PREFIX)/lib/
	install -m 644 $(STATIC_LIB) $(PREFIX)/lib/
	install -m 644 $(HEADER) $(PREFIX)/include/
