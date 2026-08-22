#include <webgpu/webgpu_cpp.h>
#include "ui_shader.h"
#include <emscripten.h>
#include <emscripten/html5.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

extern "C" {
struct ScoreDrawItem { float rect[4]; float color[4]; float params[4]; };
struct ScoreHostEvent { uint8_t pitch; uint8_t velocity; uint8_t channel; uint8_t on; };
struct ScoreAccessibilityItem { uint32_t id; uint32_t role; float rect[4]; uint32_t label_length; uint32_t flags; uint8_t label[48]; };
bool score_init(float width, float height, float pixel_ratio);
void score_shutdown();
void score_frame(float delta_seconds);
void score_resize(float width, float height, float pixel_ratio);
void score_pointer(uint32_t kind, uint32_t pointer_type, uint32_t id, float x, float y, uint32_t buttons, float pressure, float tilt_x, float tilt_y, float scroll_x, float scroll_y);
void score_key(uint32_t key, uint32_t scancode, uint32_t modifiers, uint32_t pressed, uint32_t repeat);
void score_midi(uint64_t time_ns, uint8_t status, uint8_t data1, uint8_t data2);
void score_microphone_pitch(uint8_t pitch, float confidence);
uint32_t score_host_request();
void score_host_status(uint32_t status);
size_t score_drain_playback(ScoreHostEvent* events, size_t capacity);
const ScoreDrawItem* score_draw_items();
uint32_t score_draw_count();
const ScoreAccessibilityItem* score_accessibility_items();
uint32_t score_accessibility_count();
void score_accessibility_activate(uint32_t id);
uint32_t score_import(const uint8_t* bytes, size_t length, uint32_t kind);
size_t score_serialize(uint8_t* bytes, size_t capacity);
uint32_t score_restore(const uint8_t* bytes, size_t length);
}

namespace {
constexpr uint64_t kMaxItems = 16384;

struct Globals { float viewport[2]; float time; float pixel_ratio; };

struct Runtime {
    wgpu::Instance instance;
    wgpu::Adapter adapter;
    wgpu::Device device;
    wgpu::Queue queue;
    wgpu::Surface surface;
    wgpu::TextureFormat format = wgpu::TextureFormat::BGRA8Unorm;
    wgpu::Buffer globals;
    wgpu::Buffer items;
    wgpu::BindGroup bind_group;
    wgpu::RenderPipeline pipeline;
    uint32_t physical_width = 0;
    uint32_t physical_height = 0;
    double logical_width = 0;
    double logical_height = 0;
    double pixel_ratio = 1;
    double previous_seconds = 0;
    double next_autosave_seconds = 0;
};

Runtime runtime;

double devicePixelRatio() { return EM_ASM_DOUBLE({ return window.devicePixelRatio || 1; }); }

EM_JS(void, webInitialize, (), { ScoreHost.initialize(Module.canvas); });
EM_JS(void, webEnsureAudio, (), { ScoreHost.ensureAudio(); });
EM_JS(void, webOpenFile, (), { ScoreHost.openFile(); });
EM_JS(void, webExportSnapshot, (const uint8_t* bytes, size_t length), { ScoreHost.exportSnapshot(HEAPU8.slice(bytes, bytes + length)); });
EM_JS(void, webEnsureInputs, (), { ScoreHost.ensureInputs(); });
EM_JS(void, webStartRecording, (), { ScoreHost.startRecording(); });
EM_JS(void, webStopRecording, (), { ScoreHost.stopRecording(); });
EM_JS(void, webReplayAudio, (), { ScoreHost.replayAudio(); });
EM_JS(void, webAudioMidi, (uint32_t status, uint32_t data1, uint32_t data2), { ScoreHost.sendAudioMidi(status, data1, data2); });
EM_JS(void, webAllNotesOff, (), { ScoreHost.allNotesOff(); });
EM_JS(void, webMetronome, (uint32_t accent), { ScoreHost.metronome(accent != 0); });
EM_JS(void, webSaveSnapshot, (const uint8_t* bytes, size_t length), { ScoreHost.saveSnapshot(HEAPU8.slice(bytes, bytes + length)); });
EM_JS(void, webUpdateAccessibility, (const ScoreAccessibilityItem* items, uint32_t count), { ScoreHost.updateAccessibility(items, count); });
EM_JS(void, webFatal, (const char* reason), {
    const detail = UTF8ToString(reason);
    if (Module.canvas) Module.canvas.remove();
    const panel = document.createElement('main');
    panel.setAttribute('role', 'alert');
    panel.style.cssText = 'box-sizing:border-box;min-height:100vh;display:grid;place-content:center;padding:32px;background:#090b0e;color:#e8ebe6;font:16px/1.55 system-ui,-apple-system,sans-serif';
    panel.innerHTML = '<section style="max-width:620px;padding:32px;border:1px solid #293039;border-radius:18px;background:#12161c"><p style="margin:0 0 8px;color:#59e8e0;font-weight:700;letter-spacing:.12em">SCORE NEEDS WEBGPU</p><h1 style="margin:0 0 16px;font-size:28px">This browser cannot start the GPU music studio.</h1><p style="margin:0 0 12px;color:#b9c0c7"></p><p style="margin:0;color:#8b949e">Use a current WebGPU-capable browser with hardware acceleration enabled, or run the native macOS app. Score intentionally has no WebGL, Canvas 2D, or software renderer.</p></section>';
    panel.querySelector('section p:nth-of-type(2)').textContent = detail;
    document.body.replaceChildren(panel);
});

void processHostRequest() {
    switch (score_host_request()) {
        case 1: webOpenFile(); break;
        case 2:
        case 3: webEnsureInputs(); break;
        case 4: {
            static std::vector<uint8_t> export_bytes(4 * 1024 * 1024);
            const size_t export_length = score_serialize(export_bytes.data(), export_bytes.size());
            if (export_length != 0) webExportSnapshot(export_bytes.data(), export_length);
            break;
        }
        case 5: webStartRecording(); break;
        case 6: webStopRecording(); break;
        case 7: webReplayAudio(); break;
        default: break;
    }
}

void pumpPlayback() {
    ScoreHostEvent events[128];
    const size_t count = score_drain_playback(events, 128);
    for (size_t index = 0; index < count; ++index) {
        const ScoreHostEvent& event = events[index];
        if (event.on == 2) {
            webAllNotesOff();
            continue;
        }
        if (event.on == 3) {
            webMetronome(event.velocity >= 120 ? 1 : 0);
            continue;
        }
        const uint32_t status = (event.on ? 0x90u : 0x80u) | event.channel;
        const uint32_t velocity = event.on ? event.velocity : 0;
        webAudioMidi(status, event.pitch, velocity);
    }
}

void saveSnapshot() {
    static std::vector<uint8_t> bytes(4 * 1024 * 1024);
    const size_t length = score_serialize(bytes.data(), bytes.size());
    if (length != 0) webSaveSnapshot(bytes.data(), length);
}

void configureSurface() {
    emscripten_get_element_css_size("#canvas", &runtime.logical_width, &runtime.logical_height);
    runtime.pixel_ratio = devicePixelRatio();
    uint32_t width = std::max(1u, static_cast<uint32_t>(runtime.logical_width * runtime.pixel_ratio));
    uint32_t height = std::max(1u, static_cast<uint32_t>(runtime.logical_height * runtime.pixel_ratio));
    if (width == runtime.physical_width && height == runtime.physical_height) return;
    runtime.physical_width = width;
    runtime.physical_height = height;
    emscripten_set_canvas_element_size("#canvas", width, height);
    wgpu::SurfaceConfiguration config{};
    config.device = runtime.device;
    config.format = runtime.format;
    config.usage = wgpu::TextureUsage::RenderAttachment;
    config.width = width;
    config.height = height;
    config.presentMode = wgpu::PresentMode::Fifo;
    config.alphaMode = wgpu::CompositeAlphaMode::Opaque;
    runtime.surface.Configure(&config);
    score_resize(static_cast<float>(runtime.logical_width), static_cast<float>(runtime.logical_height), static_cast<float>(runtime.pixel_ratio));
}

EM_BOOL wheelCallback(int, const EmscriptenWheelEvent* event, void*) {
    score_pointer(4, 0, 0, event->mouse.targetX, event->mouse.targetY, event->mouse.buttons, 0, 0, 0, event->deltaX, event->deltaY);
    return EM_TRUE;
}

EM_BOOL keyCallback(int type, const EmscriptenKeyboardEvent* event, void*) {
    uint32_t modifiers = (event->shiftKey ? 1u : 0u) | (event->ctrlKey ? 2u : 0u) | (event->altKey ? 4u : 0u) | (event->metaKey ? 8u : 0u);
    uint32_t key = event->keyCode;
    score_key(key, event->which, modifiers, type == EMSCRIPTEN_EVENT_KEYUP ? 0 : 1, event->repeat ? 1 : 0);
    if (key == 32) return EM_TRUE;
    return EM_FALSE;
}

void frame() {
    configureSurface();
    const double now = emscripten_get_now() / 1000.0;
    const float delta = runtime.previous_seconds == 0 ? 1.0f / 60.0f : static_cast<float>(std::min(now - runtime.previous_seconds, 0.1));
    runtime.previous_seconds = now;
    score_frame(delta);
    webUpdateAccessibility(score_accessibility_items(), score_accessibility_count());
    processHostRequest();
    pumpPlayback();
    if (runtime.next_autosave_seconds == 0 || now >= runtime.next_autosave_seconds) {
        saveSnapshot();
        runtime.next_autosave_seconds = now + 2.0;
    }
    const uint32_t count = score_draw_count();
    const ScoreDrawItem* draw_items = score_draw_items();
    Globals globals{{static_cast<float>(runtime.logical_width), static_cast<float>(runtime.logical_height)}, static_cast<float>(now), static_cast<float>(runtime.pixel_ratio)};
    runtime.queue.WriteBuffer(runtime.globals, 0, &globals, sizeof(globals));
    if (count != 0) runtime.queue.WriteBuffer(runtime.items, 0, draw_items, count * sizeof(ScoreDrawItem));
    wgpu::SurfaceTexture surface_texture{};
    runtime.surface.GetCurrentTexture(&surface_texture);
    if (!surface_texture.texture) return;
    wgpu::TextureView view = surface_texture.texture.CreateView();
    wgpu::RenderPassColorAttachment attachment{};
    attachment.view = view;
    attachment.loadOp = wgpu::LoadOp::Clear;
    attachment.storeOp = wgpu::StoreOp::Store;
    attachment.clearValue = {0.035, 0.043, 0.055, 1.0};
    wgpu::RenderPassDescriptor pass_descriptor{};
    pass_descriptor.colorAttachmentCount = 1;
    pass_descriptor.colorAttachments = &attachment;
    wgpu::CommandEncoder encoder = runtime.device.CreateCommandEncoder();
    wgpu::RenderPassEncoder pass = encoder.BeginRenderPass(&pass_descriptor);
    pass.SetPipeline(runtime.pipeline);
    pass.SetBindGroup(0, runtime.bind_group);
    pass.Draw(6, count, 0, 0);
    pass.End();
    wgpu::CommandBuffer commands = encoder.Finish();
    runtime.queue.Submit(1, &commands);
    // Emdawnwebgpu presents automatically when this requestAnimationFrame ends.
    // Calling Surface::Present from Wasm is deliberately unsupported.
}

void initialized() {
    runtime.queue = runtime.device.GetQueue();
    wgpu::EmscriptenSurfaceSourceCanvasHTMLSelector canvas_source{};
    canvas_source.selector = "#canvas";
    wgpu::SurfaceDescriptor surface_descriptor{};
    surface_descriptor.nextInChain = &canvas_source;
    runtime.surface = runtime.instance.CreateSurface(&surface_descriptor);
    wgpu::SurfaceCapabilities capabilities{};
    runtime.surface.GetCapabilities(runtime.adapter, &capabilities);
    runtime.format = capabilities.formats[0];
    wgpu::ShaderSourceWGSL wgsl{};
    wgsl.code = wgpu::StringView(reinterpret_cast<const char*>(ui_wgsl), ui_wgsl_len);
    wgpu::ShaderModuleDescriptor shader_descriptor{};
    shader_descriptor.nextInChain = &wgsl;
    wgpu::ShaderModule module = runtime.device.CreateShaderModule(&shader_descriptor);
    wgpu::BufferDescriptor globals_descriptor{}; globals_descriptor.label="score globals"; globals_descriptor.usage=wgpu::BufferUsage::Uniform | wgpu::BufferUsage::CopyDst; globals_descriptor.size=sizeof(Globals);
    runtime.globals = runtime.device.CreateBuffer(&globals_descriptor);
    wgpu::BufferDescriptor items_descriptor{}; items_descriptor.label="score draw items"; items_descriptor.usage=wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst; items_descriptor.size=kMaxItems*sizeof(ScoreDrawItem);
    runtime.items = runtime.device.CreateBuffer(&items_descriptor);
    wgpu::BindGroupLayoutEntry entries[2]{};
    entries[0].binding = 0; entries[0].visibility = wgpu::ShaderStage::Vertex | wgpu::ShaderStage::Fragment; entries[0].buffer.type = wgpu::BufferBindingType::Uniform;
    entries[1].binding = 1; entries[1].visibility = wgpu::ShaderStage::Vertex | wgpu::ShaderStage::Fragment; entries[1].buffer.type = wgpu::BufferBindingType::ReadOnlyStorage;
    wgpu::BindGroupLayoutDescriptor bgl_descriptor{}; bgl_descriptor.entryCount = 2; bgl_descriptor.entries = entries;
    wgpu::BindGroupLayout bgl = runtime.device.CreateBindGroupLayout(&bgl_descriptor);
    wgpu::PipelineLayoutDescriptor layout_descriptor{}; layout_descriptor.bindGroupLayoutCount = 1; layout_descriptor.bindGroupLayouts = &bgl;
    wgpu::PipelineLayout layout = runtime.device.CreatePipelineLayout(&layout_descriptor);
    wgpu::BlendState blend{}; blend.color.srcFactor=wgpu::BlendFactor::SrcAlpha; blend.color.dstFactor=wgpu::BlendFactor::OneMinusSrcAlpha; blend.alpha.srcFactor=wgpu::BlendFactor::One; blend.alpha.dstFactor=wgpu::BlendFactor::OneMinusSrcAlpha;
    wgpu::ColorTargetState target{}; target.format=runtime.format; target.blend=&blend;
    wgpu::FragmentState fragment{}; fragment.module=module; fragment.entryPoint="fs_main"; fragment.targetCount=1; fragment.targets=&target;
    wgpu::RenderPipelineDescriptor pipeline_descriptor{}; pipeline_descriptor.layout=layout; pipeline_descriptor.vertex.module=module; pipeline_descriptor.vertex.entryPoint="vs_main"; pipeline_descriptor.fragment=&fragment; pipeline_descriptor.primitive.topology=wgpu::PrimitiveTopology::TriangleList;
    runtime.pipeline = runtime.device.CreateRenderPipeline(&pipeline_descriptor);
    wgpu::BindGroupEntry bindings[2]{}; bindings[0].binding=0; bindings[0].buffer=runtime.globals; bindings[0].size=sizeof(Globals); bindings[1].binding=1; bindings[1].buffer=runtime.items; bindings[1].size=kMaxItems*sizeof(ScoreDrawItem);
    wgpu::BindGroupDescriptor group_descriptor{}; group_descriptor.layout=bgl; group_descriptor.entryCount=2; group_descriptor.entries=bindings;
    runtime.bind_group = runtime.device.CreateBindGroup(&group_descriptor);
    EM_ASM({
        document.documentElement.style.cssText='width:100%;height:100%;background:#090b0e';
        document.body.style.cssText='margin:0;width:100%;height:100%;overflow:hidden;background:#090b0e';
        Module.canvas.style.cssText='display:block;width:100vw;height:100vh;outline:none;touch-action:none';
        Module.canvas.tabIndex=0; Module.canvas.focus();
    });
    configureSurface();
    if (!score_init(runtime.logical_width, runtime.logical_height, runtime.pixel_ratio)) std::abort();
    emscripten_set_wheel_callback("#canvas", nullptr, true, wheelCallback);
    emscripten_set_keydown_callback(EMSCRIPTEN_EVENT_TARGET_WINDOW, nullptr, true, keyCallback);
    emscripten_set_keyup_callback(EMSCRIPTEN_EVENT_TARGET_WINDOW, nullptr, true, keyCallback);
    webInitialize();
    emscripten_set_main_loop(frame, 0, false);
}
}

extern "C" EMSCRIPTEN_KEEPALIVE uintptr_t score_web_alloc(size_t length) {
    return reinterpret_cast<uintptr_t>(std::malloc(length));
}

extern "C" EMSCRIPTEN_KEEPALIVE void score_web_free(uintptr_t pointer) {
    std::free(reinterpret_cast<void*>(pointer));
}

extern "C" EMSCRIPTEN_KEEPALIVE uint32_t score_web_import(uintptr_t pointer, size_t length, uint32_t kind) {
    return score_import(reinterpret_cast<const uint8_t*>(pointer), length, kind);
}

extern "C" EMSCRIPTEN_KEEPALIVE uint32_t score_web_restore(uintptr_t pointer, size_t length) {
    return score_restore(reinterpret_cast<const uint8_t*>(pointer), length);
}

extern "C" EMSCRIPTEN_KEEPALIVE void score_web_status(uint32_t status) {
    score_host_status(status);
}

extern "C" EMSCRIPTEN_KEEPALIVE void score_web_save_now() {
    saveSnapshot();
}

extern "C" EMSCRIPTEN_KEEPALIVE void score_web_midi(double time_milliseconds, uint32_t status, uint32_t data1, uint32_t data2) {
    score_midi(static_cast<uint64_t>(time_milliseconds * 1000000.0), status, data1, data2);
}

extern "C" EMSCRIPTEN_KEEPALIVE void score_web_pitch(uint32_t pitch, float confidence) {
    score_microphone_pitch(pitch, confidence);
}

extern "C" EMSCRIPTEN_KEEPALIVE void score_web_accessibility_activate(uint32_t id) {
    score_accessibility_activate(id);
    processHostRequest();
}

extern "C" EMSCRIPTEN_KEEPALIVE void score_web_pointer(uint32_t kind, uint32_t pointer_type, uint32_t id, float x, float y, uint32_t buttons, float pressure, float tilt_x, float tilt_y) {
    if (kind == 1) webEnsureAudio();
    score_pointer(kind, pointer_type, id, x, y, buttons, pressure, tilt_x, tilt_y, 0, 0);
    processHostRequest();
}

int main() {
    if (!EM_ASM_INT({ return typeof navigator !== 'undefined' && !!navigator.gpu; })) {
        webFatal("WebGPU is not exposed by this browser or device.");
        return 0;
    }
    runtime.instance = wgpu::Instance(wgpuCreateInstance(nullptr));
    runtime.instance.RequestAdapter(nullptr, wgpu::CallbackMode::AllowSpontaneous, [](wgpu::RequestAdapterStatus status, wgpu::Adapter adapter, wgpu::StringView message) {
        if (status != wgpu::RequestAdapterStatus::Success) {
            std::fprintf(stderr, "WebGPU adapter unavailable: %.*s\n", int(message.length), message.data);
            webFatal("No compatible hardware WebGPU adapter was available. Check hardware acceleration and browser GPU settings.");
            return;
        }
        runtime.adapter = adapter;
        wgpu::DeviceDescriptor descriptor{};
        runtime.adapter.RequestDevice(&descriptor, wgpu::CallbackMode::AllowSpontaneous, [](wgpu::RequestDeviceStatus device_status, wgpu::Device device, wgpu::StringView device_message) {
            if (device_status != wgpu::RequestDeviceStatus::Success) {
                std::fprintf(stderr, "WebGPU device unavailable: %.*s\n", int(device_message.length), device_message.data);
                webFatal("The browser found a GPU adapter but could not create a WebGPU device.");
                return;
            }
            runtime.device = device;
            initialized();
        });
    });
    return 0;
}
