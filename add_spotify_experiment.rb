#!/usr/bin/env ruby
# add_spotify_experiment.rb
# Wires the LOCAL-ONLY Spotify Connect PCM experiment
# (docs/ios/local-spotify-pcm-experiment.md) into the Xcode project.
# Idempotent — safe to re-run.
#
#  1. Registers the audio-source boundary + experiment Swift files.
#  2. Adds the "Debug-SpotifyExperimental" build configuration to the project
#     and EVERY target (a clone of Debug). Only the app + unit-test targets get
#     CHROMAGLOW_EXPERIMENTAL_SPOTIFY; only the app links the Rust receiver.
#     Debug and Release are untouched.
#  3. Adds the "Spotify Experiment Plist" run-script phase (a no-op outside
#     Debug-SpotifyExperimental).
#  4. Writes the shared "HueHome Spotify Experimental" scheme (Run/Test/Analyze
#     on Debug-SpotifyExperimental; Profile/Archive stay on Release).

require 'xcodeproj'
require 'set'

PROJECT_PATH = File.join(File.dirname(__FILE__), 'HueHome.xcodeproj')
ROOT         = File.dirname(__FILE__)
CONFIG       = 'Debug-SpotifyExperimental'
FLAG         = 'CHROMAGLOW_EXPERIMENTAL_SPOTIFY'
PHASE_NAME   = 'Spotify Experiment Plist'
SCHEME_NAME  = 'HueHome Spotify Experimental'

project     = Xcodeproj::Project.open(PROJECT_PATH)
app_target  = project.targets.find { |t| t.name == 'HueHome' }
test_target = project.targets.find { |t| t.name == 'HueHomeTests' }
abort('HueHome target not found.')      unless app_target
abort('HueHomeTests target not found.') unless test_target

# ── 1. Files ────────────────────────────────────────────────────────────────

def existing_paths(project)
  project.files.map { |f| File.expand_path(f.real_path.to_s) rescue nil }.compact.to_set
end

def ensure_group(project, path_components)
  group = project.main_group
  path_components.each do |name|
    # This project's groups are path-less; files carry root-relative paths.
    child = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == name }
    group = child || group.new_group(name)
  end
  group
end

def add_file(project, target, rel_path, group_path, existing)
  abs_path = File.join(ROOT, rel_path)
  return 0 unless File.exist?(abs_path)
  if existing.include?(File.expand_path(abs_path))
    puts "   -- Already in project: #{File.basename(abs_path)}"
    return 0
  end
  group = ensure_group(project, group_path)
  ref   = group.new_reference(abs_path)
  target.source_build_phase.add_file_reference(ref)
  puts "   ++ Added: #{group_path.join(' / ')} / #{File.basename(abs_path)}"
  1
end

APP_FILES = {
  'HueHome/Core/Audio/AudioAnalysisSource.swift'                           => %w[HueHome Core Audio],
  'HueHome/Core/Audio/MicrophoneAudioSource.swift'                         => %w[HueHome Core Audio],
  'HueHome/Experimental/SpotifyConnect/SpotifyPCMSource.swift'             => %w[HueHome Experimental SpotifyConnect],
  'HueHome/Experimental/SpotifyConnect/SpotifyConnectReceiver.swift'       => %w[HueHome Experimental SpotifyConnect],
  'HueHome/Experimental/SpotifyConnect/SpotifyPlaybackOutput.swift'        => %w[HueHome Experimental SpotifyConnect],
  'HueHome/Experimental/SpotifyConnect/SpotifyConnectExperimentSection.swift' => %w[HueHome Experimental SpotifyConnect],
}

TEST_FILES = {
  'HueHomeTests/AudioAnalysisSourceTests.swift'    => %w[HueHomeTests],
  'HueHomeTests/SpotifyPCMExperimentTests.swift'   => %w[HueHomeTests],
}

existing = existing_paths(project)
added = 0
puts '-> Source files'
APP_FILES.each  { |p, g| added += add_file(project, app_target, p, g, existing) }
TEST_FILES.each { |p, g| added += add_file(project, test_target, p, g, existing) }

# ── 2. Build configuration ──────────────────────────────────────────────────

def clone_debug(list, project)
  return list.build_configurations.find { |c| c.name == CONFIG } if list.build_configurations.any? { |c| c.name == CONFIG }
  debug = list.build_configurations.find { |c| c.name == 'Debug' }
  abort("No Debug configuration in #{list}") unless debug
  config = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  config.name = CONFIG
  config.build_settings = Marshal.load(Marshal.dump(debug.build_settings))
  config.base_configuration_reference = debug.base_configuration_reference
  list.build_configurations << config
  puts "   ++ #{CONFIG} cloned from Debug"
  config
end

def add_flag(config)
  conds = config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] || '$(inherited)'
  conds = conds.join(' ') if conds.is_a?(Array)
  conds = "#{conds} #{FLAG}" unless conds.split(/\s+/).include?(FLAG)
  config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = conds
end

puts '-> Build configuration'
clone_debug(project.build_configuration_list, project)
project.targets.each { |t| clone_debug(t.build_configuration_list, project) }

receiver = '$(SRCROOT)/Experimental/SpotifyReceiver'
app_config = app_target.build_configuration_list.build_configurations.find { |c| c.name == CONFIG }
add_flag(app_config)
app_config.build_settings['SWIFT_INCLUDE_PATHS']  = "$(inherited) #{receiver}/include"
app_config.build_settings['LIBRARY_SEARCH_PATHS'] = "$(inherited) #{receiver}/build/$(PLATFORM_NAME)"
app_config.build_settings['OTHER_LDFLAGS'] =
  '$(inherited) -lchromaglow_spotify -liconv -framework Security -framework CoreFoundation'

test_config = test_target.build_configuration_list.build_configurations.find { |c| c.name == CONFIG }
add_flag(test_config)
test_config.build_settings['SWIFT_INCLUDE_PATHS'] = "$(inherited) #{receiver}/include"

# ── 3. Run-script phase ─────────────────────────────────────────────────────

puts '-> Run-script phase'
unless app_target.shell_script_build_phases.any? { |p| p.name == PHASE_NAME }
  phase = app_target.new_shell_script_build_phase(PHASE_NAME)
  phase.shell_script = "\"${SRCROOT}/Scripts/inject_spotify_experiment_plist.sh\"\n" \
                       "touch \"${DERIVED_FILE_DIR}/chromaglow-spotify-experiment-plist.stamp\"\n"
  phase.input_paths  = ['$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)']
  phase.output_paths = ['$(DERIVED_FILE_DIR)/chromaglow-spotify-experiment-plist.stamp']
  puts "   ++ #{PHASE_NAME}"
else
  puts "   -- #{PHASE_NAME} already present"
end

project.save

# ── 4. Scheme ───────────────────────────────────────────────────────────────

puts '-> Scheme'
schemes_dir = File.join(PROJECT_PATH, 'xcshareddata', 'xcschemes')
source = File.join(schemes_dir, 'HueHome 1.xcscheme')
dest   = File.join(schemes_dir, "#{SCHEME_NAME}.xcscheme")
xml = File.read(source)
%w[TestAction LaunchAction AnalyzeAction].each do |action|
  xml = xml.sub(/(<#{action}\b[^>]*?buildConfiguration\s*=\s*")Debug(")/m, "\\1#{CONFIG}\\2")
end
File.write(dest, xml)
puts "   ++ #{File.basename(dest)} (Run/Test/Analyze: #{CONFIG}; Profile/Archive: Release)"

puts "Done (#{added} file(s) added)."
