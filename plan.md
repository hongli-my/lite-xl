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
- [ ] Stage 1
