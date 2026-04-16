#!/usr/bin/env ruby
# fix_assets_path.rb
# Corrects the Assets.xcassets file reference to point at the right location.

require 'xcodeproj'

PROJ_PATH   = File.join(__dir__, 'HueHome.xcodeproj')
ASSETS_PATH = File.join(__dir__, 'HueHome', 'Assets.xcassets')

project = Xcodeproj::Project.open(PROJ_PATH)

# Find and fix any broken Assets.xcassets references
fixed = 0
project.files.each do |f|
  if f.path&.include?('Assets.xcassets') && !f.real_path.to_s.include?('/HueHome/')
    puts "🔧 Fixing reference: #{f.real_path} → #{ASSETS_PATH}"
    f.source_tree = 'SOURCE_ROOT'
    f.path        = 'HueHome/Assets.xcassets'
    fixed += 1
  end
end

if fixed == 0
  # Try to find it by any path
  project.files.each do |f|
    if f.path&.include?('Assets.xcassets')
      puts "Found: #{f.path} (source_tree: #{f.source_tree}, real: #{f.real_path})"
      f.source_tree = 'SOURCE_ROOT'
      f.path        = 'HueHome/Assets.xcassets'
      puts "  → Fixed to SOURCE_ROOT / HueHome/Assets.xcassets"
      fixed += 1
    end
  end
end

if fixed == 0
  # Add fresh reference
  puts "⚠️  No existing reference found — adding fresh one."
  target = project.targets.find { |t| t.name == 'HueHome' }
  ref = project.main_group.new_file('HueHome/Assets.xcassets', :project)
  ref.last_known_file_type = 'folder.assetcatalog'
  target.resources_build_phase.add_file_reference(ref)
  puts "✅ Added fresh reference."
  fixed = 1
end

project.save
puts "💾 Saved. Fixed #{fixed} reference(s)."
puts "   Next: ⌘⇧K → ⌘R"
