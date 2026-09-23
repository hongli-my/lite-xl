#ifndef GPU_RENDERER_H
#define GPU_RENDERER_H

/* GPU rendering backend built on SDL_gpu (Metal on macOS).
 *
 * Stage 2 scope: draw_rect and draw_text are issued as GPU draw calls into a
 * GPU render-target texture, which is then blitted to the swapchain. The
 * software SDL_Surface path is retained behind the same macro but, when the
 * GPU path is active, rencache_end_frame drives the GPU frame instead.
 *
 * Enabled at compile time via -DLITE_USE_GPU_RENDERER (meson option
 * `gpu_renderer`). When disabled this header is effectively empty. */

#include <SDL3/SDL.h>
#include <stdbool.h>
#include "renderer.h"   /* RenRect, RenColor, RenWindow */

#ifdef __cplusplus
extern "C" {
#endif

#ifdef LITE_USE_GPU_RENDERER

#include "renwindow.h"

/* Process-wide GPU device + shared resources (pipelines, sampler, shaders). */
bool gpu_init(void);
void gpu_free(void);

/* Attach / detach a window. attach claims the window for the GPU device and
 * allocates per-window state (render target, vertex buffer, transfer bufs).
 * resize drops the render-target-sized resources so they rebuild next frame. */
bool gpu_window_attach(RenWindow *ren);
void gpu_window_detach(RenWindow *ren);
void gpu_window_resize(RenWindow *ren);

/*----------------------------------------------------------------------------
 * Frame lifecycle (called by rencache_end_frame)
 *
 *   gpu_begin_frame(ren)           -> acquires cmd buf, ensures render target,
 *                                     begins render pass (load previous content)
 *   gpu_draw_rect(...)             -> push verts + uniform, draw
 *   gpu_draw_text(...)             -> (Stage 2b) bind atlas, push verts, draw
 *   gpu_end_frame(ren)             -> end render pass, blit target->swapchain,
 *                                     submit. This REPLACES renwin_update_rects.
 *--------------------------------------------------------------------------*/
bool gpu_begin_frame(RenWindow *ren);
void gpu_end_frame(RenWindow *ren);

/* Solid-color rectangle (Stage 2a). Coordinates are in surface pixels
 * (already scaled by surface_scale). Straight-alpha color. */
void gpu_draw_rect(RenWindow *ren, RenRect rect, RenColor color, RenRect clip);

/* Set the scissor rect for the current render pass (pixels, surface scale). */
void gpu_set_scissor(RenWindow *ren, RenRect clip);

/* (Stage 2b, declared for forward compatibility) */
void gpu_draw_text(RenWindow *ren, RenRect clip);

/* Legacy Stage 1 entry, kept for the non-GPU rencache path fallback. */
bool gpu_present_surface(RenWindow *ren, SDL_Surface *surface,
                         RenRect *rects, int count);

#endif /* LITE_USE_GPU_RENDERER */

#ifdef __cplusplus
}
#endif
#endif /* GPU_RENDERER_H */
