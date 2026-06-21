// Hydra Audio — GPL-3.0
// Non-inline helpers for the plugin-host shared-memory transport. The atomic
// accessors and layout math live (inline) in the header; these wrap the POSIX
// shm calls that are variadic / awkward to invoke from Swift.

#include "hydra_plugin_shm.h"

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

int hydra_shm_create(const char *name, size_t bytes) {
    shm_unlink(name); // clear any stale region from a previous crash
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) return -1;
    if (ftruncate(fd, (off_t)bytes) != 0) {
        close(fd);
        shm_unlink(name);
        return -1;
    }
    return fd;
}

int hydra_shm_open_rw(const char *name) {
    return shm_open(name, O_RDWR, 0);
}
