#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <SDL3/SDL.h>
#include <lua.h>
#include <lauxlib.h>
#include <stdio.h>

#ifdef MACOS_USE_BUNDLE

/* 前向声明 */
@class MenuActionTarget;

/* 保存 lua_State，菜单点击时用它执行 lite-xl 命令 */
static lua_State *g_lua_state = NULL;
static MenuActionTarget *g_menu_target = nil;
static bool g_menu_installed = false;

/* 在主线程安全地执行 lite-xl 命令 */
static void run_lite_command(const char *cmd) {
  if (!g_lua_state || !cmd) return;
  NSString *ns_cmd = [NSString stringWithUTF8String:cmd];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_lua_state) return;
    NSString *escaped = [ns_cmd stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString *lua = [NSString stringWithFormat:
      @"pcall(function() require('core.command').perform('%@') end)", escaped];
    luaL_dostring(g_lua_state, [lua UTF8String]);
    lua_pop(g_lua_state, lua_gettop(g_lua_state));
  });
}

@interface MenuActionTarget : NSObject
@end
@implementation MenuActionTarget
- (void)menuClicked:(NSMenuItem *)sender {
  NSString *cmd = [sender representedObject];
  if (cmd) run_lite_command([cmd UTF8String]);
}
@end

static void add_menu_item(NSMenu *menu, NSString *title, NSString *cmd, NSString *key) {
  NSMenuItem *item = [menu addItemWithTitle:title
                                     action:@selector(menuClicked:)
                              keyEquivalent:key ? key : @""];
  [item setTarget:g_menu_target];
  [item setRepresentedObject:cmd];
}

static void install_main_menu(void) {
  NSMenu *main_menu = [[NSMenu alloc] init];

  {
    NSMenuItem *g = [main_menu addItemWithTitle:@"文件" action:NULL keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"文件"];
    [g setSubmenu:m];
    add_menu_item(m, @"新建文件",   @"doc:new-file",           @"n");
    add_menu_item(m, @"打开文件…",  @"core:open-file",         @"o");
    add_menu_item(m, @"打开目录…",  @"core:open-project-folder",@"O");
    add_menu_item(m, @"保存",       @"doc:save",               @"s");
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
    add_menu_item(m, @"粘贴",   @"doc:paste", @"v");
    add_menu_item(m, @"查找…",  @"find-replace:replace", @"f");
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
  fprintf(stderr, "[menu] install_main_menu done, NSApp=%p mainMenu=%p\n",
          (void*)NSApp, (void*)[NSApp mainMenu]); fflush(stderr);
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
    });
    SDL_RemoveEventWatch(menu_event_watch, NULL);
  }
  return SDL_APP_CONTINUE;
}

void set_macos_bundle_resources(lua_State *L)
{ @autoreleasepool
{
    NSString* resource_path = [[NSBundle mainBundle] resourcePath];
    lua_pushstring(L, [resource_path UTF8String]);
    lua_setglobal(L, "MACOS_RESOURCES");

    g_lua_state = L;
    g_menu_target = [[MenuActionTarget alloc] init];

    /* 不提前创建 NSApp——让 SDL3 自己创建并管理生命周期。
     * 挂事件观察器，等 SDL 创建窗口后再设菜单。 */
    SDL_AddEventWatch(menu_event_watch, NULL);
    fprintf(stderr, "[menu] event watch added\n"); fflush(stderr);
}}
#endif

/* Thanks to mathewmariani, taken from his lite-macos github repository. */
void enable_momentum_scroll() {
  [[NSUserDefaults standardUserDefaults]
    setBool: YES
    forKey: @"AppleMomentumScrollSupported"];
}
