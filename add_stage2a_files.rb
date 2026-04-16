#!/usr/bin/env ruby
# add_stage2a_files.rb
# Adds Stage 2A Multi-Bridge files to the Xcode project.
# Idempotent — safe to run multiple times.

require 'xcodeproj'

PROJECT_PATH = File.join(File.dirname(__FILE__), 'HueHome.xcodeproj')
SOURCE_ROOT  = File.join(File.dirname(__FILE__), 'HueHome')

puts "================================================"
puts "  HueHome Pro -- Stage 2A File Sync"
puts "================================================\n\n"

project    = Xcodeproj::Project.open(PROJECT_PATH)
app_target = project.targets.find { |t| t.name == 'HueHome' }
abort("HueHome target not found.") unless app_target

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
    puts "   -- Already in project: #{File.basename(abs_path)}"
    return 0
  end
  group = ensure_group(project, group_path)
  ref   = group.new_file(abs_path)
  target.source_build_phase.add_file_reference(ref) if abs_path.end_with?('.swift')
  puts "   ++ Added: #{group_path.join(' / ')} / #{File.basename(abs_path)}"
  1
end

existing = existing_paths(project)
added = 0

FILES = {
  # Network
  File.join(SOURCE_ROOT, 'Core/Network/BridgeAPIClient.swift')     => ['HueHome', 'Core', 'Network'],
  File.join(SOURCE_ROOT, 'Core/Network/UnifiedOrchestrator.swift') => ['HueHome', 'Core', 'Network'],
  # UI
  File.join(SOURCE_ROOT, 'UI/BridgeManager/BridgeManagerView.swift') => ['HueHome', 'UI', 'BridgeManager'],
}

FILES.each do |path, grp|
  added += add_file(project, app_target, path, grp, existing)
  existing = existing_paths(project)
end

if added > 0
  project.save
  puts "\n  Saved -- #{added} file(s) added to project."
else
  puts "\n  No changes -- all Stage 2A files already in project."
end
puts "\n  Next: xcodebuild build to verify\n"
