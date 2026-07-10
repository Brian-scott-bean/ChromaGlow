#!/usr/bin/env ruby
# add_siri_intent_files.rb
# Registers the 2026-07 Siri / App Intents files in the Xcode project. The
# HueHome/Intents/ folder had NEVER been registered in any target — the app
# shipped zero working Siri commands before this run. Lists every file for
# the whole Siri feature train; idempotent — safe to re-run, silently skips
# files that don't exist yet and files already registered.

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
  # B1 — foundation
  'HueHome/Intents/HueGroupEntity.swift'     => ['HueHome', 'Intents'],
  'HueHome/Intents/HueIntents.swift'         => ['HueHome', 'Intents'],
  'HueHome/Intents/HueAppShortcuts.swift'    => ['HueHome', 'Intents'],
  'HueHome/Intents/HueIntentAPIClient.swift' => ['HueHome', 'Intents'],
  # B3 — color
  'HueHome/Intents/SiriColorTable.swift'     => ['HueHome', 'Intents'],
  # B4 — scenes
  'HueHome/Intents/HueSceneEntity.swift'     => ['HueHome', 'Intents'],
  # B7/B8 — open-app studio intents
  'HueHome/Intents/StudioIntents.swift'      => ['HueHome', 'Intents'],
}

TEST_FILES = {
  'HueHomeTests/HueIntentEntityTests.swift'  => ['HueHomeTests'],
  'HueHomeTests/SiriColorTableTests.swift'   => ['HueHomeTests'],
  'HueHomeTests/HueIntentClientTests.swift'  => ['HueHomeTests'],
  'HueHomeTests/StudioIntentTests.swift'     => ['HueHomeTests'],
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
