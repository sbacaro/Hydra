// Hydra Audio — GPL-3.0
// VST3 hosting shim. Unity-includes the minimal hosting pieces of the
// Steinberg VST3 SDK (ThirdParty/vst3sdk, GPLv3 option) so SwiftPM can build
// everything as one target without CMake.

#include "include/hydra_vst.h"

#define RELEASE 1
#define DEVELOPMENT 0

#import <Cocoa/Cocoa.h>

// ---- Steinberg VST3 SDK (unity build of the hosting subset) ----------------
#include "pluginterfaces/base/funknown.cpp"
#include "pluginterfaces/base/coreiids.cpp"
#include "public.sdk/source/vst/vstinitiids.cpp"
#include "pluginterfaces/base/conststringtable.cpp"
#include "pluginterfaces/base/ustring.cpp"

#include "public.sdk/source/vst/hosting/module.cpp"
#include "public.sdk/source/vst/hosting/module_mac.mm"
#include "public.sdk/source/vst/hosting/hostclasses.cpp"
#include "public.sdk/source/vst/hosting/pluginterfacesupport.cpp"
#include "public.sdk/source/vst/hosting/parameterchanges.cpp"
#include "public.sdk/source/common/memorystream.cpp"

#if __has_include("public.sdk/source/vst/utility/stringconvert.cpp")
#include "public.sdk/source/vst/utility/stringconvert.cpp"
#elif __has_include("public.sdk/source/vst/hosting/stringconvert.cpp")
#include "public.sdk/source/vst/hosting/stringconvert.cpp"
#endif

#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/gui/iplugview.h"

#include <atomic>
#include <memory>
#include <string>
#include <vector>
#include <cstring>

// GUI interface IIDs are not covered by vstinitiids.cpp.
namespace Steinberg {
DEF_CLASS_IID(IPlugFrame)
DEF_CLASS_IID(IPlugView)
}

using namespace Steinberg;
using namespace Steinberg::Vst;

// ----------------------------------------------------------------------------

namespace {

Vst::HostApplication *hostContext()
{
    static Vst::HostApplication *instance = new Vst::HostApplication();
    return instance;
}

struct ModuleHandle {
    VST3::Hosting::Module::Ptr module;
    std::vector<VST3::Hosting::ClassInfo> effectClasses;
};

ModuleHandle *openModule(const char *path)
{
    std::string error;
    auto module = VST3::Hosting::Module::create(path, error);
    if (!module) {
        return nullptr;
    }
    auto handle = new ModuleHandle();
    handle->module = module;
    for (auto &classInfo : module->getFactory().classInfos()) {
        if (classInfo.category() == kVstAudioEffectClass) {
            handle->effectClasses.push_back(classInfo);
        }
    }
    return handle;
}

struct Instance;

/// Forwards GUI parameter edits into the instance's lock-free queue.
struct HydraComponentHandler : public IComponentHandler {
    Instance *owner = nullptr;
    tresult PLUGIN_API beginEdit(ParamID) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue value) SMTG_OVERRIDE;
    tresult PLUGIN_API endEdit(ParamID) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32) SMTG_OVERRIDE { return kResultOk; }

    tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE
    {
        QUERY_INTERFACE(_iid, obj, FUnknown::iid, IComponentHandler)
        QUERY_INTERFACE(_iid, obj, IComponentHandler::iid, IComponentHandler)
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1000; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1000; }
};

/// Minimal IPlugFrame: lets the editor resize its window.
struct HydraPlugFrame : public IPlugFrame {
    NSWindow *__weak window = nil;
    tresult PLUGIN_API resizeView(IPlugView *view, ViewRect *newSize) SMTG_OVERRIDE
    {
        NSWindow *win = window;
        if (win && newSize) {
            [win setContentSize:NSMakeSize(newSize->getWidth(), newSize->getHeight())];
            view->onSize(newSize);
        }
        return kResultOk;
    }
    tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE
    {
        QUERY_INTERFACE(_iid, obj, FUnknown::iid, IPlugFrame)
        QUERY_INTERFACE(_iid, obj, IPlugFrame::iid, IPlugFrame)
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1000; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1000; }
};

struct ParamEdit {
    ParamID id;
    ParamValue value;
};

struct Instance {
    VST3::Hosting::Module::Ptr module;   // keeps the dylib loaded
    IPtr<IComponent> component;
    IPtr<IAudioProcessor> processor;
    IPtr<IEditController> controller;
    bool controllerIsComponent = false;
    bool processing = false;
    std::string name;

    HydraComponentHandler handler;
    HydraPlugFrame frame;

    // GUI → audio-thread parameter queue (SPSC ring).
    static constexpr uint32_t kRingSize = 512;
    ParamEdit ring[kRingSize];
    std::atomic<uint32_t> ringWrite{0};
    uint32_t ringRead = 0;               // audio-thread only
    ParameterChanges inputParams;        // drained into process()
    ParameterChanges outputParams;

    // Editor
    IPlugView *view = nullptr;
    NSWindow *window = nil;
};

tresult PLUGIN_API HydraComponentHandler::performEdit(ParamID id, ParamValue value)
{
    if (!owner) {
        return kResultFalse;
    }
    uint32_t w = owner->ringWrite.load(std::memory_order_relaxed);
    owner->ring[w % Instance::kRingSize] = {id, value};
    owner->ringWrite.store(w + 1, std::memory_order_release);
    return kResultOk;
}

} // namespace

// ---- C API ------------------------------------------------------------------

void *hydra_vst_open_module(const char *path, int32_t *class_count)
{
    auto handle = openModule(path);
    if (!handle) {
        if (class_count) *class_count = 0;
        return nullptr;
    }
    if (class_count) *class_count = (int32_t)handle->effectClasses.size();
    return handle;
}

bool hydra_vst_class_info_at(void *module, int32_t index, hydra_vst_class_info *out)
{
    auto handle = static_cast<ModuleHandle *>(module);
    if (!handle || !out || index < 0 || index >= (int32_t)handle->effectClasses.size()) {
        return false;
    }
    auto &info = handle->effectClasses[(size_t)index];
    std::strncpy(out->name, info.name().c_str(), sizeof(out->name) - 1);
    out->name[sizeof(out->name) - 1] = 0;
    std::strncpy(out->vendor, info.vendor().c_str(), sizeof(out->vendor) - 1);
    out->vendor[sizeof(out->vendor) - 1] = 0;
    // VST3 subcategory ("Fx|Reverb", "Instrument|Synth", ...) for the app's
    // plugin manager to filter by type. ClassInfo joins the categories with '|'.
    std::strncpy(out->category, info.subCategoriesString().c_str(), sizeof(out->category) - 1);
    out->category[sizeof(out->category) - 1] = 0;
    return true;
}

void hydra_vst_close_module(void *module)
{
    delete static_cast<ModuleHandle *>(module);
}

void *hydra_vst_create_instance(const char *path, int32_t class_index,
                                double sample_rate, int32_t max_block_frames)
{
    std::unique_ptr<ModuleHandle> handle(openModule(path));
    if (!handle || class_index < 0 ||
        class_index >= (int32_t)handle->effectClasses.size()) {
        return nullptr;
    }
    auto &classInfo = handle->effectClasses[(size_t)class_index];

    auto component = handle->module->getFactory().createInstance<IComponent>(classInfo.ID());
    if (!component) {
        return nullptr;
    }
    if (component->initialize(hostContext()) != kResultOk) {
        return nullptr;
    }

    IPtr<IAudioProcessor> processor;
    if (component->queryInterface(IAudioProcessor::iid, (void **)&processor) != kResultOk || !processor) {
        component->terminate();
        return nullptr;
    }

    auto instance = new Instance();
    instance->module = handle->module;
    instance->component = component;
    instance->processor = processor;
    instance->name = classInfo.name();
    instance->handler.owner = instance;
    instance->inputParams.setMaxParameters(64);
    instance->outputParams.setMaxParameters(64);

    // Edit controller: separate class (dual-component) or the component itself.
    TUID controllerCID{};
    if (component->getControllerClassId(controllerCID) == kResultTrue) {
        instance->controller = handle->module->getFactory()
            .createInstance<IEditController>(VST3::UID::fromTUID(controllerCID));
        if (instance->controller) {
            instance->controller->initialize(hostContext());
        }
    }
    if (!instance->controller) {
        IPtr<IEditController> asController;
        if (component->queryInterface(IEditController::iid, (void **)&asController) == kResultOk) {
            instance->controller = asController;
            instance->controllerIsComponent = true;
        }
    }
    if (instance->controller) {
        instance->controller->setComponentHandler(&instance->handler);
        if (!instance->controllerIsComponent) {
            // Connect component ↔ controller and sync the component state.
            IPtr<IConnectionPoint> compCP, ctrlCP;
            component->queryInterface(IConnectionPoint::iid, (void **)&compCP);
            instance->controller->queryInterface(IConnectionPoint::iid, (void **)&ctrlCP);
            if (compCP && ctrlCP) {
                compCP->connect(ctrlCP);
                ctrlCP->connect(compCP);
            }
            MemoryStream stream;
            if (component->getState(&stream) == kResultTrue) {
                int64 pos = 0;
                stream.seek(0, IBStream::kIBSeekSet, &pos);
                instance->controller->setComponentState(&stream);
            }
        }
    }

    // Stereo main in/out, 32-bit float, realtime.
    SpeakerArrangement stereo = SpeakerArr::kStereo;
    processor->setBusArrangements(&stereo, 1, &stereo, 1); // best effort

    ProcessSetup setup{};
    setup.processMode = kRealtime;
    setup.symbolicSampleSize = kSample32;
    setup.maxSamplesPerBlock = max_block_frames;
    setup.sampleRate = sample_rate;
    if (processor->setupProcessing(setup) != kResultOk) {
        component->terminate();
        delete instance;
        return nullptr;
    }

    if (component->getBusCount(kAudio, kInput) > 0) {
        component->activateBus(kAudio, kInput, 0, true);
    }
    if (component->getBusCount(kAudio, kOutput) > 0) {
        component->activateBus(kAudio, kOutput, 0, true);
    }

    if (component->setActive(true) != kResultOk) {
        component->terminate();
        delete instance;
        return nullptr;
    }
    processor->setProcessing(true);
    instance->processing = true;
    return instance;
}

bool hydra_vst_process(void *opaque, float *const *in2, float *const *out2,
                       int32_t frames)
{
    auto instance = static_cast<Instance *>(opaque);
    if (!instance || !instance->processing) {
        return false;
    }

    // Drain GUI parameter edits into this block's parameter changes.
    instance->inputParams.clearQueue();
    uint32_t writeIndex = instance->ringWrite.load(std::memory_order_acquire);
    while (instance->ringRead != writeIndex) {
        const ParamEdit &edit = instance->ring[instance->ringRead % Instance::kRingSize];
        int32 queueIndex = 0;
        if (auto *queue = instance->inputParams.addParameterData(edit.id, queueIndex)) {
            int32 pointIndex = 0;
            queue->addPoint(0, edit.value, pointIndex);
        }
        instance->ringRead++;
    }

    AudioBusBuffers inputBus{};
    inputBus.numChannels = 2;
    inputBus.channelBuffers32 = const_cast<float **>(in2);

    AudioBusBuffers outputBus{};
    outputBus.numChannels = 2;
    outputBus.channelBuffers32 = const_cast<float **>(out2);

    instance->outputParams.clearQueue();

    ProcessData data{};
    data.processMode = kRealtime;
    data.symbolicSampleSize = kSample32;
    data.numSamples = frames;
    data.numInputs = 1;
    data.numOutputs = 1;
    data.inputs = &inputBus;
    data.outputs = &outputBus;
    data.inputParameterChanges = &instance->inputParams;
    data.outputParameterChanges = &instance->outputParams;

    return instance->processor->process(data) == kResultOk;
}

bool hydra_vst_has_editor(void *opaque)
{
    auto instance = static_cast<Instance *>(opaque);
    return instance && instance->controller != nullptr;
}

bool hydra_vst_open_editor(void *opaque, const char *title)
{
    auto instance = static_cast<Instance *>(opaque);
    if (!instance || !instance->controller) {
        return false;
    }

    // NSWindow + the plugin's IPlugView MUST be created/attached on the main
    // thread (AppKit asserts `NSWindow should only be instantiated on the main
    // thread!` otherwise). This is called from the daemon's message loop, which
    // is NOT the main thread — so force the whole UI build onto the main queue,
    // exactly like hydra_vst_teardown_editor does. The [isMainThread] guard
    // avoids a dispatch_sync-to-self deadlock when a caller is already on main.
    __block bool result = false;
    NSString *titleStr = title ? [NSString stringWithUTF8String:title] : nil;
    void (^work)(void) = ^{
        // The daemon normally runs as an ACCESSORY app (no Dock icon). Accessory
        // apps show windows but don't reliably deliver mouse/keyboard to them and
        // don't keep a plugin's redraw timer ticking — so the editor renders once
        // and then sits frozen like a static image. Promote to a regular
        // foreground app so the plugin GUI becomes fully interactive.
        if ([NSApp activationPolicy] != NSApplicationActivationPolicyRegular) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        }
        if (instance->window) {
            [instance->window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            result = true;
            return;
        }
        IPlugView *view = instance->controller->createView(ViewType::kEditor);
        if (!view) { result = false; return; }
        ViewRect rect{};
        if (view->getSize(&rect) != kResultOk || rect.getWidth() <= 0) {
            rect.right = rect.left + 800;
            rect.bottom = rect.top + 500;
        }
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(120, 120, rect.getWidth(), rect.getHeight())
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskMiniaturizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = titleStr ? titleStr
                                : [NSString stringWithUTF8String:instance->name.c_str()];
        window.releasedWhenClosed = NO;

        instance->frame.window = window;
        view->setFrame(&instance->frame);

        if (view->attached((__bridge void *)window.contentView, kPlatformTypeNSView) != kResultOk) {
            view->release();
            result = false;
            return;
        }

        instance->view = view;
        instance->window = window;
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        result = true;
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return result;
}

static void hydra_vst_teardown_editor(Instance *instance)
{
    void (^work)(void) = ^{
        if (instance->view) {
            instance->view->removed();
            instance->view->release();
            instance->view = nullptr;
        }
        if (instance->window) {
            [instance->window close];
            instance->window = nil;
        }
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
}

void hydra_vst_destroy_instance(void *opaque)
{
    auto instance = static_cast<Instance *>(opaque);
    if (!instance) {
        return;
    }
    hydra_vst_teardown_editor(instance);
    if (instance->processing) {
        instance->processor->setProcessing(false);
        instance->component->setActive(false);
    }
    if (instance->controller && !instance->controllerIsComponent) {
        instance->controller->terminate();
    }
    instance->controller = nullptr;
    instance->processor = nullptr;
    if (instance->component) {
        instance->component->terminate();
        instance->component = nullptr;
    }
    delete instance;
}
