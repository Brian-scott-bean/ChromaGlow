#!/usr/bin/env ruby
# add_stage1_files.rb
# Adds all Stage 1 new files to the HueHome Xcode project.
# Idempotent — safe to run multiple times.

require 'xcodeproj'

PROJECT_PATH = File.join(File.dirname(__FILE__), 'HueHome.xcodeproj')
SOURCE_ROOT  = File.join(File.dirname(__FILE__), 'HueHome')

puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "  HueHome Pro — Stage 1 File Sync"
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"

project    = Xcodeproj::Project.open(PROJECT_PATH)
app_target = project.targets.find { |t| t.name == 'HueHome' }
abort("❌ HueHome target not found.") unless app_target

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

def add_file(project, target, abs_path, group_path, existing)
  return 0 unless File.exist?(abs_path)
  resolved = File.expand_path(abs_path)
  if existing.include?(resolved)
    puts "   ⏭  Already in project: #{File.basename(abs_path)}"
    return 0
  end
  group = ensure_group(project, group_path)
  ref   = group.new_file(abs_path)
  target.source_build_phase.add_file_reference(ref) if abs_path.end_with?('.swift')
  puts "   ✅ Added: #{group_path.join(' / ')} / #{File.basename(abs_path)}"
  1
end

STAGE1_FILES = {
  # Design Token System
  File.join(SOURCE_ROOT, 'UI', 'Components', 'HueTokens.swift')         => ['HueHome', 'UI', 'Components'],
  File.join(SOURCE_ROOT, 'UI', 'Components', 'HueTypography.swift')     => ['HueHome', 'UI', 'Components'],
  File.join(SOURCE_ROOT, 'UI', 'Components', 'HueComponents.swift')     => ['HueHome', 'UI', 'Components'],

  # Navigation
  File.join(SOURCE_ROOT, 'UI', 'Navigation', 'MainTabView.swift')       => ['HueHome', 'UI', 'Navigation'],
  File.join(SOURCE_ROOT, 'UI', 'Navigation', 'TabShells.swift')         => ['HueHome', 'UI', 'Navigation'],

  # SwiftData Models
  File.join(SOURCE_ROOT, 'Core', 'Models', 'HueDataModels.swift')       => ['HueHome', 'Core', 'Models'],
}

puts "📱 Stage 1 files:"
existing = existing_paths(project)
added = 0

STAGE1_FILES.each do |path, grp|
  added += add_file(project, app_target, path, grp, existing)
  existing = existing_paths(project)
end

if added > 0
  project.save
  puts "\n💾 Project saved — #{added} file(s) added."
else
  puts "\nℹ️  No changes — all Stage 1 files already in project."
end

puts "\n  Next: ⌘B to build\n"
