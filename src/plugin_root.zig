const plugin = @import("systems/plugin.zig");
const hot = @import("hot_reload/abi.zig");

pub export fn score_plugin_descriptor() *const hot.PluginDescriptor {
    return plugin.descriptor();
}
