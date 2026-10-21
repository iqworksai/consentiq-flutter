Pod::Spec.new do |s|
  s.name             = 'consentiq'
  s.version          = '0.0.1'
  s.summary          = 'Writes the IAB TCF keys for the ConsentIQ Flutter SDK.'
  s.description      = <<-DESC
Writes the IABTCF_* keys to UserDefaults.standard, where IAB vendors' SDKs read them.
                       DESC
  s.homepage         = 'https://consent.iqworks.ai'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'IQWorks' => 'https://iqworks.ai' }
  s.source           = { :path => '.' }
  s.source_files = 'consentiq/Sources/consentiq/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = { 'consentiq_privacy' => ['consentiq/Sources/consentiq/PrivacyInfo.xcprivacy'] }
end
