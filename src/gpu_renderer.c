/* GPU rendering backend (SDL_gpu / Metal). See gpu_renderer.h for scope.
 *
 * Stage 2a: solid-color rectangles via a trivial MSL shader pair. The frame
 * flow is:
 *
 *   gpu_begin_frame:  ensure render-target texture (COLOR_TARGET) sized to the
 *                     surface; acquire command buffer; begin render pass with
 *                     load_op=LOAD (preserve previous frame for dirty-rect
 *                     incremental redraw).
 *   gpu_draw_rect:    push 4 verts (a quad) into the vertex transfer buffer;
 *                     push vertex+fragment uniforms; BindGPUVertexBuffers;
 *                     DrawGPUPrimitives(TRIANGLE_STRIP, 4).
 *   gpu_end_frame:    end render pass; BlitGPUTexture render-target ->
 *                     swapchain; submit. (Replaces the Stage 1 surface-upload
 *                     path for the GPU rencache driver.)
 *
 * Vertex data is streamed per-frame through a transfer buffer that we map/
 * unmap around the whole frame (begin_frame maps, end_frame unmaps + uploads
 * in one copy pass). This avoids per-draw upload overhead. */

#include <SDL3/SDL.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

#include "gpu_renderer.h"
#include "renwindow.h"

/* Embed the MSL source. SDL_gpu Metal backend compiles it at runtime. */
#include "gpu_shaders_msl.h"

#ifdef LITE_USE_GPU_RENDERER

/*----------------------------------------------------------------------------
 * Types
 *--------------------------------------------------------------------------*/

/* A streamed vertex. position in pixels; texcoord for text (unused for rect). */
typedef struct {
  float x, y;    /* position (pixels, top-left origin) */
  float u, v;    /* texcoord (0..1) */
} GpuVertex;

/* A deferred draw command. We collect these during the frame (while the
 * transfer buffer is mapped) and replay them inside the render pass in
 * gpu_end_frame, after uploading all verts in a single copy pass. This is
 * necessary because SDL_gpu forbids beginning a copy pass while a render
 * pass is active. */
typedef enum {
  GPU_DRAW_RECT,
  GPU_DRAW_TEXT,  /* Stage 2b */
} GpuDrawKind;

typedef struct {
  GpuDrawKind kind;
  Uint32 vert_offset;  /* index into the vertex transfer buffer */
  Uint32 vert_count;
  SDL_FRect clip;      /* scissor in pixels (0,0,0,0 = full target) */
  float funiform[4];   /* fragment uniform (color / mode packed) */
} GpuDrawCmd;

/* Per-window GPU state. */
typedef struct {
  /* Render target (the thing we draw into, then blit to swapchain). */
  SDL_GPUTexture *target_tex;
  int target_w, target_h;

  /* Streamed vertex transfer buffer for the current frame. */
  SDL_GPUTransferBuffer *vbuf_xfer;
  GpuVertex *vbuf_mapped;       /* NULL when not mapped */
  Uint32 vbuf_used;             /* count of GpuVertex written this frame */
  Uint32 vbuf_capacity;         /* max GpuVertex the transfer buffer holds */

  /* Deferred draw commands for this frame. */
  GpuDrawCmd *draws;
  Uint32 draws_count, draws_cap;

  /* GPU vertex buffer that receives the uploaded verts (recreated if the
   * frame needs more space than last time). */
  SDL_GPUBuffer *vbuf_gpu;
  Uint32 vbuf_gpu_size;

  /* Transfer buffer for uploading the CPU surface into the render target
   * (the base layer; GPU rects are drawn on top). */
  SDL_GPUTransferBuffer *surf_xfer;

  /* Current command buffer (valid between begin/end_frame). */
  SDL_GPUCommandBuffer *cmd;
  SDL_GPURenderPass *pass;
} GpuWindowState;

/* Shared, device-wide resources (created once in gpu_init). */
typedef struct {
  SDL_GPUDevice *device;
  SDL_GPUShader *rect_vs, *rect_fs;
  SDL_GPUShader *text_vs, *text_fs;
  SDL_GPUGraphicsPipeline *rect_pipeline;
  SDL_GPUGraphicsPipeline *text_pipeline;
  SDL_GPUSampler *atlas_sampler;
} GpuContext;

static GpuContext g_ctx = {0};

/* Wrapper that lets us specify the entrypoint (rect vs text shaders share
 * the create-info but differ in entrypoint). */
static SDL_GPUShader *create_shader_named(SDL_GPUShaderStage stage,
                                          const char *entrypoint,
                                          const char *code, size_t code_size,
                                          Uint32 num_samplers,
                                          Uint32 num_uniforms) {
  SDL_GPUShaderCreateInfo ci = {0};
  ci.code = (const Uint8 *)code;
  ci.code_size = code_size;
  ci.entrypoint = entrypoint;
  ci.format = SDL_GPU_SHADERFORMAT_MSL;
  ci.stage = stage;
  ci.num_samplers = num_samplers;
  ci.num_storage_textures = 0;
  ci.num_storage_buffers = 0;
  ci.num_uniform_buffers = num_uniforms;
  SDL_GPUShader *s = SDL_CreateGPUShader(g_ctx.device, &ci);
  if (!s)
    fprintf(stderr, "gpu: CreateGPUShader(%s) failed: %s\n", entrypoint,
            SDL_GetError());
  return s;
}

static SDL_GPUGraphicsPipeline *make_rect_pipeline(void) {
  /* Vertex layout: float2 position, float2 texcoord = 16 bytes/vertex.
   * (rect shader only reads position, but sharing the layout with text
   * lets us reuse one vertex buffer.) */
  static const SDL_GPUVertexBufferDescription vbuf_desc = {
    .slot = 0,
    .pitch = sizeof(GpuVertex),
    .input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX,
    .instance_step_rate = 0,
  };
  static const SDL_GPUVertexAttribute attrs[2] = {
    { .location = 0, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 },
    { .location = 1, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 },
  };
  SDL_GPUColorTargetBlendState blend = {0};
  blend.enable_blend = true;
  /* straight-alpha source, premultiplied-output blend:
   *   dst = src.rgb * src.a + dst.rgb * (1 - src.a)
   *   dst.a = src.a + dst.a * (1 - src.a)   (keep accumulating alpha) */
  blend.src_color_blendfactor = SDL_GPU_BLENDFACTOR_SRC_ALPHA;
  blend.dst_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
  blend.color_blend_op = SDL_GPU_BLENDOP_ADD;
  blend.src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE;
  blend.dst_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
  blend.alpha_blend_op = SDL_GPU_BLENDOP_ADD;
  blend.enable_color_write_mask = false;

  SDL_GPUGraphicsPipelineCreateInfo ci = {0};
  ci.vertex_shader = g_ctx.rect_vs;
  ci.fragment_shader = g_ctx.rect_fs;
  ci.vertex_input_state.vertex_buffer_descriptions = &vbuf_desc;
  ci.vertex_input_state.num_vertex_buffers = 1;
  ci.vertex_input_state.vertex_attributes = attrs;
  ci.vertex_input_state.num_vertex_attributes = 2;
  ci.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP;
  ci.rasterizer_state = (SDL_GPURasterizerState){
    .fill_mode = SDL_GPU_FILLMODE_FILL,
    .cull_mode = SDL_GPU_CULLMODE_NONE,
  };
  ci.multisample_state = (SDL_GPUMultisampleState){
    .sample_count = SDL_GPU_SAMPLECOUNT_1,
  };
  /* depth-stencil: all zero/false (no depth) */
  ci.target_info = (SDL_GPUGraphicsPipelineTargetInfo){0};
  SDL_GPUColorTargetDescription ctd = {0};
  ctd.format = SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM; /* matches render target */
  ctd.blend_state = blend;
  ci.target_info.color_target_descriptions = &ctd;
  ci.target_info.num_color_targets = 1;

  SDL_GPUGraphicsPipeline *p =
    SDL_CreateGPUGraphicsPipeline(g_ctx.device, &ci);
  if (!p)
    fprintf(stderr, "gpu: CreateGPUGraphicsPipeline(rect) failed: %s\n",
            SDL_GetError());
  return p;
}

/*----------------------------------------------------------------------------
 * Device lifecycle
 *--------------------------------------------------------------------------*/
bool gpu_init(void) {
  if (g_ctx.device) return true;
  g_ctx.device = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_MSL, true, NULL);
  if (!g_ctx.device) {
    fprintf(stderr, "gpu_init: SDL_CreateGPUDevice failed: %s\n",
            SDL_GetError());
    return false;
  }

  /* Compile shaders from embedded MSL source. */
  size_t code_size = sizeof(gpu_shaders_msl); /* includes trailing NUL */
  g_ctx.rect_vs = create_shader_named(SDL_GPU_SHADERSTAGE_VERTEX,
    "lite_rect_vertex", gpu_shaders_msl, code_size, 0, 1);
  g_ctx.rect_fs = create_shader_named(SDL_GPU_SHADERSTAGE_FRAGMENT,
    "lite_rect_fragment", gpu_shaders_msl, code_size, 0, 1);
  g_ctx.text_vs = create_shader_named(SDL_GPU_SHADERSTAGE_VERTEX,
    "lite_text_vertex", gpu_shaders_msl, code_size, 0, 1);
  g_ctx.text_fs = create_shader_named(SDL_GPU_SHADERSTAGE_FRAGMENT,
    "lite_text_fragment", gpu_shaders_msl, code_size, 1, 1);

  if (!g_ctx.rect_vs || !g_ctx.rect_fs || !g_ctx.text_vs || !g_ctx.text_fs) {
    fprintf(stderr, "gpu_init: shader compilation failed\n");
    return false;
  }

  g_ctx.rect_pipeline = make_rect_pipeline();
  if (!g_ctx.rect_pipeline) return false;

  /* Shared sampler for glyph atlas (Stage 2b). */
  SDL_GPUSamplerCreateInfo sci = {0};
  sci.min_filter = SDL_GPU_FILTER_LINEAR;
  sci.mag_filter = SDL_GPU_FILTER_LINEAR;
  sci.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
  sci.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
  sci.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
  sci.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
  g_ctx.atlas_sampler = SDL_CreateGPUSampler(g_ctx.device, &sci);
  if (!g_ctx.atlas_sampler) {
    fprintf(stderr, "gpu_init: CreateGPUSampler failed: %s\n", SDL_GetError());
    return false;
  }

  fprintf(stderr, "[gpu] device + pipelines + sampler ready\n");
  return true;
}

void gpu_free(void) {
  if (!g_ctx.device) return;
  SDL_WaitForGPUIdle(g_ctx.device);
  if (g_ctx.rect_pipeline)  SDL_ReleaseGPUGraphicsPipeline(g_ctx.device, g_ctx.rect_pipeline);
  if (g_ctx.text_pipeline)  SDL_ReleaseGPUGraphicsPipeline(g_ctx.device, g_ctx.text_pipeline);
  if (g_ctx.atlas_sampler)  SDL_ReleaseGPUSampler(g_ctx.device, g_ctx.atlas_sampler);
  if (g_ctx.rect_vs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.rect_vs);
  if (g_ctx.rect_fs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.rect_fs);
  if (g_ctx.text_vs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.text_vs);
  if (g_ctx.text_fs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.text_fs);
  SDL_DestroyGPUDevice(g_ctx.device);
  g_ctx.device = NULL;
  memset(&g_ctx, 0, sizeof(g_ctx));
}

/*----------------------------------------------------------------------------
 * Per-window state
 *--------------------------------------------------------------------------*/
static const Uint32 VBUF_MAX_VERTS = 1 << 16; /* 65536 verts = ~1MB */

bool gpu_window_attach(RenWindow *ren) {
  if (!g_ctx.device || !ren || !ren->window) return false;
  if (ren->gpu_state) return true;
  if (!SDL_ClaimWindowForGPUDevice(g_ctx.device, ren->window)) {
    fprintf(stderr, "gpu_window_attach: ClaimWindow failed: %s\n",
            SDL_GetError());
    return false;
  }
  GpuWindowState *s = SDL_calloc(1, sizeof(GpuWindowState));
  if (!s) {
    SDL_ReleaseWindowFromGPUDevice(g_ctx.device, ren->window);
    return false;
  }
  ren->gpu_state = s;
  fprintf(stderr, "[gpu] window attached to SDL_gpu device (Metal backend)\n");
  return true;
}

void gpu_window_detach(RenWindow *ren) {
  if (!g_ctx.device || !ren) return;
  GpuWindowState *s = ren->gpu_state;
  if (!s) return;
  SDL_WaitForGPUIdle(g_ctx.device);
  if (s->target_tex)  SDL_ReleaseGPUTexture(g_ctx.device, s->target_tex);
  if (s->vbuf_xfer)   SDL_ReleaseGPUTransferBuffer(g_ctx.device, s->vbuf_xfer);
  if (s->surf_xfer)   SDL_ReleaseGPUTransferBuffer(g_ctx.device, s->surf_xfer);
  if (s->vbuf_gpu)    SDL_ReleaseGPUBuffer(g_ctx.device, s->vbuf_gpu);
  if (s->draws)       SDL_free(s->draws);
  SDL_ReleaseWindowFromGPUDevice(g_ctx.device, ren->window);
  SDL_free(s);
  ren->gpu_state = NULL;
}

void gpu_window_resize(RenWindow *ren) {
  if (!ren || !ren->gpu_state) return;
  GpuWindowState *s = ren->gpu_state;
  SDL_WaitForGPUIdle(g_ctx.device);
  if (s->target_tex) { SDL_ReleaseGPUTexture(g_ctx.device, s->target_tex); s->target_tex = NULL; }
  s->target_w = s->target_h = 0;
  /* vbuf_xfer is size-independent, keep it. */
}

/* Ensure the render-target texture + vertex transfer buffer exist for the
 * given size. Called at begin_frame. */
static bool ensure_resources(GpuWindowState *s, int w, int h) {
  if (w <= 0 || h <= 0) return false;

  /* Render target texture. */
  if (!s->target_tex || s->target_w != w || s->target_h != h) {
    if (s->target_tex) SDL_ReleaseGPUTexture(g_ctx.device, s->target_tex);
    SDL_GPUTextureCreateInfo tci = {0};
    tci.type = SDL_GPU_TEXTURETYPE_2D;
    tci.format = SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;
    tci.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER;
    tci.width = (Uint32)w;
    tci.height = (Uint32)h;
    tci.layer_count_or_depth = 1;
    tci.num_levels = 1;
    tci.sample_count = SDL_GPU_SAMPLECOUNT_1;
    s->target_tex = SDL_CreateGPUTexture(g_ctx.device, &tci);
    if (!s->target_tex) {
      fprintf(stderr, "gpu: target CreateGPUTexture failed: %s\n",
              SDL_GetError());
      return false;
    }
    s->target_w = w;
    s->target_h = h;
    /* Surface upload buffer is size-dependent; recreate on resize. */
    if (s->surf_xfer) {
      SDL_ReleaseGPUTransferBuffer(g_ctx.device, s->surf_xfer);
      s->surf_xfer = NULL;
    }
  }

  /* Surface upload transfer buffer (w*h*4 bytes, BGRA). */
  if (!s->surf_xfer) {
    SDL_GPUTransferBufferCreateInfo sbci = {0};
    sbci.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    sbci.size = (Uint32)(w * h) * 4;
    s->surf_xfer = SDL_CreateGPUTransferBuffer(g_ctx.device, &sbci);
    if (!s->surf_xfer) {
      fprintf(stderr, "gpu: surf CreateGPUTransferBuffer failed: %s\n",
              SDL_GetError());
      return false;
    }
  }

  /* Vertex transfer buffer (size-independent, create once). */
  if (!s->vbuf_xfer) {
    SDL_GPUTransferBufferCreateInfo bci = {0};
    bci.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    bci.size = VBUF_MAX_VERTS * sizeof(GpuVertex);
    s->vbuf_xfer = SDL_CreateGPUTransferBuffer(g_ctx.device, &bci);
    if (!s->vbuf_xfer) {
      fprintf(stderr, "gpu: vbuf CreateGPUTransferBuffer failed: %s\n",
              SDL_GetError());
      return false;
    }
    s->vbuf_capacity = VBUF_MAX_VERTS;
  }
  return true;
}

/*----------------------------------------------------------------------------
 * Frame lifecycle
 *--------------------------------------------------------------------------*/

/* We need a GPU-side vertex buffer to bind. We stream verts into a transfer
 * buffer, upload to a GPU vertex buffer, then bind. To keep it simple for
 * Stage 2a, we create a vertex buffer per frame (small, reused if same size).
 * Actually simpler: use the transfer buffer directly as a vertex buffer is
 * NOT allowed (SDL_gpu requires SDL_GPUBuffer). So we need a GPU vertex
 * buffer + upload. We allocate one big enough for the whole frame. */

/* Extended per-window state: add a vertex GPU buffer. We piggyback on
 * GpuWindowState by adding the field via a parallel struct; but since
 * ren->gpu_state is void*, we just cast. Let's extend the struct. */
/* (The struct above already lacks a GPU vertex buffer; we add it here.) */

bool gpu_begin_frame(RenWindow *ren) {
  if (!g_ctx.device || !ren || !ren->gpu_state) return false;
  GpuWindowState *s = ren->gpu_state;

  RenSurface rs = renwin_get_surface(ren);
  int w = rs.surface->w, h = rs.surface->h;
  if (!ensure_resources(s, w, h)) { fprintf(stderr, "[gpu] begin_frame: ensure_resources FAILED\n"); return false; }

  /* Map the vertex transfer buffer for streaming verts during the frame. */
  s->vbuf_mapped = SDL_MapGPUTransferBuffer(g_ctx.device, s->vbuf_xfer, true);
  if (!s->vbuf_mapped) {
    fprintf(stderr, "gpu: begin_frame map failed: %s\n", SDL_GetError());
    return false;
  }
  s->vbuf_used = 0;
  s->draws_count = 0;

  /* Acquire the command buffer. The render pass is opened later in
   * gpu_end_frame, after we've uploaded all verts in a copy pass (SDL_gpu
   * forbids a copy pass while a render pass is active). */
  s->cmd = SDL_AcquireGPUCommandBuffer(g_ctx.device);
  if (!s->cmd) {
    fprintf(stderr, "gpu: AcquireGPUCommandBuffer failed: %s\n",
            SDL_GetError());
    SDL_UnmapGPUTransferBuffer(g_ctx.device, s->vbuf_xfer);
    s->vbuf_mapped = NULL;
    return false;
  }
  s->pass = NULL;
  return true;
}

/* Push a deferred draw command. */
static GpuDrawCmd *push_draw(GpuWindowState *s) {
  if (s->draws_count == s->draws_cap) {
    Uint32 nc = s->draws_cap ? s->draws_cap * 2 : 256;
    GpuDrawCmd *nd = SDL_realloc(s->draws, nc * sizeof(GpuDrawCmd));
    if (!nd) return NULL;
    s->draws = nd;
    s->draws_cap = nc;
  }
  return &s->draws[s->draws_count++];
}
static void flush_verts(RenWindow *ren, Uint32 vert_count) {
  (void)ren; (void)vert_count;
  /* Obsolete: draw commands are now deferred and replayed in gpu_end_frame. */
}

void gpu_draw_rect(RenWindow *ren, RenRect rect, RenColor color,
                   RenRect clip) {
  GpuWindowState *s = ren->gpu_state;
  if (!s || !s->vbuf_mapped || !s->cmd) return;
  if (s->vbuf_used + 4 > s->vbuf_capacity) return;

  /* Triangle strip quad: TL, BL, TR, BR (Y-down, top-left origin in pixels). */
  float x0 = (float)rect.x, y0 = (float)rect.y;
  float x1 = (float)(rect.x + rect.width), y1 = (float)(rect.y + rect.height);
  GpuVertex *v = &s->vbuf_mapped[s->vbuf_used];
  v[0] = (GpuVertex){ x0, y0, 0, 0 };
  v[1] = (GpuVertex){ x0, y1, 0, 1 };
  v[2] = (GpuVertex){ x1, y0, 1, 0 };
  v[3] = (GpuVertex){ x1, y1, 1, 1 };
  Uint32 off = s->vbuf_used;
  s->vbuf_used += 4;

  GpuDrawCmd *d = push_draw(s);
  if (!d) return;
  d->kind = GPU_DRAW_RECT;
  d->vert_offset = off;
  d->vert_count = 4;
  d->clip = (SDL_FRect){ (float)clip.x, (float)clip.y,
                         (float)clip.width, (float)clip.height };
  d->funiform[0] = color.r / 255.0f;
  d->funiform[1] = color.g / 255.0f;
  d->funiform[2] = color.b / 255.0f;
  d->funiform[3] = color.a / 255.0f;
}

void gpu_draw_text(RenWindow *ren, RenRect clip) {
  (void)ren; (void)clip;
  /* Stage 2b: glyph atlas upload + textured draw. Stub for now. */
}

void gpu_set_scissor(RenWindow *ren, RenRect clip) {
  GpuWindowState *s = ren->gpu_state;
  if (!s || !s->pass) return;
  SDL_Rect sc;
  if (clip.width <= 0 || clip.height <= 0) {
    sc = (SDL_Rect){ 0, 0, s->target_w, s->target_h };
  } else {
    sc = (SDL_Rect){ clip.x, clip.y, clip.width, clip.height };
  }
  SDL_SetGPUScissor(s->pass, &sc);
}

void gpu_end_frame(RenWindow *ren) {
  GpuWindowState *s = ren->gpu_state;
  if (!s || !s->cmd) return;

  /* Unmap the transfer buffer (verts are all written by now). */
  if (s->vbuf_mapped) {
    SDL_UnmapGPUTransferBuffer(g_ctx.device, s->vbuf_xfer);
    s->vbuf_mapped = NULL;
  }

  /* 1. Upload the CPU surface (text + images) into the render target as
   *    the base layer, and upload verts, in a single copy pass. */
  RenSurface rs = renwin_get_surface(ren);
  SDL_Surface *surf = rs.surface;
  if (surf && s->surf_xfer) {
    void *smapped = SDL_MapGPUTransferBuffer(g_ctx.device, s->surf_xfer, true);
    if (smapped) {
      /* The surface may have a pitch != w*4; copy row by row. */
      int row_bytes = surf->w * 4;
      if (surf->pitch == row_bytes) {
        SDL_memcpy(smapped, surf->pixels, (size_t)row_bytes * surf->h);
      } else {
        Uint8 *dst = smapped; const Uint8 *src = surf->pixels;
        for (int y = 0; y < surf->h; y++) {
          SDL_memcpy(dst, src, row_bytes);
          dst += row_bytes; src += surf->pitch;
        }
      }
      SDL_UnmapGPUTransferBuffer(g_ctx.device, s->surf_xfer);
    }
  }

  /* 1. Grow the GPU vertex buffer if needed (outside any pass). */
  Uint32 vert_bytes = s->vbuf_used * sizeof(GpuVertex);
  if (vert_bytes > 0 && (!s->vbuf_gpu || s->vbuf_gpu_size < vert_bytes)) {
    if (s->vbuf_gpu) SDL_ReleaseGPUBuffer(g_ctx.device, s->vbuf_gpu);
    SDL_GPUBufferCreateInfo bci = {0};
    bci.usage = SDL_GPU_BUFFERUSAGE_VERTEX;
    bci.size = vert_bytes;
    s->vbuf_gpu = SDL_CreateGPUBuffer(g_ctx.device, &bci);
    s->vbuf_gpu_size = vert_bytes;
  }

  /* 2. Copy pass: upload CPU surface -> render target, and verts -> GPU buf. */
  SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(s->cmd);
  if (cp) {
    if (surf && s->surf_xfer) {
      SDL_GPUTextureTransferInfo tsrc = {0};
      tsrc.transfer_buffer = s->surf_xfer;
      tsrc.offset = 0;
      tsrc.pixels_per_row = (Uint32)surf->w;
      tsrc.rows_per_layer = (Uint32)surf->h;
      SDL_GPUTextureRegion tdst = {0};
      tdst.texture = s->target_tex;
      tdst.w = (Uint32)surf->w;
      tdst.h = (Uint32)surf->h;
      tdst.d = 1;
      SDL_UploadToGPUTexture(cp, &tsrc, &tdst, false);
    }
    if (vert_bytes > 0 && s->vbuf_gpu) {
      SDL_GPUTransferBufferLocation bsrc = {0};
      bsrc.transfer_buffer = s->vbuf_xfer;
      bsrc.offset = 0;
      SDL_GPUBufferRegion bdst = {0};
      bdst.buffer = s->vbuf_gpu;
      bdst.offset = 0;
      bdst.size = vert_bytes;
      SDL_UploadToGPUBuffer(cp, &bsrc, &bdst, true);
    }
    SDL_EndGPUCopyPass(cp);
  }

  /* 2. Begin render pass on the target texture (only if we have GPU
   *    draws; otherwise the uploaded surface is the final image). The LOAD
   *    op preserves the surface we just uploaded into the target. */
  if (s->draws_count > 0 && vert_bytes > 0) {
    SDL_GPUColorTargetInfo tgt = {0};
    tgt.texture = s->target_tex;
    tgt.load_op = SDL_GPU_LOADOP_LOAD;   /* preserve uploaded surface */
    tgt.store_op = SDL_GPU_STOREOP_STORE;
    tgt.cycle = false;
    s->pass = SDL_BeginGPURenderPass(s->cmd, &tgt, 1, NULL);

    if (s->pass && s->vbuf_gpu) {
      SDL_GPUBufferBinding bind = {0};
      bind.buffer = s->vbuf_gpu;
      bind.offset = 0;
      SDL_BindGPUVertexBuffers(s->pass, 0, &bind, 1);

      /* 3. Replay deferred draws. */
      float vuniform[4] = { (float)s->target_w, (float)s->target_h, 0, 0 };
      SDL_PushGPUVertexUniformData(s->cmd, 0, vuniform, sizeof(vuniform));
      for (Uint32 i = 0; i < s->draws_count; i++) {
        GpuDrawCmd *d = &s->draws[i];
        /* scissor */
        SDL_Rect sc;
        if (d->clip.w > 0 && d->clip.h > 0) {
          sc = (SDL_Rect){ (int)d->clip.x, (int)d->clip.y,
                           (int)d->clip.w, (int)d->clip.h };
        } else {
          sc = (SDL_Rect){ 0, 0, s->target_w, s->target_h };
        }
        SDL_SetGPUScissor(s->pass, &sc);
        if (d->kind == GPU_DRAW_RECT) {
          SDL_BindGPUGraphicsPipeline(s->pass, g_ctx.rect_pipeline);
          SDL_PushGPUFragmentUniformData(s->cmd, 0, d->funiform, sizeof(d->funiform));
          SDL_DrawGPUPrimitives(s->pass, d->vert_count, 1, d->vert_offset, 0);
        }
        /* GPU_DRAW_TEXT: Stage 2b */
      }
    }
    if (s->pass) { SDL_EndGPURenderPass(s->pass); s->pass = NULL; }
  }

  /* 4. Blit render target -> swapchain. */
  SDL_GPUTexture *swapchain = NULL;
  Uint32 sw = 0, sh = 0;
  bool got = SDL_WaitAndAcquireGPUSwapchainTexture(s->cmd, ren->window, &swapchain,
                                             &sw, &sh);
  if (!got) {
    fprintf(stderr, "[gpu] end_frame: AcquireSwapchain FAILED: %s\n", SDL_GetError());
  } else if (!swapchain) {
    fprintf(stderr, "[gpu] end_frame: swapchain NULL\n");
  }
  if (got && swapchain) {
    SDL_GPUBlitInfo info = {0};
    info.source.texture = s->target_tex;
    info.source.w = (Uint32)s->target_w;
    info.source.h = (Uint32)s->target_h;
    info.destination.texture = swapchain;
    info.destination.w = sw;
    info.destination.h = sh;
    info.load_op = SDL_GPU_LOADOP_CLEAR;
    info.clear_color = (SDL_FColor){0, 0, 0, 1};
    info.filter = SDL_GPU_FILTER_NEAREST;
    info.cycle = true;
    SDL_BlitGPUTexture(s->cmd, &info);
  }

  bool submitted = SDL_SubmitGPUCommandBuffer(s->cmd);
  if (!submitted) {
    fprintf(stderr, "[gpu] end_frame SubmitGPUCommandBuffer failed: %s\n",
            SDL_GetError());
  }
  s->cmd = NULL;
  s->vbuf_used = 0;
  s->draws_count = 0;
}

/*----------------------------------------------------------------------------
 * Present path (Stage 1 / 2a): upload the CPU software surface into the GPU
 * render target, then blit the target to the swapchain. This is called from
 * renwin_update_rects every frame. The Stage 2 rencache GPU draw path is not
 * wired in yet (see rencache.c), so this is the active present path.
 *--------------------------------------------------------------------------*/
bool gpu_present_surface(RenWindow *ren, SDL_Surface *surface,
                         RenRect *rects, int count) {
  (void)rects; (void)count;
  if (!g_ctx.device || !ren || !ren->gpu_state || !surface) return false;
  GpuWindowState *s = ren->gpu_state;
  int w = surface->w, h = surface->h;
  if (w <= 0 || h <= 0) return false;
  if (!ensure_resources(s, w, h)) return false;

  SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(g_ctx.device);
  if (!cmd) return false;

  /* Upload surface pixels -> render target texture. */
  if (s->surf_xfer) {
    void *smapped = SDL_MapGPUTransferBuffer(g_ctx.device, s->surf_xfer, true);
    if (smapped) {
      int row_bytes = w * 4;
      if (surface->pitch == row_bytes) {
        SDL_memcpy(smapped, surface->pixels, (size_t)row_bytes * h);
      } else {
        Uint8 *dst = smapped; const Uint8 *src = surface->pixels;
        for (int y = 0; y < h; y++) {
          SDL_memcpy(dst, src, row_bytes);
          dst += row_bytes; src += surface->pitch;
        }
      }
      SDL_UnmapGPUTransferBuffer(g_ctx.device, s->surf_xfer);
    }
    SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(cmd);
    if (cp) {
      SDL_GPUTextureTransferInfo tsrc = {0};
      tsrc.transfer_buffer = s->surf_xfer;
      tsrc.offset = 0;
      tsrc.pixels_per_row = (Uint32)w;
      tsrc.rows_per_layer = (Uint32)h;
      SDL_GPUTextureRegion tdst = {0};
      tdst.texture = s->target_tex;
      tdst.w = (Uint32)w;
      tdst.h = (Uint32)h;
      tdst.d = 1;
      SDL_UploadToGPUTexture(cp, &tsrc, &tdst, false);
      SDL_EndGPUCopyPass(cp);
    }
  }

  /* Blit render target -> swapchain. */
  SDL_GPUTexture *swapchain = NULL;
  Uint32 sw = 0, sh = 0;
  if (SDL_WaitAndAcquireGPUSwapchainTexture(cmd, ren->window, &swapchain,
                                             &sw, &sh) && swapchain) {
    SDL_GPUBlitInfo info = {0};
    info.source.texture = s->target_tex;
    info.source.w = (Uint32)w;
    info.source.h = (Uint32)h;
    info.destination.texture = swapchain;
    info.destination.w = sw;
    info.destination.h = sh;
    info.load_op = SDL_GPU_LOADOP_CLEAR;
    info.clear_color = (SDL_FColor){0, 0, 0, 1};
    info.filter = SDL_GPU_FILTER_NEAREST;
    info.cycle = true;
    SDL_BlitGPUTexture(cmd, &info);
  }

  SDL_SubmitGPUCommandBuffer(cmd);
  return true;
}

#endif /* LITE_USE_GPU_RENDERER */
