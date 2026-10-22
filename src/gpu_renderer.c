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
#include <stdlib.h>

#include "gpu_renderer.h"
#include "renwindow.h"

/* Embed the MSL source. SDL_gpu Metal backend compiles it at runtime. */
#include "gpu_shaders_msl.h"

#ifdef LITE_USE_GPU_RENDERER

/*----------------------------------------------------------------------------
 * Types
 *--------------------------------------------------------------------------*/

/* A streamed vertex. position in pixels; texcoord for text (unused for rect).
 * `color` is a packed RGBA8 tint read only by the text pipeline (per-vertex,
 * so differently-coloured text runs merge into one draw); rect/rrect ignore
 * it. `tex_index` selects the atlas texture array slot (glyph path only).
 * 24-byte stride (16 + packed u8x4 + u32). */
typedef struct {
  float x, y;    /* position (pixels, top-left origin) */
  float u, v;    /* texcoord (0..1); rrect carries local pixel coords here */
  Uint32 color;  /* packed RGBA8 tint: r | g<<8 | b<<16 | a<<24 */
  Uint32 tex_index; /* atlas texture array index (glyph path) */
} GpuVertex;

/* Pack an RGBA8 tint into the byte order UBYTE4_NORM expects (R in the low
 * byte, A in the high byte) so the shader reads float4(r,g,b,a)/255. */
static Uint32 pack_rgba(Uint8 r, Uint8 g, Uint8 b, Uint8 a) {
  return (Uint32)r | ((Uint32)g << 8) | ((Uint32)b << 16) | ((Uint32)a << 24);
}

/* Number of atlas textures bound as an array for glyph rendering. Must match
 * GPU_ATLAS_COUNT in gpu_shaders.msl. */
#define GPU_ATLAS_COUNT 16

/* Atlas texture registry: each GPU atlas surface gets a stable slot index into
 * the bound texture array (see glyph shader). Textures are registered on
 * create and unregistered on destroy; slot index == array index. */
static SDL_GPUTexture *g_atlas_textures[GPU_ATLAS_COUNT];
static int g_atlas_texture_count = 0;

static int atlas_texture_index(SDL_GPUTexture *tex) {
  for (int i = 0; i < g_atlas_texture_count; i++)
    if (g_atlas_textures[i] == tex) return i;
  return -1;
}

/* A deferred draw command. We collect these during the frame (while the
 * vertex transfer buffer is mapped) and replay them inside the render pass in
 * gpu_end_frame, after uploading all verts + dirty atlas regions in one or
 * more copy passes. This is necessary because SDL_gpu forbids beginning a
 * copy pass while a render pass is active. */
typedef enum {
  GPU_DRAW_RECT,
  GPU_DRAW_RRECT,
  GPU_DRAW_TEXT,   /* glyphs: texture array, per-vertex tex_index */
  GPU_DRAW_IMAGE,  /* single texture (colour mode) */
} GpuDrawKind;

typedef struct {
  GpuDrawKind kind;
  Uint32 vert_offset;  /* index into the vertex transfer buffer */
  Uint32 vert_count;
  SDL_FRect clip;      /* scissor in pixels (0,0,0,0 = full target) */
  float funiform[8];   /* fragment uniform: rect={color.rgba,_,_,_,_},
                        * rrect={color.rgba, radius, width, height, _},
                        * text/image={_,_,_,_, mode.x,0,0,0} */
  void *texture;       /* SDL_GPUTexture* for image; NULL for glyph/rect */
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

  /* Staging buffer for DRAW_IMAGE.  Deliberately separate from the glyph
   * upload buffer: resizing a transfer buffer retires it, and a blit recorded
   * earlier in the same frame would then be reading memory it no longer owns.
   * Two buffers mean the image path and the atlas path can never do that to
   * each other. */
  SDL_GPUTransferBuffer *image_xfer;
  Uint32 image_xfer_size;

  /* Cached texture for DRAW_IMAGE (grown if a larger image is drawn).
   * The cache key is the surface plus the pixel buffer it owns and its size,
   * so an entry can never be reused for a different image that happens to be
   * allocated at the same address (see gpu_draw_image). */
  SDL_GPUTexture *image_tex;
  int image_tex_w, image_tex_h;
  SDL_Surface *last_img;
  void *last_img_pixels;
  int last_img_w, last_img_h;

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
/* Byte offset of each upload in the staging buffer; sized to g_upload_count
 * (a fixed 64-slot stack array silently dropped glyphs past 64 per frame). */
static Uint32 *g_upload_offsets = NULL;
static int g_upload_offsets_cap = 0;

/* Transfer buffer for atlas uploads (grown as needed). */
static SDL_GPUTransferBuffer *g_atlas_xfer = NULL;
static Uint32 g_atlas_xfer_size = 0;

/* Shared, device-wide resources (created once in gpu_init). */
typedef struct {
  SDL_GPUDevice *device;
  SDL_GPUShader *rect_vs, *rect_fs;
  SDL_GPUShader *rrect_vs, *rrect_fs;
  SDL_GPUShader *glyph_vs, *glyph_fs;
  SDL_GPUShader *image_vs, *image_fs;
  SDL_GPUGraphicsPipeline *rect_pipeline;
  SDL_GPUGraphicsPipeline *rrect_pipeline;
  SDL_GPUGraphicsPipeline *glyph_pipeline;
  SDL_GPUGraphicsPipeline *image_pipeline;
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
  /* Vertex layout: float2 position, float2 texcoord, u8x4 color = 20 bytes.
   * (rect shader only reads position + color, but sharing the layout with
   * text lets us reuse one vertex buffer.) */
  static const SDL_GPUVertexBufferDescription vbuf_desc = {
    .slot = 0,
    .pitch = sizeof(GpuVertex),
    .input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX,
    .instance_step_rate = 0,
  };
  static const SDL_GPUVertexAttribute attrs[3] = {
    { .location = 0, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 },
    { .location = 1, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 },
    { .location = 2, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = 16 },
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
  ci.vertex_input_state.num_vertex_attributes = 3;
  ci.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
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

static SDL_GPUGraphicsPipeline *make_rrect_pipeline(void) {
  /* Same vertex layout as rect/text (16 bytes: float2 position + float2).
   * Blend is premultiplied-output (colour factor ONE) because the SDF
   * fragment outputs (color.rgb * coverage, coverage), exactly like the
   * text pipeline -- otherwise antialiased edges would wash out. */
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
  blend.src_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE;
  blend.dst_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
  blend.color_blend_op = SDL_GPU_BLENDOP_ADD;
  blend.src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE;
  blend.dst_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
  blend.alpha_blend_op = SDL_GPU_BLENDOP_ADD;
  blend.enable_color_write_mask = false;

  SDL_GPUGraphicsPipelineCreateInfo ci = {0};
  ci.vertex_shader = g_ctx.rrect_vs;
  ci.fragment_shader = g_ctx.rrect_fs;
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
  ci.target_info = (SDL_GPUGraphicsPipelineTargetInfo){0};
  SDL_GPUColorTargetDescription ctd = {0};
  ctd.format = SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;
  ctd.blend_state = blend;
  ci.target_info.color_target_descriptions = &ctd;
  ci.target_info.num_color_targets = 1;

  SDL_GPUGraphicsPipeline *p =
    SDL_CreateGPUGraphicsPipeline(g_ctx.device, &ci);
  if (!p)
    fprintf(stderr, "gpu: CreateGPUGraphicsPipeline(rrect) failed: %s\n",
            SDL_GetError());
  return p;
}

static SDL_GPUGraphicsPipeline *make_glyph_pipeline(void) {
  /* Vertex layout: float2 pos + float2 texcoord + u8x4 color + u32 tex_index
   * = 24 bytes. Blend is premultiplied alpha (ONE / ONE_MINUS_SRC_ALPHA); the
   * fragment outputs (color.rgb * coverage, coverage). */
  static const SDL_GPUVertexBufferDescription vbuf_desc = {
    .slot = 0,
    .pitch = sizeof(GpuVertex),
    .input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX,
    .instance_step_rate = 0,
  };
  static const SDL_GPUVertexAttribute attrs[4] = {
    { .location = 0, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 },
    { .location = 1, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 },
    { .location = 2, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = 16 },
    { .location = 3, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_UINT, .offset = 20 },
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
  ci.vertex_shader = g_ctx.glyph_vs;
  ci.fragment_shader = g_ctx.glyph_fs;
  ci.vertex_input_state.vertex_buffer_descriptions = &vbuf_desc;
  ci.vertex_input_state.num_vertex_buffers = 1;
  ci.vertex_input_state.vertex_attributes = attrs;
  ci.vertex_input_state.num_vertex_attributes = 4;
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
    fprintf(stderr, "gpu: CreateGPUGraphicsPipeline(glyph) failed: %s\n",
            SDL_GetError());
  return p;
}

static SDL_GPUGraphicsPipeline *make_image_pipeline(void) {
  /* Same vertex layout minus tex_index (3 attributes, 24-byte stride shared
   * with the glyph pipeline). Single texture, colour mode, premultiplied. */
  static const SDL_GPUVertexBufferDescription vbuf_desc = {
    .slot = 0,
    .pitch = sizeof(GpuVertex),
    .input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX,
    .instance_step_rate = 0,
  };
  static const SDL_GPUVertexAttribute attrs[3] = {
    { .location = 0, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 },
    { .location = 1, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 },
    { .location = 2, .buffer_slot = 0,
      .format = SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = 16 },
  };
  SDL_GPUColorTargetBlendState blend = {0};
  blend.enable_blend = true;
  blend.src_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE;
  blend.dst_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
  blend.color_blend_op = SDL_GPU_BLENDOP_ADD;
  blend.src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE;
  blend.dst_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
  blend.alpha_blend_op = SDL_GPU_BLENDOP_ADD;
  blend.enable_color_write_mask = false;

  SDL_GPUGraphicsPipelineCreateInfo ci = {0};
  ci.vertex_shader = g_ctx.image_vs;
  ci.fragment_shader = g_ctx.image_fs;
  ci.vertex_input_state.vertex_buffer_descriptions = &vbuf_desc;
  ci.vertex_input_state.num_vertex_buffers = 1;
  ci.vertex_input_state.vertex_attributes = attrs;
  ci.vertex_input_state.num_vertex_attributes = 3;
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
    fprintf(stderr, "gpu: CreateGPUGraphicsPipeline(image) failed: %s\n",
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

  /* Every failure past this point must release what was created: ren_create
   * attaches the window whenever g_ctx.device is set, so a half-initialised
   * context would run the GPU path with NULL pipelines.  gpu_free() zeroes
   * g_ctx, which sends the window back to the CPU renderer instead. */
#define GPU_INIT_FAIL() do { gpu_free(); return false; } while (0)

  /* Compile shaders from embedded MSL source. */
  size_t code_size = sizeof(gpu_shaders_msl); /* includes trailing NUL */
  g_ctx.rect_vs = create_shader_named(SDL_GPU_SHADERSTAGE_VERTEX,
    "lite_rect_vertex", gpu_shaders_msl, code_size, 0, 1);
  g_ctx.rect_fs = create_shader_named(SDL_GPU_SHADERSTAGE_FRAGMENT,
    "lite_rect_fragment", gpu_shaders_msl, code_size, 0, 0);
  g_ctx.rrect_vs = create_shader_named(SDL_GPU_SHADERSTAGE_VERTEX,
    "lite_rrect_vertex", gpu_shaders_msl, code_size, 0, 1);
  g_ctx.rrect_fs = create_shader_named(SDL_GPU_SHADERSTAGE_FRAGMENT,
    "lite_rrect_fragment", gpu_shaders_msl, code_size, 0, 1);
  g_ctx.glyph_vs = create_shader_named(SDL_GPU_SHADERSTAGE_VERTEX,
    "lite_glyph_vertex", gpu_shaders_msl, code_size, 0, 1);
  g_ctx.glyph_fs = create_shader_named(SDL_GPU_SHADERSTAGE_FRAGMENT,
    "lite_glyph_fragment", gpu_shaders_msl, code_size, GPU_ATLAS_COUNT, 0);
  g_ctx.image_vs = create_shader_named(SDL_GPU_SHADERSTAGE_VERTEX,
    "lite_image_vertex", gpu_shaders_msl, code_size, 0, 1);
  g_ctx.image_fs = create_shader_named(SDL_GPU_SHADERSTAGE_FRAGMENT,
    "lite_image_fragment", gpu_shaders_msl, code_size, 1, 0);

  if (!g_ctx.rect_vs || !g_ctx.rect_fs || !g_ctx.rrect_vs || !g_ctx.rrect_fs ||
      !g_ctx.glyph_vs || !g_ctx.glyph_fs || !g_ctx.image_vs || !g_ctx.image_fs) {
    fprintf(stderr, "gpu_init: shader compilation failed\n");
    GPU_INIT_FAIL();
  }

  g_ctx.rect_pipeline = make_rect_pipeline();
  if (!g_ctx.rect_pipeline) GPU_INIT_FAIL();

  g_ctx.rrect_pipeline = make_rrect_pipeline();
  if (!g_ctx.rrect_pipeline) GPU_INIT_FAIL();

  g_ctx.glyph_pipeline = make_glyph_pipeline();
  if (!g_ctx.glyph_pipeline) GPU_INIT_FAIL();

  g_ctx.image_pipeline = make_image_pipeline();
  if (!g_ctx.image_pipeline) GPU_INIT_FAIL();

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
    GPU_INIT_FAIL();
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
  if (g_ctx.rrect_pipeline) SDL_ReleaseGPUGraphicsPipeline(g_ctx.device, g_ctx.rrect_pipeline);
  if (g_ctx.glyph_pipeline) SDL_ReleaseGPUGraphicsPipeline(g_ctx.device, g_ctx.glyph_pipeline);
  if (g_ctx.image_pipeline) SDL_ReleaseGPUGraphicsPipeline(g_ctx.device, g_ctx.image_pipeline);
  if (g_ctx.atlas_sampler)  SDL_ReleaseGPUSampler(g_ctx.device, g_ctx.atlas_sampler);
  if (g_ctx.rect_vs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.rect_vs);
  if (g_ctx.rect_fs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.rect_fs);
  if (g_ctx.rrect_vs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.rrect_vs);
  if (g_ctx.rrect_fs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.rrect_fs);
  if (g_ctx.glyph_vs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.glyph_vs);
  if (g_ctx.glyph_fs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.glyph_fs);
  if (g_ctx.image_vs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.image_vs);
  if (g_ctx.image_fs) SDL_ReleaseGPUShader(g_ctx.device, g_ctx.image_fs);
  if (g_atlas_xfer) { SDL_ReleaseGPUTransferBuffer(g_ctx.device, g_atlas_xfer); g_atlas_xfer = NULL; }
  g_atlas_xfer_size = 0;
  SDL_free(g_uploads); g_uploads = NULL; g_upload_count = g_upload_cap = 0;
  SDL_free(g_upload_offsets); g_upload_offsets = NULL; g_upload_offsets_cap = 0;
  memset(g_atlas_textures, 0, sizeof(g_atlas_textures));
  g_atlas_texture_count = 0;
  SDL_DestroyGPUDevice(g_ctx.device);
  g_ctx.device = NULL;
  memset(&g_ctx, 0, sizeof(g_ctx));
}

/*----------------------------------------------------------------------------
 * Per-window state
 *--------------------------------------------------------------------------*/
static const Uint32 VBUF_MAX_VERTS = 1 << 20; /* 1M verts = ~16MB; a maximized
  window of long lines needs ~700k verts (110k glyphs x 6) and the overflow
  path silently dropped text batches, leaving selection rects over
  undrawn-looking "black" regions */

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
  s->last_img_pixels = NULL;
  if (s->vbuf_xfer)   SDL_ReleaseGPUTransferBuffer(g_ctx.device, s->vbuf_xfer);
  if (s->image_xfer)  SDL_ReleaseGPUTransferBuffer(g_ctx.device, s->image_xfer);
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
  /* vbuf_xfer is size-independent, keep it.  The image texture survives a
   * resize, but drop the cache key so the next draw re-uploads into it. */
  s->last_img = NULL;
  s->last_img_pixels = NULL;
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
  if (s->vbuf_used + 6 > s->vbuf_capacity) return;

  /* rencache commands use logical (HiDPI-divided) coordinates; the GPU
   * render target is in physical pixels, so scale up. */
  RenSurface rs = renwin_get_surface(ren);
  int ss = rs.scale;

  /* Triangle list quad (6 verts): TL, BL, TR + TR, BL, BR. We use a list,
   * not a strip, so merged quads stay disjoint — a strip would connect them
   * with degenerate diagonal triangles. */
  float x0 = (float)(rect.x * ss), y0 = (float)(rect.y * ss);
  float x1 = (float)((rect.x + rect.width) * ss), y1 = (float)((rect.y + rect.height) * ss);
  Uint32 packed = pack_rgba(color.r, color.g, color.b, color.a);

  float cx = (float)(clip.x * ss), cy = (float)(clip.y * ss);
  float cw = (float)(clip.width * ss), ch = (float)(clip.height * ss);
  GpuDrawCmd *last = (s->draws_count > 0) ? &s->draws[s->draws_count - 1] : NULL;
  bool merge = last && last->kind == GPU_DRAW_RECT &&
               last->clip.x == cx && last->clip.y == cy &&
               last->clip.w == cw && last->clip.h == ch;

  Uint32 off = s->vbuf_used;
  GpuVertex *v = &s->vbuf_mapped[off];
  v[0] = (GpuVertex){ x0, y0, 0, 0, packed };
  v[1] = (GpuVertex){ x0, y1, 0, 1, packed };
  v[2] = (GpuVertex){ x1, y0, 1, 0, packed };
  v[3] = (GpuVertex){ x1, y0, 1, 0, packed };
  v[4] = (GpuVertex){ x0, y1, 0, 1, packed };
  v[5] = (GpuVertex){ x1, y1, 1, 1, packed };
  s->vbuf_used = off + 6;

  if (merge) {
    last->vert_count += 6;
    return;
  }

  GpuDrawCmd *d = push_draw(s);
  if (!d) { s->vbuf_used = off; return; }
  d->kind = GPU_DRAW_RECT;
  d->vert_offset = off;
  d->vert_count = 6;
  d->clip = (SDL_FRect){ cx, cy, cw, ch };
  d->texture = NULL;
}

/* Solid-color rounded rectangle. `rect` and `clip` are in logical units
 * (scaled up internally, like gpu_draw_rect); `radius` too. The second
 * vertex attribute carries LOCAL pixel coordinates inside the quad, which
 * the SDF fragment shader needs to evaluate the distance to the border. */
void gpu_draw_rounded_rect(RenWindow *ren, RenRect rect, RenColor color,
                           int radius, RenRect clip) {
  GpuWindowState *s = ren->gpu_state;
  if (!s || !s->vbuf_mapped || !s->cmd) return;
  if (clip.width <= 0 || clip.height <= 0) return;
  if (s->vbuf_used + 4 > s->vbuf_capacity) return;

  RenSurface rs = renwin_get_surface(ren);
  int ss = rs.scale;

  float x0 = (float)(rect.x * ss), y0 = (float)(rect.y * ss);
  float x1 = (float)((rect.x + rect.width) * ss);
  float y1 = (float)((rect.y + rect.height) * ss);
  float w = x1 - x0, h = y1 - y0;
  if (w <= 0 || h <= 0) return;

  /* Triangle strip quad with local pixel coords in the uv slots. */
  GpuVertex *v = &s->vbuf_mapped[s->vbuf_used];
  v[0] = (GpuVertex){ x0, y0, 0, 0 };
  v[1] = (GpuVertex){ x0, y1, 0, h };
  v[2] = (GpuVertex){ x1, y0, w, 0 };
  v[3] = (GpuVertex){ x1, y1, w, h };
  Uint32 off = s->vbuf_used;
  s->vbuf_used += 4;

  GpuDrawCmd *d = push_draw(s);
  if (!d) { s->vbuf_used = off; return; }
  d->kind = GPU_DRAW_RRECT;
  d->vert_offset = off;
  d->vert_count = 4;
  d->clip = (SDL_FRect){ (float)(clip.x * ss), (float)(clip.y * ss),
                         (float)(clip.width * ss), (float)(clip.height * ss) };
  d->funiform[0] = color.r / 255.0f;
  d->funiform[1] = color.g / 255.0f;
  d->funiform[2] = color.b / 255.0f;
  d->funiform[3] = color.a / 255.0f;
  d->funiform[4] = (float)radius * (float)ss;
  d->funiform[5] = w;
  d->funiform[6] = h;
  d->funiform[7] = 0;
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
  if (!tex) {
    fprintf(stderr, "gpu: atlas CreateGPUTexture failed: %s\n", SDL_GetError());
    return NULL;
  }
  /* Register in the texture array. If the array is full the glyph path falls
   * back to a dedicated single-texture draw for this surface (see
   * gpu_draw_text_quads). */
  if (g_atlas_texture_count < GPU_ATLAS_COUNT)
    g_atlas_textures[g_atlas_texture_count++] = tex;
  return tex;
}

void gpu_atlas_destroy_texture(void *tex) {
  if (g_ctx.device && tex) {
    /* Compact the registry so the array stays dense (no NULL slots). Slot
     * indices are recomputed each frame, so shifting is safe. */
    for (int i = 0; i < g_atlas_texture_count; i++) {
      if (g_atlas_textures[i] == (SDL_GPUTexture *)tex) {
        for (int j = i; j < g_atlas_texture_count - 1; j++)
          g_atlas_textures[j] = g_atlas_textures[j + 1];
        g_atlas_texture_count--;
        break;
      }
    }
    SDL_ReleaseGPUTexture(g_ctx.device, (SDL_GPUTexture *)tex);
  }
}

/* Forget pending uploads that read from a surface the caller is about to
 * destroy (font_clear_glyph_cache).  A stale entry would be dereferenced the
 * next time the list is flushed. */
void gpu_atlas_forget_surface(SDL_Surface *surf) {
  int n = 0;
  for (int i = 0; i < g_upload_count; i++) {
    if (g_uploads[i].surf == surf) continue;
    g_uploads[n++] = g_uploads[i];
  }
  g_upload_count = n;
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

/* Grow-only (re)allocation of a staging transfer buffer.  Callers must run
 * this *before* recording any blit that reads the buffer: resizing retires the
 * old buffer, and a copy that is already sitting in this frame's command buffer
 * would then be reading memory that no longer belongs to it. */
static bool ensure_xfer(SDL_GPUTransferBuffer **buf, Uint32 *cap, Uint32 size) {
  if (*buf && *cap >= size) return true;
  Uint32 want = *cap > size ? *cap : size;   /* never shrink */
  if (*buf) {
    SDL_ReleaseGPUTransferBuffer(g_ctx.device, *buf);
    *buf = NULL;
  }
  SDL_GPUTransferBufferCreateInfo bci = {0};
  bci.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
  bci.size = want;
  *buf = SDL_CreateGPUTransferBuffer(g_ctx.device, &bci);
  *cap = *buf ? want : 0;
  return *buf != NULL;
}

/* Upload all pending dirty atlas regions. Called from gpu_end_frame before
 * the render pass. All regions are packed into the staging transfer buffer
 * at distinct byte offsets during a single map, and each recorded upload
 * reads its own offset: the GPU replays the copy pass only after the CPU has
 * finished filling the buffer, so entries must not share storage. Rows are
 * packed tightly (pitch = w * bpp) to match the pixels_per_row the GPU reads.
 * The pending list holds pointers borrowed from the font glyph caches, so it
 * is dropped as a whole if the upload cannot be set up at all rather than
 * kept across frames. */
static void flush_atlas_uploads(SDL_GPUCommandBuffer *cmd) {
  if (g_upload_count == 0) return;

  int n = g_upload_count;
  if (n > g_upload_offsets_cap) {
    Uint32 *nd = SDL_realloc(g_upload_offsets, (size_t)n * sizeof(Uint32));
    if (!nd) { g_upload_count = 0; return; }
    g_upload_offsets = nd;
    g_upload_offsets_cap = n;
  }
  Uint32 total = 0;
  for (int i = 0; i < n; i++) {
    int bpp = (g_uploads[i].fmt == 0) ? 1 : 4;
    Uint32 size = (Uint32)(g_uploads[i].dirty.w * g_uploads[i].dirty.h * bpp);
    size = (size + 3u) & ~3u;   /* Metal requires 4-byte-aligned offsets */
    if (total + size < total) { /* overflow */ n = i; break; }
    g_upload_offsets[i] = total;
    total += size;
  }

  if (!ensure_xfer(&g_atlas_xfer, &g_atlas_xfer_size, total)) {
    fprintf(stderr, "gpu: atlas staging buffer (%u bytes) failed: %s\n",
            (unsigned)total, SDL_GetError());
    g_upload_count = 0;
    return;
  }

  Uint8 *mapped = SDL_MapGPUTransferBuffer(g_ctx.device, g_atlas_xfer, true);
  if (!mapped) { g_upload_count = 0; return; }
  for (int i = 0; i < n; i++) {
    AtlasUpload *u = &g_uploads[i];
    int bpp = (u->fmt == 0) ? 1 : 4;
    copy_atlas_region(mapped + g_upload_offsets[i], u->dirty.w * bpp, u->surf, &u->dirty, u->fmt);
  }
  SDL_UnmapGPUTransferBuffer(g_ctx.device, g_atlas_xfer);

  SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(cmd);
  if (!cp) { g_upload_count = 0; return; }
  for (int i = 0; i < n; i++) {
    AtlasUpload *u = &g_uploads[i];
    SDL_GPUTextureTransferInfo tsrc = {0};
    tsrc.transfer_buffer = g_atlas_xfer;
    tsrc.offset = g_upload_offsets[i];
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
  g_uploads_last = n;
  g_upload_count = 0;
}

void gpu_draw_text_quads(RenWindow *ren, void *tex,
                         const GpuTextVertex *verts, int vert_count,
                         RenColor color, int mode, RenRect clip) {
  GpuWindowState *s = ren->gpu_state;
  if (!s || !s->vbuf_mapped || !s->cmd || !tex || vert_count <= 0) return;
  if (clip.width <= 0 || clip.height <= 0) return;
  if (s->vbuf_used + (Uint32)vert_count > s->vbuf_capacity) return;

  Uint32 packed = pack_rgba(color.r, color.g, color.b, color.a);
  int tex_index = atlas_texture_index((SDL_GPUTexture *)tex);
  /* in_array: sampled from the bound texture array via per-vertex tex_index.
   * Otherwise (array overflow) fall back to a dedicated single-texture draw. */
  bool in_array = (tex_index >= 0);
  /* tex_index packs the atlas slot (low 16 bits) and mode (high 16 bits). */
  Uint32 packed_index = (Uint32)(in_array ? tex_index : 0) | ((Uint32)mode << 16);

  /* Merge with the previous glyph draw when it is an array draw sharing the
   * clip. Per-vertex colour + tex_index + mode make tint, texture and mode all
   * independent of the draw, so differently coloured/fonted/formatted runs
   * merge. */
  GpuDrawCmd *last = (s->draws_count > 0) ? &s->draws[s->draws_count - 1] : NULL;
  bool merge = in_array && last && last->kind == GPU_DRAW_TEXT &&
               last->texture == NULL &&
               last->clip.x == (float)clip.x && last->clip.y == (float)clip.y &&
               last->clip.w == (float)clip.width && last->clip.h == (float)clip.height;

  Uint32 off = s->vbuf_used;
  GpuVertex *v = &s->vbuf_mapped[off];
  for (int i = 0; i < vert_count; i++) {
    v[i] = (GpuVertex){ verts[i].x, verts[i].y, verts[i].u, verts[i].v, packed,
                        packed_index };
  }
  s->vbuf_used = off + (Uint32)vert_count;

  if (merge) {
    last->vert_count += (Uint32)vert_count;
    return;
  }

  GpuDrawCmd *d = push_draw(s);
  if (!d) { s->vbuf_used = off; return; }
  d->kind = GPU_DRAW_TEXT;
  d->vert_offset = off;
  d->vert_count = (Uint32)vert_count;
  d->clip = (SDL_FRect){ (float)clip.x, (float)clip.y,
                         (float)clip.width, (float)clip.height };
  /* texture == NULL -> bind the atlas array; otherwise single-texture draw. */
  d->texture = in_array ? NULL : tex;
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

  /* Upload only when the image changes.  rencache reuses the same SDL_Surface
   * across frames, so an unchanged one can skip the convert+upload -- but the
   * surface pointer alone is not a safe cache key: the address of a freed
   * surface is routinely reused by the next allocation, which would then be
   * drawn from the stale texture.  Its pixel buffer, size and the presence of
   * the texture are part of the key as well. */
  bool unchanged = (img == s->last_img && img->pixels == s->last_img_pixels &&
                    iw == s->last_img_w && ih == s->last_img_h &&
                    s->image_tex != NULL);
  if (!unchanged) {
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

    /* Upload image data via the image staging buffer. */
    Uint32 size = (Uint32)(iw * ih) * 4;
    if (!ensure_xfer(&s->image_xfer, &s->image_xfer_size, size)) {
      SDL_DestroySurface(rgba);
      return;
    }
    Uint8 *mapped = SDL_MapGPUTransferBuffer(g_ctx.device, s->image_xfer, true);
    bool uploaded = false;
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
      SDL_UnmapGPUTransferBuffer(g_ctx.device, s->image_xfer);
      SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(s->cmd);
      if (cp) {
        SDL_GPUTextureTransferInfo tsrc = {0};
        tsrc.transfer_buffer = s->image_xfer;
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
        uploaded = true;
      }
    }
    SDL_DestroySurface(rgba);
    /* Only pin the cache key when the upload actually happened: otherwise the
     * texture holds stale bytes and the "unchanged" test would keep drawing
     * them on every later frame. */
    if (!uploaded) return;
    s->last_img = img;
    s->last_img_pixels = img->pixels;
    s->last_img_w = iw;
    s->last_img_h = ih;
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
  v[0] = (GpuVertex){ x0, y0, 0, 0, 0xFFFFFFFFu, 0 };
  v[1] = (GpuVertex){ x0, y1, 0, vmax, 0xFFFFFFFFu, 0 };
  v[2] = (GpuVertex){ x1, y0, umax, 0, 0xFFFFFFFFu, 0 };
  v[3] = (GpuVertex){ x1, y0, umax, 0, 0xFFFFFFFFu, 0 };
  v[4] = (GpuVertex){ x0, y1, 0, vmax, 0xFFFFFFFFu, 0 };
  v[5] = (GpuVertex){ x1, y1, umax, vmax, 0xFFFFFFFFu, 0 };
  Uint32 off = s->vbuf_used;
  s->vbuf_used += 6;

  GpuDrawCmd *d = push_draw(s);
  if (!d) { s->vbuf_used = off; return; }
  d->kind = GPU_DRAW_IMAGE;
  d->vert_offset = off;
  d->vert_count = 6;
  d->clip = (SDL_FRect){ (float)(clip.x * ss), (float)(clip.y * ss),
                         (float)(clip.width * ss), (float)(clip.height * ss) };
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
    tgt.clear_color = (SDL_FColor){0, 0, 0, 0};
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

    SDL_GPUGraphicsPipeline *bound_pipeline = NULL;
    /* texture binding state: 0 = none, 1 = atlas array, 2 = single texture */
    int bound_tex_mode = 0;
    void *bound_single_tex = NULL;
    bool have_scissor = false;
    SDL_Rect bound_scissor = {0};

    for (Uint32 i = 0; i < s->draws_count; i++) {
      GpuDrawCmd *d = &s->draws[i];
      SDL_Rect sc;
      if (d->clip.w > 0 && d->clip.h > 0) {
        sc = (SDL_Rect){ (int)d->clip.x, (int)d->clip.y,
                         (int)d->clip.w, (int)d->clip.h };
      } else {
        sc = (SDL_Rect){ 0, 0, s->target_w, s->target_h };
      }
      if (!have_scissor || sc.x != bound_scissor.x || sc.y != bound_scissor.y ||
          sc.w != bound_scissor.w || sc.h != bound_scissor.h) {
        SDL_SetGPUScissor(s->pass, &sc);
        bound_scissor = sc;
        have_scissor = true;
      }

      SDL_GPUGraphicsPipeline *pipe =
        (d->kind == GPU_DRAW_RECT) ? g_ctx.rect_pipeline :
        (d->kind == GPU_DRAW_RRECT) ? g_ctx.rrect_pipeline :
        (d->kind == GPU_DRAW_IMAGE) ? g_ctx.image_pipeline : g_ctx.glyph_pipeline;
      if (pipe != bound_pipeline) {
        SDL_BindGPUGraphicsPipeline(s->pass, pipe);
        bound_pipeline = pipe;
      }

      /* Bind textures for glyph/image draws. */
      if (d->kind == GPU_DRAW_TEXT || d->kind == GPU_DRAW_IMAGE) {
        if (d->kind == GPU_DRAW_TEXT && d->texture == NULL) {
          /* Glyph array: bind all 16 slots (shader array is fixed-size).
           * Real atlas textures fill slots 0..N-1; the rest are padded with a
           * valid texture (never sampled, since tex_index < N). */
          if (bound_tex_mode != 1) {
            SDL_GPUTextureSamplerBinding tsb[GPU_ATLAS_COUNT];
            int n = g_atlas_texture_count; /* >= 1 here */
            for (int k = 0; k < GPU_ATLAS_COUNT; k++) {
              tsb[k].texture = g_atlas_textures[k < n ? k : 0];
              tsb[k].sampler = g_ctx.atlas_sampler;
            }
            SDL_BindGPUFragmentSamplers(s->pass, 0, tsb, GPU_ATLAS_COUNT);
            bound_tex_mode = 1;
          }
        } else {
          /* Single texture at slot 0 (overflow glyph or image). */
          void *tex = d->texture;
          if (bound_tex_mode != 2 || bound_single_tex != tex) {
            SDL_GPUTextureSamplerBinding tsb = {0};
            tsb.texture = (SDL_GPUTexture *)tex;
            tsb.sampler = g_ctx.atlas_sampler;
            SDL_BindGPUFragmentSamplers(s->pass, 0, &tsb, 1);
            bound_tex_mode = 2;
            bound_single_tex = tex;
          }
        }
      }

      if (d->kind == GPU_DRAW_RRECT) {
        SDL_PushGPUFragmentUniformData(s->cmd, 0, d->funiform, sizeof(d->funiform));
        SDL_DrawGPUPrimitives(s->pass, d->vert_count, 1, d->vert_offset, 0);
      } else {
        /* rect/glyph/image: no fragment uniform (per-vertex / fixed mode) */
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
    info.clear_color = (SDL_FColor){0, 0, 0, 0};
    info.filter = SDL_GPU_FILTER_NEAREST;
    /* cycle must stay false for a swapchain texture: SDL owns its lifetime
     * and cycling user-side is not supported. */
    info.cycle = false;
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

#endif /* LITE_USE_GPU_RENDERER */
