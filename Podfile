source 'https://github.com/CocoaPods/Specs.git'

minVersion = '12.0'

platform :osx, minVersion

# cocoapods-prune-localizations doesn't appear to auto-detect pods properly, so using a manual list
supported_locales = ['Base', 'da', 'de', 'en', 'es', 'fr', 'it', 'ja', 'ko', 'nl', 'pt-BR', 'sv', 'tr', 'zh-Hans']
# plugin 'cocoapods-prune-localizations', { :localizations => supported_locales }

target "SelfControl" do
    use_frameworks! :linkage => :static
    pod 'MASPreferences', '~> 1.1.4'
    pod 'TransformerKit', '~> 1.1.1'
    pod 'FormatterKit/TimeIntervalFormatter', '~> 1.8.0'
    pod 'LetsMove', '~> 1.24'
    
    # Add test target
    target 'SelfControlTests' do
        inherit! :complete
    end
end

target "SelfControl Killer" do
    use_frameworks! :linkage => :static
end

# we can't use_frameworks on these because they're command-line tools
# Sentry says we need use_frameworks, but they seem to work OK anyway?
target "SCKillerHelper" do
end
target "selfcontrol-cli" do
end
target "org.eyebeam.selfcontrold" do
end

# fork: these old pod versions don't compile against current macOS SDKs; patch them in place
def patch_pod_file(path, from, to)
    return unless File.exist?(path)
    s = File.read(path)
    return unless s.include?(from)
    File.chmod(File.stat(path).mode | 0200, path)
    File.write(path, s.gsub(from, to))
end

# fork: CocoaPods expects static-framework resources at the framework root, but macOS
# frameworks keep them under Resources/. Fix the generated copy-resources scripts.
post_integrate do |pi|
   Dir.glob('Pods/Target Support Files/*/*-resources.sh').each do |f|
       patch_pod_file(f, 'MASPreferences.framework/en.lproj/', 'MASPreferences.framework/Resources/en.lproj/')
   end
end

post_install do |pi|
   Dir.glob('Pods/TransformerKit/Sources/*.{h,m}').each do |f|
       patch_pod_file(f, '@import Darwin.Availability;', '#import <Availability.h>')
       patch_pod_file(f, '@import Darwin.C.time;', '#import <time.h>')
       patch_pod_file(f, '@import Darwin.C.xlocale;', '#import <xlocale.h>')
   end

   pi.pods_project.targets.each do |t|
       t.build_configurations.each do |bc|
           if Gem::Version.new(bc.build_settings['MACOSX_DEPLOYMENT_TARGET']) < Gem::Version.new(minVersion)
#            if bc.build_settings['MACOSX_DEPLOYMENT_TARGET'] == '8.0'
               bc.build_settings['MACOSX_DEPLOYMENT_TARGET'] = minVersion
           end
       end
   end
end
