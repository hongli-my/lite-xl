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
 *   gpu_begin_frame(ren)           -> acquires cmd buf, maps vertex transfer
 *                                     buffer (render pass opened in end_frame)
 *   gpu_draw_rect(...)             -> push quad verts + deferred draw cmd
 *   gpu_draw_text_quads(...)       -> push glyph quad verts + deferred draw cmd
 *   gpu_end_frame(ren)             -> upload dirty atlas + verts in copy pass,
 *                                     begin render pass (LOAD op for fb fetch),
 *                                     replay draws, blit target->swapchain,
 *                                     submit.
 *--------------------------------------------------------------------------*/
bool gpu_begin_frame(RenWindow *ren);
void gpu_end_frame(RenWindow *ren);

/* Solid-color rectangle. Coordinates are in surface pixels (already scaled
 * by surface_scale). Straight-alpha color. */
void gpu_draw_rect(RenWindow *ren, RenRect rect, RenColor color, RenRect clip);

/* Glyph atlas GPU texture lifecycle.
 *   fmt: 0=grayscale, 1=subpixel LCD, 2=color (emoji)
 * Returns an opaque pointer (SDL_GPUTexture* internally). */
void *gpu_atlas_create_texture(int w, int h, int fmt);
void gpu_atlas_destroy_texture(void *tex);

/* Mark a sub-region of an atlas texture dirty. The corresponding CPU surface
 * region will be uploaded (with format conversion) at the next gpu_end_frame.
 * Safe to call during begin_frame..end_frame (just records into a list). */
void gpu_atlas_mark_dirty(void *tex, SDL_Surface *surf,
                          int x, int y, int w, int h, int fmt);

/* A glyph quad vertex: position (pixels) + texcoord (normalized 0..1). */
typedef struct {
  float x, y, u, v;
} GpuTextVertex;

/* Push one or more glyph quads as a single draw. All verts must sample the
 * same atlas texture. mode: 0=grayscale, 1=subpixel LCD, 2=color emoji.
 * color is the foreground tint (straight alpha). */
void gpu_draw_text_quads(RenWindow *ren, void *tex,
                         const GpuTextVertex *verts, int vert_count,
                         RenColor color, int mode, RenRect clip);

/* Draw an image (SDL_Surface) into a rectangle. The surface is converted to
 * RGBA32 and uploaded to a cached GPU texture, then drawn as a textured quad
 * using the text pipeline in color mode (standard SRC-over alpha blend). */
void gpu_draw_image(RenWindow *ren, SDL_Surface *img,
                    RenRect rect, RenRect clip);

/* Legacy Stage 1 entry, kept for the non-GPU rencache path fallback. */
bool gpu_present_surface(RenWindow *ren, SDL_Surface *surface,
                         RenRect *rects, int count);

#endif /* LITE_USE_GPU_RENDERER */

#ifdef __cplusplus
}
#endif
#endif /* GPU_RENDERER_H */
