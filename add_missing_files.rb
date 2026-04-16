#!/usr/bin/env ruby
# add_missing_files.rb
# Idempotent — safe to run after each story to add new files + test target.
# Preserves Signing & Capabilities settings already configured in Xcode.

require 'xcodeproj'

PROJECT_PATH = File.join(File.dirname(__FILE__), 'HueHome.xcodeproj')
SOURCE_ROOT  = File.join(File.dirname(__FILE__), 'HueHome')
TESTS_ROOT   = File.join(File.dirname(__FILE__), 'HueHomeTests')

puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "  HueHome Pro — Sync Project Files"
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"

project      = Xcodeproj::Project.open(PROJECT_PATH)
app_target   = project.targets.find { |t| t.name == 'HueHome' }
abort("❌ HueHome target not found.") unless app_target

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

def existing_paths(project)
  project.files.map { |f|
    File.expand_path(f.real_path.to_s) rescue nil
  }.compact.to_set
end

def ensure_group(project, path_components)
  group = project.main_group
  path_components.each do |name|
    child = group.children.find { |c| c.respond_to?(:name) && c.name == name }
    group = child || group.new_group(name)
  end
  group
end

def add_file_if_missing(project, target, abs_path, group_path, existing, label)
  return unless File.exist?(abs_path)
  resolved = File.expand_path(abs_path)
  if existing.include?(resolved)
    puts "   ⏭  Already in project: #{File.basename(abs_path)}"
    return 0
  end
  group = ensure_group(project, group_path)
  ref   = group.new_file(abs_path)
  target.source_build_phase.add_file_reference(ref) if abs_path.end_with?('.swift')
  puts "   ✅ Added [#{label}]: #{group_path.join(' / ')} / #{File.basename(abs_path)}"
  1
end

# ──────────────────────────────────────────────
# Story 1.2 / 1.3 App Sources
# ──────────────────────────────────────────────
puts "📱 App sources:"
existing = existing_paths(project)
added = 0

APP_FILES = {
  File.join(SOURCE_ROOT, 'UI',   'Splash',      'SplashView.swift')           => ['HueHome', 'UI', 'Splash'],
  File.join(SOURCE_ROOT, 'UI',   'Dashboard',   'DashboardView.swift')         => ['HueHome', 'UI', 'Dashboard'],
  File.join(SOURCE_ROOT, 'UI',   'Settings',    'SettingsView.swift')          => ['HueHome', 'UI', 'Settings'],
  File.join(SOURCE_ROOT, 'UI',   'RoomDetail',  'RoomDetailView.swift')        => ['HueHome', 'UI', 'RoomDetail'],
  File.join(SOURCE_ROOT, 'UI',   'RoomDetail',  'SceneChip.swift')             => ['HueHome', 'UI', 'RoomDetail'],
  File.join(SOURCE_ROOT, 'UI',   'RoomDetail',  'CreateSceneView.swift')       => ['HueHome', 'UI', 'RoomDetail'],
  File.join(SOURCE_ROOT, 'UI',   'Automations', 'AutomationsView.swift')       => ['HueHome', 'UI', 'Automations'],
  File.join(SOURCE_ROOT, 'UI',   'LightControl', 'LightControlView.swift')     => ['HueHome', 'UI', 'LightControl'],
  File.join(SOURCE_ROOT, 'UI',   'Components',  'HapticManager.swift')         => ['HueHome', 'UI', 'Components'],
  File.join(SOURCE_ROOT, 'UI',   'Components',  'GlassmorphicCard.swift')      => ['HueHome', 'UI', 'Components'],
  File.join(SOURCE_ROOT, 'UI',   'Components',  'HueColorUtils.swift')         => ['HueHome', 'UI', 'Components'],
  File.join(SOURCE_ROOT, 'Core', 'Models',      'HueScene.swift')              => ['HueHome', 'Core', 'Models'],
  File.join(SOURCE_ROOT, 'Core', 'Models',      'SceneDisplayItem.swift')      => ['HueHome', 'Core', 'Models'],
  File.join(SOURCE_ROOT, 'Core', 'Models',      'CreateSceneRequest.swift')    => ['HueHome', 'Core', 'Models'],
  File.join(SOURCE_ROOT, 'Core', 'Models',      'HueBehaviorInstance.swift')   => ['HueHome', 'Core', 'Models'],
  File.join(SOURCE_ROOT, 'Core', 'ViewModels',  'AutomationsViewModel.swift')  => ['HueHome', 'Core', 'ViewModels'],
  File.join(SOURCE_ROOT, 'Core', 'Models',      'HueRoom.swift')               => ['HueHome', 'Core', 'Models'],
  File.join(SOURCE_ROOT, 'Core', 'Models',      'HueLight.swift')              => ['HueHome', 'Core', 'Models'],
  File.join(SOURCE_ROOT, 'Core', 'Models',      'HueGroupedLight.swift')       => ['HueHome', 'Core', 'Models'],
  File.join(SOURCE_ROOT, 'Core', 'Models',      'LightDisplayItem.swift')      => ['HueHome', 'Core', 'Models'],
  File.join(SOURCE_ROOT, 'Core', 'Network',     'HueAPIClient.swift')          => ['HueHome', 'Core', 'Network'],
  File.join(SOURCE_ROOT, 'Core', 'Network',     'WidgetDataStore.swift')       => ['HueHome', 'Core', 'Network'],
  File.join(SOURCE_ROOT, 'Core', 'Network',     'HueSSEService.swift')         => ['HueHome', 'Core', 'Network'],
  File.join(SOURCE_ROOT, 'Core', 'ViewModels',  'DashboardViewModel.swift')    => ['HueHome', 'Core', 'ViewModels'],
  File.join(SOURCE_ROOT, 'Core', 'ViewModels',  'RoomDetailViewModel.swift')   => ['HueHome', 'Core', 'ViewModels'],
}

APP_FILES.each do |path, grp|
  added += add_file_if_missing(project, app_target, path, grp, existing, 'App').to_i
  existing = existing_paths(project)  # refresh after each add
end

# ──────────────────────────────────────────────
# Test Target
# ──────────────────────────────────────────────
puts "\n🧪 Test target:"
test_target = project.targets.find { |t| t.name == 'HueHomeTests' }

unless test_target
  puts "   🆕 Creating HueHomeTests unit test target…"
  test_target = project.new_target(:unit_test_bundle, 'HueHomeTests', :ios, '17.0')
  test_target.add_dependency(app_target)

  test_target.build_configurations.each do |config|
    config.build_settings['SWIFT_VERSION']               = '5.9'
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET']  = '17.0'
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER']   = 'com.huehome.pro.tests'
    config.build_settings['TEST_HOST']                   = '$(BUILT_PRODUCTS_DIR)/HueHome.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/HueHome'
    config.build_settings['BUNDLE_LOADER']               = '$(TEST_HOST)'
    config.build_settings['SWIFT_STRICT_CONCURRENCY']    = 'complete'
  end
  puts "   ✅ HueHomeTests target created."
end

existing = existing_paths(project)
TEST_FILES = {
  File.join(TESTS_ROOT, 'KeychainManagerTests.swift') => ['HueHomeTests'],
  File.join(TESTS_ROOT, 'HueAPIClientTests.swift')    => ['HueHomeTests'],
}

TEST_FILES.each do |path, grp|
  added += add_file_if_missing(project, test_target, path, grp, existing, 'Test').to_i
  existing = existing_paths(project)
end

# ──────────────────────────────────────────────
# Save
# ──────────────────────────────────────────────
if added > 0
  project.save
  puts "\n💾 Project saved (#{added} item(s) added)."
else
  puts "\nℹ️  No changes — project is already up to date."
end

puts "\n  Next: ⌘R to build, ⌘U to run tests.\n"
