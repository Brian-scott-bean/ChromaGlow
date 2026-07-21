#!/usr/bin/env ruby
# add_music_files.rb
# Registers the 2026-07 music-integration files (design doc:
# docs/ios/music-integration-design-2026-07.md) in the Xcode project.
# Lists every file for the whole music feature train (R1 core → R5 Spotify);
# idempotent — safe to re-run, silently skips files that don't exist yet and
# files already registered.

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
  # R1 — core layer
  'HueHome/Core/FeatureFlags.swift'                  => ['HueHome', 'Core'],
  'HueHome/Core/Music/MusicSource.swift'             => ['HueHome', 'Core', 'Music'],
  'HueHome/Core/Music/MockMusicSource.swift'         => ['HueHome', 'Core', 'Music'],
  'HueHome/Core/Music/TrackTempoResolver.swift'      => ['HueHome', 'Core', 'Music'],
  'HueHome/Core/Music/ArtworkPaletteExtractor.swift' => ['HueHome', 'Core', 'Music'],
  'HueHome/Core/Music/MusicSessionCoordinator.swift' => ['HueHome', 'Core', 'Music'],
  # R2 — Now Playing UI
  'HueHome/UI/Music/NowPlayingBar.swift'             => ['HueHome', 'UI', 'Music'],
  'HueHome/UI/Music/MusicSourcePicker.swift'         => ['HueHome', 'UI', 'Music'],
  # R3 — Apple Music + live tempo providers
  'HueHome/Core/Music/AppleMusicSource.swift'        => ['HueHome', 'Core', 'Music'],
  'HueHome/Core/Music/TempoProviders.swift'          => ['HueHome', 'Core', 'Music'],
  # R4 — Shazam auto-detect
  'HueHome/Core/Music/ShazamSource.swift'            => ['HueHome', 'Core', 'Music'],
  # R5 — Spotify (dev-flagged)
  'HueHome/Core/Music/SpotifyAuthService.swift'      => ['HueHome', 'Core', 'Music'],
  'HueHome/Core/Music/SpotifyAPIClient.swift'        => ['HueHome', 'Core', 'Music'],
  'HueHome/Core/Music/SpotifySource.swift'           => ['HueHome', 'Core', 'Music'],
}

TEST_FILES = {
  'HueHomeTests/BeatClockServiceDriveTests.swift'    => ['HueHomeTests'],
  'HueHomeTests/TrackTempoResolverTests.swift'       => ['HueHomeTests'],
  'HueHomeTests/ArtworkPaletteTests.swift'           => ['HueHomeTests'],
  'HueHomeTests/MusicSourceContractTests.swift'      => ['HueHomeTests'],
  'HueHomeTests/MusicSourcePickerModelTests.swift'   => ['HueHomeTests'],
  'HueHomeTests/MusicUISnapshotTests.swift'          => ['HueHomeTests'],
  'HueHomeTests/AppleMusicMappingTests.swift'        => ['HueHomeTests'],
  'HueHomeTests/TempoProviderTests.swift'            => ['HueHomeTests'],
  'HueHomeTests/ShazamPolicyTests.swift'             => ['HueHomeTests'],
  'HueHomeTests/SpotifyAuthTests.swift'              => ['HueHomeTests'],
  'HueHomeTests/MicDemandPolicyTests.swift'          => ['HueHomeTests'],
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
