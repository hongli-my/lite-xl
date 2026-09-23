# GPU 文本渲染 / 动态字形图集 调研报告

> 服务于 lite-xl GPU 渲染器 Stage 2（文本上 GPU）。所有结论均标注来源仓库 + 文件:行号，
> 本地克隆于 `.research_repos/`（alacritty / kitty / imgui / xterm.js / glyphon / etagere）。
> Skia 为 Chromium/VSCode 编辑器文本路径，源码经 github raw 抓取确认。

---

## 0. 速查矩阵（5 大焦点问题 × 6 个实现）

| 维度 | alacritty (Rust/OpenGL) | kitty (C/OpenGL) | glyphon (Rust/wgpu) | xterm.js webgl (TS/WebGL2) | ImGui (C++/Metal) | Skia/Chromium (C++/Ganesh) |
|---|---|---|---|---|---|---|
| **grow 策略** | 多纹理定容（1024²），满了 push 新纹理，不 resize | 多层纹理数组；immutable 不可扩 → 新建更大数组 + `glGetTexImage` 回读再 `glTexSubImage3D` 重传（保留旧 sprite） | 单纹理翻倍 grow（×2，封顶 max_texture_dimension_2d），新建纹理 + **全量重栅格化重传** | 多 page 同尺寸；满 4 个同尺寸 page → 合并成 1 个 2× 大 page（drawImage 拷贝）；超限则 evictAll | 1.92 动态：resize 纹理（重建）+ 使所有 UV 失效 + 重打包；多纹理 TexList | plot + multitexture：满了加新 page/proxy；LRU 驱逐处理碎片 |
| **dirty 上传** | 逐字形 `glTexSubImage2D`（局部），无 dirty 表 | 逐 sprite `glTexSubImage3D`（局部，单 cell 矩形） | 逐字形 `queue.write_texture`（局部，带 origin）；grow 时全量重传 | 逐 page `glTexImage2D` 整页重传，但用 `page.version` 增量判定哪些页变了 | Metal：创建时整纹理 `replaceRegion`；更新时局部 `replaceRegion(rect)`；grow 时整纹理重建 | 延迟上传（flush 期批量），按 plot 子矩形局部上传 |
| **灰度/子像素/彩色分纹理?** | **不分**，单一 RGBA 纹理；RGB=LCD 覆盖，RGBA=彩色 emoji，`multicolor` flag 区分 | **不分**，单一 RGBA(sRGB) 纹理数组；`colored` flag | **分**：mask(R8Unorm) + color(Rgba8Unorm[Srgb]) 两个纹理 | 单一 RGBA（Canvas2D 产物），无分 | 单一 RGBA8Unorm；灰度存为 white×alpha，彩色存 BGRA→RGBA，`Colored` flag | **分**：`MaskFormat{kA8, kLCD, kARGB}`，每种格式一个 atlas |
| **子像素 LCD on GPU** | **shader 层**，dual-source blending（GLSL3 单 pass）/ 3-pass 累加（GLES2） | sRGB gamma 灰度 AA 为主，数组路径非 LCD | **无**（R8 灰度 mask；子像素仅做 *位置* 量化 SubpixelBin，非 LCD 渲染） | **无**（Canvas2D fillText→RGBA，灰度） | **无**（FT_RENDER_MODE_NORMAL，灰度） | **shader 层**，kLCD 格式存 RGB 覆盖 + 专用 shader 逐通道混合；大字号走 SDFT |
| **glyph→GPU offset 映射层** | `GlyphCache: HashMap<GlyphKey, Glyph{tex_id,uv...}>` | 三层：`sprite_pos_map`(glyph 序列→`SpritePosition{idx,rendered,colored}`) → `sprite_index` → `(x,y,z)`（`sprite_index_to_pos`）；外加 `decorations_map` R32UI 整数纹理做 cell→idx | `InnerAtlas.glyph_cache: LruCache<CacheKey, GlyphDetails{gpu_cache: InAtlas{x,y}}>` | `TextureAtlas._cacheMap: FourKeyMap→IRasterizedGlyph{texturePage, texturePosition}` | `TextStrike: THashTable<PackedGPUGlyphID, GlyphEntry{atlas loc}>` + `atlasGeneration` 失效令牌 | 同 Skia |

---

## 1. alacritty（Rust + OpenGL glutin）

> ⚠️ 纠正：alacritty 用的是 **OpenGL（glutin/gl）**，不是 wgpu。但其 atlas + glyph_cache +
> 子像素 shader 的设计模式正是问题所问，最具参考价值。

### 1.1 数据结构

```rust
// alacritty/alacritty/src/renderer/text/atlas.rs
pub const ATLAS_SIZE: i32 = 1024;          // 固定尺寸，不 grow 单纹理
pub struct Atlas {
    id: GLuint,            // 单张 GL_TEXTURE_2D
    width: i32, height: i32,
    row_extent: i32,       // 当前行最左空闲 x（bump 指针）
    row_baseline: i32,     // 当前行 y 基线
    row_tallest: i32,      // 当前行最高字形（换行 advance）
    is_gles_context: bool,
}
pub enum AtlasInsertError { Full, GlyphTooLarge }

// alacritty/alacritty/src/renderer/text/glyph_cache.rs
pub struct Glyph {              // 一个字形在 GPU 里的全部定位信息
    pub tex_id: GLuint,         // 属于哪张 atlas 纹理
    pub multicolor: bool,       // emoji vs 普通文本
    pub top: i16, pub left: i16, pub width: i16, pub height: i16,
    pub uv_bot: f32, pub uv_left: f32, pub uv_width: f32, pub uv_height: f32,
}
pub struct GlyphCache {         // CPU 侧缓存：GlyphKey -> Glyph
    cache: HashMap<GlyphKey, Glyph, RandomState>,
    rasterizer: Rasterizer,
    font_key/bold_key/italic_key/bold_italic_key: FontKey,
    font_size, metrics, ...
}
pub trait LoadGlyph {           // 桥接：cache 命中失败时把栅格化结果塞进 atlas
    fn load_glyph(&mut self, rasterized: &RasterizedGlyph) -> Glyph;
    fn clear(&mut self);
}
```

### 1.2 grow = 多纹理定容（不 resize）

```rust
// atlas.rs  load_glyph() —— 静态方法，操作一个 atlas 数组
pub fn load_glyph(active_tex: &mut GLuint, atlas: &mut Vec<Atlas>,
                  current_atlas: &mut usize, rasterized: &RasterizedGlyph) -> Glyph {
    match atlas[*current_atlas].insert(rasterized, active_tex) {
        Ok(glyph) => glyph,
        Err(Full) => {                       // 当前 atlas 满了
            *current_atlas += 1;
            if *current_atlas == atlas.len() {
                atlas.push(Atlas::new(ATLAS_SIZE, is_gles));  // ★ push 一张新的 1024²
            }
            Self::load_glyph(active_tex, atlas, current_atlas, rasterized) // 递归重试
        }
        Err(GlyphTooLarge) => Glyph { width:0, height:0, .. },  // 占位
    }
}
```
**要点**：每张纹理固定 1024²，满了就开新一张，**永不 resize 单纹理**，因此**无需重传旧字形**。
`Glyph.tex_id` 记录属于哪张。`clear()` 只重置 row 指针，纹理像素保留（下次覆盖写）。

### 1.3 dirty 上传 = 逐字形局部 `glTexSubImage2D`

```rust
// atlas.rs insert_inner()
gl::TexSubImage2D(TEXTURE_2D, 0, offset_x, offset_y, width, height,
                  format, UNSIGNED_BYTE, buffer.as_ptr());
```
无 dirty region 表——新字形首次出现时立刻局部上传自己那一小块。
font size 变更时 `reset_glyph_cache` → `loader.clear()` 仅重置所有 atlas 的 row 指针（纹理复用覆盖）。

### 1.4 格式策略 = 单一 RGBA 纹理

```rust
// atlas.rs insert_inner()  —— 注释原文："Use RGBA texture for both normal and emoji glyphs,
//                                               since it has no performance impact."
match &glyph.buffer {
    BitmapBuffer::Rgb(buf)  => { multicolor=false; (RGB,  buf) }   // LCD 子像素覆盖（3 通道）
    BitmapBuffer::Rgba(buf) => { multicolor=true;  (RGBA, buf) }   // 彩色 emoji
}
```
普通文本与彩色 emoji 共用同一张 RGBA 纹理，靠 `Glyph.multicolor` + shader 分支区分。

### 1.5 子像素 LCD = shader 层 dual-source blending（核心）

```glsl
// alacritty/alacritty/res/glsl3/text.f.glsl
layout(location = 0, index = 0) out vec4 color;       // FRAG_COLOR  → 作 src0
layout(location = 0, index = 1) out vec4 alphaMask;   // ALPHA_MASK  → 作 src1（混合因子）
uniform sampler2D mask;                               // atlas，RGB=LCD 覆盖

void main() {
    if (renderingPass == 0) { /* 背景 */ ALPHA_MASK=1.0; FRAG_COLOR=premult(bg); return; }
    if (int(colored) == COLORED) {                    // emoji
        FRAG_COLOR  = texture(mask, TexCoords);       // RGBA 彩色
        ALPHA_MASK  = vec4(FRAG_COLOR.a);             // alpha 作覆盖
    } else {                                          // 普通文本
        vec3 textColor = texture(mask, TexCoords).rgb;// ★ RGB = 3 个子像素的覆盖
        ALPHA_MASK = vec4(textColor, textColor.r);
        FRAG_COLOR = vec4(fg.rgb, 1.0);
    }
}
```
配合 `glBlendFunc(SRC1_COLOR, ONE_MINUS_SRC1_COLOR)`（glsl3.rs），混合因子取 src1 即 `ALPHA_MASK.rgb`：

```
result.rgb = FRAG_COLOR.rgb * ALPHA_MASK.rgb + dst.rgb * (1 - ALPHA_MASK.rgb)
           = fg.rgb * coverage.rgb + bg.rgb * (1 - coverage.rgb)     ← 逐 RGB 通道 = LCD 子像素
```
即 **atlas 把 LCD 子像素覆盖存成 RGB，shader 用 dual-source blending 单 pass 完成逐通道混合**。

GLES2（无 dual-source 扩展）退化为 3 pass 累加（`res/gles2/text.f.glsl render_text()`）：
pass1 写 `fg*coverage`、pass2 写 `bg*(max_rgb - coverage)` 补子像素间隙、pass3 再叠加，等价效果。

### 1.6 渲染 = instanced + 按 tex_id 分批

```rust
// glsl3.rs
gl::BlendFunc(SRC1_COLOR, ONE_MINUS_SRC1_COLOR);
const BATCH_MAX: usize = 0x1_0000;            // 65536 实例/批
struct Batch { tex: GLuint, instances: Vec<InstanceData> }
// add_render_item: 若 batch.tex != glyph.tex_id → render_batch() flush
//   → glBufferSubData(ARRAY_BUFFER, STREAM_DRAW) 重传整批 instance
//   → set_rendering_pass(Background); DrawElementsInstanced(6 idx, n)
//   → set_rendering_pass(SubpixelPass1);   DrawElementsInstanced(6 idx, n)
```
顶点 instance（`InstanceData`）= col/row + glyph offset/size + uv + 文本色 RGB + cell_flags + bg RGBA。

### 1.7 数据流

```
cell ─► GlyphCache.get(GlyphKey) ─hit─► Glyph{tex_id,uv}
                    │miss
                    ▼
        rasterizer.get_glyph() ─► RasterizedGlyph{buffer: Rgb|Rgba, w,h,top,left}
                    │
                    ▼  LoaderApi.load_glyph()
        Atlas.load_glyph(atlas:Vec, current_atlas) ─► insert_inner()
                    │   glTexSubImage2D(局部)  ─► GPU atlas 纹理[i]
                    ▼
              Glyph{tex_id, uv_*}  ─► cache.insert()
                    │
        RenderApi.add_render_item ─► Batch(按 tex_id 分组)
                    │
        render_batch ─► glBufferSubData(instance) + DrawElementsInstanced×2pass
```

---

## 2. kitty（C + Python，OpenGL，纹理数组）

### 2.1 三层映射（glyph → GPU offset 的典范设计）

```
┌─────────────────────────────────────────────────────────────────────┐
│ 第 1 层：glyph 序列 → SpritePosition      (glyph-cache.c, verstable)│
│   find_or_create_sprite_position(map, glyphs[], count,              │
│       ligature_index, cell_count, scale, subscale,                  │
│       multicell_y, vertical_align, &created) -> SpritePosition*     │
│   SpritePosition { sprite_index idx; bool rendered; bool colored; } │
│   （key 含 glyph id 数组 → 支持 ligature / 多 cell 合字）            │
├─────────────────────────────────────────────────────────────────────┤
│ 第 2 层：sprite_index -> (x,y,z)           (fonts.c)                 │
│   sprite_index_to_pos(idx, xnum, ynum, &x,&y,&z)                     │
│   idx = z*(xnum*ynum) + y*xnum + x        （线性序 → 三维网格）      │
├─────────────────────────────────────────────────────────────────────┤
│ 第 3 层：(x,y,z) -> GL_TEXTURE_2D_ARRAY    (shaders.c)              │
│   glTexStorage3D(2D_ARRAY, 1, SRGB8_ALPHA8, W, H, znum)             │
│   glTexSubImage3D(2D_ARRAY,0, x*cellW, y*(cellH+1), z, ...)         │
└─────────────────────────────────────────────────────────────────────┘
   另有 decorations_map：R32UI 整数纹理，GPU 侧 cell -> sprite_index 查表
```

```c
// kitty/kitty/fonts.h (glyph-cache.h)
typedef union SpritePosition {
    struct { sprite_index idx : 32; bool rendered:1; bool colored:1; uint32_t:30; };
    uint64_t val;
} SpritePosition;
// kitty/kitty/data-types.h
typedef uint32_t sprite_index;
// kitty/kitty/fonts.c
typedef struct { unsigned x, y, z, xnum, ynum, max_y; } GPUSpriteTracker;
sprite_index current_sprite_index(t) = t->z*(t->xnum*t->ynum) + t->y*t->xnum + t->x;
void sprite_tracker_set_layout(t, cell_w, cell_h) {
    t->xnum = MIN(MAX(1u, max_texture_size/cell_w), UINT16_MAX);
    t->max_y = max_texture_size / (cell_h+1);   // 每层最大行数
    t->ynum = 1;
    // z 增长 = 加 layer，封顶 min(UINT16_MAX, max_array_len≤0xfff)
}
```

### 2.2 grow = 重建更大 immutable 数组 + 回读重传（保留旧 sprite）

```c
// kitty/kitty/shaders.c
static void realloc_sprite_texture(FONTS_DATA_HANDLE fg) {
    sprite_tracker_current_layout(fg, &xnum, &ynum, &z);
    znum = z + 1;
    width  = xnum * cell_width;
    height = ynum * (cell_height + 1);
    GLuint tex = setup_new_sprites_texture(GL_TEXTURE_2D_ARRAY);   // NEAREST, CLAMP
    glTexStorage3D(GL_TEXTURE_2D_ARRAY, 1, GL_SRGB8_ALPHA8, width, height, znum); // immutable
    if (old_texture_id) {
        copy_32bit_texture(old, new, GL_TEXTURE_2D_ARRAY);  // glGetTexImage 回读 → glTexSubImage3D 重传
        free_texture(&old);
    }
    sprite_map->last_num_of_layers = znum;
    sprite_map->texture_id = tex;
}
```
**要点**：`glTexStorage3D` 分配的是 **immutable storage**，无法原地扩容，故 grow 必须新建更大纹理
并把旧内容 **`glGetTexImage` 读回 CPU 再 `glTexSubImage3D` 灌回去**（`copy_32bit_texture`）。
触发时机（`send_sprite_to_gpu`）：`znum >= last_num_of_layers || (znum==0 && ynum>last_ynum)`。

### 2.3 dirty 上传 = 逐 sprite 局部 `glTexSubImage3D`

```c
// shaders.c  send_sprite_to_gpu()
sprite_index_to_pos(idx, xnum, ynum, &x, &y, &z);
x *= cell_width;  y *= (cell_height + 1);
glTexSubImage3D(GL_TEXTURE_2D_ARRAY, 0, x, y, z,
                cell_width, cell_height+1, 1, GL_RGBA, GL_UNSIGNED_INT_8_8_8_8, buf);
```
每个 sprite 是一个 cell 大小的 RGBA 位图，按 (x,y,z) 灌进数组对应格子。NEAREST 采样防 cell 边缘串色。

### 2.4 格式 = 单一 RGBA(sRGB) 纹理数组；`colored` flag

彩色 emoji 与普通字形同住一个 RGBA sRGB 数组，`SpritePosition.colored` 标记。
kitty 在数组路径上主要走 **sRGB gamma 校正的灰度 AA**（不是 LCD-in-array）。

---

## 3. glyphon（Rust + wgpu，fontdue/ab_glyph + wgpu 的现代代表）

> glyphon = `cosmic-text`(布局/shaping) + `swash`(栅格化) + `etagere`(打包) + `wgpu`。
> 这是"fontdue/ab_glyph + wgpu"类 demo 的工业级形态。

### 3.1 数据结构

```rust
// glyphon/src/text_atlas.rs
pub(crate) struct InnerAtlas {
    pub kind: Kind,                                 // Mask | Color{srgb}
    pub texture: wgpu::Texture,
    pub texture_view: wgpu::TextureView,
    pub packer: etagere::BucketedAtlasAllocator,    // ★ 桶式 shelf 打包
    pub size: u32,                                  // 初始 256
    pub glyph_cache: LruCache<GlyphonCacheKey, GlyphDetails>,  // ★ LRU 驱逐
    pub generation: usize,                          // 帧计数器（驱逐判定）
    pub max_texture_dimension_2d: u32,
}
impl InnerAtlas { const INITIAL_SIZE: u32 = 256; }

pub(crate) enum Kind {
    Mask,                       // -> R8Unorm       (1 通道，灰度)
    Color { srgb: bool },       // -> Rgba8Unorm[Srgb] (4 通道，彩色)
}
pub struct TextAtlas {
    color_atlas: InnerAtlas,    // ★ 灰度/彩色 分两张纹理，格式不同
    mask_atlas:  InnerAtlas,
    bind_group: BindGroup,      // 绑定 color_atlas + mask_atlas + sampler
    format, color_mode, ...
}
// glyphon/src/text_render.rs
pub struct GlyphDetails {
    width: u16, height: u16,
    gpu_cache: GpuCacheStatus,  // InAtlas{x,y,content_type} | SkipRasterization
    atlas_id: Option<etagere::AllocId>,
    top: i16, left: i16, last_used: usize,
}
pub struct TextRenderer {
    vertex_buffer: wgpu::Buffer,  // 几何增长，满了 destroy+重建
    glyph_vertices: Vec<GlyphToRender>,
    pipeline, ...
}
```

### 3.2 grow = 单纹理翻倍 + 全量重栅格化重传

```rust
// text_atlas.rs  InnerAtlas::grow()
if self.size >= max_texture_dimension_2d { return false; }
let new_size = (self.size * 2).min(max_texture_dimension_2d);   // ×2，封顶
self.packer.grow(size2(new_size, new_size));
self.texture = device.create_texture(&TextureDescriptor {       // ★ 新建更大纹理
    size: Extent3d { width: new_size, height: new_size, depth_or_array_layers: 1 },
    format: self.kind.texture_format(),
    usage: TEXTURE_BINDING | COPY_DST, ..
});
for (&cache_key, glyph) in &self.glyph_cache {                  // ★ 遍历全部缓存字形
    let GpuCacheStatus::InAtlas { x, y, .. } = glyph.gpu_cache else { continue };
    let image = cache.get_image_uncached(font_system, cache_key).unwrap(); // 重新取位图
    queue.write_texture(TexelCopyTextureInfo {
        texture: &self.texture, origin: Origin3d { x, y, z: 0 }, ..
    }, &image.data, .., Extent3d { width, height, 1 });          // 逐个重传
}
self.texture_view = self.texture.create_view(..);
self.size = new_size;
```
**要点**：grow 是 **重建纹理 + 把所有已缓存字形重新从 swash 取位图再 `write_texture` 重传一遍**。
比 kitty 的"回读旧纹理拷贝"更简单（不用 GPU→CPU 回读），但代价是重新走一遍栅格化缓存。

### 3.3 分配 = LRU 驱逐优先，驱逐不够才 grow

```rust
// text_atlas.rs  try_allocate()
loop {
    if let Some(a) = self.packer.allocate(size) { return Some(a); }  // 1. 直接打包
    let (_, v) = self.glyph_cache.peek_lru()?;                        // 2. 找最久未用
    if v.last_used == self.generation { return None; }                //   全在用 → 触发 grow
    let (_, v) = self.glyph_cache.pop_lru().unwrap();
    self.packer.deallocate(v.atlas_id.unwrap());                      // 3. 释放其 atlas 槽位
}
// text_render.rs  prepare_glyph() 调用方：
loop {
    match inner.try_allocate(w, h) {
        Some(a) => break a,
        None => if !atlas.grow(..) { return Err(PrepareError::AtlasFull); }
    }
}
```
`generation` 在每帧 `trim()` 自增；`last_used == generation` 表示本帧用过、不可驱逐。

### 3.4 dirty 上传 = 逐字形局部 `queue.write_texture`

```rust
// text_render.rs  prepare_glyph()
let allocation = inner.try_allocate(w, h).or_grow();
let atlas_min = allocation.rectangle.min;
queue.write_texture(
    TexelCopyTextureInfo { texture: &inner.texture, origin: Origin3d { x: atlas_min.x, y: atlas_min.y, .. }, .. },
    &image.data,
    TexelCopyBufferLayout { bytes_per_row: Some(w * inner.num_channels()), .. },
    Extent3d { width: w, height: h, depth_or_array_layers: 1 },
);
```
局部上传；bounds 裁剪时还会调整 `atlas_x/atlas_y`（采样区域平移），避免越界。

### 3.5 顶点上传 = 整缓冲 `write_buffer` 重流，满了重建

```rust
// text_render.rs  prepare() 末尾
if self.vertex_buffer_size >= vertices.len() {
    queue.write_buffer(&self.vertex_buffer, 0, vertices_raw);   // ★ 整缓冲重流
} else {
    self.vertex_buffer.destroy();
    let (buf, sz) = create_oversized_buffer(.., mapped_at_creation); // 重建更大
    self.vertex_buffer = buf; self.vertex_buffer_size = sz;
}
// render()
pass.draw(0..4, 0..self.glyph_vertices.len() as u32);  // triangle strip, instanced
```

### 3.6 shader（wgsl）—— 无 LCD，mask = R8 alpha 调制

```rust
// glyphon/src/cache.rs —— sampler 全 Nearest
sampler: device.create_sampler(&SamplerDescriptor {
    min_filter: Nearest, mag_filter: Nearest, mipmap_filter: Nearest, ..
});
// shader.wgsl
@group(0) @binding(0) var color_atlas_texture: texture_2d<f32>;
@group(0) @binding(1) var mask_atlas_texture:  texture_2d<f32>;
@fragment fn fs_main(in) -> vec4<f32> {
    switch in.content_type {
        case 0u { return textureSampleLevel(color_atlas_texture, .., uv, 0.0); } // 彩色直采
        case 1u { return vec4(color.rgb, color.a * textureSampleLevel(mask_atlas_texture, .., uv, 0.0).x); } // ★ 灰度 mask 调 alpha
    }
}
```
**子像素**：glyphon **不做 LCD**。`cosmic_text::SubpixelBin` 只是把字形 x 位置量化到 1/3 像素 bin，
栅格化仍为灰度 R8。swash 的 `SubpixelMask` 被显式降级为 `Mask`（注释 "Not implemented yet"）。

---

## 4. etagere（glyphon 用的动态打包器）

```rust
// etagere/src/lib.rs —— shelf packing 算法
pub struct AtlasAllocator;            // guillotine 式，逐项追踪，碎片处理好但慢
pub struct BucketedAtlasAllocator;    // 桶式 shelf，整桶空才回收，适合大量小项（glyphon 用）
pub struct Allocation { pub id: AllocId, pub rectangle: Rectangle }
impl BucketedAtlasAllocator {
    pub fn new(size: Size) -> Self;
    pub fn allocate(&mut self, size: Size) -> Option<Allocation>;
    pub fn deallocate(&mut self, id: AllocId);
    pub fn grow(&mut self, new_size: Size);   // ★ 原地扩容（不改已分配矩形坐标）
}
// 支持 alignment / vertical_shelves / num_columns
```
对比：alacritty/xterm 用手写 shelf（row_extent/row_tallest）；kitty 用固定 cell 网格（不需打包器）。

---

## 5. xterm.js WebGL addon（VSCode 集成终端的 GPU 文本路径）

### 5.1 多 page + 合并 grow

```ts
// xterm.js/addons/addon-webgl/src/TextureAtlas.ts
class TextureAtlas {
  private _pages: AtlasPage[] = [];          // 多张 canvas/纹理
  private _activePages: AtlasPage[] = [];
  private _textureSize = 512;                 // 初始
  static maxAtlasPages = min(32, MAX_TEXTURE_IMAGE_UNITS);
  static maxTextureSize = MAX_TEXTURE_SIZE;   // 硬件上限
  private _pageLayoutVersion = 0;             // ★ 结构变更失效令牌
}
class AtlasPage {
  canvas: HTMLCanvasElement; ctx: CanvasRenderingContext2D;
  currentRow: { x, y, height };               // shelf 打包
  glyphs: IRasterizedGlyph[]; percentageUsed; version;
}
// grow: 满了 _createNewPage()（新 512² canvas，同尺寸，类 alacritty）
//       但当 pages >= max(4, maxAtlasPages) → 尝试把 4 张同尺寸 page
//       合并成 1 张 2× 大 page（ctx.drawImage 2×2 拷贝），更新所有 glyph 的
//       texturePage/texturePosition，pageLayoutVersion++（使 renderer 重建模型）
//       合并不成 → _evictAllPages() + 新建
```

### 5.2 dirty 上传 = 逐 page 整页 `texImage2D`，靠 `version` 增量

```ts
// GlyphRenderer.ts  render()
for (let i = 0; i < pageCount; i++) {
  if (this._atlas.pages[i].version !== this._atlasTextures[i].version) {
    this._bindAtlasPageTexture(gl, atlas, i);   // 仅重传变化的页
  }
}
// _bindAtlasPageTexture()
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, atlas.pages[i].canvas);
this._atlasTextures[i].version = atlas.pages[i].version;
```
**无局部 sub-image**——整页 canvas 重传，但用 per-page `version` 比较避免不变页的重传。
`pageLayoutVersion` 变化时 `beginFrame()` 返回 true → renderer 全量重建顶点（重取所有 UV）。

### 5.3 多纹理 = sampler 数组 + shader if-else

```ts
// GlyphRenderer.ts
TextureAtlas.maxAtlasPages = Math.min(32, gl.getParameter(gl.MAX_TEXTURE_IMAGE_UNITS));
uniform sampler2D u_texture[maxFragmentShaderTextureUnits];
// fragment: if (v_texpage==0) outColor=texture(u_texture[0],v_texcoord);
//            else if (v_texpage==1) ...   （动态拼字符串生成）
// 顶点 instance: offset, size, texpage, texcoord, texsize, cellpos（11 float/cell）
gl.drawElementsInstanced(gl.TRIANGLE_STRIP, 4, gl.UNSIGNED_BYTE, 0, cellCount);
```
顶点 **双缓冲**（`attributesBuffers[2]` 交替），避免 GPU 占用时阻塞 CPU 写入。`STREAM_DRAW`。
混合 `SRC_ALPHA/ONE_MINUS_SRC_ALPHA`，**灰度**（Canvas2D fillText → RGBA），**无 LCD**。

---

## 6. ImGui ImFontAtlas（C++，1.92 起改为动态）

### 6.1 数据结构（imgui.h:3751+）

```cpp
struct ImFontAtlas {
    // 输入
    ImTextureFormat TexDesiredFormat;   // RGBA32(默认) | Alpha8
    int TexGlyphPadding;                // 默认 1
    int TexMinWidth, TexMinHeight;      // POT，默认 512/128
    int TexMaxWidth, TexMaxHeight;      // POT，默认 8192
    // 输出（★ 1.92 动态：纹理可随时创建/resize）
    ImTextureRef  TexRef;               // 当前纹理标识，随时可能变
    ImTextureData* TexData;             // 当前纹理
    ImVector<ImTextureData*> TexList;   // ★ 多纹理
    bool Locked;            // NewFrame..EndFrame 期间，若后端不支持 TexUpdates 则锁
    bool RendererHasTextures;           // ImGuiBackendFlags_RendererHasTextures
    bool TexPixelsUseColors;            // 提示后端选格式
    ImVec2 TexUvScale, TexUvWhitePixel; // 随纹理重建而变
    ImFontAtlasBuilder* Builder;        // 不透明打包器
    // API（1.92）
    ImFontAtlasRectId AddCustomRect(int w, int h, ImFontAtlasRect* out); // ★ 立即打包
    bool GetCustomRect(ImFontAtlasRectId id, ImFontAtlasRect* out) const; // ★ UV 随时失效，勿缓存
    void CompactCache();                // 碎片整理 + 纹理收缩
};
```
**关键注释原文**：`"Texture may be created/resized at any time... IT WILL INVALIDATE
RECTANGLE DATA SUCH AS UV COORDINATES. Always use latest values from GetCustomRect()."`

### 6.2 grow = resize 纹理（重建）+ UV 全失效 + 重打包

不像 alacritty 多张同尺寸，ImGui 选择 **resize 单纹理**（受 TexMaxWidth/Height 约束），
重建后所有 UV 失效，调用方每帧从 `GetCustomRect()` 重取。`CompactCache()` 做碎片整理。
旧路径（pre-1.92 / 无 RendererHasTextures 后端）：`Build()` 一次性烘焙整张 CPU 像素图，
后端 `GetTexDataAsRGBA32()` 取走上传一次，`SetTexID()` 绑定——**静态、无动态更新**。

### 6.3 Metal 后端上传（imgui_impl_metal.mm）

```objc
// 创建：整纹理上传
MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                            MTLPixelFormatRGBA8Unorm width:tex->Width height:tex->Height];
td.usage = MTLTextureUsageShaderRead;
id<MTLTexture> texture = [device newTextureWithDescriptor:td];
[texture replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0
            withBytes:tex->Pixels bytesPerRow:W*4];
// 更新（动态）：局部矩形
[backend_tex.metalTexture replaceRegion:MTLRegionMake2D(r.x,r.y,r.w,r.h) ..];
// grow：整纹理重建（newTextureWithDescriptor + 全量 replaceRegion）
```

### 6.4 栅格化（imgui_freetype.cpp）—— 灰度，无 LCD

```cpp
FT_Render_Mode mode = (flags & Monochrome) ? FT_RENDER_MODE_MONO : FT_RENDER_MODE_NORMAL; // ★ 无 LCD
FT_Render_Glyph(slot, mode);
ImGui_ImplFreeType_BlitGlyph(ft_bitmap, dst, dst_pitch):
    case FT_PIXEL_MODE_GRAY:  // 1 byte → RGBA(white * alpha)，shader 用顶点色 tint
    case FT_PIXEL_MODE_MONO:  // 1 bit
    case FT_PIXEL_MODE_BGRA:  // 彩色 emoji → RGBA，Colored=true
```

---

## 7. Skia / Chromium（VSCode/Electron 编辑器文本的真正 GPU 路径）

> VSCode 编辑器文本走 Chromium → Skia Ganesh GPU 后端；VSCode 集成终端走 xterm.js（见 §5）。

```cpp
// src/gpu/MaskFormat.h  （经 github raw 确认）
enum class MaskFormat : int { kA8, kLCD, kARGB, k565 /*, ...*/ };  // ★ 三种文本格式

// src/gpu/ganesh/text/GrAtlasManager.h
class GrAtlasManager {
    GrDrawOpAtlas* fAtlases[kMaskFormatCount];   // ★ 每种格式一个独立 atlas（不同纹理）
    GrDrawOpAtlas::ErrorCode addGlyphToAtlas(const SkGlyph&, .., GrDeferredUploadTarget*);
    const GrSurfaceProxyView* getViews(MaskFormat fmt, unsigned* numActiveProxies); // multitexture
    uint64_t atlasGeneration(MaskFormat);        // ★ 单调失效令牌（驱逐/结构变更时 bump）
    void setUseTokenBulk(const GrBulkUsePlotUpdater&, GrFlushState::Token, MaskFormat);
    void compact(GrFlushState::Token);           // LRU 驱逐未用 plot
};
// src/gpu/ganesh/text/TextStrike.h
class TextStrike final : public TextStrikeBase {
    THashTable<GlyphEntry*, PackedGPUGlyphID, HashTraits> fCache;  // glyph-key → GlyphEntry
};
```
**设计**：
- **映射层**：`(font strike, PackedGPUGlyphID) → GlyphEntry`（`TextStrike` 的 hash 表，`StrikeCache` 管所有 strike）→ atlas 位置（page/plot/rect）于 `GrDrawOpAtlas[MaskFormat]`。`atlasGeneration` 是失效令牌（类比 xterm `pageLayoutVersion` / glyphon `generation`）。
- **grow**：plot 制 + multitexture——atlas 内部分若干 plot（子矩形），满了开新 page/proxy（多纹理），用 LRU last-use-token 驱逐整 plot，`compact()` 回收。不 resize 单纹理。
- **灰度/LCD/彩色分纹理**：`kA8`/`kLCD`/`kARGB` 各一张 atlas，格式不同。
- **LCD on GPU**：`kLCD` 格式把子像素覆盖存成 RGB（自有一张 atlas），文本 shader 采样 RGB 做逐通道混合（与 alacritty dual-source 同思路，Skia 用自家 shader 实现）。大字号另走 **SDFT（signed distance field）** 路径。
- **上传**：延迟上传——flush 期 `GrDeferredUploadTarget` 批量把命中的字形按 plot 子矩形局部上传。

---

## 8. 五大焦点问题 · 跨实现定论

### Q1 动态 atlas 满了怎么办？（新建更大纹理 vs 多纹理）

三类策略，各有取舍：

| 策略 | 代表 | 优点 | 缺点 |
|---|---|---|---|
| **多张同尺寸纹理** | alacritty(1024²×N)、xterm(512²×N，含 4→1 合并)、Skia(multitexture pages) | grow 零成本（只 new 不搬数据）；天然支持并发/分批 | 纹理数无限增长需靠驱逐/合并收敛；shader 要按 tex_id/page 分支或分批 |
| **单纹理 resize（重建+重传）** | glyphon(×2 翻倍)、ImGui(resize)、kitty(immutable 数组重建) | 单纹理、UV 连续、shader 简单 | grow 代价高：glyphon 重栅格化全量重传；kitty GPU→CPU 回读再灌；ImGui UV 全失效 |
| **固定网格 + 加 layer** | kitty(znum 增长，immutable 数组重建+回读拷贝) | sprite 索引连续、cell 对齐 | 适合等宽 cell 场景；非等宽不适用 |

> **给 lite-xl 的提示**：lite-xl 字形非等宽（编辑器，非终端），不适合 kitty 网格。
> 选 **alacritty 式多张同尺寸** 最省事（grow 零搬数据），或 **glyphon 式单纹理翻倍**（UV 连续、shader 简单但 grow 要重传）。

### Q2 dirty region 如何追踪和上传？

- **逐字形局部 sub-image（主流）**：alacritty `glTexSubImage2D`、kitty `glTexSubImage3D`、glyphon `queue.write_texture`、ImGui Metal `replaceRegion(rect)`、Skia plot 上传。**无显式 dirty region 表**——新字形首次出现即局部上传，因为字形缓存本身是按需 lazy 填充的，"新出现"= dirty。
- **整页/整纹理重传 + version 增量**：xterm（整 canvas `texImage2D`，靠 per-page `version` 跳过未变页）；ImGui 创建时整纹理上传；glyphon/kitty **grow 时**整纹理/全量重传。
- **顶点缓冲**：基本都 **整缓冲重流**（STREAM_DRAW / write_buffer），不追踪顶点 dirty——GPU 重画成本低，复杂度不划算（与 lite-xl plan.md 的判断一致）。

### Q3 灰度/子像素/彩色字形是否用不同纹理？

- **共用单一 RGBA 纹理**：alacritty、kitty、ImGui、xterm —— RGB 通道复用（LCD 覆盖 / 彩色 / white×alpha），靠 flag + shader 分支。省纹理、省绑定切换，但格式不优（灰度也占 4 字节）。
- **按格式分纹理**：glyphon（mask R8 + color RGBA8）、Skia（kA8/kLCD/kARGB 三张）—— 格式精确（灰度只占 1 字节）、可独立 grow/驱逐，但要多绑一个纹理 + shader 切换。
- **lite-xl 现状**：已经是 3 种 format（Grayscale / Subpixel / Color）+ 3 subpixel 位置的分 surface 设计 → 天然适配"按格式分纹理"。

### Q4 子像素 LCD 渲染在 GPU 上怎么做？

- **shader 层（真 LCD）**：
  - **alacritty**：atlas 存 RGB（LCD 覆盖），fragment shader 用 **dual-source blending**（`location(0,index=1)` 输出作 SRC1 混合因子）单 pass 逐通道混合 `fg*coverage + bg*(1-coverage)`；GLES2 退化为 3-pass 累加。
  - **Skia**：`kLCD` 格式存 RGB 覆盖，专用文本 shader 逐通道混合（同思路，自家实现）。
- **预处理（非 LCD）**：
  - **glyphon**：完全不 LCD；`SubpixelBin` 只量化字形 *放置位置* 到 1/3 像素，栅格化仍灰度 R8。
  - **ImGui / xterm / kitty**：灰度 AA（kitty 额外 sRGB gamma 校正）。
- **lite-xl 现状**：已用 `FT_LCD_MODE_LCD` 生成 RGB 子像素位图 + 缓存 3 个 subpixel 位置（`SUBPIXEL_BITMAPS_CACHED=3`），目前 CPU 逐像素 blend。**alacritty 的 dual-source 方案是直接可照搬的 GPU 化路径**。

### Q5 是否有"map glyph → GPU texture offset"的映射层？

**全部都有**，且分层一致：

```
glyph key  ──hash──►  GlyphRecord{atlas_id/tex_id, uv/rect, metrics}  ──►  GPU 纹理坐标
```
| 实现 | 映射层 | 记录 | 失效机制 |
|---|---|---|---|
| alacritty | `GlyphCache.cache: HashMap<GlyphKey,Glyph>` | `Glyph{tex_id,uv_*,metrics}` | font 变更全清 |
| kitty | `sprite_pos_map`(verstable) → `sprite_index` → `(x,y,z)` | `SpritePosition{idx,rendered,colored}` | layout 变更重建 |
| glyphon | `InnerAtlas.glyph_cache: LruCache` | `GlyphDetails{gpu_cache:InAtlas{x,y},atlas_id}` | LRU 驱逐 + generation |
| xterm | `TextureAtlas._cacheMap: FourKeyMap` | `IRasterizedGlyph{texturePage,texturePosition}` | pageLayoutVersion |
| ImGui | `TextStrike.fCache: THashTable` | `GlyphEntry{atlas loc}` | atlasGeneration |
| Skia | 同 ImGui | 同 | 同 |
| **lite-xl 现状** | `GlyphMap.metrics[bitmap_idx][row]` → `GlyphMetric{atlas_idx,surface_idx,...}` → `GlyphAtlas.surfaces[surface_idx]`(SDL_Surface*) | 已是 key→metric→surface 三层 | 字号变更全清 |

> lite-xl 已有的 `GlyphMetric{atlas_idx, surface_idx, x1,y0,y1, bitmap_left/top, format}` 几乎就是
> `Glyph{tex_id, uv, metrics}` 的 C 版——只需把 `surface_idx` 换成 `(gpu_texture, uv_rect)`。

---

## 9. 对 lite-xl Stage 2 的具体启示

### 9.1 现有结构（src/renderer.c:86-130）

```c
typedef struct {
    SDL_Surface **surfaces;     // bump-allocator，固定宽，字形纵向堆叠
    unsigned int width, nsurface;
} GlyphAtlas;                   // 每种 format 一组

typedef struct {
    float xadvance;
    unsigned short atlas_idx, surface_idx;   // ★ 这就是 "surface pointer → offset"
    int bitmap_left, bitmap_top;
    unsigned int x1, y0, y1;                 // 在 surface 内的矩形
    unsigned short flags; unsigned char format;
} GlyphMetric;

typedef struct {
    GlyphMetric *metrics[SUBPIXEL_BITMAPS_CACHED][GLYPHMAP_ROW]; // 3 个 subpixel 位置
    GlyphAtlas *atlas[EGlyphFormatSize];     // Grayscale / Subpixel / Color
    size_t natlas[EGlyphFormatSize], bytesize;
} GlyphMap;
```

### 9.2 推荐映射（最小改动对接业界模式）

```c
// 新增：把 SDL_Surface* 镜像成 GPU 纹理 + UV（参照 alacritty Glyph / glyphon GlyphDetails）
typedef struct {
    SDL_GPUTexture *gpu_tex;      // 一张 atlas 纹理（多张则数组）
    unsigned int tex_w, tex_h;    // 纹理尺寸
    // shelf 打包状态（参照 alacritty Atlas）
    unsigned int row_extent, row_baseline, row_tallest;
    SDL_GPUTextureFormat fmt;     // R8Unorm(mask) / RGBA8Unorm(color) / 或 RGB(LCD)
    bool dirty;                   // 本帧是否新增字形（局部上传用）
} GlyphAtlasGPU;                  // 取代/并存 GlyphAtlas.surfaces

// GlyphMetric 增补（不破坏 rencache）
typedef struct {
    float xadvance;
    unsigned short atlas_idx;     // -> GlyphAtlasGPU[atlas_idx]
    unsigned short tex_idx;       // 多纹理时的索引（替代 surface_idx）
    int bitmap_left, bitmap_top;
    unsigned short uv_x, uv_y, uv_w, uv_h;  // ★ 直接存像素坐标，shader 里 /tex_w
    unsigned short flags; unsigned char format;
} GlyphMetric;
```

### 9.3 关键函数签名（建议）

```c
// gpu_renderer.c
// 首次渲染字形时：FreeType 位图 -> 局部上传到 atlas 纹理（参照 alacritty insert_inner）
bool gpu_atlas_upload_glyph(GlyphAtlasGPU *a,
                            const FT_Bitmap *bmp, int dst_x, int dst_y,
                            EGlyphFormat fmt);

// grow：参照 alacritty（多张同尺寸，零搬数据）—— 首选
bool gpu_atlas_grow_append(GlyphAtlasGPU **arr, size_t *n, EGlyphFormat fmt);
// 或参照 glyphon（单纹理翻倍 + 全量重传）—— UV 连续但 grow 贵
bool gpu_atlas_grow_double(GlyphAtlasGPU *a);

// 绘制：参照 alacritty glsl3.rs 的 instanced + 按 tex 分批
void gpu_draw_text(RenWindow *ren, SDL_GPUCommandBuffer *cmd,
                   RenFont **font, const char *text, size_t len,
                   float x, int y, RenColor color);
```

### 9.4 格式 & LCD 策略建议

lite-xl 已有 3 format × 3 subpixel 的位图，两种 GPU 化路线：

**路线 A（照搬 alacritty，推荐）**：单一 RGBA atlas，LCD 子像素覆盖存 RGB，
MSL fragment shader 用 **dual-source blending**（Metal 支持 `[[color(0)]]` + `[[color(0), index(1)]]`）单 pass 逐通道混合。
3 个 subpixel 位置各占 atlas 一个槽（保持现有缓存语义）。彩色 emoji 走 `multicolor` 分支。
- 优点：1 张纹理/字体、shader 1 套、与现有 `EGlyphFormat` 几乎 1:1。
- 风险：SDL_gpu 是否暴露 dual-source blend（`SDL_GPUBlendFactor` 需有 `SRC1_COLOR`）；若无则退化 alacritty GLES2 的 3-pass。

**路线 B（照搬 glyphon）**：mask(R8) + color(RGBA8) 两张纹理，LCD 子像素降级为灰度（放弃真 LCD）。
- 优点：wgpu/SDL_gpu 通用、shader 简单（mask 调 alpha）。
- 缺点：**丢掉 lite-xl 现有的 LCD 子像素质量**（macOS Retina 上肉眼可辨）。

> macOS Metal 原生支持 dual-source blending（`MTLRenderPipelineColorAttachmentDescriptor.sourceRGBBlendFactor = blendSource1Color`），
> 若 SDL_gpu 3.2.8 暴露了对应枚举，路线 A 是质量与复杂度最佳平衡。

### 9.5 grow / dirty / 顶点取舍（直接结论）

- **grow**：alacritty 式多张同尺寸（512² 或 1024²），grow = push 新纹理，**零重传**。editor 字形集随文档增长但不爆炸，配合 font 切换时全清即可。
- **dirty**：逐字形局部 `SDL_UploadToGPUTexture`（带 rect），首次栅格化时上传；不维护 dirty 表。
- **顶点**：rencache 命令缓冲已做脏矩形；GPU 侧按 alacritty instanced + 按纹理分批，整缓冲 STREAM 重流。plan.md "GPU 重画成本低，脏矩形优化收益不抵复杂度" 的判断与业界一致（glyphon/xterm 都是整缓冲重流）。

---

## 10. 参考文件索引（本地 .research_repos/）

| 实现 | 关键文件 |
|---|---|
| alacritty | `alacritty/alacritty/src/renderer/text/{atlas.rs,glyph_cache.rs,mod.rs,glsl3.rs}`、`alacritty/alacritty/res/glsl3/{text.f.glsl,text.v.glsl}`、`res/gles2/text.f.glsl` |
| kitty | `kitty/kitty/{glyph-cache.c,glyph-cache.h,fonts.c,fonts.h,shaders.c,data-types.h}` |
| glyphon | `glyphon/src/{text_atlas.rs,cache.rs,text_render.rs,shader.wgsl}` |
| etagere | `etagere/src/{lib.rs,allocator.rs,bucketed.rs}` |
| xterm.js | `xterm.js/addons/addon-webgl/src/{TextureAtlas.ts,GlyphRenderer.ts,WebglRenderer.ts}` |
| ImGui | `imgui/imgui.h`(3751+)、`imgui/backends/imgui_impl_metal.mm`、`imgui/misc/freetype/imgui_freetype.cpp` |
| Skia | github `google/skia` main 分支：`src/gpu/MaskFormat.h`、`src/gpu/ganesh/text/{GrAtlasManager.h,TextStrike.h,GlyphData.h}`、`src/gpu/ganesh/GrDrawOpAtlas.h` |
