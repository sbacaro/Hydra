#!/usr/bin/env ruby
# frozen_string_literal: true
# Hydra Audio — GPL-3.0
#
# Generates Hydra.xcodeproj from source. The .xcodeproj IS the committed source
# of truth for the build; this script just lets us regenerate it deterministically
# (the pbxproj is large and fragile to hand-edit). Run after adding/removing files.
#
#   gem install xcodeproj      # once
#   ruby Scripts/generate_xcodeproj.rb
#
# Targets produced (all macOS 26, universal arm64 + x86_64):
#   HydraCore           framework (Swift)   — shared constants/models/WS messages
#   HydraVST            framework (C++/ObjC++) — VST3 hosting shim (Steinberg SDK)
#   HydraNDIShim        framework (C)       — dlopen() facade for the NDI runtime
#   HydraModuleABI      framework (C)       — generic module plugin ABI
#   HydraSurface        framework (Swift)   — control-surface bridge (HiQnet/HUI)
#   HydraDaemon         framework (Swift)   — audio engine, runs in-process in the app
#   HydraApp            app (Swift)         — SwiftUI UI + the in-process engine
#   HydraVirtualSoundcard  .driver bundle (C) — 512-wire AudioServerPlugIn backplane
#   HydraCoreTests      unit test bundle    — XCTest over HydraCore

require 'xcodeproj'

ROOT       = File.expand_path('..', __dir__)
PROJ_PATH  = File.join(ROOT, 'Hydra.xcodeproj')
DEPLOY     = '26.0'
MARKETING  = '1.0.7'
BUILD_NUM  = '1.0.7'
SRC_EXT    = %w[.swift .c .m .mm .cpp .cc].freeze

project = Xcodeproj::Project.new(PROJ_PATH)

# Xcode 16+ synchronized folder groups (PBXFileSystemSynchronizedRootGroup)
# require the modern pbxproj object format. Bump from the gem's default (46).
project.instance_variable_set(:@object_version, '77')

# Localization: English is the development (base) language; pt-BR ships as a
# translation. Strings live in Sources/HydraApp/Localizable.xcstrings (String
# Catalog), auto-extracted at build time (SWIFT_EMIT_LOC_STRINGS=YES on the app).
project.root_object.development_region = 'en'
project.root_object.known_regions = %w[en Base pt-BR es fr de it]

# Stable code-signing identity. macOS privacy permissions (TCC, e.g. system audio
# capture) are tied to the app's code signature; with ad-hoc signing ("-") the
# signature changes every build, so granted permissions reset after a rebuild. A
# self-signed "Hydra Dev" certificate keeps the signature stable across rebuilds.
# Create it once in Keychain Access → Certificate Assistant → Create a Certificate
# (name "Hydra Dev", Identity Type: Self-Signed Root, Certificate Type: Code
# Signing). Falls back to ad-hoc when the cert isn't present.
SIGN_ID = `security find-identity -v -p codesigning 2>/dev/null`.include?('"Hydra Dev"') ? 'Hydra Dev' : '-'

# Project-wide: ENABLE Xcode's Run Script sandbox — this is Xcode's recommended
# setting (and what "Update to recommended settings" asks for). The ONLY script
# phase that writes outside the sandbox is the VST3-SDK fetch, which now lives on
# its own aggregate target (FetchVST3SDK) with sandboxing turned back OFF there —
# so every normal target satisfies the recommendation. The clang module verifier
# stays OFF (it fails on the mixed C/C++/Swift framework targets).
project.build_configurations.each do |c|
  c.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
  c.build_settings['ENABLE_MODULE_VERIFIER']        = 'NO'
end

# Stamp the project as reviewed at the current Xcode baseline so Xcode stops
# nagging with "Update to recommended settings" (Xcode 26.0 → 2600).
project.root_object.attributes['LastUpgradeCheck']     = '2600'
project.root_object.attributes['LastSwiftUpdateCheck'] = '2600'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Create (or reuse) a group whose files live under <ROOT>/<rel_dir>, add every
# file matching the glob patterns, and wire compilable ones into the target's
# Sources phase. Returns all created PBXFileReferences keyed by basename.
def add_dir(project, target, rel_dir, patterns)
  group = project.main_group.find_subpath(rel_dir, true)
  group.set_source_tree('SOURCE_ROOT')
  group.set_path(rel_dir)
  files = patterns.flat_map { |p| Dir.glob(File.join(ROOT, rel_dir, p)) }
                  .reject { |f| File.basename(f) == '.DS_Store' }
                  .uniq.sort
  refs = {}
  files.each do |f|
    ref = group.new_file(File.basename(f))
    refs[File.basename(f)] = ref
  end
  if target
    sources = refs.values.select { |r| SRC_EXT.include?(File.extname(r.path)) }
    target.add_file_references(sources)
  end
  refs
end

# Xcode 26 synchronized folder group: the whole <rel_dir> is tied to <target>
# and Xcode assigns each file to the right phase (Swift→Sources, assets/strings→
# Resources) automatically. Adding a source file no longer needs a regenerate.
# `exclude` lists paths (relative to rel_dir) kept OUT of auto-membership — e.g.
# the Info.plist (referenced via INFOPLIST_FILE) or a LaunchAgent plist that is
# only wanted in a bespoke Copy Files phase, not Copy Bundle Resources.
def sync_dir(project, target, rel_dir, exclude: [], public_headers: [])
  group = project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup)
  group.source_tree = '<group>'
  group.path = rel_dir
  project.main_group.children << group

  if !exclude.empty? || !public_headers.empty?
    ex = project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedBuildFileExceptionSet)
    ex.target = target
    ex.membership_exceptions = exclude unless exclude.empty?
    # Promote the umbrella header(s) to Public so the modulemap exports them.
    ex.public_headers = public_headers unless public_headers.empty?
    group.exceptions ||= []
    group.exceptions << ex
  end

  target.file_system_synchronized_groups ||= []
  target.file_system_synchronized_groups << group
  group
end

def each_config(target)
  target.build_configurations.each { |c| yield c, c.build_settings, (c.name == 'Release') }
end

def common!(target, bundle_id, extra = {})
  each_config(target) do |cfg, s, release|
    s['PRODUCT_BUNDLE_IDENTIFIER'] = bundle_id
    s['MACOSX_DEPLOYMENT_TARGET']  = DEPLOY
    # Swift 6.2 — stage 2: full Swift 6 language mode. Data-race safety is now
    # enforced (former warnings become errors). Approachable Concurrency keeps the
    # 6.2 ergonomic features on; default actor isolation is per-target below
    # (MainActor for the UI app; nonisolated for the daemon/host, which run
    # concurrent background + real-time work).
    s['SWIFT_VERSION']                  = '6.0'
    s['SWIFT_APPROACHABLE_CONCURRENCY'] = 'YES'
    s['SWIFT_STRICT_CONCURRENCY']       = 'complete'
    s['MARKETING_VERSION']         = MARKETING
    s['CURRENT_PROJECT_VERSION']   = BUILD_NUM
    s['ALWAYS_SEARCH_USER_PATHS']  = 'NO'
    s['CLANG_ENABLE_OBJC_WEAK']    = 'YES'
    s['SWIFT_OPTIMIZATION_LEVEL']  = release ? '-O' : '-Onone'
    s['ONLY_ACTIVE_ARCH']          = release ? 'NO' : 'YES'
    s['ARCHS']                     = release ? 'arm64 x86_64' : '$(ARCHS_STANDARD)'
    # Frameworks + test bundle have no explicit Info.plist → generate one.
    # App/daemon override this to NO (they pass their own INFOPLIST_FILE).
    s['GENERATE_INFOPLIST_FILE']   = 'YES'
    # Xcode's recommended default (Run Script sandbox ON). Safe for every normal
    # target: the only unsandboxed script — the VST3-SDK fetch — is isolated to
    # the FetchVST3SDK aggregate target.
    s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
    extra.each { |k, v| s[k] = v }
  end
end

def link_and_embed(app, frameworks)
  frameworks.each do |fw|
    app.add_dependency(fw)
    app.frameworks_build_phase.add_file_reference(fw.product_reference, true)
  end
  embed = app.new_copy_files_build_phase('Embed Frameworks')
  embed.symbol_dst_subfolder_spec = :frameworks
  embed.dst_path = ''
  frameworks.each do |fw|
    bf = embed.add_file_reference(fw.product_reference, true)
    bf.settings = { 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] }
  end
end

# ---------------------------------------------------------------------------
# library frameworks
# ---------------------------------------------------------------------------

core = project.new_target(:framework, 'HydraCore', :osx, DEPLOY, nil, :swift)
sync_dir(project, core, 'Sources/HydraCore')
common!(core, 'audio.hydra.core', 'DEFINES_MODULE' => 'YES')

# Real-time DSP library (SPSC ring + polyphase resampler integration), split out
# of the daemon so it can be unit-tested directly (HydraRTTests). Depends on
# HydraCore; uses CoreAudio (AudioBufferList helpers) + Synchronization (atomics).
rt = project.new_target(:framework, 'HydraRT', :osx, DEPLOY, nil, :swift)
sync_dir(project, rt, 'Sources/HydraRT')
rt.add_dependency(core)
rt.frameworks_build_phase.add_file_reference(core.product_reference, true)
rt.add_system_framework(%w[CoreAudio])
common!(rt, 'audio.hydra.rt', 'DEFINES_MODULE' => 'YES')

# --- C / C++ shims: framework + explicit modulemap so Swift can `import` them.
def c_framework(project, name, dir, public_header, modulemap, bundle_id, extra = {})
  fw = project.new_target(:framework, name, :osx, DEPLOY, nil, :c)
  # Synchronized folder group: sources compile automatically; the umbrella
  # header (include/<public_header>) is promoted to Public so the modulemap
  # exports it. The module.modulemap itself is referenced via MODULEMAP_FILE
  # (not compiled). Adding a new source no longer needs a regenerate.
  sync_dir(project, fw, dir, public_headers: ["include/#{public_header}"])
  common!(fw, bundle_id, {
    'DEFINES_MODULE'            => 'YES',
    'MODULEMAP_FILE'            => "#{dir}/#{modulemap}",
    'CLANG_ENABLE_MODULES'      => 'YES'
  }.merge(extra))
  fw
end

ndishim = c_framework(project, 'HydraNDIShim', 'Sources/HydraNDIShim',
                      'hydra_ndi.h', 'module.modulemap', 'audio.hydra.ndishim')

moduleabi = c_framework(project, 'HydraModuleABI', 'Sources/HydraModuleABI',
                        'hydra_module.h', 'module.modulemap', 'audio.hydra.moduleabi')

# Shared-memory transport between the daemon and the out-of-process plugin host.
pluginhostabi = c_framework(project, 'HydraPluginHostABI', 'Sources/HydraPluginHostABI',
                            'hydra_plugin_shm.h', 'module.modulemap', 'audio.hydra.pluginhostabi')

vst = c_framework(project, 'HydraVST', 'Sources/HydraVST',
                  'hydra_vst.h', 'module.modulemap', 'audio.hydra.vst', {
  'CLANG_CXX_LANGUAGE_STANDARD' => 'c++2b',
  'CLANG_CXX_LIBRARY'           => 'libc++',
  'GCC_PREPROCESSOR_DEFINITIONS'=> '$(inherited) RELEASE=1',
  'HEADER_SEARCH_PATHS'         => '$(inherited) $(SRCROOT)/Sources/HydraVST $(SRCROOT)/ThirdParty/vst3sdk',
  # Quiet third-party noise from the Steinberg VST3 SDK headers/sources:
  # doxygen \ref / “parameter not found” doc warnings, and the deprecated
  # std::wstring_convert in the SDK's stringconvert.cpp. Not our code.
  'CLANG_WARN_DOCUMENTATION_COMMENTS'   => 'NO',
  'GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS' => 'NO'
})
vst.add_system_framework(%w[Cocoa CoreFoundation Foundation])

# Fetch the Steinberg VST3 SDK before compiling HydraVST (idempotent, gitignored).
# Declaring an output (the SDK umbrella header) lets Xcode skip the phase on
# every subsequent build via dependency analysis — no more "runs every build".
# Run it from a SEPARATE aggregate target that HydraVST depends on. Keeping the
# unsandboxed fetch script OUT of HydraVST (which has a Copy Headers phase) avoids
# the "tasks in 'Copy Headers' are delayed by unsandboxed script phases" warning,
# while still fetching the SDK before HydraVST compiles.
fetch_target = project.new_aggregate_target('FetchVST3SDK', [], :osx, DEPLOY)
fetch = fetch_target.new_shell_script_build_phase('Fetch VST3 SDK')
fetch.shell_script = "\"$SRCROOT/Scripts/fetch_vst3sdk.sh\"\n"
fetch.input_paths  = ['$(SRCROOT)/Scripts/fetch_vst3sdk.sh']
fetch.output_paths = ['$(SRCROOT)/ThirdParty/vst3sdk/pluginterfaces/base/ipluginbase.h']
# The fetch git-clones the SDK into $SRCROOT/ThirdParty — outside any sandbox —
# so THIS target (and only this one) keeps the Run Script sandbox OFF.
fetch_target.build_configurations.each do |c|
  c.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
end
vst.add_dependency(fetch_target)

# Control-surface bridge (HiQnet ↔ Mackie HUI) for Soundcraft Si consoles. Pure
# Swift codecs + CoreMIDI/Network I/O; NO Hydra dependency (it logs via an onLog
# hook). Consumed by HydraDaemon (SurfaceManager.swift) and embedded by the app.
surface = project.new_target(:framework, 'HydraSurface', :osx, DEPLOY, nil, :swift)
sync_dir(project, surface, 'Sources/HydraSurface')
surface.add_system_framework(%w[CoreMIDI Network])
common!(surface, 'audio.hydra.surface', 'DEFINES_MODULE' => 'YES')

# ---------------------------------------------------------------------------
# executables (.app)
# ---------------------------------------------------------------------------
RPATH = '@executable_path/../Frameworks @loader_path/../Frameworks'

# Audio engine — formerly the standalone `hydrad` executable + LaunchAgent. Now a
# FRAMEWORK linked into the app and started in-process via DaemonRuntime.start(),
# so the user sees ONE process. Source path stays Sources/hydrad (main.swift is an
# empty stub). It LINKS the frameworks it uses; the app EMBEDS them all.
daemon = project.new_target(:framework, 'HydraDaemon', :osx, DEPLOY, nil, :swift)
sync_dir(project, daemon, 'Sources/hydrad', exclude: ['Info.plist', 'hydrad.entitlements'])
common!(daemon, 'audio.hydra.daemon', {
  'DEFINES_MODULE'         => 'YES',
  'CODE_SIGN_STYLE'        => 'Manual',
  'CODE_SIGN_IDENTITY'     => SIGN_ID,
  'LD_RUNPATH_SEARCH_PATHS'=> "$(inherited) #{RPATH}",
  'PRODUCT_NAME'           => 'HydraDaemon'
})
[core, rt, vst, ndishim, moduleabi, pluginhostabi, surface].each do |fw|
  daemon.add_dependency(fw)
  daemon.frameworks_build_phase.add_file_reference(fw.product_reference, true)
end

# Out-of-process VST chain host (crash isolation). Built as an .app so a later
# iteration can host plugin editor GUIs (AppKit) in the same crashable process.
# Faceless (LSUIElement). The app launches it and talks to it over shared
# memory (HydraPluginHostABI); a plugin crash kills THIS, not Hydra.
pluginhost = project.new_target(:application, 'hydra-plugin-host', :osx, DEPLOY, nil, :swift)
sync_dir(project, pluginhost, 'Sources/hydra-plugin-host')
common!(pluginhost, 'audio.hydra.pluginhost', {
  'INFOPLIST_KEY_LSUIElement' => 'YES',
  'CODE_SIGN_STYLE'        => 'Manual',
  'CODE_SIGN_IDENTITY'     => SIGN_ID,
  'ENABLE_HARDENED_RUNTIME'=> 'YES',
  # The host loads third-party VST3 .dylibs — under the hardened runtime it needs
  # the same library-validation exception the app has, or the signed release build
  # can't open plugin editors (works in a dev build, fails from the .pkg).
  'CODE_SIGN_ENTITLEMENTS' => 'Sources/hydra-plugin-host/hydra-plugin-host.entitlements',
  # App icon (Hydra waveform on dark gray) so the editor window/Dock shows the
  # brand instead of a generic icon while the host is foreground.
  'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
  'LD_RUNPATH_SEARCH_PATHS'=> "$(inherited) #{RPATH}",
  'PRODUCT_NAME'           => 'hydra-plugin-host'
})
link_and_embed(pluginhost, [vst, pluginhostabi])

app = project.new_target(:application, 'HydraApp', :osx, DEPLOY, nil, :swift)
# Exclude the Info.plist (wired via INFOPLIST_FILE). The old LaunchAgents plist is
# no longer used (the engine runs in-process) — exclude it so a stale copy can't
# become a Copy-Bundle-Resource.
sync_dir(project, app, 'Sources/HydraApp',
         exclude: ['Info.plist', 'LaunchAgents/audio.hydra.daemon.plist'])
common!(app, 'audio.hydra.app', {
  'INFOPLIST_FILE'          => 'Sources/HydraApp/Info.plist',
  'GENERATE_INFOPLIST_FILE' => 'NO',
  'CODE_SIGN_ENTITLEMENTS'  => 'Sources/HydraApp/HydraApp.entitlements',
  'CODE_SIGN_STYLE'         => 'Manual',
  'CODE_SIGN_IDENTITY'      => SIGN_ID,
  'ENABLE_HARDENED_RUNTIME' => 'YES',
  'LD_RUNPATH_SEARCH_PATHS' => "$(inherited) #{RPATH}",
  # Product (and thus the .app and Dock name) is "Hydra", not the target name
  # "HydraApp". The bundle id stays audio.hydra.app.
  'PRODUCT_NAME'            => 'Hydra',
  'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
  'SWIFT_EMIT_LOC_STRINGS'  => 'YES',
  # UI target: main-actor-by-default (Swift 6.2). Most SwiftUI code is already
  # main-actor; this removes the @MainActor boilerplate and matches new-project
  # defaults. The daemon/host keep the nonisolated default (concurrent work).
  'SWIFT_DEFAULT_ACTOR_ISOLATION' => 'MainActor'
})
# The app now LINKS + EMBEDS the audio engine (HydraDaemon) and every framework it
# uses, since they're all loaded by this single process.
link_and_embed(app, [core, daemon, rt, vst, ndishim, moduleabi, pluginhostabi, surface])

# In-app auto-update is implemented in Sources/HydraApp/Updater.swift using only
# system frameworks (URLSession + CryptoKit + AppKit) — no embedded framework.

# App icon + accent: the asset catalog lives at the repo root (Media.xcassets).
# Add it to the app's resources so actool compiles AppIcon into the bundle —
# without this the Dock shows a blank icon.
app_assets = project.new_file('Media.xcassets')
app.resources_build_phase.add_file_reference(app_assets, true)

# Localizable.xcstrings (String Catalog) lives in Sources/HydraApp and is now
# picked up automatically by the synchronized folder group above — no explicit
# reference needed (adding one would double-bundle it).

# ---------------------------------------------------------------------------
# backplane driver (.driver — AudioServerPlugIn bundle)
# ---------------------------------------------------------------------------
driver = project.new_target(:bundle, 'HydraVirtualSoundcard', :osx, '11.0', nil, :c)
# Hidden engine hub: compile ONLY the hub wrapper (HydraEngineHub.c), which
# #includes Hydra.c and marks the device hidden + renamed "Hydra Engine".
# Hydra.c and bridges/*.c are #included by their own wrappers, never compiled
# directly here (that would duplicate the driver's symbols).
add_dir(project, driver, 'Backplane/Driver', ['HydraEngineHub.c'])
driver.add_system_framework(%w[CoreAudio CoreFoundation Accelerate])
# Bundle the plugin icon into Resources.
hub_icon = driver.new_copy_files_build_phase('Copy Plugin Icon')
hub_icon.symbol_dst_subfolder_spec = :resources
hub_icon.dst_path = ''
hub_icon.add_file_reference(project.new_file('Backplane/Driver/Hydra.icns'), true)
each_config(driver) do |cfg, s, release|
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'audio.hydra.virtualsoundcard'
  s['PRODUCT_NAME']              = 'HydraVirtualSoundcard'
  s['MACOSX_DEPLOYMENT_TARGET']  = '11.0'
  s['MARKETING_VERSION']         = MARKETING
  s['CURRENT_PROJECT_VERSION']   = BUILD_NUM
  s['WRAPPER_EXTENSION']         = 'driver'
  s['MACH_O_TYPE']               = 'mh_bundle'
  s['INFOPLIST_FILE']            = 'Backplane/Driver/Hydra.plist'
  s['GENERATE_INFOPLIST_FILE']   = 'NO'
  s['INSTALL_PATH']              = '/Library/Audio/Plug-Ins/HAL'
  s['SKIP_INSTALL']              = 'YES'
  s['CODE_SIGN_STYLE']           = 'Manual'
  s['CODE_SIGN_IDENTITY']        = SIGN_ID
  s['ARCHS']                     = 'arm64 x86_64'
  s['ONLY_ACTIVE_ARCH']          = 'NO'
  s['ALWAYS_SEARCH_USER_PATHS']  = 'NO'
  # The driver is derived from BlackHole; its debug-logging printf calls trip
  # -Wformat ("data argument not used by format string"). Benign — quiet it.
  s['GCC_WARN_TYPECHECK_CALLS_TO_PRINTF'] = 'NO'
end

# ---------------------------------------------------------------------------
# Hydra Audio Bridges (8 fixed loopback devices, each its own .driver bundle)
# ---------------------------------------------------------------------------
# Each bridge compiles ONLY its wrapper (bridges/HydraBridge_*.c), which sets the
# per-bridge overrides (channels/name/UID, kBox_Aquired=false) and #includes the
# shared Hydra.c. Device UIDs differ per bundle (kDriver_Name + "_UID"), so they
# coexist without colliding. Starts hidden; the Hydra engine acquires the box.
# Columns: target, wrapper .c, bundle-id suffix, product name, own Info.plist
# (each plist carries a UNIQUE CFPlugIn factory UUID so the 8 bundles don't
# collide in coreaudiod's plugin registry).
HYDRA_BRIDGES = [
  ['HydraBridge2A',  'HydraBridge_2A.c',  '2a',  'HydraAudioBridge2A',  'Info_2A.plist'],
  ['HydraBridge2B',  'HydraBridge_2B.c',  '2b',  'HydraAudioBridge2B',  'Info_2B.plist'],
  ['HydraBridge4',   'HydraBridge_4.c',   '4',   'HydraAudioBridge4',   'Info_4.plist'],
  ['HydraBridge8',   'HydraBridge_8.c',   '8',   'HydraAudioBridge8',   'Info_8.plist'],
  ['HydraBridge16',  'HydraBridge_16.c',  '16',  'HydraAudioBridge16',  'Info_16.plist'],
  ['HydraBridge32',  'HydraBridge_32.c',  '32',  'HydraAudioBridge32',  'Info_32.plist'],
  ['HydraBridge64',  'HydraBridge_64.c',  '64',  'HydraAudioBridge64',  'Info_64.plist'],
  ['HydraBridge128', 'HydraBridge_128.c', '128', 'HydraAudioBridge128', 'Info_128.plist'],
]
bridge_drivers = HYDRA_BRIDGES.map do |tname, wrapper, idkey, product, plist|
  bt = project.new_target(:bundle, tname, :osx, '11.0', nil, :c)
  # Only the wrapper compiles (it #includes ../Hydra.c). The Info plists in the
  # same folder are referenced via INFOPLIST_FILE, never compiled.
  add_dir(project, bt, 'Backplane/Driver/bridges', [wrapper])
  bt.add_system_framework(%w[CoreAudio CoreFoundation Accelerate])
  # Bundle the plugin icon into Resources.
  icon = bt.new_copy_files_build_phase('Copy Plugin Icon')
  icon.symbol_dst_subfolder_spec = :resources
  icon.dst_path = ''
  icon.add_file_reference(project.new_file('Backplane/Driver/Hydra.icns'), true)
  each_config(bt) do |cfg, s, release|
    s['PRODUCT_BUNDLE_IDENTIFIER'] = "audio.hydra.bridge.#{idkey}"
    s['PRODUCT_NAME']              = product
    s['MACOSX_DEPLOYMENT_TARGET']  = '11.0'
    s['MARKETING_VERSION']         = MARKETING
    s['CURRENT_PROJECT_VERSION']   = BUILD_NUM
    s['WRAPPER_EXTENSION']         = 'driver'
    s['MACH_O_TYPE']               = 'mh_bundle'
    s['INFOPLIST_FILE']            = "Backplane/Driver/bridges/#{plist}"
    s['GENERATE_INFOPLIST_FILE']   = 'NO'
    s['INSTALL_PATH']              = '/Library/Audio/Plug-Ins/HAL'
    s['SKIP_INSTALL']              = 'YES'
    s['CODE_SIGN_STYLE']           = 'Manual'
    s['CODE_SIGN_IDENTITY']        = SIGN_ID
    s['ARCHS']                     = 'arm64 x86_64'
    s['ONLY_ACTIVE_ARCH']          = 'NO'
    s['ALWAYS_SEARCH_USER_PATHS']  = 'NO'
    s['GCC_WARN_TYPECHECK_CALLS_TO_PRINTF'] = 'NO'
    s['HEADER_SEARCH_PATHS']       = '$(inherited) $(SRCROOT)/Backplane/Driver'
  end
  bt
end

# Embed the built backplane driver inside HydraApp.app/Contents/Resources so the
# in-app Welcome flow (InstallManager) can install it to /Library/Audio/Plug-Ins/HAL
# without shipping a separate file. The app depends on the driver target so it is
# built first, and code-signs it on copy.
app.add_dependency(driver)
embed_driver = app.new_copy_files_build_phase('Embed Soundcard Driver')
embed_driver.symbol_dst_subfolder_spec = :resources
embed_driver.dst_path = ''
embed_bf = embed_driver.add_file_reference(driver.product_reference, true)
embed_bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }

# The audio engine (HydraDaemon) is no longer a separate process: it's embedded as
# a framework via link_and_embed(app, …) above, so there is NO Helpers daemon copy
# and NO LaunchAgent. The old LaunchAgents plist is unused.

# Embed the out-of-process plugin host in Contents/Library/Helpers so the engine
# can launch it (RemotePluginHost.defaultHostURL locates it there). It's still a
# separate child process (crash isolation), spawned only when a VST is loaded;
# code-signed on copy.
app.add_dependency(pluginhost)
embed_pluginhost = app.new_copy_files_build_phase('Embed Plugin Host')
embed_pluginhost.symbol_dst_subfolder_spec = :wrapper
embed_pluginhost.dst_path = 'Contents/Library/Helpers'
pluginhost_bf = embed_pluginhost.add_file_reference(pluginhost.product_reference, true)
pluginhost_bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }

# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------
tests = project.new_target(:unit_test_bundle, 'HydraCoreTests', :osx, DEPLOY, nil, :swift)
sync_dir(project, tests, 'Tests/HydraCoreTests')
tests.add_dependency(core)
tests.frameworks_build_phase.add_file_reference(core.product_reference, true)
common!(tests, 'audio.hydra.core.tests', {
  'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks',
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'CODE_SIGN_STYLE'         => 'Manual',
  'CODE_SIGN_IDENTITY'      => '-'
})

# Real-time DSP tests — exercise HydraRT (SPSC ring + polyphase resampler)
# directly, including under TSan/ASan (see the HydraRTTests scheme + CI).
rtTests = project.new_target(:unit_test_bundle, 'HydraRTTests', :osx, DEPLOY, nil, :swift)
sync_dir(project, rtTests, 'Tests/HydraRTTests')
rtTests.add_dependency(core)
rtTests.add_dependency(rt)
rtTests.frameworks_build_phase.add_file_reference(core.product_reference, true)
rtTests.frameworks_build_phase.add_file_reference(rt.product_reference, true)
common!(rtTests, 'audio.hydra.rt.tests', {
  'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks',
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'CODE_SIGN_STYLE'         => 'Manual',
  'CODE_SIGN_IDENTITY'      => '-'
})

# Control-surface codec tests — HiQnet/HUI round-trips (Swift Testing). They
# `@testable import HydraSurface`, so the framework is a dependency here.
surfaceTests = project.new_target(:unit_test_bundle, 'HydraSurfaceTests', :osx, DEPLOY, nil, :swift)
sync_dir(project, surfaceTests, 'Tests/HydraSurfaceTests')
surfaceTests.add_dependency(surface)
surfaceTests.frameworks_build_phase.add_file_reference(surface.product_reference, true)
common!(surfaceTests, 'audio.hydra.surface.tests', {
  'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks',
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'CODE_SIGN_STYLE'         => 'Manual',
  'CODE_SIGN_IDENTITY'      => '-'
})

# The xcodeproj gem seeds every new target with ENABLE_MODULE_VERIFIER = YES,
# which OVERRIDES the project-level NO and makes the clang module verifier fail on
# the VST3 SDK's C++ headers (Command VerifyModule failed). Force it off on every
# target's build configurations, after all targets exist.
project.targets.each do |t|
  t.build_configurations.each do |c|
    c.build_settings['ENABLE_MODULE_VERIFIER'] = 'NO'
    # Follow the macOS SYSTEM accent: with the brand mark now neutral (gray +
    # white), the UI tint should be the accent the user chose in System Settings.
    # The xcodeproj gem defaults this to "AccentColor" (a fixed indigo asset);
    # clearing it makes Color.accentColor == the system accent, matching the grid
    # (which already uses controlAccentColor). The indigo AccentColor.colorset is
    # left inert.
    c.build_settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = ''
  end
end

# ---------------------------------------------------------------------------
# shared schemes
# ---------------------------------------------------------------------------
project.save

def shared_scheme(project, name, build_target, test_target = nil)
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(build_target)
  if build_target.product_type == 'com.apple.product-type.application'
    scheme.set_launch_target(build_target)
  end
  if test_target
    tref = Xcodeproj::XCScheme::TestAction::TestableReference.new(test_target)
    scheme.test_action.add_testable(tref)
  end
  scheme.save_as(project.path, name, true)
end

shared_scheme(project, 'HydraApp', app, tests)
shared_scheme(project, 'HydraDaemon', daemon, tests)
shared_scheme(project, 'HydraCore', core, tests)
shared_scheme(project, 'HydraRTTests', core, rtTests)
shared_scheme(project, 'HydraSurfaceTests', surface, surfaceTests)
shared_scheme(project, 'HydraVirtualSoundcard.driver', driver)

puts "Wrote #{PROJ_PATH}"
puts "Targets: #{project.targets.map(&:name).join(', ')}"
