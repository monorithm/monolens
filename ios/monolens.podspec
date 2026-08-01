#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint monolens.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'monolens'
  s.version          = '0.4.0'
  s.summary          = 'Camera capture and on-device media editing.'
  s.description      = <<-DESC
Camera capture, image crop/rotate and ffmpeg-free video trim, backed by AVFoundation.
                       DESC
  s.homepage         = 'https://github.com/monorithm/monolens'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Monorithm' => 'engineering@monorithm.com' }
  s.source           = { :path => '.' }
  s.source_files = 'monolens/Sources/monolens/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # MediaProbe reads file attributes, a required-reason API, so the manifest is
  # declared rather than left as the template's commented-out placeholder. It
  # has to be bundled here *and* in Package.swift: CocoaPods and SPM each build
  # this plugin, and a consumer using the other one would ship without it and
  # hit ITMS-91053 at submission.
  s.resource_bundles = {'monolens_privacy' => ['monolens/Sources/monolens/PrivacyInfo.xcprivacy']}
end
