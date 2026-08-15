# Automate serpapi-zig end to end
#
# rake --tasks
#
# The Zig build system does the real work; these tasks mirror the
# serpapi-ruby Rakefile so every SerpApi library automates the same steps.

# Cross-compilation targets, named after the CPU architectures listed in
# https://zig.guide/build-system/cross-compilation
# Zig spells i386 as "x86"; every other name maps one to one.
TARGETS = {
  'x86_64' => 'x86_64-linux',
  'arm' => 'arm-linux',
  'aarch64' => 'aarch64-linux',
  'i386' => 'x86-linux',
  'riscv64' => 'riscv64-linux',
  'wasm32' => 'wasm32-wasi'
}.freeze

desc 'run out of box testing using the local build'
task oobt: %i[lint build] do
  sh 'zig build oobt'
end

desc 'execute all the steps except release'
task default: %i[lint build test doc]

desc 'build the library and the demo application'
task :build do
  sh 'zig build'
end

desc 'run unit tests (no network access)'
task :test do
  sh 'zig build test --summary all'
end

desc 'run integration tests against serpapi.com (needs SERPAPI_KEY)'
task :itest do
  sh 'zig build itest --summary all'
end

desc 'measure code coverage with kcov (needs kcov, SERPAPI_KEY)'
task :cov do
  sh 'zig build cov'
  puts 'report: zig-out/coverage/merged/kcov-merged/index.html'
end

desc 'check formatting with zig fmt'
task :lint do
  sh 'zig build lint'
end

desc 'format the code in place'
task :format do
  sh 'zig fmt build.zig src test oobt bench'
end

desc 'build the API documentation'
task :doc do
  sh 'zig build doc'
  puts 'documentation: zig-out/docs/index.html'
end

desc 'benchmark persistent vs non-persistent connections (needs SERPAPI_KEY)'
task :bench do
  sh 'zig build bench'
end

desc 'delete build artifacts'
task :clean do
  rm_rf 'zig-out'
  rm_rf '.zig-cache'
end

desc "cross-compile for every architecture: #{TARGETS.keys.join(', ')}"
task cross: TARGETS.keys.map { |arch| :"cross:#{arch}" }

namespace :cross do
  TARGETS.each do |arch, triple|
    desc "cross-compile for #{arch} (#{triple})"
    task arch do
      sh "zig build -Dtarget=#{triple} -Doptimize=ReleaseSafe --prefix zig-out/#{arch}"
      puts "built: zig-out/#{arch}/bin/"
    end
  end

  desc 'run the unit tests for every architecture through QEMU (Linux targets)'
  task :test do
    TARGETS.each do |arch, triple|
      next if triple.start_with?('wasm32') # no sockets under wasi

      sh "zig build test -Dtarget=#{triple} -fqemu --summary all"
      puts "tests passed on #{arch}"
    end
  end
end

namespace :install do
  desc 'install QEMU on macOS to run foreign-architecture binaries'
  task :qemu do
    sh 'brew install qemu'
    puts 'QEMU installed. Cross-architecture tests: rake cross:test'
  end

  desc 'install kcov on macOS for code coverage'
  task :kcov do
    sh 'brew install kcov'
  end
end

desc 'release: tag the current version and push it to GitHub'
task :release do
  version = File.read('build.zig.zon')[/\.version\s*=\s*"([^"]+)"/, 1]
  raise 'cannot read version from build.zig.zon' if version.nil?

  puts "releasing v#{version}"
  sh 'git diff --quiet' do |ok, _|
    raise 'working tree is dirty, commit first' unless ok
  end
  sh "git tag -a v#{version} -m 'Release v#{version}'"
  sh 'git push origin master --tags'
  puts "released: https://github.com/serpapi/serpapi-zig/releases/tag/v#{version}"
end
