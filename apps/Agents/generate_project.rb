# Regenerates Agents.xcodeproj from the files in Agents/.
# Usage: gem install xcodeproj && ruby generate_project.rb
require 'xcodeproj'

ROOT = __dir__
path = File.join(ROOT, 'Agents.xcodeproj')
project = Xcodeproj::Project.new(path)
project.root_object.attributes['LastSwiftUpdateCheck'] = '1600'
project.root_object.attributes['LastUpgradeCheck'] = '1600'

target = project.new_target(:application, 'Agents', :ios, '17.0')
# new_target links an iOS-only Foundation.framework path; SwiftUI apps don't need it (and it breaks macOS).
target.frameworks_build_phase.files.dup.each do |build_file|
  ref = build_file.file_ref
  build_file.remove_from_project
  ref&.remove_from_project
end
project.frameworks_group.remove_from_project if project.frameworks_group.children.empty?
group = project.main_group.new_group('Agents', 'Agents')

sources = Dir.glob(File.join(ROOT, 'Agents', '**', '*.swift')).sort
sources.each do |file|
  rel = file.sub(File.join(ROOT, 'Agents') + '/', '')
  ref = group.new_file(rel)
  target.source_build_phase.add_file_reference(ref)
end
assets = group.new_file('Assets.xcassets')
target.resources_build_phase.add_file_reference(assets)
%w[Info.plist Agents-iOS.entitlements Agents-macOS.entitlements].each { |f| group.new_file(f) }

project.root_object.attributes['TargetAttributes'] = {
  target.uuid => { 'CreatedOnToolsVersion' => '16.0' }
}

target.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_NAME'] = 'Agents'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.keoly.agents'
  s['MARKETING_VERSION'] = '1.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '5.0'
  s['SDKROOT'] = 'auto'
  s['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator macosx'
  s['SUPPORTS_MACCATALYST'] = 'NO'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  s['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['DEVELOPMENT_TEAM'] = '2KTZ966L7U'
  s['CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]'] = 'Agents/Agents-iOS.entitlements'
  s['CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]'] = 'Agents/Agents-iOS.entitlements'
  s['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]'] = 'Agents/Agents-macOS.entitlements'
  s['ENABLE_HARDENED_RUNTIME'] = 'YES'
  s['ENABLE_PREVIEWS'] = 'YES'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['INFOPLIST_FILE'] = 'Agents/Info.plist'
  s['INFOPLIST_KEY_CFBundleDisplayName'] = 'Agents'
  s['INFOPLIST_KEY_LSApplicationCategoryType'] = 'public.app-category.productivity'
  # Only HTTPS to AI providers: exempt from export-compliance paperwork.
  s['INFOPLIST_KEY_ITSAppUsesNonExemptEncryption'] = 'NO'
  s['INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphone*]'] = 'YES'
  s['INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphone*]'] = 'YES'
  s['INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone'] = 'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'
  s['INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad'] = 'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  s['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
  s['LD_RUNPATH_SEARCH_PATHS[sdk=iphone*]'] = ['$(inherited)', '@executable_path/Frameworks']
  s['LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]'] = ['$(inherited)', '@executable_path/../Frameworks']
  s['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  s.delete('LD_RUNPATH_SEARCH_PATHS')
end

project.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  config.build_settings['SWIFT_VERSION'] = '5.0'
end

project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(target, nil, launch_target: true)
scheme.save_as(path, 'Agents', true)
puts "Wrote #{path} with #{sources.size} Swift files"
