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
#   hydrad              app (Swift)         — background daemon (.app, LSUIElement)
#   HydraApp            app (Swift)         — SwiftUI UI, client of the daemon
#   HydraVirtualSoundcard  .driver bundle (C) — 512-wire AudioServerPlugIn backplane
#   HydraCoreTests      unit test bundle    — XCTest over HydraCore

require 'xcodeproj'

ROOT       = File.expand_path('..', __dir__)
PROJ_PATH  = File.join(ROOT, 'Hydra.xcodeproj')
DEPLOY     = '26.0'
MARKETING  = '0.19.1'
BUILD_NUM  = '0.19.1'
SRC_EXT    = %w[.swift .c .m .mm .cpp .cc].freeze

project = Xcodeproj::Project.new(PROJ_PATH)

# Localization: English is the development (base) language; pt-BR ships as a
# translation. Strings live in Sources/HydraApp/Localizable.xcstrings (String
# Catalog), auto-extracted at build time (SWIFT_EMIT_LOC_STRINGS=YES on the app).
project.root_object.development_region = 'en'
project.root_object.known_regions = %w[en Base pt-BR]

# Stable code-signing identity for SMAppService. The LaunchAgent records a code
# requirement (LWCR) at registration; with ad-hoc signing ("-") the signature
# changes every build, so after a rebuild launchd refuses to spawn hydrad
# (EX_CONFIG / "needs LWCR update"). A self-signed "Hydra Dev" certificate keeps
# the signature — and thus the LWCR — stable across rebuilds. Create it once in
# Keychain Access → Certificate Assistant → Create a Certificate
# (name "Hydra Dev", Identity Type: Self-Signed Root, Certificate Type: Code
# Signing). Falls back to ad-hoc when the cert isn't present.
SIGN_ID = `security find-identity -v -p codesigning 2>/dev/null`.include?('"Hydra Dev"') ? 'Hydra Dev' : '-'

# Project-wide: disable Xcode's Run Script sandbox (blocks the VST-SDK fetch) and
# the clang module verifier (fails on the mixed C/C++/Swift framework targets).
project.build_configurations.each do |c|
  c.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  c.build_settings['ENABLE_MODULE_VERIFIER']        = 'NO'
end

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

def each_config(target)
  target.build_configurations.each { |c| yield c, c.build_settings, (c.name == 'Release') }
end

def common!(target, bundle_id, extra = {})
  each_config(target) do |cfg, s, release|
    s['PRODUCT_BUNDLE_IDENTIFIER'] = bundle_id
    s['MACOSX_DEPLOYMENT_TARGET']  = DEPLOY
    s['SWIFT_VERSION']             = '5.0'
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
    # Xcode 14+ sandboxes Run Script phases by default, which blocks our VST-SDK
    # fetch script from reading itself ("Sandbox: deny file-read-data ...").
    s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
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
add_dir(project, core, 'Sources/HydraCore', %w[*.swift])
common!(core, 'audio.hydra.core', 'DEFINES_MODULE' => 'YES')

# --- C / C++ shims: framework + explicit modulemap so Swift can `import` them.
def c_framework(project, name, dir, public_header, modulemap, bundle_id, extra = {})
  fw = project.new_target(:framework, name, :osx, DEPLOY, nil, :c)
  refs = add_dir(project, fw, dir, %w[*.c *.m *.mm *.cpp])
  hdrs = add_dir(project, fw, "#{dir}/include", %w[*.h])
  # publish the umbrella header referenced by the modulemap
  ph = hdrs[public_header]
  fw.headers_build_phase.add_file_reference(ph, true).settings = { 'ATTRIBUTES' => ['Public'] } if ph
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
vst.add_dependency(fetch_target)

# ---------------------------------------------------------------------------
# executables (.app)
# ---------------------------------------------------------------------------
RPATH = '@executable_path/../Frameworks @loader_path/../Frameworks'

daemon = project.new_target(:application, 'hydrad', :osx, DEPLOY, nil, :swift)
add_dir(project, daemon, 'Sources/hydrad', %w[*.swift])
common!(daemon, 'audio.hydra.daemon', {
  'INFOPLIST_FILE'         => 'Sources/hydrad/Info.plist',
  'INFOPLIST_KEY_LSUIElement' => 'YES',
  'GENERATE_INFOPLIST_FILE'=> 'NO',
  'CODE_SIGN_ENTITLEMENTS' => 'Sources/hydrad/hydrad.entitlements',
  'CODE_SIGN_STYLE'        => 'Manual',
  'CODE_SIGN_IDENTITY'     => SIGN_ID,
  'ENABLE_HARDENED_RUNTIME'=> 'YES',
  'LD_RUNPATH_SEARCH_PATHS'=> "$(inherited) #{RPATH}",
  'PRODUCT_NAME'           => 'hydrad'
})
link_and_embed(daemon, [core, vst, ndishim, moduleabi])

app = project.new_target(:application, 'HydraApp', :osx, DEPLOY, nil, :swift)
add_dir(project, app, 'Sources/HydraApp', %w[*.swift])
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
  'SWIFT_EMIT_LOC_STRINGS'  => 'YES'
})
link_and_embed(app, [core])

# App icon + accent: the asset catalog lives at the repo root (Media.xcassets).
# Add it to the app's resources so actool compiles AppIcon into the bundle —
# without this the Dock shows a blank icon.
app_assets = project.new_file('Media.xcassets')
app.resources_build_phase.add_file_reference(app_assets, true)

# Localizable String Catalog (English base + pt-BR). Xcode compiles it and
# extracts new Text() strings into it on build.
app_strings = project.new_file('Sources/HydraApp/Localizable.xcstrings')
app.resources_build_phase.add_file_reference(app_strings, true)

# ---------------------------------------------------------------------------
# backplane driver (.driver — AudioServerPlugIn bundle)
# ---------------------------------------------------------------------------
driver = project.new_target(:bundle, 'HydraVirtualSoundcard', :osx, '11.0', nil, :c)
add_dir(project, driver, 'Backplane/Driver', %w[*.c])
icns = add_dir(project, driver, 'Backplane/Driver', %w[*.icns])
driver.resources_build_phase.add_file_reference(icns['Hydra.icns'], true) if icns['Hydra.icns']
driver.add_system_framework(%w[CoreAudio CoreFoundation Accelerate])
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

# Embed the hydrad daemon as a bundled LaunchAgent so SMAppService.agent can
# register it (RunAtLoad + KeepAlive) and launchd starts it at login / on
# register. SMAppService REQUIRES the helper to live inside the app bundle:
#   • hydrad.app → Contents/Library/Helpers/   (BundleProgram path in the plist)
#   • audio.hydra.daemon.plist → Contents/Library/LaunchAgents/
# The app depends on the daemon target so it is built first and code-signed on copy.
app.add_dependency(daemon)

embed_helper = app.new_copy_files_build_phase('Embed Daemon Helper')
embed_helper.symbol_dst_subfolder_spec = :wrapper
embed_helper.dst_path = 'Contents/Library/Helpers'
helper_bf = embed_helper.add_file_reference(daemon.product_reference, true)
helper_bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }

embed_agent = app.new_copy_files_build_phase('Embed LaunchAgent')
embed_agent.symbol_dst_subfolder_spec = :wrapper
embed_agent.dst_path = 'Contents/Library/LaunchAgents'
agent_plist = project.new_file('Sources/HydraApp/LaunchAgents/audio.hydra.daemon.plist')
embed_agent.add_file_reference(agent_plist, true)

# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------
tests = project.new_target(:unit_test_bundle, 'HydraCoreTests', :osx, DEPLOY, nil, :swift)
add_dir(project, tests, 'Tests/HydraCoreTests', %w[*.swift])
tests.add_dependency(core)
tests.frameworks_build_phase.add_file_reference(core.product_reference, true)
common!(tests, 'audio.hydra.core.tests', {
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
shared_scheme(project, 'hydrad', daemon, tests)
shared_scheme(project, 'HydraCore', core, tests)
shared_scheme(project, 'HydraVirtualSoundcard.driver', driver)

puts "Wrote #{PROJ_PATH}"
puts "Targets: #{project.targets.map(&:name).join(', ')}"
