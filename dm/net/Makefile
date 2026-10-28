CC = clang
CFLAGS = -std=c11 -O1 -g -Wall -Wextra -Werror
SOURCES = lan_relay.c ../host/hle_ldn_protocol.c
HEADERS = lan_relay.h ../host/net_discovery.h ../host/discovery_protocol.h ../host/hle_ldn.h
.PHONY: all test test-sanitize
all: build/nx-discovery-relay
build:
	mkdir -p build
build/nx-discovery-relay: lan_relay_main.c $(SOURCES) $(HEADERS) | build
	$(CC) $(CFLAGS) -o $@ lan_relay_main.c $(SOURCES)
build/test_lan_relay: test_lan_relay.c $(SOURCES) $(HEADERS) | build
	$(CC) $(CFLAGS) -DDM_LAN_RELAY_TEST -o $@ test_lan_relay.c $(SOURCES)
build/test_lan_relay_asan: test_lan_relay.c $(SOURCES) $(HEADERS) | build
	$(CC) $(CFLAGS) -DDM_LAN_RELAY_TEST -fsanitize=address,undefined -fno-omit-frame-pointer -o $@ test_lan_relay.c $(SOURCES)
test: build/test_lan_relay
	build/test_lan_relay
test-sanitize: build/test_lan_relay_asan
	build/test_lan_relay_asan
