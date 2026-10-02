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
 * vertex transfer buffer is mapped) and replay them inside the render pass in
 * gpu_end_frame, after uploading all verts + dirty atlas regions in one or
 * more copy passes. This is necessary because SDL_gpu forbids beginning a
 * copy pass while a render pass is active. */
typedef enum {
  GPU_DRAW_RECT,
  GPU_DRAW_TEXT,
} GpuDrawKind;

typedef struct {
  GpuDrawKind kind;
  Uint32 vert_offset;  /* index into the vertex transfer buffer */
  Uint32 vert_count;
  SDL_FRect clip;      /* scissor in pixels (0,0,0,0 = full target) */
  float funiform[8];   /* fragment uniform: rect={color.rgba,_,_,_,_},
                        * text={color.rgba, mode.x,0,0,0} */
  void *texture;       /* SDL_GPUTexture* for text; NULL for rect */
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

  /* Transfer buffer for the fallback present path (gpu_present_surface).
   * NOT used by the GPU rencache path. Lazily created on first present. */
  SDL_GPUTransferBuffer *surf_xfer;
  Uint32 surf_xfer_size;

  /* Cached texture for DRAW_IMAGE (grown if a larger image is drawn).
   * last_img caches the surface pointer to skip re-uploading when the
   * same image is redrawn (e.g. markdown preview dirty-redraw). */
  SDL_GPUTexture *image_tex;
  int image_tex_w, image_tex_h;
  SDL_Surface *last_img;

  /* Current command buffer (valid between begin/end_frame). */
  SDL_GPUCommandBuffer *cmd;
  SDL_GPURenderPass *pass;
  bool need_clear;   /* true after (re)creating target_tex */
} GpuWindowState;

/*----------------------------------------------------------------------------
 * Glyph atlas GPU texture management
 *
 * CPU surfaces (in renderer.c GlyphAtlas) are mirrored to GPU textures.
 * When a glyph is first rasterized, renderer.c calls gpu_atlas_mark_dirty().
 * At gpu_end_frame, all dirty regions are uploaded (with pixel format
 * conversion) in copy passes before the render pass begins.
 *
 * Format mapping (SDL_gpu has no R8G8B8, so LCD/color expand to RGBA):
 *   Grayscale (INDEX8, 1B/px) -> R8_UNORM        (direct copy)
 *   Subpixel  (RGB24,  3B/px) -> R8G8B8A8_UNORM  (RGB->RGBA, A=255)
 *   Color     (BGRA32, 4B/px) -> R8G8B8A8_UNORM  (BGRA->RGBA, swap R/B)
 *--------------------------------------------------------------------------*/
typedef struct {
  void *tex;          /* SDL_GPUTexture* */
  SDL_Surface *surf;  /* CPU source surface */
  SDL_Rect dirty;     /* merged dirty region in surf coordinates */
  int fmt;            /* 0=grayscale, 1=subpixel, 2=color */
} AtlasUpload;

static AtlasUpload *g_uploads = NULL;
static int g_upload_count = 0, g_upload_cap = 0;

/* Transfer buffer for atlas uploads (grown as needed). */
static SDL_GPUTransferBuffer *g_atlas_xfer = NULL;
static Uint32 g_atlas_xfer_size = 0;

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

/* Performance counters (set in gpu_init; LITE_GPU_STATS=1 for per-frame). */
static Uint64 g_perf_freq = 0;
static bool   g_perf_verbose = false;
static Uint64 g_perf_sum_ns = 0;
static Uint64 g_perf_min_ns = 0;
static Uint64 g_perf_max_ns = 0;
static Uint64 g_frame_start = 0;
static int    g_uploads_last = 0;

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

static SDL_GPUGraphicsPipeline *make_text_pipeline(void) {
  /* Same vertex layout as rect (float2 pos + float2 texcoord, 16 bytes).
   * Blend is ENABLED with premultiplied alpha: the fragment shader outputs
   *   (color.rgb * coverage, coverage)
   * so the colour source factor must be ONE -- SRC_ALPHA would multiply the
   * coverage in a second time (color.rgb * coverage^2), which washes out
   * every antialiased edge.  With ONE:
   *   result = src + dst * (1 - src.a)
   *          = color.rgb * coverage + dst.rgb * (1 - coverage)
   * which matches the CPU grayscale formula exactly.  The rect pipeline keeps
   * SRC_ALPHA because lite_rect_fragment outputs straight alpha. */
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
  blend.enable_blend = true;  /* premultiplied alpha: colour factor is ONE */
  blend.src_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE;
  blend.dst_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
  blend.color_blend_op = SDL_GPU_BLENDOP_ADD;
  blend.src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE;
  blend.dst_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
  blend.alpha_blend_op = SDL_GPU_BLENDOP_ADD;
  blend.enable_color_write_mask = false;

  SDL_GPUGraphicsPipelineCreateInfo ci = {0};
  ci.vertex_shader = g_ctx.text_vs;
  ci.fragment_shader = g_ctx.text_fs;
  ci.vertex_input_state.vertex_buffer_descriptions = &vbuf_desc;
  ci.vertex_input_state.num_vertex_buffers = 1;
  ci.vertex_input_state.vertex_attributes = attrs;
  ci.vertex_input_state.num_vertex_attributes = 2;
  ci.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
  ci.rasterizer_state = (SDL_GPURasterizerState){
    .fill_mode = SDL_GPU_FILLMODE_FILL,
    .cull_mode = SDL_GPU_CULLMODE_NONE,
  };
  ci.multisample_state = (SDL_GPUMultisampleState){
    .sample_count = SDL_GPU_SAMPLECOUNT_1,
  };
  ci.target_info = (SDL_GPUGraphicsPipelineTargetInfo){0};
  SDL_GPUColorTargetDescription ctd = {0};
  ctd.format = SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;
  ctd.blend_state = blend;
  ci.target_info.color_target_descriptions = &ctd;
  ci.target_info.num_color_targets = 1;

  SDL_GPUGraphicsPipeline *p =
    SDL_CreateGPUGraphicsPipeline(g_ctx.device, &ci);
  if (!p)
    fprintf(stderr, "gpu: CreateGPUGraphicsPipeline(text) failed: %s\n",
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

  g_ctx.text_pipeline = make_text_pipeline();
  if (!g_ctx.text_pipeline) return false;

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

  g_perf_freq = SDL_GetPerformanceFrequency();
  g_perf_verbose = SDL_GetHintBoolean("LITE_GPU_STATS", false);

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
  if (g_atlas_xfer) { SDL_ReleaseGPUTransferBuffer(g_ctx.device, g_atlas_xfer); g_atlas_xfer = NULL; }
  g_atlas_xfer_size = 0;
  SDL_free(g_uploads); g_uploads = NULL; g_upload_count = g_upload_cap = 0;
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
  if (s->image_tex)   SDL_ReleaseGPUTexture(g_ctx.device, s->image_tex);
  /* last_img is a borrowed pointer (owned by rencache), just clear it. */
  s->last_img = NULL;
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
    s->need_clear = true;
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

static Uint32 g_frame_count = 0;

bool gpu_begin_frame(RenWindow *ren) {
  if (!g_ctx.device || !ren || !ren->gpu_state) return false;
  GpuWindowState *s = ren->gpu_state;

  RenSurface rs = renwin_get_surface(ren);
  int w = rs.surface->w, h = rs.surface->h;
  if (!ensure_resources(s, w, h)) { fprintf(stderr, "[gpu] begin_frame: ensure_resources FAILED\n"); return false; }

  g_frame_count++;
  g_frame_start = SDL_GetPerformanceCounter();
  if (g_frame_count == 1)
    fprintf(stderr, "[gpu] GPU render path active (Metal, %dx%d)\n", w, h);

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



void gpu_draw_rect(RenWindow *ren, RenRect rect, RenColor color,
                   RenRect clip) {
  GpuWindowState *s = ren->gpu_state;
  if (!s || !s->vbuf_mapped || !s->cmd) return;
  if (clip.width <= 0 || clip.height <= 0) return;
  if (s->vbuf_used + 4 > s->vbuf_capacity) return;

  /* rencache commands use logical (HiDPI-divided) coordinates; the GPU
   * render target is in physical pixels, so scale up. */
  RenSurface rs = renwin_get_surface(ren);
  int ss = rs.scale;

  /* Triangle strip quad: TL, BL, TR, BR (Y-down, top-left origin in pixels). */
  float x0 = (float)(rect.x * ss), y0 = (float)(rect.y * ss);
  float x1 = (float)((rect.x + rect.width) * ss), y1 = (float)((rect.y + rect.height) * ss);
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
  d->clip = (SDL_FRect){ (float)(clip.x * ss), (float)(clip.y * ss),
                         (float)(clip.width * ss), (float)(clip.height * ss) };
  d->funiform[0] = color.r / 255.0f;
  d->funiform[1] = color.g / 255.0f;
  d->funiform[2] = color.b / 255.0f;
  d->funiform[3] = color.a / 255.0f;
  d->texture = NULL;
}

/*----------------------------------------------------------------------------
 * Glyph atlas GPU texture management
 *--------------------------------------------------------------------------*/

static SDL_GPUTextureFormat atlas_gpu_format(int fmt) {
  switch (fmt) {
    case 0: return SDL_GPU_TEXTUREFORMAT_R8_UNORM;       /* grayscale */
    default: return SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM; /* LCD, color */
  }
}

void *gpu_atlas_create_texture(int w, int h, int fmt) {
  if (!g_ctx.device) return NULL;
  SDL_GPUTextureCreateInfo tci = {0};
  tci.type = SDL_GPU_TEXTURETYPE_2D;
  tci.format = atlas_gpu_format(fmt);
  tci.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
  tci.width = (Uint32)w;
  tci.height = (Uint32)h;
  tci.layer_count_or_depth = 1;
  tci.num_levels = 1;
  tci.sample_count = SDL_GPU_SAMPLECOUNT_1;
  SDL_GPUTexture *tex = SDL_CreateGPUTexture(g_ctx.device, &tci);
  if (!tex)
    fprintf(stderr, "gpu: atlas CreateGPUTexture failed: %s\n", SDL_GetError());
  return tex;
}

void gpu_atlas_destroy_texture(void *tex) {
  if (g_ctx.device && tex)
    SDL_ReleaseGPUTexture(g_ctx.device, (SDL_GPUTexture *)tex);
}

void gpu_atlas_mark_dirty(void *tex, SDL_Surface *surf,
                          int x, int y, int w, int h, int fmt) {
  if (!tex || !surf || w <= 0 || h <= 0) return;
  /* Find existing entry for this texture (merge dirty rect). */
  for (int i = 0; i < g_upload_count; i++) {
    if (g_uploads[i].tex == tex) {
      SDL_Rect *d = &g_uploads[i].dirty;
      int x0 = d->x < x ? d->x : x;
      int y0 = d->y < y ? d->y : y;
      int x1 = (d->x + d->w) > (x + w) ? (d->x + d->w) : (x + w);
      int y1 = (d->y + d->h) > (y + h) ? (d->y + d->h) : (y + h);
      d->x = x0; d->y = y0; d->w = x1 - x0; d->h = y1 - y0;
      return;
    }
  }
  if (g_upload_count == g_upload_cap) {
    int nc = g_upload_cap ? g_upload_cap * 2 : 32;
    AtlasUpload *nd = SDL_realloc(g_uploads, nc * sizeof(AtlasUpload));
    if (!nd) return;
    g_uploads = nd;
    g_upload_cap = nc;
  }
  g_uploads[g_upload_count].tex = tex;
  g_uploads[g_upload_count].surf = surf;
  g_uploads[g_upload_count].dirty = (SDL_Rect){ x, y, w, h };
  g_uploads[g_upload_count].fmt = fmt;
  g_upload_count++;
}

/* Copy a dirty region from the CPU surface to the transfer buffer,
 * converting pixel format as needed. dst is RGBA32 (4 B/px) or R8 (1 B/px)
 * depending on the GPU texture format. */
static void copy_atlas_region(Uint8 *dst, int dst_pitch,
                              SDL_Surface *surf, const SDL_Rect *r, int fmt) {
  const Uint8 *src = (const Uint8 *)surf->pixels;
  int src_pitch = surf->pitch;
  if (fmt == 0) {
    /* Grayscale: INDEX8 surface, R8 GPU texture — 1:1 byte copy */
    for (int y = 0; y < r->h; y++) {
      const Uint8 *s = src + (r->y + y) * src_pitch + r->x;
      SDL_memcpy(dst + y * dst_pitch, s, (size_t)r->w);
    }
  } else if (fmt == 1) {
    /* Subpixel LCD: RGB24 surface (3 B/px) -> RGBA32 (4 B/px), A=255 */
    for (int y = 0; y < r->h; y++) {
      const Uint8 *s = src + (r->y + y) * src_pitch + r->x * 3;
      Uint8 *d = dst + y * dst_pitch;
      for (int x = 0; x < r->w; x++) {
        d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 255;
        s += 3; d += 4;
      }
    }
  } else {
    /* Color emoji: BGRA32 surface -> RGBA32, swap R and B */
    for (int y = 0; y < r->h; y++) {
      const Uint8 *s = src + (r->y + y) * src_pitch + r->x * 4;
      Uint8 *d = dst + y * dst_pitch;
      for (int x = 0; x < r->w; x++) {
        d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = s[3];
        s += 4; d += 4;
      }
    }
  }
}

/* Upload all pending dirty atlas regions. Called from gpu_end_frame before
 * the render pass. Each dirty entry gets its own transfer buffer (small,
 * transient — only new glyphs per frame). */
static void flush_atlas_uploads(SDL_GPUCommandBuffer *cmd) {
  if (g_upload_count == 0) return;
  SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(cmd);
  if (!cp) { g_upload_count = 0; return; }
  for (int i = 0; i < g_upload_count; i++) {
    AtlasUpload *u = &g_uploads[i];
    int bpp = (u->fmt == 0) ? 1 : 4;
    Uint32 size = (Uint32)(u->dirty.w * u->dirty.h * bpp);
    /* Grow the shared atlas transfer buffer if needed. */
    if (size > g_atlas_xfer_size) {
      if (g_atlas_xfer) SDL_ReleaseGPUTransferBuffer(g_ctx.device, g_atlas_xfer);
      SDL_GPUTransferBufferCreateInfo bci = {0};
      bci.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
      bci.size = size;
      g_atlas_xfer = SDL_CreateGPUTransferBuffer(g_ctx.device, &bci);
      g_atlas_xfer_size = size;
      if (!g_atlas_xfer) { g_atlas_xfer_size = 0; continue; }
    }
    Uint8 *mapped = SDL_MapGPUTransferBuffer(g_ctx.device, g_atlas_xfer, true);
    if (mapped) {
      copy_atlas_region(mapped, u->dirty.w * bpp, u->surf, &u->dirty, u->fmt);
      SDL_UnmapGPUTransferBuffer(g_ctx.device, g_atlas_xfer);
    }
    SDL_GPUTextureTransferInfo tsrc = {0};
    tsrc.transfer_buffer = g_atlas_xfer;
    tsrc.offset = 0;
    tsrc.pixels_per_row = (Uint32)u->dirty.w;
    tsrc.rows_per_layer = (Uint32)u->dirty.h;
    SDL_GPUTextureRegion tdst = {0};
    tdst.texture = (SDL_GPUTexture *)u->tex;
    tdst.x = (Uint32)u->dirty.x;
    tdst.y = (Uint32)u->dirty.y;
    tdst.w = (Uint32)u->dirty.w;
    tdst.h = (Uint32)u->dirty.h;
    tdst.d = 1;
    SDL_UploadToGPUTexture(cp, &tsrc, &tdst, false);
  }
  SDL_EndGPUCopyPass(cp);
  g_uploads_last = g_upload_count;
  g_upload_count = 0;
}

void gpu_draw_text_quads(RenWindow *ren, void *tex,
                         const GpuTextVertex *verts, int vert_count,
                         RenColor color, int mode, RenRect clip) {
  GpuWindowState *s = ren->gpu_state;
  if (!s || !s->vbuf_mapped || !s->cmd || !tex || vert_count <= 0) return;
  if (clip.width <= 0 || clip.height <= 0) return;
  if (s->vbuf_used + (Uint32)vert_count > s->vbuf_capacity) return;

  GpuVertex *v = &s->vbuf_mapped[s->vbuf_used];
  for (int i = 0; i < vert_count; i++) {
    v[i] = (GpuVertex){ verts[i].x, verts[i].y, verts[i].u, verts[i].v };
  }
  Uint32 off = s->vbuf_used;
  s->vbuf_used += vert_count;

  GpuDrawCmd *d = push_draw(s);
  if (!d) return;
  d->kind = GPU_DRAW_TEXT;
  d->vert_offset = off;
  d->vert_count = (Uint32)vert_count;
  d->clip = (SDL_FRect){ (float)clip.x, (float)clip.y,
                         (float)clip.width, (float)clip.height };
  d->funiform[0] = color.r / 255.0f;
  d->funiform[1] = color.g / 255.0f;
  d->funiform[2] = color.b / 255.0f;
  d->funiform[3] = color.a / 255.0f;
  d->funiform[4] = (float)mode;
  d->funiform[5] = 0;
  d->funiform[6] = 0;
  d->funiform[7] = 0;
  d->texture = tex;
}

/*----------------------------------------------------------------------------
 * Image drawing (DRAW_IMAGE)
 *
 * Converts the SDL_Surface to RGBA32, uploads to a cached GPU texture
 * (grown on demand), and draws a textured quad using the text pipeline in
 * color mode (mode=2, white tint) → standard SRC-over alpha blend, matching
 * the CPU path's SDL_BlitSurface(BLEND) semantics.
 *--------------------------------------------------------------------------*/
void gpu_draw_image(RenWindow *ren, SDL_Surface *img,
                    RenRect rect, RenRect clip) {
  GpuWindowState *s = ren->gpu_state;
  if (!s || !s->vbuf_mapped || !s->cmd || !img) return;
  if (rect.width <= 0 || rect.height <= 0) return;
  if (clip.width <= 0 || clip.height <= 0) return;
  if (s->vbuf_used + 6 > s->vbuf_capacity) return;

  RenSurface rs = renwin_get_surface(ren);
  int ss = rs.scale;
  int dw = rect.width * ss, dh = rect.height * ss;
  int iw = img->w, ih = img->h;

  /* Upload only when the surface pointer changes. rencache reuses the
   * same SDL_Surface object across frames, so pointer equality means the
   * image content hasn't changed and we can skip the convert+upload. */
  if (img != s->last_img) {
    SDL_Surface *rgba = SDL_ConvertSurface(img, SDL_PIXELFORMAT_RGBA32);
    if (!rgba) return;
    iw = rgba->w; ih = rgba->h;
    if (iw <= 0 || ih <= 0) { SDL_DestroySurface(rgba); return; }

    /* Ensure the cached image texture is large enough (grow-only). */
    if (!s->image_tex || s->image_tex_w < iw || s->image_tex_h < ih) {
      if (s->image_tex) SDL_ReleaseGPUTexture(g_ctx.device, s->image_tex);
      SDL_GPUTextureCreateInfo tci = {0};
      tci.type = SDL_GPU_TEXTURETYPE_2D;
      tci.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
      tci.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
      tci.width = iw; tci.height = ih;
      tci.layer_count_or_depth = 1;
      tci.num_levels = 1;
      tci.sample_count = SDL_GPU_SAMPLECOUNT_1;
      s->image_tex = SDL_CreateGPUTexture(g_ctx.device, &tci);
      s->image_tex_w = iw;
      s->image_tex_h = ih;
    }
    if (!s->image_tex) { SDL_DestroySurface(rgba); return; }

    /* Upload image data via the shared atlas transfer buffer. */
    Uint32 size = (Uint32)(iw * ih) * 4;
    if (size > g_atlas_xfer_size) {
      if (g_atlas_xfer) SDL_ReleaseGPUTransferBuffer(g_ctx.device, g_atlas_xfer);
      SDL_GPUTransferBufferCreateInfo bci = {0};
      bci.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
      bci.size = size;
      g_atlas_xfer = SDL_CreateGPUTransferBuffer(g_ctx.device, &bci);
      g_atlas_xfer_size = size;
      if (!g_atlas_xfer) { g_atlas_xfer_size = 0; SDL_DestroySurface(rgba); return; }
    }
    Uint8 *mapped = SDL_MapGPUTransferBuffer(g_ctx.device, g_atlas_xfer, true);
    if (mapped) {
      int row_bytes = iw * 4;
      if (rgba->pitch == row_bytes) {
        SDL_memcpy(mapped, rgba->pixels, (size_t)row_bytes * ih);
      } else {
        Uint8 *d = mapped; const Uint8 *p = rgba->pixels;
        for (int y = 0; y < ih; y++) {
          SDL_memcpy(d, p, row_bytes);
          d += row_bytes; p += rgba->pitch;
        }
      }
      SDL_UnmapGPUTransferBuffer(g_ctx.device, g_atlas_xfer);
    }
    SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(s->cmd);
    if (cp) {
      SDL_GPUTextureTransferInfo tsrc = {0};
      tsrc.transfer_buffer = g_atlas_xfer;
      tsrc.offset = 0;
      tsrc.pixels_per_row = (Uint32)iw;
      tsrc.rows_per_layer = (Uint32)ih;
      SDL_GPUTextureRegion tdst = {0};
      tdst.texture = s->image_tex;
      tdst.w = (Uint32)iw;
      tdst.h = (Uint32)ih;
      tdst.d = 1;
      SDL_UploadToGPUTexture(cp, &tsrc, &tdst, false);
      SDL_EndGPUCopyPass(cp);
    }
    SDL_DestroySurface(rgba);
    s->last_img = img;
  }
  if (!s->image_tex) return;

  /* Push a textured quad. UV maps the sub-region used (image may be smaller
   * than the cached texture). Text pipeline color mode = standard blend.
   * Triangle list: 6 verts (TL,BL,TR + TR,BL,BR). */
  float x0 = (float)(rect.x * ss), y0 = (float)(rect.y * ss);
  float x1 = x0 + dw, y1 = y0 + dh;
  float umax = (float)iw / s->image_tex_w;
  float vmax = (float)ih / s->image_tex_h;
  GpuVertex *v = &s->vbuf_mapped[s->vbuf_used];
  v[0] = (GpuVertex){ x0, y0, 0, 0 };
  v[1] = (GpuVertex){ x0, y1, 0, vmax };
  v[2] = (GpuVertex){ x1, y0, umax, 0 };
  v[3] = (GpuVertex){ x1, y0, umax, 0 };
  v[4] = (GpuVertex){ x0, y1, 0, vmax };
  v[5] = (GpuVertex){ x1, y1, umax, vmax };
  Uint32 off = s->vbuf_used;
  s->vbuf_used += 6;

  GpuDrawCmd *d = push_draw(s);
  if (!d) return;
  d->kind = GPU_DRAW_TEXT;  /* reuse text pipeline (color mode) */
  d->vert_offset = off;
  d->vert_count = 6;
  d->clip = (SDL_FRect){ (float)(clip.x * ss), (float)(clip.y * ss),
                         (float)(clip.width * ss), (float)(clip.height * ss) };
  d->funiform[0] = 1.0f;  /* white tint */
  d->funiform[1] = 1.0f;
  d->funiform[2] = 1.0f;
  d->funiform[3] = 1.0f;
  d->funiform[4] = 2.0f;  /* mode = color */
  d->funiform[5] = 0;
  d->funiform[6] = 0;
  d->funiform[7] = 0;
  d->texture = s->image_tex;
}

void gpu_end_frame(RenWindow *ren) {
  GpuWindowState *s = ren->gpu_state;
  if (!s || !s->cmd) return;

  /* Unmap the vertex transfer buffer (verts are all written by now). */
  if (s->vbuf_mapped) {
    SDL_UnmapGPUTransferBuffer(g_ctx.device, s->vbuf_xfer);
    s->vbuf_mapped = NULL;
  }

  /* 1. Upload dirty glyph atlas regions (new glyphs rasterized this frame). */
  flush_atlas_uploads(s->cmd);

  /* 2. Grow the GPU vertex buffer if needed. */
  Uint32 vert_bytes = s->vbuf_used * sizeof(GpuVertex);
  if (vert_bytes > 0 && (!s->vbuf_gpu || s->vbuf_gpu_size < vert_bytes)) {
    if (s->vbuf_gpu) SDL_ReleaseGPUBuffer(g_ctx.device, s->vbuf_gpu);
    /* Grow with 2x strategy from an initial 64 KB (4096 verts) to avoid
     * recreating the GPU buffer every time the vert count fluctuates. */
    Uint32 alloc = s->vbuf_gpu_size ? s->vbuf_gpu_size : 4096 * sizeof(GpuVertex);
    while (alloc < vert_bytes) alloc *= 2;
    if (alloc > VBUF_MAX_VERTS * sizeof(GpuVertex))
      alloc = VBUF_MAX_VERTS * sizeof(GpuVertex);
    SDL_GPUBufferCreateInfo bci = {0};
    bci.usage = SDL_GPU_BUFFERUSAGE_VERTEX;
    bci.size = alloc;
    s->vbuf_gpu = SDL_CreateGPUBuffer(g_ctx.device, &bci);
    s->vbuf_gpu_size = alloc;
  }

  /* 3. Copy pass: upload verts -> GPU vertex buffer. */
  if (vert_bytes > 0 && s->vbuf_gpu) {
    SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(s->cmd);
    if (cp) {
      SDL_GPUTransferBufferLocation bsrc = {0};
      bsrc.transfer_buffer = s->vbuf_xfer;
      bsrc.offset = 0;
      SDL_GPUBufferRegion bdst = {0};
      bdst.buffer = s->vbuf_gpu;
      bdst.offset = 0;
      bdst.size = vert_bytes;
      SDL_UploadToGPUBuffer(cp, &bsrc, &bdst, true);
      SDL_EndGPUCopyPass(cp);
    }
  }

  /* 4. Render pass on the target texture.
   *    - First frame after (re)create: CLEAR to black, then draw everything.
   *    - Subsequent frames: LOAD (preserve previous content for dirty-rect
   *      incremental redraw + framebuffer fetch in text shader). */
  {
    SDL_GPUColorTargetInfo tgt = {0};
    tgt.texture = s->target_tex;
    tgt.load_op = s->need_clear ? SDL_GPU_LOADOP_CLEAR : SDL_GPU_LOADOP_LOAD;
    tgt.store_op = SDL_GPU_STOREOP_STORE;
    tgt.clear_color = (SDL_FColor){0, 0, 0, 1};
    tgt.cycle = false;
    s->need_clear = false;
    s->pass = SDL_BeginGPURenderPass(s->cmd, &tgt, 1, NULL);
  }

  if (s->pass && s->vbuf_gpu && s->draws_count > 0) {
    SDL_GPUBufferBinding bind = {0};
    bind.buffer = s->vbuf_gpu;
    bind.offset = 0;
    SDL_BindGPUVertexBuffers(s->pass, 0, &bind, 1);

    float vuniform[4] = { (float)s->target_w, (float)s->target_h, 0, 0 };
    SDL_PushGPUVertexUniformData(s->cmd, 0, vuniform, sizeof(vuniform));

    for (Uint32 i = 0; i < s->draws_count; i++) {
      GpuDrawCmd *d = &s->draws[i];
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
      } else if (d->kind == GPU_DRAW_TEXT && d->texture) {
        SDL_BindGPUGraphicsPipeline(s->pass, g_ctx.text_pipeline);
        SDL_GPUTextureSamplerBinding tsb = {0};
        tsb.texture = (SDL_GPUTexture *)d->texture;
        tsb.sampler = g_ctx.atlas_sampler;
        SDL_BindGPUFragmentSamplers(s->pass, 0, &tsb, 1);
        SDL_PushGPUFragmentUniformData(s->cmd, 0, d->funiform, sizeof(d->funiform));
        SDL_DrawGPUPrimitives(s->pass, d->vert_count, 1, d->vert_offset, 0);
      }
    }
  }
  if (s->pass) { SDL_EndGPURenderPass(s->pass); s->pass = NULL; }

  /* 5. Blit render target -> swapchain. */
  SDL_GPUTexture *swapchain = NULL;
  Uint32 sw = 0, sh = 0;
  bool got = SDL_WaitAndAcquireGPUSwapchainTexture(s->cmd, ren->window, &swapchain,
                                             &sw, &sh);
  if (!got) {
    fprintf(stderr, "[gpu] end_frame: AcquireSwapchain FAILED: %s\n", SDL_GetError());
  } else if (!swapchain) {
    /* Window minimized — not an error, cancel is automatic on submit. */
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
  if (g_perf_freq) {
    Uint64 dt = SDL_GetPerformanceCounter() - g_frame_start;
    Uint64 ns = dt * 1000000000ULL / g_perf_freq;
    g_perf_sum_ns += ns;
    if (ns < g_perf_min_ns || g_perf_min_ns == 0) g_perf_min_ns = ns;
    if (ns > g_perf_max_ns) g_perf_max_ns = ns;
    if (g_perf_verbose)
      fprintf(stderr, "[gpu] frame %u: %.3f ms | draws=%u verts=%u uploads=%d\n",
              g_frame_count, ns / 1000000.0, s->draws_count, s->vbuf_used,
              g_uploads_last);
  }
  if ((g_frame_count % 300) == 0) {
    double avg = g_perf_freq ? (double)g_perf_sum_ns / 300.0 / 1000000.0 : 0;
    double mn = g_perf_min_ns / 1000000.0;
    double mx = g_perf_max_ns / 1000000.0;
    fprintf(stderr, "[gpu] %u frames | draws=%u verts=%u uploads=%d | "
            "frame avg=%.2f min=%.2f max=%.2f ms\n",
            g_frame_count, s->draws_count, s->vbuf_used, g_uploads_last,
            avg, mn, mx);
    g_perf_sum_ns = 0; g_perf_min_ns = 0; g_perf_max_ns = 0;
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

  /* Lazily create the surface upload transfer buffer (fallback path only). */
  Uint32 surf_bytes = (Uint32)(w * h) * 4;
  if (!s->surf_xfer || s->surf_xfer_size < surf_bytes) {
    if (s->surf_xfer) SDL_ReleaseGPUTransferBuffer(g_ctx.device, s->surf_xfer);
    SDL_GPUTransferBufferCreateInfo sbci = {0};
    sbci.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    sbci.size = surf_bytes;
    s->surf_xfer = SDL_CreateGPUTransferBuffer(g_ctx.device, &sbci);
    s->surf_xfer_size = s->surf_xfer ? surf_bytes : 0;
    if (!s->surf_xfer) { SDL_SubmitGPUCommandBuffer(cmd); return false; }
  }

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
