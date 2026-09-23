#ifndef GPU_RENDERER_H
#define GPU_RENDERER_H

/* GPU-accelerated presentation backend built on SDL_gpu.
 *
 * Stage 1 scope: the software renderer (renderer.c) still draws into an
 * SDL_Surface as before; this module only takes ownership of the final
 * "present" step, uploading the surface pixels to a GPU texture and blitting
 * it to the window's swapchain. That is enough to validate the whole SDL_gpu
 * pipeline (device / swapchain / copy pass / blit / submit) before later
 * stages move draw_rect / draw_text themselves onto the GPU.
 *
 * Enabled at compile time via -DLITE_USE_GPU_RENDERER (see meson option
 * `gpu_renderer`). When disabled this header is effectively empty. */

#include <SDL3/SDL.h>
#include <stdbool.h>
#include "renderer.h"   /* RenRect, RenWindow */

#ifdef __cplusplus
extern "C" {
#endif

#ifdef LITE_USE_GPU_RENDERER

/* Process-wide GPU device (singleton). A single device claims every window. */
bool gpu_init(void);
void gpu_free(void);

/* Attach / detach a window to the GPU device. attach claims the window so
 * SDL_gpu can present to it; it also allocates the per-window staging state
 * (upload texture + transfer buffer). detach releases everything.
 * attach must run after the SDL_Window is created. */
bool gpu_window_attach(RenWindow *ren);
void gpu_window_detach(RenWindow *ren);

/* Drop the cached staging texture / transfer buffer so they get recreated at
 * the new size on the next present. Call on window resize. */
void gpu_window_resize(RenWindow *ren);

/* Present `surface` to the window's swapchain.
 * The dirty `rects` are currently ignored (full-surface upload each frame);
 * they are kept in the signature for a future incremental-upload optimisation.
 * Returns true on success, false on a GPU error (the caller should fall back
 * gracefully — for Stage 1 we just log). */
bool gpu_present_surface(RenWindow *ren, SDL_Surface *surface,
                         RenRect *rects, int count);

#endif /* LITE_USE_GPU_RENDERER */

#ifdef __cplusplus
}
#endif
#endif /* GPU_RENDERER_H */
