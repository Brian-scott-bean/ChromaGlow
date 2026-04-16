#!/usr/bin/env ruby
# add_app_icon.rb
# Registers HueHome/Assets.xcassets in the Xcode project and sets
# the ASSETCATALOG_COMPILER_APPICON_NAME build setting.

require 'xcodeproj'

PROJ_PATH   = File.join(__dir__, 'HueHome.xcodeproj')
SOURCE_ROOT = File.join(__dir__, 'HueHome')
ASSETS_PATH = File.join(SOURCE_ROOT, 'Assets.xcassets')

project = Xcodeproj::Project.open(PROJ_PATH)

# Find the HueHome app target
target = project.targets.find { |t| t.name == 'HueHome' }
abort '❌ HueHome target not found' unless target

# Find or create the HueHome group
hue_group = project.main_group.find_subpath('HueHome', false)
abort '❌ HueHome group not found in project' unless hue_group

# Check if already added
already = hue_group.files.any? { |f| f.path&.include?('Assets.xcassets') }
if already
  puts '⏭  Assets.xcassets already in project.'
else
  # Add as a file reference
  ref = hue_group.new_reference(ASSETS_PATH)
  ref.last_known_file_type = 'folder.assetcatalog'
  ref.source_tree = '<group>'
  ref.path = 'Assets.xcassets'

  # Add to Copy Bundle Resources build phase
  phase = target.resources_build_phase
  phase.add_file_reference(ref)
  puts '✅ Assets.xcassets added to HueHome target.'
end

# Set ASSETCATALOG_COMPILER_APPICON_NAME in all build configs
target.build_configurations.each do |config|
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
end
puts '✅ Build settings: ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon'

project.save
puts '💾 Project saved.'
puts ''
puts '  Next: ⌘⇧K (clean) then ⌘R — your icon should appear on device.'
