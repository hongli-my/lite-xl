/* GPU presentation backend (SDL_gpu). See gpu_renderer.h for the Stage 1
 * scope. This file is only compiled when LITE_USE_GPU_RENDERER is defined.
 *
 * Per-frame present flow:
 *   1. map the transfer buffer, memcpy the surface pixels in (row by row,
 *      because the surface pitch may differ from width*4)
 *   2. acquire a command buffer
 *   3. copy pass: upload transfer buffer -> staging GPU texture
 *   4. acquire the window's swapchain texture
 *   5. SDL_BlitGPUTexture staging -> swapchain (clears + blits in one call,
 *      no shader needed — SDL_gpu supplies the internal blit pipeline)
 *   6. submit the command buffer
 *
 * The staging texture / transfer buffer are cached per window and rebuilt
 * only when the surface size changes (see ensure_staging). */

#include <SDL3/SDL.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

#include "gpu_renderer.h"
#include "renwindow.h"

#ifdef LITE_USE_GPU_RENDERER

typedef struct {
  SDL_GPUTexture          *staging_tex;   /* receives surface pixels */
  SDL_GPUTransferBuffer   *xfer_buf;      /* CPU->GPU upload staging */
  int                      tex_w, tex_h;  /* current staging size */
  bool                     first_present; /* log once on first GPU present */
} GpuWindowState;

static SDL_GPUDevice *g_device = NULL;

/*----------------------------------------------------------------------------
 * Device lifecycle
 *--------------------------------------------------------------------------*/
bool gpu_init(void) {
  if (g_device) return true;
  /* macOS -> Metal backend. We pass MSL format even though Stage 1 uses no
   * custom shaders: SDL_gpu needs at least one format flag to pick a backend,
   * and MSL is the only one we can provide on macOS without an offline
   * compiler. debug=true gives validation output during bring-up. */
  g_device = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_MSL, true, NULL);
  if (!g_device) {
    fprintf(stderr, "gpu_init: SDL_CreateGPUDevice failed: %s\n", SDL_GetError());
    return false;
  }
  return true;
}

void gpu_free(void) {
  if (g_device) {
    SDL_DestroyGPUDevice(g_device);
    g_device = NULL;
  }
}

/*----------------------------------------------------------------------------
 * Per-window state
 *--------------------------------------------------------------------------*/
bool gpu_window_attach(RenWindow *ren) {
  if (!g_device || !ren || !ren->window) return false;
  if (ren->gpu_state) return true;  /* already attached */
  if (!SDL_ClaimWindowForGPUDevice(g_device, ren->window)) {
    fprintf(stderr, "gpu_window_attach: ClaimWindow failed: %s\n", SDL_GetError());
    return false;
  }
  ren->gpu_state = SDL_calloc(1, sizeof(GpuWindowState));
  if (!ren->gpu_state) {
    SDL_ReleaseWindowFromGPUDevice(g_device, ren->window);
    return false;
  }
  ((GpuWindowState *)ren->gpu_state)->first_present = true;
  fprintf(stderr, "[gpu] window attached to SDL_gpu device (Metal backend)\n");
  return true;
}

void gpu_window_detach(RenWindow *ren) {
  if (!g_device || !ren) return;
  GpuWindowState *s = ren->gpu_state;
  if (!s) return;
  /* Make sure no in-flight work references these resources before freeing. */
  SDL_WaitForGPUIdle(g_device);
  if (s->staging_tex) SDL_ReleaseGPUTexture(g_device, s->staging_tex);
  if (s->xfer_buf)    SDL_ReleaseGPUTransferBuffer(g_device, s->xfer_buf);
  SDL_ReleaseWindowFromGPUDevice(g_device, ren->window);
  SDL_free(s);
  ren->gpu_state = NULL;
}

void gpu_window_resize(RenWindow *ren) {
  if (!ren || !ren->gpu_state) return;
  GpuWindowState *s = ren->gpu_state;
  SDL_WaitForGPUIdle(g_device);
  if (s->staging_tex) { SDL_ReleaseGPUTexture(g_device, s->staging_tex); s->staging_tex = NULL; }
  if (s->xfer_buf)    { SDL_ReleaseGPUTransferBuffer(g_device, s->xfer_buf); s->xfer_buf = NULL; }
  s->tex_w = s->tex_h = 0;
}

/* (Re)create the staging texture + transfer buffer for the given size, unless
 * they already match. Returns true on success. */
static bool ensure_staging(GpuWindowState *s, int w, int h) {
  if (s->staging_tex && s->tex_w == w && s->tex_h == h) return true;
  if (s->staging_tex) { SDL_ReleaseGPUTexture(g_device, s->staging_tex); s->staging_tex = NULL; }
  if (s->xfer_buf)    { SDL_ReleaseGPUTransferBuffer(g_device, s->xfer_buf); s->xfer_buf = NULL; }

  SDL_GPUTextureCreateInfo tci = {0};
  tci.type = SDL_GPU_TEXTURETYPE_2D;
  tci.format = SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;  /* matches SDL_PIXELFORMAT_BGRA32 */
  tci.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;           /* blit source requires SAMPLER */
  tci.width = (Uint32)w;
  tci.height = (Uint32)h;
  tci.layer_count_or_depth = 1;
  tci.num_levels = 1;
  tci.sample_count = SDL_GPU_SAMPLECOUNT_1;
  s->staging_tex = SDL_CreateGPUTexture(g_device, &tci);
  if (!s->staging_tex) {
    fprintf(stderr, "gpu: CreateGPUTexture failed: %s\n", SDL_GetError());
    return false;
  }

  SDL_GPUTransferBufferCreateInfo bci = {0};
  bci.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
  bci.size = (Uint32)(w * h * 4);
  s->xfer_buf = SDL_CreateGPUTransferBuffer(g_device, &bci);
  if (!s->xfer_buf) {
    fprintf(stderr, "gpu: CreateGPUTransferBuffer failed: %s\n", SDL_GetError());
    SDL_ReleaseGPUTexture(g_device, s->staging_tex);
    s->staging_tex = NULL;
    return false;
  }

  s->tex_w = w;
  s->tex_h = h;
  return true;
}

/*----------------------------------------------------------------------------
 * Present
 *--------------------------------------------------------------------------*/
bool gpu_present_surface(RenWindow *ren, SDL_Surface *surface,
                         RenRect *rects, int count) {
  (void)rects; (void)count;  /* Stage 1: full-surface upload */
  if (!g_device || !ren || !ren->gpu_state || !surface) return false;
  GpuWindowState *s = ren->gpu_state;

  int w = surface->w, h = surface->h;
  if (w <= 0 || h <= 0) return false;
  if (!ensure_staging(s, w, h)) return false;

  /* 1. copy surface pixels into the transfer buffer */
  void *mapped = SDL_MapGPUTransferBuffer(g_device, s->xfer_buf, true);
  if (!mapped) {
    fprintf(stderr, "gpu: MapGPUTransferBuffer failed: %s\n", SDL_GetError());
    return false;
  }
  int row_bytes = w * 4;
  if (surface->pitch == row_bytes) {
    memcpy(mapped, surface->pixels, (size_t)row_bytes * h);
  } else {
    for (int y = 0; y < h; y++) {
      memcpy((uint8_t *)mapped + (size_t)y * row_bytes,
             (uint8_t *)surface->pixels + (size_t)y * surface->pitch,
             row_bytes);
    }
  }
  SDL_UnmapGPUTransferBuffer(g_device, s->xfer_buf);

  /* 2. command buffer */
  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(g_device);
  if (!cmd) {
    fprintf(stderr, "gpu: AcquireGPUCommandBuffer failed: %s\n", SDL_GetError());
    return false;
  }

  /* 3. upload transfer buffer -> staging texture */
  SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(cmd);
  if (cp) {
    SDL_GPUTextureTransferInfo src = {0};
    src.transfer_buffer = s->xfer_buf;
    src.offset = 0;
    src.pixels_per_row = (Uint32)w;
    src.rows_per_layer = (Uint32)h;
    SDL_GPUTextureRegion dst = {0};
    dst.texture = s->staging_tex;
    dst.w = (Uint32)w;
    dst.h = (Uint32)h;
    dst.d = 1;
    SDL_UploadToGPUTexture(cp, &src, &dst, true);
    SDL_EndGPUCopyPass(cp);
  }

  /* 4. acquire swapchain texture */
  SDL_GPUTexture *swapchain = NULL;
  Uint32 swap_w = 0, swap_h = 0;
  if (!SDL_WaitAndAcquireGPUSwapchainTexture(cmd, ren->window, &swapchain, &swap_w, &swap_h)) {
    fprintf(stderr, "gpu: AcquireSwapchainTexture failed: %s\n", SDL_GetError());
    SDL_SubmitGPUCommandBuffer(cmd);
    return false;
  }
  if (!swapchain) {
    /* First frame or window minimized: nothing to present. */
    SDL_SubmitGPUCommandBuffer(cmd);
    return true;
  }

  /* 5. blit staging -> swapchain (clear + blit in one call, no shader) */
  SDL_GPUBlitInfo info = {0};
  info.source.texture = s->staging_tex;
  info.source.w = (Uint32)w;
  info.source.h = (Uint32)h;
  info.destination.texture = swapchain;
  info.destination.w = swap_w;
  info.destination.h = swap_h;
  info.load_op = SDL_GPU_LOADOP_CLEAR;
  info.clear_color = (SDL_FColor){0, 0, 0, 1};
  info.filter = SDL_GPU_FILTER_NEAREST;  /* pixel-exact; surface is already at device resolution */
  info.cycle = true;
  SDL_BlitGPUTexture(cmd, &info);

  /* 6. submit */
  if (!SDL_SubmitGPUCommandBuffer(cmd)) {
    fprintf(stderr, "gpu: SubmitGPUCommandBuffer failed: %s\n", SDL_GetError());
    return false;
  }
  if (s->first_present) {
    s->first_present = false;
    fprintf(stderr, "[gpu] first frame presented via SDL_gpu (surface %dx%d -> swapchain %ux%u)\n",
            w, h, swap_w, swap_h);
  }
  return true;
}

#endif /* LITE_USE_GPU_RENDERER */
