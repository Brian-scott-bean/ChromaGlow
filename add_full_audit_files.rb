#!/usr/bin/env ruby
# add_full_audit_files.rb
# Registers the 2026-07-22 full-audit-round files in the Xcode project and
# prunes references to the dead Sync-engine stack once those files are
# deleted from disk. Idempotent — safe to run at every commit of the round;
# silently skips files that don't exist yet and files already registered,
# and only removes a reference when its file is truly gone.

require 'xcodeproj'
require 'set'

PROJECT_PATH = File.join(File.dirname(__FILE__), 'HueHome.xcodeproj')
ROOT         = File.dirname(__FILE__)

project     = Xcodeproj::Project.open(PROJECT_PATH)
app_target  = project.targets.find { |t| t.name == 'HueHome' }
test_target = project.targets.find { |t| t.name == 'HueHomeTests' }
abort('HueHome target not found.')      unless app_target
abort('HueHomeTests target not found.') unless test_target

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

# Remove a file reference (and its build-phase entries) ONLY if the file is
# gone from disk — keeps the script runnable before and after the deletion
# commit without ever orphaning a live file.
def prune_if_deleted(project, rel_path)
  abs = File.expand_path(File.join(ROOT, rel_path))
  return 0 if File.exist?(abs)
  refs = project.files.select { |f|
    (File.expand_path(f.real_path.to_s) == abs) rescue false
  }
  return 0 if refs.empty?
  refs.each(&:remove_from_project)
  puts "   xx Pruned dead reference: #{rel_path}"
  refs.length
end

APP_FILES = {
  # Commit 11 — RestSender extracted from the dead Sync-engine stack
  'HueHome/Core/Network/RestSender.swift' => ['HueHome', 'Core', 'Network'],
}

TEST_FILES = {
  # Commit 6 — L-47 observation-firing pin
  'HueHomeTests/AutomationsViewModelTests.swift' => ['HueHomeTests'],
}

# Commit 11 — the dead Sync-engine stack (pruned only once deleted on disk)
DEAD_FILES = [
  'HueHome/UI/Sync/SyncModeEngine.swift',
  'HueHome/UI/Sync/VisualizerEngine.swift',
  'HueHome/UI/Sync/GamingEngine.swift',
  'HueHome/UI/Sync/AmbientEngine.swift',
  'HueHome/UI/Sync/SyncEngineProtocol.swift',
]

existing = existing_paths(project)
changed = 0

APP_FILES.each do |rel, grp|
  changed += add_file(project, app_target, File.join(ROOT, rel), grp, existing)
  existing = existing_paths(project)
end
TEST_FILES.each do |rel, grp|
  changed += add_file(project, test_target, File.join(ROOT, rel), grp, existing)
  existing = existing_paths(project)
end
DEAD_FILES.each do |rel|
  changed += prune_if_deleted(project, rel)
end

if changed > 0
  project.save
  puts "\n  Saved -- #{changed} change(s)."
else
  puts "\n  No changes."
end
