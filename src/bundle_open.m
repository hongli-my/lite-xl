#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <SDL3/SDL.h>
#include <lua.h>
#include "custom_events.h"

#ifdef MACOS_USE_BUNDLE

/* 前向声明 */
@class MenuActionTarget;

static MenuActionTarget *g_menu_target = nil;
static bool g_menu_installed = false;

/* 菜单命令事件：菜单点击只把命令投递到编辑器自己的事件队列，
 * 由 core.on_event 在正常的一帧里执行。
 * 不要在这里直接调 luaL_dostring：AppKit 的动作是在 SDL 抽事件
 * （也就是 Lua 正停在某个 C 调用里）的时候被触发的，那时再进
 * 解释器属于重入，lua_pop(L, lua_gettop(L)) 还会把调用方的栈
 * 一起清掉。 */
static const char *MENU_COMMAND_EVENT = "menucmd";
static char *g_pending_command = NULL;

/* 由事件循环调用：把待执行的命令交给 Lua */
static int menu_command_callback(lua_State *L, SDL_Event *event) {
  if (g_pending_command == NULL) return 0;
  lua_pushstring(L, MENU_COMMAND_EVENT);
  lua_pushstring(L, g_pending_command);
  SDL_free(g_pending_command);
  g_pending_command = NULL;
  return 2;
}

static void push_menu_command(NSString *cmd) {
  if (cmd == nil) return;
  char *dup = SDL_strdup([cmd UTF8String]);
  if (dup == NULL) return;
  /* 后点的菜单项覆盖前一个尚未处理的 */
  SDL_free(g_pending_command);
  g_pending_command = dup;
  CustomEvent event = {0};
  if (!push_custom_event(MENU_COMMAND_EVENT, &event)) {
    SDL_free(g_pending_command);
    g_pending_command = NULL;
  }
}

@interface MenuActionTarget : NSObject
@end
@implementation MenuActionTarget
- (void)menuClicked:(NSMenuItem *)sender {
  push_menu_command([sender representedObject]);
}
@end

static void add_menu_item(NSMenu *menu, NSString *title, NSString *cmd, NSString *key) {
  NSMenuItem *item = [menu addItemWithTitle:title
                                     action:@selector(menuClicked:)
                              keyEquivalent:key ? key : @""];
  [item setTarget:g_menu_target];
  [item setRepresentedObject:cmd];
}

/* 本地事件监视器：在 AppKit 派发 keydown 之前截获 Cmd+W。
 * macOS 下 Cmd+W 会触发 NSWindow performClose:（窗口带标准 close 按钮），
 * 即便窗口 delegate windowShouldClose: 返回 NO 不关窗，SDL3 仍会因
 * "唯一顶层窗口被请求关闭"而 post SDL_EVENT_QUIT；全屏/最大化过渡动画
 * 会让该 quit 延迟到 key 事件之后入队，漏过 system.c 里的 1000ms quit
 * 过滤（CMD_W_QUIT_IGNORE_MS hack），导致编辑器误退出而不是关闭标签。
 *
 * 在事件派发前吃掉 Cmd+W 并直接投递 root:close 命令，从源头消除
 * performClose:，于是不再产生 SDL_EVENT_QUIT。事件被吞后 SDL keymap
 * 那条 cmd+w 绑定也不再触发，关标签统一走 menucmd 路径，其 0.15s
 * 去重与 root:close 自身的 300ms 去重共同处理按键重复，行为同现状。 */
static id g_cmdw_monitor = nil;

static BOOL event_is_cmd_w_key(NSEvent *e) {
  if ([e type] != NSEventTypeKeyDown) return NO;
  /* 只看逻辑修饰键，过滤设备相关位（如 caps lock 状态） */
  NSUInteger mods = [e modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (!(mods & NSEventModifierFlagCommand)) return NO;
  /* 排除带 Option/Control/Shift 的变体，留给其它绑定 */
  if (mods & (NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift)) return NO;
  /* 与 AppKit 的 key equivalent 匹配一致，用忽略修饰键后的字符，
   * 精确拦截 AppKit 会触发 performClose: 的那个事件 */
  return [[[e charactersIgnoringModifiers] lowercaseString] isEqualToString:@"w"];
}

static void install_cmdw_monitor(void) {
  if (g_cmdw_monitor != nil) return;  /* 进程级，只挂一次；原地重启不重复 */
  g_cmdw_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                          handler:^NSEvent *(NSEvent *e) {
    if (event_is_cmd_w_key(e)) {
      push_menu_command(@"root:close");
      return nil;  /* 吞掉，阻止 performClose: → SDL_EVENT_QUIT */
    }
    return e;
  }];
}

static void install_main_menu(void) {
  install_cmdw_monitor();

  /* The key equivalents below intentionally repeat bindings that already exist
   * in data/core/keymap-macos.lua: out of a bundle there is no native menu, so
   * the keymap is the only way to reach those commands.  When the bundle is
   * present AppKit handles the key equivalent before SDL sees the event, so the
   * command runs once.  Keep both in sync. */
  NSMenu *main_menu = [[NSMenu alloc] init];

  {
    NSMenuItem *g = [main_menu addItemWithTitle:@"文件" action:NULL keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"文件"];
    [g setSubmenu:m];
    add_menu_item(m, @"新建文件",   @"core:new-doc",          @"n");
    add_menu_item(m, @"打开文件…",  @"core:open-file",         @"o");
    add_menu_item(m, @"打开目录…",  @"core:open-project-folder",@"O");
    add_menu_item(m, @"打开远端目录…", @"remote-projects:open-dialog", nil);
    add_menu_item(m, @"另存为…",    @"doc:save-as",            @"S");
    add_menu_item(m, @"关闭标签",   @"root:close",             @"w");
    add_menu_item(m, @"退出",       @"core:quit",              @"q");
  }
  {
    NSMenuItem *g = [main_menu addItemWithTitle:@"编辑" action:NULL keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"编辑"];
    [g setSubmenu:m];
    add_menu_item(m, @"撤销",   @"doc:undo",  @"z");
    add_menu_item(m, @"重做",   @"doc:redo",  @"Z");
    add_menu_item(m, @"剪切",   @"doc:cut",   @"x");
    add_menu_item(m, @"复制",   @"doc:copy",  @"c");
    add_menu_item(m, @"粘贴",   @"doc:paste",  @"v");
    add_menu_item(m, @"查找…",  @"find-replace:find",    @"f");
    add_menu_item(m, @"替换…",  @"find-replace:replace", @"r");
  }
  {
    NSMenuItem *g = [main_menu addItemWithTitle:@"视图" action:NULL keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"视图"];
    [g setSubmenu:m];
    add_menu_item(m, @"放大字号", @"scale:increase", @"+");
    add_menu_item(m, @"缩小字号", @"scale:decrease", @"-");
    add_menu_item(m, @"重置字号", @"scale:reset",    @"0");
    add_menu_item(m, @"侧边栏",   @"treeview:toggle", @"\\");
  }
  {
    NSMenuItem *g = [main_menu addItemWithTitle:@"命令" action:NULL keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"命令"];
    [g setSubmenu:m];
    add_menu_item(m, @"命令面板…",  @"core:find-command", @"P");
    add_menu_item(m, @"查找文件…",  @"core:find-file",    @"p");
  }
  {
    NSMenuItem *g = [main_menu addItemWithTitle:@"设置" action:NULL keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"设置"];
    [g setSubmenu:m];
    add_menu_item(m, @"打开用户设置", @"core:open-user-module", nil);
    add_menu_item(m, @"打开日志",     @"core:open-log",         nil);
  }

  [NSApp setMainMenu:main_menu];
}

/* SDL 事件观察器：等窗口首次显示后（SDL 已完成 NSApp 初始化）再设菜单。
 * 过早设菜单会被 SDL3 的 finishLaunching 覆盖；过晚则用户看到空菜单栏。
 * 窗口 EXPOSED 事件意味着 SDL 已建好窗口、NSApp 已 run 起来。 */
static bool SDLCALL menu_event_watch(void *userdata, SDL_Event *event) {
  if (!g_menu_installed && event->type == SDL_EVENT_WINDOW_EXPOSED) {
    g_menu_installed = true;
    dispatch_async(dispatch_get_main_queue(), ^{
      install_main_menu();
      [NSApp activateIgnoringOtherApps:YES];
      /* 不在观察器回调里改观察器列表，放到主队列里摘 */
      SDL_RemoveEventWatch(menu_event_watch, NULL);
    });
  }
  return SDL_APP_CONTINUE;
}

void set_macos_bundle_resources(lua_State *L)
{ @autoreleasepool
{
    NSString* resource_path = [[NSBundle mainBundle] resourcePath];
    lua_pushstring(L, [resource_path UTF8String]);
    lua_setglobal(L, "MACOS_RESOURCES");

    /* 菜单项对 target 是弱引用，而 Lite XL 可以原地重启 Lua 状态
     * （autorestart 保存 init.lua 就会触发），所以 target 只创建一次、
     * 与进程同生命周期，重启后老菜单项不会指到已经被释放的对象上。 */
    if (g_menu_target == nil) {
      g_menu_target = [[MenuActionTarget alloc] init];
      register_custom_event(MENU_COMMAND_EVENT, menu_command_callback);
      /* 不提前创建 NSApp——让 SDL3 自己创建并管理生命周期。
       * 挂事件观察器，等 SDL 创建窗口后再设菜单。 */
      SDL_AddEventWatch(menu_event_watch, NULL);
    } else if (g_menu_installed) {
      /* 原地重启：窗口已经存在，不会再有 EXPOSED 事件，直接同步重装菜单
       * （此时 SDL 的启动流程已经结束，不会再被覆盖）。 */
      install_main_menu();
    }
}}
#endif

/* Thanks to mathewmariani, taken from his lite-macos github repository. */
void enable_momentum_scroll() {
  [[NSUserDefaults standardUserDefaults]
    setBool: YES
    forKey: @"AppleMomentumScrollSupported"];
}
