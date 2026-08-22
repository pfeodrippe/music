const hot = @import("../hot_reload/abi.zig");
const transport = @import("transport.zig");
const practice = @import("practice.zig");

const all_systems = transport.systems ++ practice.systems;

const development_plugin = hot.PluginDescriptor{
    .abi = hot.abi_version,
    .generation = 1,
    .systems = &all_systems,
    .system_count = all_systems.len,
};

/// Development dynamic-library entrypoint is exported by `plugin_root.zig`.
/// Release builds call this descriptor statically and contain no loader.
pub fn descriptor() *const hot.PluginDescriptor {
    return &development_plugin;
}
