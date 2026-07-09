#!/usr/bin/env ruby
# add_scenes_overhaul_files.rb
# Registers the 2026-07 Scenes-overhaul files (Phases 0–6) in the Xcode project.
# Idempotent — safe to run after each phase; silently skips files that don't
# exist yet and files already registered.

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

APP_FILES = {
  # Phase 0 — ScenesTabView decomposition
  'HueHome/UI/Scenes/SceneMoodCard.swift'          => ['HueHome', 'UI', 'Scenes'],
  'HueHome/UI/Scenes/SceneSpeedSheet.swift'        => ['HueHome', 'UI', 'Scenes'],
  'HueHome/UI/Scenes/RenameSceneSheet.swift'       => ['HueHome', 'UI', 'Scenes'],
  # Phase 1 — grouped IA
  'HueHome/Core/Models/SceneGrouping.swift'        => ['HueHome', 'Core', 'Models'],
  'HueHome/UI/Scenes/SceneRoomSectionView.swift'   => ['HueHome', 'UI', 'Scenes'],
  # Phase 2 — usage store
  'HueHome/Core/Models/SceneUsageStore.swift'      => ['HueHome', 'Core', 'Models'],
  # Phase 3 — saved colors
  'HueHome/Core/Models/SavedColorStore.swift'      => ['HueHome', 'Core', 'Models'],
  'HueHome/UI/Components/SavedColorStrip.swift'    => ['HueHome', 'UI', 'Components'],
  # Phase 5 — scene copy
  'HueHome/Core/Models/SceneCopyEngine.swift'      => ['HueHome', 'Core', 'Models'],
  'HueHome/UI/Scenes/CopySceneSheet.swift'         => ['HueHome', 'UI', 'Scenes'],
}

TEST_FILES = {
  'HueHomeTests/SceneGroupingTests.swift'          => ['HueHomeTests'],
  'HueHomeTests/SceneUsageStoreTests.swift'        => ['HueHomeTests'],
  'HueHomeTests/SavedColorStoreTests.swift'        => ['HueHomeTests'],
  'HueHomeTests/SceneCopyEngineTests.swift'        => ['HueHomeTests'],
}

existing = existing_paths(project)
added = 0

APP_FILES.each do |rel, grp|
  added += add_file(project, app_target, File.join(ROOT, rel), grp, existing)
  existing = existing_paths(project)
end
TEST_FILES.each do |rel, grp|
  added += add_file(project, test_target, File.join(ROOT, rel), grp, existing)
  existing = existing_paths(project)
end

if added > 0
  project.save
  puts "\n  Saved -- #{added} file(s) added."
else
  puts "\n  No changes."
end
