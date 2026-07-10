#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>

static volatile sig_atomic_t probe_requested;
static struct wl_compositor *compositor;

static void request_probe(int signal_number) {
  (void)signal_number;
  probe_requested = 1;
}

static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface,
                            uint32_t version) {
  (void)data;
  if (strcmp(interface, wl_compositor_interface.name) == 0) {
    uint32_t bind_version = version < 4 ? version : 4;
    compositor = wl_registry_bind(registry, name, &wl_compositor_interface,
                                  bind_version);
  }
}

static void registry_global_remove(void *data, struct wl_registry *registry,
                                   uint32_t name) {
  (void)data;
  (void)registry;
  (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void write_probe(const char *path, const char *token, unsigned counter,
                        int roundtrip_result) {
  char temporary[4096];
  if (snprintf(temporary, sizeof(temporary), "%s.tmp", path) >=
      (int)sizeof(temporary)) {
    abort();
  }
  FILE *output = fopen(temporary, "w");
  if (output == NULL) {
    abort();
  }
  fprintf(output,
          "{\"pid\":%ld,\"token\":\"%s\",\"counter\":%u,"
          "\"roundtrip_result\":%d}\n",
          (long)getpid(), token, counter, roundtrip_result);
  if (fclose(output) != 0 || rename(temporary, path) != 0) {
    abort();
  }
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s PROBE-PATH TOKEN\n", argv[0]);
    return 2;
  }

  struct sigaction action = {.sa_handler = request_probe};
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGUSR1, &action, NULL) != 0) {
    perror("sigaction");
    return 1;
  }

  struct wl_display *display = wl_display_connect(NULL);
  if (display == NULL) {
    fprintf(stderr, "failed to connect to Wayland display\n");
    return 1;
  }
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  if (wl_display_roundtrip(display) < 0 || compositor == NULL) {
    fprintf(stderr, "wl_compositor is unavailable\n");
    return 1;
  }
  struct wl_surface *surface = wl_compositor_create_surface(compositor);
  if (surface == NULL) {
    fprintf(stderr, "failed to create surface\n");
    return 1;
  }
  wl_surface_commit(surface);
  if (wl_display_roundtrip(display) < 0) {
    fprintf(stderr, "initial Wayland roundtrip failed\n");
    return 1;
  }

  unsigned counter = 0x5a17U;
  write_probe(argv[1], argv[2], counter, 0);
  for (;;) {
    pause();
    if (probe_requested) {
      probe_requested = 0;
      ++counter;
      int result = wl_display_roundtrip(display);
      write_probe(argv[1], argv[2], counter, result);
      if (result < 0) {
        return 1;
      }
    }
  }
}
