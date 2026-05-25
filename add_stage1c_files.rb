#!/usr/bin/env ruby
# add_stage1c_files.rb
# Adds @Observable migration + new test files to the Xcode project.
# Idempotent — safe to run multiple times.

require 'xcodeproj'

PROJECT_PATH = File.join(File.dirname(__FILE__), 'ChromaGlow.xcodeproj')
SOURCE_ROOT  = File.join(File.dirname(__FILE__), 'ChromaGlow')
TESTS_ROOT   = File.join(File.dirname(__FILE__), 'ChromaGlowTests')

puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "  ChromaGlow — Stage 1C File Sync"
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"

project    = Xcodeproj::Project.open(PROJECT_PATH)
app_target  = project.targets.find { |t| t.name == 'ChromaGlow' }
test_target = project.targets.find { |t| t.name == 'ChromaGlowTests' }
abort("❌ ChromaGlow target not found.") unless app_target
abort("❌ ChromaGlowTests target not found. Run add_missing_files.rb first.") unless test_target

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
    puts "   ⏭  Already in project: #{File.basename(abs_path)}"
    return 0
  end
  group = ensure_group(project, group_path)
  ref   = group.new_file(abs_path)
  target.source_build_phase.add_file_reference(ref) if abs_path.end_with?('.swift')
  puts "   ✅ Added: #{group_path.join(' / ')} / #{File.basename(abs_path)}"
  1
end

existing = existing_paths(project)
added = 0

puts "🧪 Test files:"
TEST_FILES = {
  File.join(TESTS_ROOT, 'HueTokensTests.swift')          => ['ChromaGlowTests'],
  File.join(TESTS_ROOT, 'HueDataModelsTests.swift')      => ['ChromaGlowTests'],
  File.join(TESTS_ROOT, 'DashboardViewModelTests.swift') => ['ChromaGlowTests'],
}

TEST_FILES.each do |path, grp|
  added += add_file(project, test_target, path, grp, existing)
  existing = existing_paths(project)
end

if added > 0
  project.save
  puts "\n💾 Project saved — #{added} file(s) added."
else
  puts "\nℹ️  No changes — all Stage 1C files already in project."
end

puts "\n  Next: ⌘U to run all tests\n"
