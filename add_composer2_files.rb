#!/usr/bin/env ruby
# add_composer2_files.rb
# Registers the Composer 2 lab files (experiment/composer-2-dream-studio) in
# the Xcode project: HueHome/Core/Composer2, HueHome/UI/Composer2(/Editors)
# and the Composer2Lab* tests. Idempotent — safe to re-run; skips files that
# don't exist yet and files already registered. Same skeleton as
# add_music_files.rb.

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

CORE = ['HueHome', 'Core', 'Composer2']
UI   = ['HueHome', 'UI', 'Composer2']
EDIT = ['HueHome', 'UI', 'Composer2', 'Editors']

APP_FILES = {
  'HueHome/Core/Composer2/Composer2Random.swift'        => CORE,
  'HueHome/Core/Composer2/Composer2Palette.swift'       => CORE,
  'HueHome/Core/Composer2/Composer2Space.swift'         => CORE,
  'HueHome/Core/Composer2/Composer2Motion.swift'        => CORE,
  'HueHome/Core/Composer2/Composer2Rhythm.swift'        => CORE,
  'HueHome/Core/Composer2/Composer2Modulation.swift'    => CORE,
  'HueHome/Core/Composer2/Composer2Events.swift'        => CORE,
  'HueHome/Core/Composer2/Composer2Models.swift'        => CORE,
  'HueHome/Core/Composer2/Composer2Engine.swift'        => CORE,
  'HueHome/Core/Composer2/Composer2LiveOutput.swift'    => CORE,
  'HueHome/Core/Composer2/Composer2PresetLibrary.swift' => CORE,
  'HueHome/Core/Composer2/Composer2Store.swift'         => CORE,
  'HueHome/Core/Composer2/Composer2LegacyImport.swift'  => CORE,
  # v2.2 — the theme library
  'HueHome/Core/Composer2/Composer2ThemeCatalog.swift'  => CORE,
  'HueHome/Core/Composer2/Composer2Presets+Seasons.swift' => CORE,
  'HueHome/Core/Composer2/Composer2Presets+World.swift' => CORE,
  'HueHome/Core/Composer2/Composer2BehaviorLibrary.swift' => CORE,

  'HueHome/UI/Composer2/Composer2Theme.swift'           => UI,
  'HueHome/UI/Composer2/Composer2Document.swift'        => UI,
  'HueHome/UI/Composer2/Composer2SlotLayout.swift'      => UI,
  'HueHome/UI/Composer2/Composer2PreviewFeed.swift'     => UI,
  'HueHome/UI/Composer2/Composer2LiveGateway.swift'     => UI,
  'HueHome/UI/Composer2/Composer2PlaybackCenter.swift'  => UI,
  'HueHome/UI/Composer2/Composer2View.swift'            => UI,
  'HueHome/UI/Composer2/Composer2Header.swift'          => UI,
  'HueHome/UI/Composer2/Composer2HeroCard.swift'        => UI,
  'HueHome/UI/Composer2/Composer2ModeSelector.swift'    => UI,
  'HueHome/UI/Composer2/Composer2MiniPreviews.swift'    => UI,
  'HueHome/UI/Composer2/Composer2PerformanceBar.swift'  => UI,
  'HueHome/UI/Composer2/Composer2EntryCard.swift'       => UI,
  # v2.2 — the luminous redesign
  'HueHome/UI/Composer2/Composer2Controls.swift'        => UI,
  'HueHome/UI/Composer2/Composer2LookCard.swift'        => UI,
  'HueHome/UI/Composer2/Composer2LibraryView.swift'     => UI,
  'HueHome/UI/Composer2/Composer2TuneView.swift'        => UI,
  'HueHome/UI/Composer2/Composer2LayersView.swift'      => UI,
  'HueHome/UI/Composer2/Composer2Ambience.swift'        => UI,

  'HueHome/UI/Composer2/Editors/Composer2EditorScaffold.swift' => EDIT,
  'HueHome/UI/Composer2/Editors/Composer2PaletteEditor.swift'  => EDIT,
  'HueHome/UI/Composer2/Editors/Composer2MotionEditor.swift'   => EDIT,
  'HueHome/UI/Composer2/Editors/Composer2RhythmEditor.swift'   => EDIT,
  'HueHome/UI/Composer2/Editors/Composer2SpaceEditor.swift'    => EDIT,
  'HueHome/UI/Composer2/Editors/Composer2AudioEditor.swift'    => EDIT,
  'HueHome/UI/Composer2/Editors/Composer2VariationEditor.swift'=> EDIT,
  'HueHome/UI/Composer2/Editors/Composer2EventsEditor.swift'   => EDIT,
}

TEST_FILES = {
  'HueHomeTests/Composer2LabPrimitiveTests.swift'   => ['HueHomeTests'],
  'HueHomeTests/Composer2LabLayerTests.swift'       => ['HueHomeTests'],
  'HueHomeTests/Composer2LabEventTests.swift'       => ['HueHomeTests'],
  'HueHomeTests/Composer2LabEngineTests.swift'      => ['HueHomeTests'],
  'HueHomeTests/Composer2LabPersistenceTests.swift' => ['HueHomeTests'],
  'HueHomeTests/Composer2LabPresetTests.swift'      => ['HueHomeTests'],
  'HueHomeTests/Composer2LabLifecycleTests.swift'   => ['HueHomeTests'],
  'HueHomeTests/Composer2LabGuardTests.swift'       => ['HueHomeTests'],
  'HueHomeTests/Composer2LabSnapshotTests.swift'    => ['HueHomeTests'],
  'HueHomeTests/Composer2LabSlotTests.swift'        => ['HueHomeTests'],
  'HueHomeTests/Composer2LabIntegrationTests.swift' => ['HueHomeTests'],
  'HueHomeTests/Composer2LabRecoveryTests.swift'    => ['HueHomeTests'],
  'HueHomeTests/Composer2LabPerformanceTests.swift' => ['HueHomeTests'],
  # v2.2
  'HueHomeTests/Composer2LabThemeTests.swift'       => ['HueHomeTests'],
}

# Files the redesign retired: drop their references (idempotent).
REMOVED_FILES = %w[
  Composer2QuickPanel.swift Composer2CustomizeGrid.swift Composer2AdvancedPanel.swift
  Composer2ExpertStack.swift Composer2LayerCard.swift
]
removed = 0
project.files.select { |f| REMOVED_FILES.include?(File.basename(f.path.to_s)) }.each do |ref|
  ref.build_files.each { |bf| bf.remove_from_project }
  ref.remove_from_project
  puts "   -- Removed: #{File.basename(ref.path.to_s)}"
  removed += 1
end

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

if added > 0 || removed > 0
  project.save
  puts "\n  Saved -- #{added} file(s) added, #{removed} removed."
else
  puts "\n  No changes."
end
