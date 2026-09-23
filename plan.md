# GPU 渲染器开发计划 (gpu-renderer 分支)

## 背景与约束
- fork 自用，主平台 macOS (aarch64-darwin)，SDL3 3.2.8 已带完整 SDL_gpu API + Metal 后端
- 上游 lite-xl **无 GPU 渲染实现**（81 分支无一相关），本实现为自研
- 我无法 GUI 运行时测试，需用户配合验证每个 Stage
- shader 方案：MSL 源码字符串内嵌，Metal 后端运行时编译（无需 metal CLI / SDL_shadercross）
- 仅 macOS Metal 后端（跨平台需后续加 SPIR-V/DXIL，非本期目标）

## 架构决策
rencache 命令缓冲层**渲染后端无关**（Command 只存 rect/color/text/font），完全不动。
改造点仅在 `renderer.c` 的 `ren_draw_rect/text/image` 后端 + `renwindow.c` 窗口目标。

```
Lua (api/renderer.c)  -- 不动
  └─ rencache.c  -- 不动 (命令缓冲 + 脏矩形)
       └─ renderer.c ren_draw_rect/text/image  -- 分派到 GPU 后端
            └─ [NEW] gpu_renderer.c  -- SDL_gpu 提交
                 └─ Metal (macOS) / Vulkan (Linux,后续) / D3D12 (Win,后续)
```

## 分阶段实施

### Stage 1 — GPU 管线骨架 + 矩形渲染 (最小闭环)
**目标**：GPU device 初始化 + draw_rect 走 GPU，验证整个 SDL_gpu 管线通。
- 新增 `src/gpu_renderer.c` / `src/gpu_renderer.h`：
  - GPU device/swapchain 创建
  - MSL shader（顶点+片段，纯色填充）
  - graphics pipeline 创建
  - 顶点缓冲（矩形 quad）
  - render pass + draw
- 改 `src/renwindow.c`：增加 GPU 字段，window surface 与 GPU swapchain 共存（渐进迁移）
- 改 `src/renderer.c`：`ren_draw_rect` 分派到 GPU（保留 CPU fallback 作 debug）
- 改 `src/rencache.c`：`end_frame` 增加 GPU 提交路径
- meson.build：加 gpu_renderer.c，macOS 链接 Metal framework
- **验证**：编译通过 + 启动不崩 + 能看到 GPU 绘制的矩形（背景/选区）

### Stage 2 — 文本渲染 (glyph atlas → GPU 纹理)
**目标**：文字走 GPU，这是最大头。
- FreeType 位图 → GPU texture atlas（已多级缓存，迁移到 GPU 纹理）
- MSL 片段 shader 增加纹理采样
- 顶点缓冲携带 UV 坐标
- 字形缓存结构改造：GlyphAtlas 从 SDL_Surface → SDL_GPUTexture
- **验证**：文本正常显示，中英文/emoji

### Stage 3 — 图片渲染 + 收尾
- `ren_draw_image` 走 GPU 纹理
- 删除 software fallback（或保留为编译选项）
- rencache end_frame 简化：GPU 用 scissor clip，不必每脏矩形重放全部命令
- 性能对比

## 风险
- R1: MSL 运行时编译失败 → shader 语法错误难调，需仔细对照 SDL_gpu 期望的绑定布局
- R2: swapchain 与现有 SDL_Renderer 路径冲突 → renwindow 需谨慎双路径共存
- R3: glyph atlas 上传格式（subpixel RGB24 / color BGRA）与 GPU 纹理格式匹配
- R4: 我无法 GUI 测试，每 Stage 需用户验证

## 当前状态
- [x] 分支 gpu-renderer 已建
- [x] 调研完成
- [x] Stage 1 完成（GPU present 后端，SDL_gpu device/swapchain/blit，commit d289c72）
- [ ] Stage 2

---

# Stage 2 详细规划 — 文本渲染上 GPU

## 核心难点（Stage 1 后才暴露的架构约束）

Stage 1 只接管 present，draw_rect/draw_text 仍画到 CPU `SDL_Surface`。
Stage 2 要把文本上 GPU，但发现一个**根本约束**：

> draw_text 和 draw_rect **必须一起上 GPU**，否则无法合成。

原因：如果 render target 变成 GPU texture，CPU 版 draw_text 就没地方画
（GPU texture 不能被 CPU 直接写）；反之若保持 CPU surface，draw_text 上
GPU 就失去意义。两者绑定在同一绘制目标上。

所以 Stage 2 的真实范围 = **draw_rect + draw_text 一起迁移到 GPU render target**。

## 当前 CPU 渲染管线（理解）

```
Lua → rencache 命令缓冲 (SET_CLIP/DRAW_RECT/DRAW_TEXT/DRAW_IMAGE)
  └─ rencache_end_frame:
       1. hash 每条命令 → 算出脏 cell → 脏矩形
       2. 对每个脏矩形: set clip → 重放全部命令(只画相交的)
            ren_draw_rect  → SDL_FillSurfaceRect / BlitSurfaceScaled (CPU)
            ren_draw_text  → 逐像素 alpha blend 字形→surface (CPU 热点)
       3. ren_update_rects → Stage1 GPU present
```

glyph cache 结构：
- `RenFont.glyphs` (GlyphMap) → `atlas[format][idx]` (GlyphAtlas) → `surfaces[]` (SDL_Surface*)
- 3 种 format: Grayscale(8bit alpha) / Subpixel(24bit LCD RGB) / Color(32bit BGRA emoji)
- 每字形缓存 3 个 subpixel 版本 (SUBPIXEL_BITMAPS_CACHED=3)
- surface 是 bump-allocator 式：固定宽，字形从上往下排列
- `font_load_glyph_bitmap` 首次渲染后缓存，返回的 surface 长期存活

## Stage 2 实施方案

### 2a. GPU render target + draw_rect 上 GPU
**新增** `gpu_renderer.c`:
- `gpu_target_create(w,h)` — 创建 render target GPU texture (COLOR_TARGET | SAMPLER)
- `gpu_begin_render_pass(cmd)` — BeginGPURenderPass，load_op=LOAD (保留上一帧)
- `gpu_draw_rect(cmd, rect, color, clip)` — 纯色矩形 + alpha blend
  - MSL vertex shader: quad 顶点 → clip space
  - MSL fragment shader: uniform color * blend
  - pipeline: blend state = SRC_ALPHA/ONE_MINUS_SRC_ALPHA
- `gpu_target_present(ren, cmd)` — render target texture → swapchain (BlitGPUTexture)

**改** `renderer.c`:
- `ren_draw_rect` 增加 `#ifdef LITE_USE_GPU_RENDERER` 分支 → gpu_draw_rect
- 仍保留 CPU 路径作 fallback

**改** `rencache.c` end_frame:
- GPU 路径: 不再按脏矩形重放，改为 **full-frame clear + 单次重放全部命令**
  (GPU 重绘成本低，脏矩形优化在 GPU 上收益不抵复杂度)
- 或保留脏矩形 + scissor rect（更复杂，2b 再决定）

### 2b. glyph atlas → GPU texture + draw_text 上 GPU
**新增** glyph atlas GPU 镜像:
- `GlyphAtlas` 增加 `SDL_GPUTexture *gpu_tex` 字段
- `font_load_glyph_bitmap` 首次渲染后：upload surface → gpu_tex (lazy)
- atlas surface 增长时：重建 gpu_tex + 全量 upload

**新增** `gpu_draw_text`:
- MSL fragment shader: 采样 atlas texture + tint color + alpha blend
- 3 种 format 分 3 个 pipeline（或 1 个 pipeline + format uniform）
- 顶点: quad (位置 + UV + color uniform)
- subpixel: 特殊处理（RGB 子像素采样，shader 输出 3 通道）

**改** `renderer.c`:
- `ren_draw_text` 增加 GPU 分支 → gpu_draw_text

### 2c. 清理 + 验证
- `ren_draw_image` 上 GPU（简单：texture blit）
- 删除/保留 CPU fallback（编译选项控制）
- Retina scale 验证（顶点坐标 * scale）
- 性能对比

## 工作量与风险评估

| 项 | 估算 | 风险 |
|----|------|------|
| MSL shader (vertex + 3 fragment) | ~150 行 | R1: 运行时编译失败难调 |
| gpu_renderer.c 扩展 | ~400 行 | R2: pipeline/sampler 配置错 || glyph atlas GPU 镜像 | ~200 行 | R3: surface/tex 格式匹配 |
| renderer.c/rencache.c 改造 | ~200 行 | R4: 脏矩形机制取舍 |
| **合计** | **~950 行** | **需用户每步 GUI 验证** |

## 替代方案（低风险，非 GPU）

如果 Stage 2 风险过高，可先做 **CPU draw_text 性能优化**（行为不变，可编译验证）:
- `SDL_GetPixelFormatDetails` 当前在**每个字形每一行**都调用（renderer.c:722-723）— 明显性能 bug，应提到循环外
- 假定 surface format 固定 BGRA32，去掉运行时 format 查询
- 行级 memcpy 优化
- 风险低，但不是真正的 GPU 渲染
