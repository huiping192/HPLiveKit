#
# Be sure to run `pod lib lint HPLiveKit.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'HPLiveKit'
  s.version          = '0.1.0'
  s.summary          = 'Swift rtmp base live streaming lib.'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = "Swift rtmp base live streaming lib"

  s.homepage         = 'https://github.com/huiping192/HPLiveKit'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'HuipingGuo' => 'huiping192@gmail.com' }
  s.source           = { :git => 'https://github.com/huiping192/HPLiveKit.git', :tag => s.version.to_s }
  s.social_media_url = 'https://twitter.com/huiping192'

  s.ios.deployment_target = '8.0'
  s.swift_version = '4.0'
  s.source_files = 'Sources/HPLiveKit/**/*.{swift,h,m}'
  
  s.frameworks = "VideoToolbox", "AudioToolbox","AVFoundation","Foundation","UIKit"
  s.dependency 'HPLibRTMP' , '~> 0.0.3'

end
