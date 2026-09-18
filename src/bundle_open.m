#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <lua.h>
#include <lauxlib.h>
#include <stdio.h>

#ifdef MACOS_USE_BUNDLE

/* 保存 lua_State，菜单点击时用它执行 lite-xl 命令 */
static lua_State *g_lua_state = NULL;

/* 在主线程安全地执行 lite-xl 命令。
 * core.run 已在跑，command.perform 已可用。
 * 用 pcall 包裹避免抛错炸进程。 */
static void run_lite_command(const char *cmd) {
  if (!g_lua_state || !cmd) return;
  NSString *ns_cmd = [NSString stringWithUTF8String:cmd];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_lua_state) return;
    /* 转义单引号，防止命令名里有特殊字符 */
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
  /* cmd 存在 sender 的 representedObject 里（NSString） */
  NSString *cmd = [sender representedObject];
  if (cmd) run_lite_command([cmd UTF8String]);
}
@end

/* 往 menu 加一个菜单项 */
static void add_menu_item(NSMenu *menu, NSString *title, NSString *cmd, NSString *key, MenuActionTarget *target) {
  NSMenuItem *item = [menu addItemWithTitle:title
                                     action:@selector(menuClicked:)
                              keyEquivalent:key ? key : @""];
  [item setTarget:target];
  [item setRepresentedObject:cmd];  /* 用 representedObject 存命令名，避免指针/tag 的内存问题 */
}

void set_macos_bundle_resources(lua_State *L)
{ @autoreleasepool
{
    NSString* resource_path = [[NSBundle mainBundle] resourcePath];
    lua_pushstring(L, [resource_path UTF8String]);
    lua_setglobal(L, "MACOS_RESOURCES");

    g_lua_state = L;

    MenuActionTarget *target = [[MenuActionTarget alloc] init];
    NSMenu *main_menu = [[NSMenu alloc] init];

    /* --- 文件 --- */
    {
      NSMenuItem *g = [main_menu addItemWithTitle:@"文件" action:NULL keyEquivalent:@""];
      NSMenu *m = [[NSMenu alloc] initWithTitle:@"文件"];
      [g setSubmenu:m];
      add_menu_item(m, @"新建文件",   @"doc:new-file",           @"n", target);
      add_menu_item(m, @"打开文件…",  @"core:open-file",         @"o", target);
      add_menu_item(m, @"打开目录…",  @"core:open-project-folder",@"O", target);
      add_menu_item(m, @"保存",       @"doc:save",               @"s", target);
      add_menu_item(m, @"另存为…",    @"doc:save-as",            @"S", target);
      add_menu_item(m, @"关闭标签",   @"root:close",             @"w", target);
      add_menu_item(m, @"退出",       @"core:quit",              @"q", target);
    }
    /* --- 编辑 --- */
    {
      NSMenuItem *g = [main_menu addItemWithTitle:@"编辑" action:NULL keyEquivalent:@""];
      NSMenu *m = [[NSMenu alloc] initWithTitle:@"编辑"];
      [g setSubmenu:m];
      add_menu_item(m, @"撤销",   @"doc:undo",  @"z", target);
      add_menu_item(m, @"重做",   @"doc:redo",  @"Z", target);
      add_menu_item(m, @"剪切",   @"doc:cut",   @"x", target);
      add_menu_item(m, @"复制",   @"doc:copy",  @"c", target);
      add_menu_item(m, @"粘贴",   @"doc:paste", @"v", target);
      add_menu_item(m, @"查找…",  @"find-replace:replace", @"f", target);
    }
    /* --- 视图 --- */
    {
      NSMenuItem *g = [main_menu addItemWithTitle:@"视图" action:NULL keyEquivalent:@""];
      NSMenu *m = [[NSMenu alloc] initWithTitle:@"视图"];
      [g setSubmenu:m];
      add_menu_item(m, @"放大字号", @"scale:increase", @"+", target);
      add_menu_item(m, @"缩小字号", @"scale:decrease", @"-", target);
      add_menu_item(m, @"重置字号", @"scale:reset",    @"0", target);
      add_menu_item(m, @"侧边栏",   @"treeview:toggle", @"\\", target);
    }
    /* --- 命令 --- */
    {
      NSMenuItem *g = [main_menu addItemWithTitle:@"命令" action:NULL keyEquivalent:@""];
      NSMenu *m = [[NSMenu alloc] initWithTitle:@"命令"];
      [g setSubmenu:m];
      add_menu_item(m, @"命令面板…",  @"core:find-command", @"P", target);
      add_menu_item(m, @"查找文件…",  @"core:find-file",    @"p", target);
    }
    /* --- 设置 --- */
    {
      NSMenuItem *g = [main_menu addItemWithTitle:@"设置" action:NULL keyEquivalent:@""];
      NSMenu *m = [[NSMenu alloc] initWithTitle:@"设置"];
      [g setSubmenu:m];
      add_menu_item(m, @"打开用户设置", @"core:open-user-module", nil, target);
      add_menu_item(m, @"打开日志",     @"core:open-log",         nil, target);
    }

    [NSApp setMainMenu:main_menu];
}}
#endif

/* Thanks to mathewmariani, taken from his lite-macos github repository. */
void enable_momentum_scroll() {
  [[NSUserDefaults standardUserDefaults]
    setBool: YES
    forKey: @"AppleMomentumScrollSupported"];
}
