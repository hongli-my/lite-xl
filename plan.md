# GPU 渲染器开发计划 (gpu-renderer 分支)

## 当前状态：✅ 功能完整 + 优化完成

GPU 渲染器已实现并验证通过。所有渲染原语（矩形、文字、图片）均走 GPU/Metal，
CPU 回退保留为编译时选项。实测 ~5-6ms/帧（≈167fps），远低于 16ms (60fps) 预算。

## 架构

```
Lua (api/renderer.c)  — 不动
  └─ rencache.c  — 不动 (命令缓冲 + 脏矩形)
       └─ renderer.c ren_draw_rect/text/image  — #ifdef 分派到 GPU
            └─ gpu_renderer.c  — SDL_gpu 提交 (1092 行)
                 └─ Metal (macOS)
```

### 渲染流水线
1. Lua 调 rencache 命令（SET_CLIP / DRAW_RECT / DRAW_TEXT / DRAW_IMAGE）
2. `rencache_end_frame`：hash 命令 → 算脏矩形 → 对每个脏矩形重放全部命令
3. GPU 路径：`gpu_begin_frame`（map vbuf + acquire cmd）→ replay draw cmds → `gpu_end_frame`
4. `gpu_end_frame`：flush atlas uploads → upload verts → render pass → replay draws → blit → submit

### 关键设计
- **延迟绘制**：SDL_gpu 不允许 render pass 中穿插 copy pass，所以顶点先收集到 CPU 数组，
  帧末一次性 upload + replay
- **Premultiplied alpha blending**：grayscale `coverage = glyph.r * color.a`；
  subpixel LCD 用 average 近似；color emoji `coverage = glyph.a * color.a`
  Pipeline blend: `SRC_ALPHA / ONE_MINUS_SRC_ALPHA` + `BLENDOP_ADD`
- **Glyph atlas GPU 镜像**：`GlyphAtlas.gpu_tex`，lazy 创建 + dirty rect 上传
- **顶点缓冲**：GPU buffer，2x 增长策略，初始 4096 verts (64KB)
- **TRIANGLE_LIST**（非 STRIP）：text/image 用 6 verts/quad，支持批合并

## 已完成的优化

| 优化 | commit | 效果 |
|------|--------|------|
| surf_xfer lazy 化 | 8a44efa | GPU 路径不再每帧分配 21MB |
| DRAW_IMAGE 支持 | 8a44efa | 图片走 GPU texture + text pipeline |
| LITE_GPU_STATS 性能测量 | 8a44efa | 每帧 ms/draws/verts/uploads |
| 顶点缓冲复用 | 8a44efa | 2x 增长，避免每帧重建 |
| **glyph quad 批合并** | 8ec1e01 | draws 373→93 (4x)，TRIANGLE_LIST |
| clip early-out | 12bb287 | 空 clip 跳过 push_draw |
| meson custom_target | e1a5a5c | shader header 自动重生成 |
| image 上传缓存 | dee6208 | 同一 surface 跳过 convert+upload |

## 文件清单

| 文件 | 行数 | 说明 |
|------|------|------|
| `src/gpu_renderer.c` | 1071 | GPU 后端核心 |
| `src/gpu_renderer.h` | 97 | 公开接口 |
| `src/gpu_shaders.msl` | 137 | MSL shader 源码 |
| `src/gpu_shaders_msl.h` | 146 | 自动生成的 C 字符串头 |
| `scripts/msl-to-header.py` | 35 | .msl → .h 转换器 |
| `scripts/deploy-gpu.sh` | 18 | 部署到 .app bundle |
| **合计** | **1504** | |

## 构建

```bash
# 首次配置（gpu_renderer 默认关闭）
cd build-static
meson setup .. -Dgpu_renderer=true -Ddefault_library=static

# 编译
ninja

# 部署到 .app（ninja 只编译 binary，不更新 bundle）
bash scripts/deploy-gpu.sh

# 运行（Metal validation 默认开）
~/Desktop/"Lite XL.app/Contents/MacOS/lite-xl"

# 性能测量
LITE_GPU_STATS=1 ~/Desktop/"Lite XL.app/Contents/MacOS/lite-xl"
```

改 shader 后无需手动跑脚本——meson custom_target 自动重新生成 `gpu_shaders_msl.h`。

## 后续可选方向

1. **draw call 进一步合并** — 当前 ~93-387 draws/帧。rencache 每个文本命令
   是独立 `ren_draw_text_gpu` 调用，批合并只在单命令内有效。跨命令合并需
   改 draw cmd 结构（texture array 或 frame-level batch buffer），复杂度高。

2. **subpixel LCD 精确路径** — 当前用 average 近似。framebuffer fetch
   (`[[color(0)]]`) 本可精确合成，但产生黑方块（根因未明）。默认 grayscale
   不受影响。

3. **跨平台后端** — Vulkan (Linux) / D3D12 (Windows)。需 SDL_shadercross
   做 MSL→SPIR-V/DXIL 交叉编译，或手写各平台 shader。

4. **index buffer** — TRIANGLE_LIST + 静态 index buffer 可将顶点数据从
   6→4/quad（-33%），但当前顶点量小（~8K verts/帧），收益可忽略。
