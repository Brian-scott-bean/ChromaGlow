#!/usr/bin/env ruby
# add_create_global_scene.rb
# Adds CreateGlobalSceneView to the Xcode project.
# Idempotent — safe to run multiple times.

require 'xcodeproj'

PROJECT_PATH = File.join(File.dirname(__FILE__), 'ChromaGlow.xcodeproj')
SOURCE_ROOT  = File.join(File.dirname(__FILE__), 'ChromaGlow')

project    = Xcodeproj::Project.open(PROJECT_PATH)
app_target = project.targets.find { |t| t.name == 'ChromaGlow' }
abort("ChromaGlow target not found.") unless app_target

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
added    = 0

new_files = [
  { path: "UI/Scenes/CreateGlobalSceneView.swift", group: ["ChromaGlow", "UI", "Scenes"] },
]

new_files.each do |f|
  abs = File.join(SOURCE_ROOT, f[:path])
  added += add_file(project, app_target, abs, f[:group], existing)
end

project.save
puts "\nDone — #{added} file(s) added."
