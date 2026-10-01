#!/usr/bin/env ruby
# add_luminous_files.rb
# Registers the Luminous app redesign files (experiment/luminous-app-redesign)
# in the Xcode project. Idempotent — safe to re-run; skips files that don't
# exist yet and files already registered. Same skeleton as
# add_composer2_files.rb.

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
    child = group.children.find { |c| c.respond_to?(:name) && c.name == name } ||
            group.children.find { |c| c.respond_to?(:path) && c.path == name }
    group = child || group.new_group(name, name)
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
  ref   = group.new_reference(resolved)
  target.source_build_phase.add_file_reference(ref) if abs_path.end_with?('.swift')
  puts "   ++ Added: #{group_path.join(' / ')} / #{File.basename(abs_path)}"
  1
end

APP_FILES = {
  'HueHome/UI/Components/LuminousStage.swift'            => ['HueHome', 'UI', 'Components'],
  'HueHome/UI/Components/PhotosensitivityNotice.swift'   => ['HueHome', 'UI', 'Components'],
  'HueHome/UI/Composer2/ComposerLibraryHome.swift'       => ['HueHome', 'UI', 'Composer2'],
  'HueHome/UI/Dashboard/HomeRoomCard.swift'              => ['HueHome', 'UI', 'Dashboard'],
  'HueHome/UI/Dashboard/HomeNowPlaying.swift'            => ['HueHome', 'UI', 'Dashboard'],
  'HueHome/UI/RoomDetail/RoomLightTile.swift'            => ['HueHome', 'UI', 'RoomDetail'],
  'HueHome/UI/RoomDetail/RoomLooksSection.swift'         => ['HueHome', 'UI', 'RoomDetail'],
  'HueHome/UI/Scenes/LuminousSceneCard.swift'            => ['HueHome', 'UI', 'Scenes'],
  # Lane More
  'HueHome/UI/Components/LuminousMoreParts.swift'        => ['HueHome', 'UI', 'Components'],
}

TEST_FILES = {
  'HueHomeTests/LuminousKitTests.swift' => ['HueHomeTests'],
}

existing = existing_paths(project)
added = 0
APP_FILES.each  { |rel, grp| added += add_file(project, app_target,  File.join(ROOT, rel), grp, existing) }
TEST_FILES.each { |rel, grp| added += add_file(project, test_target, File.join(ROOT, rel), grp, existing) }
project.save if added > 0
puts "Done — #{added} file(s) added."
