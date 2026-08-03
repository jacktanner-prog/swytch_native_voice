Pod::Spec.new do |s|
  s.name             = 'swytch_native_voice'
  s.version          = '0.1.0'
  s.summary          = 'Native Twilio Voice bridge for Swytch Mobile.'
  s.description      = <<-DESC
Isolated PushKit, CallKit and Twilio Voice integration for Swytch Mobile.
                       DESC
  s.homepage         = 'https://swytchmobile.com'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Swytch' }
  s.author           = { 'Swytch' => 'support@swytchmobile.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'TwilioVoice', '~> 6.13'
  s.platform = :ios, '15.0'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
