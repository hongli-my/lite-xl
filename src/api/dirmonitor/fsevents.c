#include <SDL3/SDL.h>
#include <CoreServices/CoreServices.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>

struct dirmonitor_internal {
  SDL_Mutex* lock;
  char** changes;
  size_t count;
  FSEventStreamRef stream;
  int fds[2];
  bool pipe_open;
};

CFRunLoopRef main_run_loop;


struct dirmonitor_internal* init_dirmonitor() {
  static bool mainloop_registered = false;
  if (!mainloop_registered) {
    main_run_loop = CFRunLoopGetCurrent();
    mainloop_registered = true;
  }

  struct dirmonitor_internal* monitor = SDL_calloc(1, sizeof(struct dirmonitor_internal));
  monitor->stream = NULL;
  monitor->changes = NULL;
  monitor->count = 0;
  monitor->lock = SDL_CreateMutex();
  monitor->pipe_open = false;

  return monitor;
}


void wake_dirmonitor(struct dirmonitor_internal* monitor) {
  /* non-blocking write: never called with the lock held, so it cannot block
   * the FSEventStream callback thread even when the pipe is full */
  if (monitor->pipe_open) {
    ssize_t written = write(monitor->fds[1], "", 1);
    (void)written;
  }
}


static void stop_monitor_stream(struct dirmonitor_internal* monitor) {
  if (monitor->stream) {
    FSEventStreamStop(monitor->stream);
    FSEventStreamUnscheduleFromRunLoop(
      monitor->stream, main_run_loop, kCFRunLoopDefaultMode
    );
    FSEventStreamInvalidate(monitor->stream);
    FSEventStreamRelease(monitor->stream);
    monitor->stream = NULL;
  }
  /* wake up a check thread blocked in get_changes_dirmonitor; the pipe and
   * the lock are intentionally kept alive here -- they are owned by
   * deinit_dirmonitor, which runs only after the check thread is joined */
  wake_dirmonitor(monitor);

  SDL_LockMutex(monitor->lock);
  if (monitor->count > 0) {
    for (size_t i = 0; i<monitor->count; i++) {
      SDL_free(monitor->changes[i]);
    }
    SDL_free(monitor->changes);
    monitor->changes = NULL;
    monitor->count = 0;
  }
  SDL_UnlockMutex(monitor->lock);
}


void deinit_dirmonitor(struct dirmonitor_internal* monitor) {
  stop_monitor_stream(monitor);
  if (monitor->pipe_open) {
    close(monitor->fds[0]);
    close(monitor->fds[1]);
    monitor->pipe_open = false;
  }
  SDL_DestroyMutex(monitor->lock);
  monitor->lock = NULL;
}


static void stream_callback(
  ConstFSEventStreamRef streamRef,
  void* monitor_ptr,
  size_t numEvents,
  void* eventPaths,
  const FSEventStreamEventFlags eventFlags[],
  const FSEventStreamEventId eventIds[]
)
{
  if (numEvents <= 0) {
    return;
  }

  struct dirmonitor_internal* monitor = monitor_ptr;
  char** path_list = eventPaths;

  SDL_LockMutex(monitor->lock);
  size_t total = 0;
  if (monitor->count == 0) {
    total = numEvents;
    monitor->changes = SDL_calloc(numEvents, sizeof(char*));
  } else {
    total = monitor->count + numEvents;
    monitor->changes = SDL_realloc(
      monitor->changes,
      sizeof(char*) * total
    );
  }
  for (size_t idx = monitor->count; idx < total; idx++) {
    size_t pidx = idx - monitor->count;
    monitor->changes[idx] = SDL_malloc(strlen(path_list[pidx])+1);
    strcpy(monitor->changes[idx], path_list[pidx]);
  }
  monitor->count = total;
  SDL_UnlockMutex(monitor->lock);

  wake_dirmonitor(monitor);
}


int get_changes_dirmonitor(
  struct dirmonitor_internal* monitor,
  char* buffer,
  int buffer_size
) {
  /* block until a wake byte arrives: the fd is non-blocking, so without
   * this poll the check thread would spin at full speed and flood the SDL
   * event queue.  wake_dirmonitor() writes a byte on shutdown, and the
   * fd is only closed after the check thread has been joined, so polling
   * here is safe. */
  (void)buffer;
  (void)buffer_size;
  if (!monitor->pipe_open) {
    /* watch was never set up: fds[0] would be fd 0 (stdin); idle slowly
     * instead of polling an unrelated descriptor */
    SDL_Delay(50);
    return 0;
  }
  struct pollfd p = { .fd = monitor->fds[0], .events = POLLIN, .revents = 0 };
  poll(&p, 1, -1);

  /* drain all pending wakeups; the fd is non-blocking so this cannot hang */
  char response[1];
  while (read(monitor->fds[0], response, 1) == 1) {
    /* keep draining */
  }

  SDL_LockMutex(monitor->lock);
  size_t results = monitor->count;
  SDL_UnlockMutex(monitor->lock);

  return (int)results;
}


int translate_changes_dirmonitor(
  struct dirmonitor_internal* monitor,
  char* buffer,
  int buffer_size,
  int (*change_callback)(int, const char*, void*),
  void* L
) {
  /* take ownership of the pending list under the lock, then run the
   * callbacks without holding it: a callback may re-enter dirmonitor APIs
   * and the mutex is non-recursive */
  (void)buffer;
  (void)buffer_size;
  SDL_LockMutex(monitor->lock);
  char** changes = monitor->changes;
  size_t count = monitor->count;
  monitor->changes = NULL;
  monitor->count = 0;
  SDL_UnlockMutex(monitor->lock);

  for (size_t i = 0; i<count; i++) {
    change_callback(strlen(changes[i]), changes[i], L);
    SDL_free(changes[i]);
  }
  SDL_free(changes);
  return 0;
}


int add_dirmonitor(struct dirmonitor_internal* monitor, const char* path) {
  stop_monitor_stream(monitor);

  if (!monitor->lock) {
    monitor->lock = SDL_CreateMutex();
  }
  if (!monitor->pipe_open) {
    if (pipe(monitor->fds) != 0) {
      return -1;
    }
    /* non-blocking so neither end can ever block while holding the lock */
    for (int i = 0; i < 2; i++) {
      int flags = fcntl(monitor->fds[i], F_GETFL, 0);
      fcntl(monitor->fds[i], F_SETFL, flags | O_NONBLOCK);
    }
    monitor->pipe_open = true;
  }

  FSEventStreamContext context = {
    .info = monitor,
    .retain = NULL,
    .release = NULL,
    .copyDescription = NULL,
    .version = 0
  };

  CFStringRef path_str = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
  CFArrayRef paths_array = CFArrayCreate(NULL, (const void **)&path_str, 1, NULL);

  monitor->stream = FSEventStreamCreate(
    NULL,
    stream_callback,
    &context,
    paths_array,
    kFSEventStreamEventIdSinceNow,
    0,
    kFSEventStreamCreateFlagNone
      | kFSEventStreamCreateFlagWatchRoot
      | kFSEventStreamCreateFlagFileEvents
  );

  /* the stream and the array both retain the string: drop our references */
  CFRelease(path_str);

  /* invalid path / permissions: FSEventStreamCreate returns NULL and using
   * it afterwards would crash */
  if (!monitor->stream) {
    CFRelease(paths_array);
    return -1;
  }

  FSEventStreamScheduleWithRunLoop(
    monitor->stream, main_run_loop, kCFRunLoopDefaultMode
  );

  if (!FSEventStreamStart(monitor->stream)) {
    FSEventStreamUnscheduleFromRunLoop(
      monitor->stream, main_run_loop, kCFRunLoopDefaultMode
    );
    FSEventStreamInvalidate(monitor->stream);
    FSEventStreamRelease(monitor->stream);
    monitor->stream = NULL;
    CFRelease(paths_array);
    return -1;
  }

  /* the created stream retains the array; our reference can go */
  CFRelease(paths_array);

  return 1;
}


void remove_dirmonitor(struct dirmonitor_internal* monitor, int fd) {
  stop_monitor_stream(monitor);
}


int get_mode_dirmonitor() { return 1; }
