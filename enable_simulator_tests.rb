#!/usr/bin/env ruby
# enable_simulator_tests.rb
# Adds SUPPORTED_PLATFORMS = iphoneos iphonesimulator to HueHomeTests
# so xcodebuild test can run on simulator from command line.

require 'xcodeproj'

p = Xcodeproj::Project.open(File.join(File.dirname(__FILE__), 'HueHome.xcodeproj'))
test_target = p.targets.find { |t| t.name == 'HueHomeTests' }
abort('HueHomeTests not found') unless test_target

test_target.build_configurations.each do |cfg|
  cfg.build_settings['SUPPORTED_PLATFORMS'] = 'iphonesimulator iphoneos'
end

p.save
puts 'Done -- HueHomeTests now supports both iphoneos and iphonesimulator'
