#!/usr/bin/env ruby
# add_play_along_files.rb
# Registers the Play Along files (experiment/play-along) in the Xcode project.
# Idempotent — safe to re-run; skips files that don't exist yet and files
# already registered. Same skeleton as add_composer2_files.rb.

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

NETWORK  = ['HueHome', 'Core', 'Network']
AUDIO    = ['HueHome', 'Core', 'Audio']
MUSIC    = ['HueHome', 'Core', 'Music']
CORE_C2  = ['HueHome', 'Core', 'Composer2']
UI_C2    = ['HueHome', 'UI', 'Composer2']
TESTS    = ['HueHomeTests']

APP_FILES = {
  'HueHome/Core/Network/FrameDeadlinePacer.swift'      => NETWORK,
  'HueHome/Core/Audio/OnsetFrameAnalyzer.swift'        => AUDIO,
  'HueHome/Core/Audio/BeatTracker.swift'               => AUDIO,
  'HueHome/Core/Audio/OutputLatencyModel.swift'        => AUDIO,
  'HueHome/Core/Audio/MicrophoneHopRelay.swift'        => AUDIO,
  'HueHome/Core/Music/SongMemory.swift'                => MUSIC,
  'HueHome/Core/Composer2/Composer2PlayAlong.swift'    => CORE_C2,
  'HueHome/Core/Composer2/Composer2PlayAlongDirector.swift' => CORE_C2,
  'HueHome/Core/Composer2/Composer2Quantizer.swift'    => CORE_C2,
  'HueHome/Core/Composer2/Composer2LandingSource.swift' => CORE_C2,
  'HueHome/Core/Composer2/Composer2AlbumPalette.swift' => CORE_C2,
  'HueHome/UI/Composer2/Composer2PlayAlongControls.swift' => UI_C2,
}

TEST_FILES = {
  'HueHomeTests/PlayAlongTestSynth.swift'              => TESTS,
  'HueHomeTests/FrameDeadlinePacerTests.swift'         => TESTS,
  'HueHomeTests/OnsetFrameAnalyzerTests.swift'         => TESTS,
  'HueHomeTests/BeatTrackerTests.swift'                => TESTS,
  'HueHomeTests/BeatClockPlayAlongTests.swift'         => TESTS,
  'HueHomeTests/OutputLatencyModelTests.swift'         => TESTS,
  'HueHomeTests/SongMemoryTests.swift'                 => TESTS,
  'HueHomeTests/Composer2LabPlayAlongTests.swift'      => TESTS,
  'HueHomeTests/Composer2LabQuantizerTests.swift'      => TESTS,
  'HueHomeTests/Composer2LabAlbumPaletteTests.swift'   => TESTS,
  'HueHomeTests/MicrophoneHopRelayTests.swift'         => TESTS,
}

existing = existing_paths(project)
added = 0
APP_FILES.each  { |rel, grp| added += add_file(project, app_target,  File.join(ROOT, rel), grp, existing) }
TEST_FILES.each { |rel, grp| added += add_file(project, test_target, File.join(ROOT, rel), grp, existing) }

if added > 0
  project.save
  puts "✅ Registered #{added} file(s)."
else
  puts "Nothing to add."
end
