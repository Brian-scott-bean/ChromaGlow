#!/usr/bin/env ruby
# generate_xcodeproj.rb
# Generates ChromaGlow.xcodeproj for Epic 1 / Story 1.1 using the xcodeproj gem.
# Run from: /Users/brianbean/Desktop/huehome-pro-v0.1.0/

require 'xcodeproj'
require 'fileutils'

# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
PROJECT_NAME      = 'ChromaGlow'
BUNDLE_ID         = 'com.huehome.pro'
DEPLOYMENT_TARGET = '17.0'
SWIFT_VERSION     = '5.9'
PROJECT_ROOT      = File.dirname(__FILE__)
SOURCE_ROOT       = File.join(PROJECT_ROOT, 'ChromaGlow')
PROJ_PATH         = File.join(PROJECT_ROOT, "#{PROJECT_NAME}.xcodeproj")

puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "  ChromaGlow — Xcode Project Generator"
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "  Project root : #{PROJECT_ROOT}"
puts "  Source root  : #{SOURCE_ROOT}"
puts "  Output       : #{PROJ_PATH}"
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"

# ─────────────────────────────────────────────
# STEP 1 — Create Info.plist
# ─────────────────────────────────────────────
PLIST_PATH = File.join(SOURCE_ROOT, 'Info.plist')
unless File.exist?(PLIST_PATH)
  puts "📄 Writing Info.plist…"
  plist_content = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleDevelopmentRegion</key>
      <string>$(DEVELOPMENT_LANGUAGE)</string>
      <key>CFBundleExecutable</key>
      <string>$(EXECUTABLE_NAME)</string>
      <key>CFBundleIdentifier</key>
      <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
      <key>CFBundleInfoDictionaryVersion</key>
      <string>6.0</string>
      <key>CFBundleName</key>
      <string>$(PRODUCT_NAME)</string>
      <key>CFBundlePackageType</key>
      <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
      <key>CFBundleShortVersionString</key>
      <string>0.1.0</string>
      <key>CFBundleVersion</key>
      <string>1</string>
      <key>LSRequiresIPhoneOS</key>
      <true/>
      <key>NSBonjourServices</key>
      <array>
        <string>_hue._tcp</string>
      </array>
      <key>NSLocalNetworkUsageDescription</key>
      <string>ChromaGlow needs local network access to discover your Philips Hue Bridge via mDNS.</string>
      <key>UIApplicationSceneManifest</key>
      <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <false/>
      </dict>
      <key>UILaunchScreen</key>
      <dict/>
      <key>UISupportedInterfaceOrientations</key>
      <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
      </array>
    </dict>
    </plist>
  XML
  File.write(PLIST_PATH, plist_content)
  puts "   ✅ Info.plist written.\n\n"
else
  puts "   ⏭  Info.plist already exists — skipping.\n\n"
end

# ─────────────────────────────────────────────
# STEP 2 — Create .xcodeproj
# ─────────────────────────────────────────────
puts "🏗️  Creating #{PROJECT_NAME}.xcodeproj…"
project = Xcodeproj::Project.new(PROJ_PATH)

# ─────────────────────────────────────────────
# STEP 3 — Create group hierarchy mirroring file system
# ─────────────────────────────────────────────
puts "📁 Building group hierarchy…"

root_group = project.main_group

# Helper: get-or-create a group at a given path under a parent group
def ensure_group(parent, name)
  existing = parent.children.find { |c| c.respond_to?(:name) && c.name == name }
  existing || parent.new_group(name)
end

hue_group    = ensure_group(root_group, PROJECT_NAME)
core_group   = ensure_group(hue_group,  'Core')
keychain_grp = ensure_group(core_group, 'Keychain')
network_grp  = ensure_group(core_group, 'Network')
vm_grp       = ensure_group(core_group, 'ViewModels')
ui_group     = ensure_group(hue_group,  'UI')
setup_grp    = ensure_group(ui_group,   'BridgeSetup')

puts "   ✅ Groups created.\n\n"

# ─────────────────────────────────────────────
# STEP 4 — Map source files → Xcode groups
# ─────────────────────────────────────────────
SOURCE_FILES = {
  File.join(SOURCE_ROOT, 'ChromaGlowApp.swift')                              => hue_group,
  File.join(SOURCE_ROOT, 'Info.plist')                                    => hue_group,
  File.join(SOURCE_ROOT, 'Core', 'Keychain', 'KeychainManager.swift')    => keychain_grp,
  File.join(SOURCE_ROOT, 'Core', 'Network', 'BridgeDiscoveryService.swift') => network_grp,
  File.join(SOURCE_ROOT, 'Core', 'ViewModels', 'BridgeDiscoveryViewModel.swift') => vm_grp,
  File.join(SOURCE_ROOT, 'UI', 'BridgeSetup', 'BridgeSetupView.swift')   => setup_grp,
}

puts "📎 Adding source files to groups…"
compile_sources = []
plist_ref       = nil

SOURCE_FILES.each do |abs_path, group|
  rel_path = abs_path.sub("#{PROJECT_ROOT}/", '')
  unless File.exist?(abs_path)
    puts "   ⚠️  MISSING: #{rel_path} — skipping."
    next
  end

  ref = group.new_file(abs_path)
  puts "   + #{rel_path}"

  if abs_path.end_with?('.swift')
    compile_sources << ref
  elsif abs_path.end_with?('.plist')
    plist_ref = ref
  end
end
puts "\n"

# ─────────────────────────────────────────────
# STEP 5 — Create App target
# ─────────────────────────────────────────────
puts "🎯 Creating '#{PROJECT_NAME}' app target…"
target = project.new_target(:application, PROJECT_NAME, :ios, DEPLOYMENT_TARGET)

# Add compile sources build phase
compile_sources.each do |ref|
  target.source_build_phase.add_file_reference(ref)
  puts "   ✔ Compile: #{File.basename(ref.path)}"
end

# Add resources build phase (plist is not compiled but referenced via build setting)
puts "\n"

# ─────────────────────────────────────────────
# STEP 6 — Build settings
# ─────────────────────────────────────────────
puts "⚙️  Configuring build settings…"

common_settings = {
  'ALWAYS_SEARCH_USER_PATHS'          => 'NO',
  'CLANG_ENABLE_MODULES'              => 'YES',
  'CLANG_ENABLE_OBJC_ARC'            => 'YES',
  'SWIFT_VERSION'                     => SWIFT_VERSION,
  'IPHONEOS_DEPLOYMENT_TARGET'        => DEPLOYMENT_TARGET,
  'PRODUCT_BUNDLE_IDENTIFIER'         => BUNDLE_ID,
  'PRODUCT_NAME'                      => '$(TARGET_NAME)',
  'INFOPLIST_FILE'                    => 'ChromaGlow/Info.plist',
  'SWIFT_EMIT_LOC_STRINGS'            => 'YES',
  'ENABLE_PREVIEWS'                   => 'YES',
  # Strict concurrency for async/await safety
  'SWIFT_STRICT_CONCURRENCY'          => 'complete',
  # Physical device only — no simulator arch bleeding
  'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64',
}

debug_settings = common_settings.merge(
  'DEBUG_INFORMATION_FORMAT'   => 'dwarf',
  'ENABLE_TESTABILITY'         => 'YES',
  'GCC_DYNAMIC_NO_PIC'         => 'NO',
  'GCC_OPTIMIZATION_LEVEL'     => '0',
  'MTL_ENABLE_DEBUG_INFO'      => 'INCLUDE_SOURCE',
  'ONLY_ACTIVE_ARCH'           => 'YES',
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'DEBUG',
  'SWIFT_OPTIMIZATION_LEVEL'   => '-Onone',
)

release_settings = common_settings.merge(
  'DEBUG_INFORMATION_FORMAT'   => 'dwarf-with-dsym',
  'ENABLE_NS_ASSERTIONS'       => 'NO',
  'MTL_ENABLE_DEBUG_INFO'      => 'NO',
  'SWIFT_OPTIMIZATION_LEVEL'   => '-Owholemodule',
  'VALIDATE_PRODUCT'           => 'YES',
)

target.build_configurations.each do |config|
  settings = config.name == 'Debug' ? debug_settings : release_settings
  settings.each { |k, v| config.build_settings[k] = v }
  puts "   ✔ #{config.name} settings applied."
end
puts "\n"

# ─────────────────────────────────────────────
# STEP 7 — Project-level build configs
# ─────────────────────────────────────────────
project.build_configurations.each do |config|
  config.build_settings['SWIFT_VERSION'] = SWIFT_VERSION
end

# ─────────────────────────────────────────────
# STEP 8 — Save
# ─────────────────────────────────────────────
puts "💾 Saving #{PROJECT_NAME}.xcodeproj…"
project.save
puts "   ✅ Saved.\n\n"

# ─────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "  ✅ Done! Project generated successfully."
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts ""
puts "  Next steps:"
puts "  1. open #{PROJ_PATH}"
puts "  2. Select your physical iPhone in the toolbar"
puts "  3. Set your Team under Signing & Capabilities"
puts "  4. Hit ⌘R and tap 'Scan for Bridge'"
puts ""
